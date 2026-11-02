import Encoders
import FluidAudio
import Foundation

/// Tuning for batch (`-i`) and end-of-capture diarization: hark's own
/// per-utterance clustering (`SpeakerClustering`) over voice embeddings from
/// FluidAudio's offline (pyannote community-1) pipeline, and the configuration
/// that pipeline runs with when its own timeline is wanted.
enum DiarizationDefaults {
    /// Default cut for hark's utterance clustering (`--speaker-threshold`):
    /// the cosine distance between clusters of utterance embeddings above
    /// which they stay separate speakers. Measured on a three-woman film scene:
    /// utterances by one voice sit around 0.74 apart (p90 0.91), two voices
    /// around 0.84 (p10 0.69), so the metric is tight; `0.8` lands nearest the
    /// true count there, `0.7` splits a voice into several, `0.9` merges all
    /// three. When the cast is known, equal `--min-speakers`/`--max-speakers`
    /// are the reliable route. (`Double` so `config show` renders it.)
    static let clusteringThreshold: Double = 0.8

    /// Shortest zero-vote stretch (seconds) the pipeline re-embeds on its own.
    ///
    /// A local speaker that got no embedding in any window (anything under the
    /// pipeline's 1 s embedding floor) would otherwise be tie-broken onto
    /// cluster 0 and absorbed by the surrounding speaker. Re-embedding the exact
    /// span is what keeps a one-word answer with its own voice.
    static let reembedFloorSeconds: Double = 0.4

    /// The `OfflineDiarizerConfig` behind the diarizer's own timeline
    /// (`--diarize-only`, and the text-only apple engine). `minSpeakers`/
    /// `maxSpeakers` bound the speaker count; equal bounds force it. The
    /// pipeline's clustering keeps pyannote's community-1 threshold: its
    /// window embeddings live on a different distance scale from hark's
    /// utterance embeddings, so `--speaker-threshold` does not reach it. Pure,
    /// so the tuning is unit-testable without loading the CoreML models.
    static func offlineConfig(minSpeakers: Int?, maxSpeakers: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        config.zeroVoteReembed = .init(enabled: true, minDurationSeconds: reembedFloorSeconds)
        if let minSpeakers, let maxSpeakers, minSpeakers == maxSpeakers {
            config = config.withSpeakers(exactly: minSpeakers)
        } else if minSpeakers != nil || maxSpeakers != nil {
            config = config.withSpeakers(min: minSpeakers, max: maxSpeakers)
        }
        return config
    }
}

/// One diarized span: a time range attributed to a speaker label.
struct DiarizedSegment: Equatable {
    let start: Double
    let end: Double
    let speaker: String
}

/// Turns a diarizer's raw `(start, end, speakerId)` spans into friendly,
/// stable `Speaker N` labels (numbered by first appearance) and merges
/// consecutive same-speaker spans separated by a small gap. Pure — unit-tested.
enum SpeakerLabeling {
    static func normalize(
        _ raw: [(start: Double, end: Double, id: String)], mergeGap: Double = 1.0
    ) -> [DiarizedSegment] {
        let sorted = raw.sorted { $0.start < $1.start }
        var numbers: [String: Int] = [:]
        var result: [DiarizedSegment] = []
        for span in sorted where span.end > span.start {
            let number = numbers[span.id] ?? (numbers.count + 1)
            numbers[span.id] = number
            let label = "Speaker \(number)"
            if let last = result.last, last.speaker == label, span.start - last.end <= mergeGap {
                result[result.count - 1] = DiarizedSegment(
                    start: last.start, end: max(last.end, span.end), speaker: label)
            } else {
                result.append(DiarizedSegment(start: span.start, end: span.end, speaker: label))
            }
        }
        return result
    }
}

/// Maps opaque diarizer speaker ids to stable, human-friendly `Speaker N`
/// labels (numbered by first appearance). Pure — unit-tested.
struct SpeakerNumbering {
    private var numbers: [String: Int] = [:]

    mutating func label(for id: String) -> String {
        let number = numbers[id] ?? (numbers.count + 1)
        numbers[id] = number
        return "Speaker \(number)"
    }
}

/// A speaker label for a live transcript segment spanning `[start, end]`
/// seconds (PRD §6.7). Backed by the streaming EEND diarizer's timeline
/// (`EENDStreamingDiarizer`). Returns nil to fall back to the transcriber's
/// fixed label.
protocol LiveSpeakerResolver: AnyObject, Sendable {
    func label(start: Double, end: Double) -> String?
}

