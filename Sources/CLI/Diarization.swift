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
        var config = DiarizerConfig()
        if let maxSpeakers { config.numClusters = maxSpeakers }
        config.clusteringThreshold = Float(threshold ?? DiarizationDefaults.clusteringThreshold)
        let manager = DiarizerManager(config: config)
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
    /// microphone track to "You" in offline-live mode).
    static func diarizeToCues(
        audioPath: String, engineName: String, modelFlag: String?, language: String?,
        translate: Bool, maxSpeakers: Int?, threshold: Double?, relabel: String? = nil
    ) throws -> [TranscriptCue] {
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: audioPath))
        guard !samples.isEmpty else { return [] }

        let diarizer = try SpeakerDiarizer.makeOffline(maxSpeakers: maxSpeakers, threshold: threshold)
        let segments = try diarizer.diarize(samples)
        Log.verbose("diarization: \(segments.count) speaker segment(s)")

        let backend = try TranscriptionEngine.makeBatch(
            engineName: engineName, modelFlag: modelFlag, language: language, translate: translate)
        defer { backend.shutdown() }

        var cues: [TranscriptCue] = []
        for segment in segments {
            let startSample = max(0, Int(segment.start * 16000))
            let endSample = min(samples.count, Int(segment.end * 16000))
            guard endSample - startSample >= 1600 else { continue }  // < 0.1 s: skip

            let wav = try writeWav16kMono(Array(samples[startSample..<endSample]))
            defer { try? FileManager.default.removeItem(at: wav) }
            let text = try backend.transcribe(
                wavFile: wav, language: language, translate: translate, format: .txt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(
                TranscriptCue(
                    start: segment.start, end: segment.end, text: text,
                    speaker: relabel ?? segment.speaker))
        }
        return cues
    }

    /// Merges cue lists from multiple tracks into one time-ordered transcript.
    static func merge(_ cueLists: [[TranscriptCue]]) -> [TranscriptCue] {
        cueLists.flatMap { $0 }.sorted { $0.start < $1.start }
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
