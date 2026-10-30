import Encoders
import FluidAudio
import Foundation

/// Tuning for FluidAudio acoustic diarization shared by the streaming and
/// offline paths.
enum DiarizationDefaults {
    /// Default embedding-clustering threshold (in `--speaker-threshold` units).
    ///
    /// FluidAudio's library default is `0.7`, but `DiarizerManager` multiplies it
    /// by `1.2` to derive the `SpeakerManager` assignment cutoff — an effective
    /// `0.84` cosine distance, which is far too lenient and collapses distinct
    /// speakers into a single `Speaker 1`. We lower it so the effective cutoff
    /// lands near `0.78`, separating voices without over-splitting. Overridden by
    /// `--speaker-threshold`. (`Double` so `config show` can render it cleanly.)
    static let clusteringThreshold: Double = 0.65

    /// Shortest span (seconds) the offline diarizer is allowed to emit.
    ///
    /// FluidAudio's library default is `1.0`, so every sub-second utterance was
    /// discarded before the recognizer ever saw it — a 0.55 s "Hello." that plain
    /// batch transcribes fine vanished from a diarized one. The same value also
    /// gates new-speaker creation in `SpeakerManager`, so it can't go arbitrarily
    /// low: `0.25` keeps it above the pipeline's independent activity floor
    /// (`minActiveFramesCount`, 10 frames ≈ 0.17 s), which is what stops a brief
    /// noise burst minting a spurious `Speaker N`. Measured on a 26-turn two-voice
    /// clip (clean and with room noise): every turn from 0.4 s up survives, the
    /// label count stays at the true 2, and no turn that `1.0` already
    /// transcribed changes its words or its speaker.
    static let minSpeechDuration: Double = 0.25

    /// The `DiarizerConfig` hark runs offline diarization with. Pure, so the
    /// tuning above is unit-testable without loading the CoreML models.
    static func offlineConfig(maxSpeakers: Int?, threshold: Double?) -> DiarizerConfig {
        var config = DiarizerConfig()
        if let maxSpeakers { config.numClusters = maxSpeakers }
        config.clusteringThreshold = Float(threshold ?? clusteringThreshold)
        config.minSpeechDuration = Float(minSpeechDuration)
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

/// Offline acoustic diarization via FluidAudio's Pyannote pipeline (CoreML/ANE).
/// Apple-Silicon-first; the model is downloaded on first use into FluidAudio's
/// cache and loaded once. Used for batch (`-i`) diarization (PRD §6.7b).
final class SpeakerDiarizer {
    private let manager: DiarizerManager

    private init(manager: DiarizerManager) { self.manager = manager }

    static func makeOffline(maxSpeakers: Int?, threshold: Double?) throws -> SpeakerDiarizer {
        guard Platform.isAppleSilicon else {
            throw HarkError.unavailable("""
                acoustic diarization requires Apple Silicon (CoreML/ANE). Deterministic \
                source attribution (--system/--app --mix --speakers) works on Intel.
                """)
        }
        if FluidAudioCache.isCached(FluidAudioCache.diarizerBundle) {
            Log.verbose("loading diarization model")
        } else {
            Log.notice("downloading diarization model (first use)…")
        }
        let manager = DiarizerManager(
            config: DiarizationDefaults.offlineConfig(maxSpeakers: maxSpeakers, threshold: threshold))
        let models = try RunLoopBridge.runBlocking(timeout: 1800) {
            UncheckedSendableBox(value: try await DiarizerModels.downloadIfNeeded())
        }
        manager.initialize(models: models.value)
        return SpeakerDiarizer(manager: manager)
    }

    /// Pre-downloads the diarization CoreML models (no diarization run), for
    /// `hark models download fluidaudio:diarizer`.
    static func download() throws {
        guard Platform.isAppleSilicon else {
            throw HarkError.unavailable("acoustic diarization requires Apple Silicon (CoreML/ANE).")
        }
        Log.notice("downloading diarization models …")
        _ = try RunLoopBridge.runBlocking(timeout: 3600) {
            UncheckedSendableBox(value: try await DiarizerModels.downloadIfNeeded())
        }
    }

    /// Diarizes 16 kHz mono samples into labeled, merged speaker segments.
    func diarize(_ samples: [Float]) throws -> [DiarizedSegment] {
        let result = try manager.performCompleteDiarization(samples, sampleRate: 16000)
        let raw = result.segments.map {
            (start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), id: $0.speakerId)
        }
        return SpeakerLabeling.normalize(raw)
    }
}

/// Batch diarized transcription (PRD §6.7b): diarize a file, then transcribe
/// each speaker span independently and label it. Engine-agnostic — it uses only
/// the shared "transcribe a WAV → text" primitive, so it works with any engine.
enum BatchDiarization {
    static func diarizeAndTranscribe(
        audioPath: String, engineName: String, modelFlag: String?, language: String?,
        translate: Bool, maxSpeakers: Int?, threshold: Double?, format: TranscriptOutputFormat
    ) throws -> String {
        let cues = try diarizeToCues(
            audioPath: audioPath, engineName: engineName, modelFlag: modelFlag,
            language: language, translate: translate, maxSpeakers: maxSpeakers, threshold: threshold)
        let fullText = cues.map(\.text).joined(separator: " ")
        return TranscriptFormatting.render(cues: cues, fullText: fullText, format: format)
    }