/// Offline acoustic diarization via FluidAudio's pyannote community-1 pipeline
/// (CoreML/ANE): whole-file segmentation, embeddings, then agglomerative + VBx
/// clustering over the entire recording. Apple-Silicon-first; the models are
/// downloaded on first use into FluidAudio's cache and loaded once. Used for
/// batch (`-i`) and end-of-capture diarization (PRD §6.7b).
///
/// This replaces FluidAudio's online `DiarizerManager`, which clustered one
/// embedding per 10 s chunk and local speaker slot: when several voices shared
/// a slot their embedding was a blend that always sat near the first centroid,
/// so a three-way conversation came out as one `Speaker 1` whatever the
/// threshold. Clustering per-window embeddings over the whole file is what
/// keeps the voices apart.
final class SpeakerDiarizer {
    private let manager: OfflineDiarizerManager
    private let config: OfflineDiarizerConfig
    /// The speaker-count bounds and `--speaker-threshold` as requested, for
    /// the per-utterance clustering (`SpeakerClustering`) that runs outside
    /// FluidAudio; nil threshold means `DiarizationDefaults.clusteringThreshold`.
    let minSpeakers: Int?
    let maxSpeakers: Int?
    let threshold: Double?

    private init(
        manager: OfflineDiarizerManager, config: OfflineDiarizerConfig,
        minSpeakers: Int?, maxSpeakers: Int?, threshold: Double?
    ) {
        self.manager = manager
        self.config = config
        self.minSpeakers = minSpeakers
        self.maxSpeakers = maxSpeakers
        self.threshold = threshold
    }

    /// The offline model files inside FluidAudio's `speaker-diarization` bundle
    /// (the online tracker's files share the folder, so the folder alone does not
    /// say whether these are present).
    static var isCached: Bool {
        FluidAudioCache.isCached(
            FluidAudioCache.diarizerBundle + "/" + ModelNames.OfflineDiarizer.embeddingFile)
    }

    static func makeOffline(
        minSpeakers: Int?, maxSpeakers: Int?, threshold: Double?
    ) throws -> SpeakerDiarizer {
        guard Platform.isAppleSilicon else {
            throw HarkError.unavailable("""
                acoustic diarization requires Apple Silicon (CoreML/ANE). Deterministic \
                source attribution (--system/--app --mix --speakers) works on Intel.
                """)
        }
        if isCached {
            Log.verbose("loading diarization model")
        } else {
            Log.notice("downloading diarization model (first use)…")
        }
        let config = DiarizationDefaults.offlineConfig(minSpeakers: minSpeakers, maxSpeakers: maxSpeakers)
        let manager = OfflineDiarizerManager(config: config)
        let models = try RunLoopBridge.runBlocking(timeout: 1800) {
            try await OfflineDiarizerModels.load()
        }
        manager.initialize(models: models)
        return SpeakerDiarizer(
            manager: manager, config: config, minSpeakers: minSpeakers, maxSpeakers: maxSpeakers,
            threshold: threshold)
    }

    /// One raw 256-dim voice embedding per span of `samples` (16 kHz mono), in
    /// order, from the pipeline's WeSpeaker model. A span shorter than the model
    /// window is tiled to fill it; a longer one is embedded in pieces and averaged.
    func embed(spans: [Range<Double>], in samples: [Float]) throws -> [[Float]] {
        let box = UncheckedSendableBox(value: manager)
        let source = ArrayAudioSampleSource(samples: samples)
        return try RunLoopBridge.runBlocking(timeout: 3600) {
            try await box.value.embedSpans(audioSource: source, spans: spans)
        }
    }

    /// Pre-downloads the diarization CoreML models (no diarization run), for
    /// `hark models download fluidaudio:diarizer`.
    static func download() throws {
        guard Platform.isAppleSilicon else {
            throw HarkError.unavailable("acoustic diarization requires Apple Silicon (CoreML/ANE).")
        }
        Log.notice("downloading diarization models …")
        _ = try RunLoopBridge.runBlocking(timeout: 3600) {
            try await OfflineDiarizerModels.load()
        }
    }

    /// Diarizes 16 kHz mono samples into a labeled speaker timeline. A
    /// recording the diarizer finds no speech in yields an empty timeline.
    func diarize(_ samples: [Float]) throws -> [DiarizedSegment] {
        let clustering = config.clustering
        Log.verbose(
            "diarizer timeline: pipeline threshold \(clustering.threshold), speakers "
                + "\(clustering.numSpeakers.map { "exactly \($0)" } ?? "\(clustering.minSpeakers.map(String.init) ?? "1")…\(clustering.maxSpeakers.map(String.init) ?? "auto")")"
        )
        let box = UncheckedSendableBox(value: manager)
        let result: DiarizationResult
        do {
            result = try RunLoopBridge.runBlocking(timeout: 3600) {
                try await box.value.process(audio: samples)
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            Log.verbose("diarizer: no speech detected")
            return []
        }
        let raw = result.segments.map {
            (start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), id: $0.speakerId)
        }
        let ids = Set(raw.map(\.id)).sorted()
        Log.verbose("diarizer: \(raw.count) raw span(s), \(ids.count) speaker id(s) \(ids)")
        if Log.isVerbose, let database = result.speakerDatabase, database.count > 1 {
            Log.verbose("diarizer: cosine distances between speaker centroids")
            for a in ids {
                guard let left = database[a] else { continue }
                let row = ids.compactMap { b -> String? in
                    guard b != a, let right = database[b] else { return nil }
                    return String(format: "%@ %.3f", b, Self.cosineDistance(left, right))
                }
                Log.verbose("diarizer:   \(a): " + row.joined(separator: "  "))
            }
        }
        return SpeakerLabeling.normalize(raw)
    }

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 1 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }
}

/// Batch diarized transcription (PRD §6.7b): transcribe a file with the
/// engine's own utterance segmentation, diarize it, and give each utterance the
/// speaker who covers it (splitting an utterance that straddles two). The text
/// never follows the diarizer's spans, so a span that merged several turns still
/// yields one cue per turn. Engine-agnostic — it uses only the shared "transcribe
/// a WAV → srt" primitive, so it works with any engine that times its output.
enum BatchDiarization {
    static func diarizeAndTranscribe(
        audioPath: String, engineName: String, modelFlag: String?, language: String?,
        translate: Bool, minSpeakers: Int?, maxSpeakers: Int?, threshold: Double?,
        cueLimits: CueLimits, format: TranscriptOutputFormat
    ) throws -> String {
        let cues = try diarizeToCues(
            audioPath: audioPath, engineName: engineName, modelFlag: modelFlag,
            language: language, translate: translate, minSpeakers: minSpeakers,
            maxSpeakers: maxSpeakers, threshold: threshold, cueLimits: cueLimits)
        let fullText = cues.map(\.text).joined(separator: " ")
        return TranscriptFormatting.render(cues: cues, fullText: fullText, format: format)
    }

    /// Transcribes `audioPath` into utterance cues and labels them by speaker.
    /// `relabel`, when given, names every cue's speaker instead of diarizing
    /// (used to force the microphone track to "You" in offline-live mode).
    /// `channel` reads one channel of the file instead of the mix of all of them.
    static func diarizeToCues(
        audioPath: String, engineName: String, modelFlag: String?, language: String?,
        translate: Bool, minSpeakers: Int?, maxSpeakers: Int?, threshold: Double?,
        cueLimits: CueLimits = .default, relabel: String? = nil, channel: Int? = nil
    ) throws -> [TranscriptCue] {
        let backend = try TranscriptionEngine.makeBatch(
            engineName: engineName, modelFlag: modelFlag, language: language, translate: translate,
            cueLimits: cueLimits)
        defer { backend.shutdown() }
        return try diarizeToCues(
            audioPath: audioPath, backend: backend, language: language, translate: translate,
            relabel: relabel, channel: channel
        ) {
            try SpeakerDiarizer.makeOffline(
                minSpeakers: minSpeakers, maxSpeakers: maxSpeakers, threshold: threshold)
        }
    }