    /// Diarizes `audioPath` and transcribes each speaker span into labeled cues.
    /// `relabel`, when given, overrides every cue's speaker (used to force the
    /// microphone track to "You" in offline-live mode). `channel` reads one
    /// channel of the file instead of the mix of all of them.
    static func diarizeToCues(
        audioPath: String, engineName: String, modelFlag: String?, language: String?,
        translate: Bool, maxSpeakers: Int?, threshold: Double?, relabel: String? = nil,
        channel: Int? = nil
    ) throws -> [TranscriptCue] {
        let diarizer = try SpeakerDiarizer.makeOffline(maxSpeakers: maxSpeakers, threshold: threshold)
        let backend = try TranscriptionEngine.makeBatch(
            engineName: engineName, modelFlag: modelFlag, language: language, translate: translate)
        defer { backend.shutdown() }
        return try diarizeToCues(
            audioPath: audioPath, diarizer: diarizer, backend: backend, language: language,
            translate: translate, relabel: relabel, channel: channel)
    }

    /// One pass over one channel (or the whole file) with a diarizer and a
    /// transcription backend the caller owns, so a caller that reads several
    /// channels of the same file loads the transcription model once rather than
    /// once per channel. The diarizer is the caller's to keep or rebuild: it
    /// remembers the voices it has already seen.
    private static func diarizeToCues(
        audioPath: String, diarizer: SpeakerDiarizer, backend: TranscriptionBackend,
        language: String?, translate: Bool, relabel: String?, channel: Int?
    ) throws -> [TranscriptCue] {
        // Decode through the shared pipeline, as transcription does: FluidAudio's
        // converter folds channels with AVAudioConverter, which keeps channel 0,
        // so a speaker recorded only on the right channel would diarize as silence.
        let mono = try AudioPipeline.normalizeFileForWhisper(audioPath, channel: channel)
        defer { try? FileManager.default.removeItem(at: mono) }
        let samples = try AudioConverter().resampleAudioFile(mono)
        guard !samples.isEmpty else { return [] }

        let segments = try diarizer.diarize(samples)
        Log.verbose("diarization: \(segments.count) speaker segment(s)")

        let minimumSamples = Int((backend.minimumAudioSeconds * 16000).rounded(.up))

        var cues: [TranscriptCue] = []
        for segment in segments {
            let startSample = max(0, Int(segment.start * 16000))
            let endSample = min(samples.count, Int(segment.end * 16000))
            guard
                let slice = Self.samplesForTranscription(
                    samples, from: startSample, to: endSample,
                    skipBelowSamples: 1600, minimumSamples: minimumSamples)
            else { continue }

            let wav = try writeWav16kMono(slice)
            defer { try? FileManager.default.removeItem(at: wav) }
            let text = try backend.transcribe(
                wavFile: wav, language: language, translate: translate, format: .txt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isNonSpeechPlaceholder(text) else { continue }
            cues.append(
                TranscriptCue(
                    start: segment.start, end: segment.end, text: text,
                    speaker: relabel ?? segment.speaker))
        }
        return cues
    }

    /// Source attribution for a two-channel file (`-i FILE --speaker-mode
    /// source`, PRD §6.7c): channel 0 holds the microphone and channel 1 the
    /// call, so each channel is read on its own, transcribed as a single
    /// speaker, labeled by origin, and merged back into one time-ordered
    /// transcript — the same two-track shape the offline-live path produces.
    /// Overlapping speech survives, because the two voices never share a track.
    static func attributeChannels(
        audioPath: String, engineName: String, modelFlag: String?, language: String?,
        translate: Bool, threshold: Double?, labels: SpeakerLabels
    ) throws -> [TranscriptCue] {
        try requireSourceChannels(AudioPipeline.channelCount(of: audioPath), path: audioPath)
        // One transcription backend for both channels, since it is the larger
        // load and `transcribe` carries nothing between calls. A diarizer each,
        // on purpose. FluidAudio's `DiarizerManager` holds its speaker database
        // in a stored property that diarizing never resets, so one instance
        // would match the call's voices against the microphone's at an
        // assignment cutoff of `clusteringThreshold * 1.2`, the 0.78 that
        // `DiarizationDefaults` tunes to keep two people apart. No cue could be
        // mislabeled, because `relabel` overwrites the speaker per channel, but
        // spans that belong apart would collapse and move the cue boundaries.
        let backend = try TranscriptionEngine.makeBatch(
            engineName: engineName, modelFlag: modelFlag, language: language, translate: translate)
        defer { backend.shutdown() }
        func cues(channel: Int, label: String) throws -> [TranscriptCue] {
            let diarizer = try SpeakerDiarizer.makeOffline(maxSpeakers: 1, threshold: threshold)
            return try diarizeToCues(
                audioPath: audioPath, diarizer: diarizer, backend: backend, language: language,
                translate: translate, relabel: label, channel: channel)
        }
        return merge([
            try cues(channel: 0, label: labels.you),
            try cues(channel: 1, label: labels.others),
        ])
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