    /// One pass over one channel (or the whole file) with a backend the caller
    /// owns. `makeDiarizer` is called only when the cues need a diarizer: a
    /// relabeled track has one speaker by definition and never loads one.
    static func diarizeToCues(
        audioPath: String, backend: TranscriptionBackend, language: String?, translate: Bool,
        relabel: String?, channel: Int?, makeDiarizer: () throws -> SpeakerDiarizer
    ) throws -> [TranscriptCue] {
        // Decode through the shared pipeline, as transcription does: FluidAudio's
        // converter folds channels with AVAudioConverter, which keeps channel 0,
        // so a speaker recorded only on the right channel would diarize as silence.
        let mono = try AudioPipeline.normalizeFileForWhisper(audioPath, channel: channel)
        defer { try? FileManager.default.removeItem(at: mono) }

        if let relabel {
            let cues = try utteranceCues(mono: mono, backend: backend, language: language, translate: translate)
                ?? wholeFileCue(mono: mono, backend: backend, language: language, translate: translate)
            return cues.map { TranscriptCue(start: $0.start, end: $0.end, text: $0.text, speaker: relabel) }
        }

        let samples = try AudioConverter().resampleAudioFile(mono)
        guard !samples.isEmpty else { return [] }
        let diarizer = try makeDiarizer()

        if let cues = try utteranceCues(mono: mono, backend: backend, language: language, translate: translate) {
            return try labelByVoice(cues, samples: samples, diarizer: diarizer)
        }
        // An engine without timed output (apple) can only be handed the
        // diarizer's own spans.
        let timeline = try diarizer.diarize(samples)
        Log.verbose(
            "diarization: \(timeline.count) speaker span(s), "
                + "\(Set(timeline.map(\.speaker)).count) speaker(s)")
        return try transcribeSpans(
            samples, timeline: timeline, backend: backend, language: language, translate: translate)
    }

    /// Labels utterance cues by clustering one voice embedding per utterance.
    /// Each cue is embedded over its own span, so a one-word answer gets its own
    /// vector instead of sharing a 10 s window with whoever spoke around it; the
    /// clusters are then named `Speaker N` in order of first appearance. A cue
    /// whose span cannot be embedded (empty or past the audio) takes the label
    /// of the cue before it.
    static func labelByVoice(
        _ cues: [TranscriptCue], samples: [Float], diarizer: SpeakerDiarizer
    ) throws -> [TranscriptCue] {
        let seconds = Double(samples.count) / 16000
        let spans = cues.enumerated().compactMap { index, cue -> (index: Int, span: Range<Double>)? in
            let start = max(0, cue.start)
            let end = min(cue.end, seconds)
            guard end > start, start < seconds else { return nil }
            return (index, start..<end)
        }
        guard !spans.isEmpty else { return cues }
        let embeddings = try diarizer.embed(spans: spans.map(\.span), in: samples)
        let threshold = diarizer.threshold ?? DiarizationDefaults.clusteringThreshold
        let clusters = SpeakerClustering.cluster(
            embeddings, minSpeakers: diarizer.minSpeakers, maxSpeakers: diarizer.maxSpeakers,
            threshold: threshold)
        Log.verbose(
            "diarization: \(spans.count) utterance(s) embedded, \(Set(clusters).count) speaker(s) "
                + "(threshold \(threshold), speakers "
                + "\(diarizer.minSpeakers.map(String.init) ?? "1")…\(diarizer.maxSpeakers.map(String.init) ?? "auto"))")
        var labels = [String?](repeating: nil, count: cues.count)
        for (position, item) in spans.enumerated() {
            labels[item.index] = "Speaker \(clusters[position] + 1)"
        }
        var previous = labels.compactMap { $0 }.first ?? "Speaker 1"
        return cues.enumerated().map { index, cue in
            let label = labels[index] ?? previous
            previous = label
            return TranscriptCue(start: cue.start, end: cue.end, text: cue.text, speaker: label)
        }
    }

    /// The diarizer's timeline as text-less cues (`--diarize-only`): what the
    /// diarizer saw, before any transcript is laid over it.
    static func timelineCues(
        audioPath: String, minSpeakers: Int?, maxSpeakers: Int?, threshold: Double?
    ) throws -> [TranscriptCue] {
        let mono = try AudioPipeline.normalizeFileForWhisper(audioPath)
        defer { try? FileManager.default.removeItem(at: mono) }
        let samples = try AudioConverter().resampleAudioFile(mono)
        guard !samples.isEmpty else { return [] }
        let diarizer = try SpeakerDiarizer.makeOffline(
            minSpeakers: minSpeakers, maxSpeakers: maxSpeakers, threshold: threshold)
        return try diarizer.diarize(samples).map {
            TranscriptCue(start: $0.start, end: $0.end, text: "", speaker: $0.speaker)
        }
    }

    /// The engine's own utterances for a normalized file, from its srt output;
    /// nil for an engine that only writes plain text (apple, in batch).
    /// Placeholder and empty cues are dropped.
    static func utteranceCues(
        mono: URL, backend: TranscriptionBackend, language: String?, translate: Bool
    ) throws -> [TranscriptCue]? {
        if backend is AppleSpeechBackend { return nil }
        let srt = try backend.transcribe(
            wavFile: mono, language: language, translate: translate, format: .srt)
        return TranscriptFormatting.cues(fromSRT: srt).compactMap(speechOnly)
    }

    /// A single cue spanning the whole file, for an engine without timed output.
    private static func wholeFileCue(
        mono: URL, backend: TranscriptionBackend, language: String?, translate: Bool
    ) throws -> [TranscriptCue] {
        let text = try backend.transcribe(
            wavFile: mono, language: language, translate: translate, format: .txt)
        let file = try AudioPipeline.openForReading(mono.path)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        return [TranscriptCue(start: 0, end: seconds, text: text)].compactMap(speechOnly)
    }

    /// Transcribes each diarized span on its own and labels it — the fallback
    /// for an engine that cannot time its own utterances.
    static func transcribeSpans(
        _ samples: [Float], timeline: [DiarizedSegment], backend: TranscriptionBackend,
        language: String?, translate: Bool
    ) throws -> [TranscriptCue] {
        let minimumSamples = Int((backend.minimumAudioSeconds * 16000).rounded(.up))
        var cues: [TranscriptCue] = []
        for segment in timeline {
            let startSample = max(0, Int(segment.start * 16000))
            let endSample = min(samples.count, Int(segment.end * 16000))
            guard
                let slice = samplesForTranscription(
                    samples, from: startSample, to: endSample,
                    skipBelowSamples: 1600, minimumSamples: minimumSamples)
            else { continue }
            let wav = try writeWav16kMono(slice)
            defer { try? FileManager.default.removeItem(at: wav) }
            let text = try backend.transcribe(
                wavFile: wav, language: language, translate: translate, format: .txt)
            if let cue = speechOnly(
                TranscriptCue(start: segment.start, end: segment.end, text: text, speaker: segment.speaker))
            {
                cues.append(cue)
            }
        }
        return cues
    }

    /// The cue with its text trimmed, or nil when it holds no recognized speech.
    static func speechOnly(_ cue: TranscriptCue) -> TranscriptCue? {
        let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isNonSpeechPlaceholder(text) else { return nil }
        return TranscriptCue(start: cue.start, end: cue.end, text: text, speaker: cue.speaker)
    }

    /// Source attribution for a two-channel file (`-i FILE --speaker-mode
    /// source`, PRD §6.7c): channel 0 holds the microphone and channel 1 the
    /// call, so each channel is transcribed on its own as a single speaker,
    /// labeled by origin, and merged back into one time-ordered transcript — the
    /// same two-track shape the offline-live path produces. Overlapping speech
    /// survives, because the two voices never share a track. No diarizer is
    /// involved: the attribution is the channel, and the utterances are the
    /// engine's own.
    static func attributeChannels(
        audioPath: String, engineName: String, modelFlag: String?, language: String?,
        translate: Bool, cueLimits: CueLimits = .default, labels: SpeakerLabels
    ) throws -> [TranscriptCue] {
        try requireSourceChannels(AudioPipeline.channelCount(of: audioPath), path: audioPath)
        // One transcription backend for both channels, since it is the larger
        // load and `transcribe` carries nothing between calls.
        let backend = try TranscriptionEngine.makeBatch(
            engineName: engineName, modelFlag: modelFlag, language: language, translate: translate,
            cueLimits: cueLimits)
        defer { backend.shutdown() }
        return try attributeChannels(
            audioPath: audioPath, backend: backend, language: language, translate: translate,
            labels: labels)
    }

    /// The per-channel pass with a backend the caller owns. Internal so tests
    /// can drive it with a stub engine.
    static func attributeChannels(
        audioPath: String, backend: TranscriptionBackend, language: String?, translate: Bool,
        labels: SpeakerLabels
    ) throws -> [TranscriptCue] {
        return mergeTracks(
            mic: try wholeChannelCues(
                audioPath: audioPath, channel: 0, backend: backend, language: language,
                translate: translate, label: labels.you),
            system: try wholeChannelCues(
                audioPath: audioPath, channel: 1, backend: backend, language: language,
                translate: translate, label: labels.others))
    }

    /// Transcribes one channel of `audioPath` in a single call, every cue
    /// labeled `label`. Timings come from the engine's own srt; the apple
    /// engine writes plain text only, so its channel is one cue spanning it.
    static func wholeChannelCues(
        audioPath: String, channel: Int, backend: TranscriptionBackend, language: String?,
        translate: Bool, label: String
    ) throws -> [TranscriptCue] {
        let mono = try AudioPipeline.normalizeFileForWhisper(audioPath, channel: channel)
        defer { try? FileManager.default.removeItem(at: mono) }
        let cues = try utteranceCues(mono: mono, backend: backend, language: language, translate: translate)
            ?? wholeFileCue(mono: mono, backend: backend, language: language, translate: translate)
        return cues.map { TranscriptCue(start: $0.start, end: $0.end, text: $0.text, speaker: label) }
    }

    /// Rejects a file that cannot carry source attribution. Mirrors the live
    /// path's "source needs two sources" usage error: a mixed single-channel
    /// recording has nothing to attribute, and with more than two channels
    /// there is no telling which one is the microphone.
    static func requireSourceChannels(_ channels: Int, path: String) throws {
        guard channels == 2 else {
            throw HarkError.usage("""
                speaker-mode 'source' attributes the mic vs the call, so on a file it needs \
                two channels (mic left, call right): '\(path)' has \(channels) \
                channel\(channels == 1 ? "" : "s"). Use --speaker-mode auto to diarize it \
                acoustically.
                """)
        }
    }

    /// Samples to hand the recognizer for a diarized span, or nil when the span is
    /// too short to be speech at all (under `skipBelowSamples`, the existing 0.1 s
    /// bound). Anything longer is padded with trailing zeros up to `minimumSamples`,
    /// the engine's floor, so a real quarter-second answer is transcribed instead of
    /// failing the whole run. Cue timings still come from the diarized span, so the
    /// padding never reaches the transcript.
    static func samplesForTranscription(
        _ samples: [Float], from start: Int, to end: Int,
        skipBelowSamples: Int, minimumSamples: Int
    ) -> [Float]? {
        let lower = max(0, min(start, samples.count))
        let upper = max(lower, min(end, samples.count))
        guard upper - lower >= skipBelowSamples else { return nil }
        var slice = Array(samples[lower..<upper])
        if slice.count < minimumSamples {
            slice.append(contentsOf: [Float](repeating: 0, count: minimumSamples - slice.count))
        }
        return slice
    }

    /// Merges cue lists from multiple tracks into one time-ordered transcript.
    ///
    /// Two cues can share a start — overlapping speech on two tracks is the
    /// case this exists for — and `sorted` is not stable, so equal starts have
    /// to be broken by something or the same input can produce two different
    /// transcripts. The track's position does it: on an attributed file that
    /// puts the microphone before the call, and unlike the speaker name it does
    /// not move when the labels change.
    static func merge(_ cueLists: [[TranscriptCue]]) -> [TranscriptCue] {
        cueLists.enumerated()
            .flatMap { track, cues in
                cues.enumerated().map { (start: $1.start, track: track, index: $0, cue: $1) }
            }
            .sorted {
                ($0.start, $0.track, $0.index) < ($1.start, $1.track, $1.index)
            }
            .map(\.cue)
    }

    /// Merges the two tracks of an offline-live recording, microphone first, so
    /// a cue that starts at the same instant on both tracks lands the same way
    /// round as on an attributed file. The order the caller happens to diarize
    /// the two files in is not the transcript's order; this is.
    static func mergeTracks(mic: [TranscriptCue], system: [TranscriptCue]) -> [TranscriptCue] {
        merge([mic, system])
    }

    /// Writes 16 kHz mono Float samples to a temporary 16-bit WAV.
    private static func writeWav16kMono(_ samples: [Float]) throws -> URL {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-diar-\(UUID().uuidString).wav")
        let writer = try WAVFileWriter(
            destination: .file(url),
            format: PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1))
        try writer.write(data)
        try writer.finalize()
        return url
    }
}
