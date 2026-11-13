import Foundation
import WhisperKit

/// Keeps the furthest segment end seen this run so the reported fraction is
/// monotonic (windows are sequential, but WhisperKit's seek can revisit
/// earlier audio) and safe to update from the decoder's callback threads.
private final class SegmentProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEnd: Double = 0
    private let duration: Double
    private let handler: @Sendable (Double) -> Void

    init(duration: Double, handler: @escaping @Sendable (Double) -> Void) {
        self.duration = duration
        self.handler = handler
    }

    func accept(_ segments: [TranscriptionSegment]) {
        guard duration > 0, let end = segments.last.map({ Double($0.end) }), end.isFinite
        else { return }
        lock.lock()
        guard end > lastEnd else { lock.unlock(); return }
        lastEnd = end
        lock.unlock()
        handler(min(end / duration, 1))
    }
}

/// On-device CoreML transcription via WhisperKit (PRD §6.6, engine
/// `whisperkit`). Apple-Silicon-first; multilingual with auto-detect and
/// translation. The model is loaded once (resident) and reused across batch and
/// live segments. Models are CoreML bundles downloaded from Hugging Face on
/// first use into `~/.hark/models/whisperkit`.
final class WhisperKitBackend: TranscriptionBackend {
    let capabilities = EngineCapabilities(autoDetect: true, translate: true, usesModelFile: true)

    private let pipe: UncheckedSendableBox<WhisperKit>
    private let modelLabel: String

    private init(pipe: WhisperKit, modelLabel: String) {
        self.pipe = UncheckedSendableBox(value: pipe)
        self.modelLabel = modelLabel
    }

    var label: String { "whisperkit (CoreML, \(modelLabel))" }

    /// Where WhisperKit downloads its CoreML bundles (kept alongside ggml models
    /// so `hark models list` can show them).
    static var downloadBase: URL {
        ModelRegistry.modelsDirectory.appendingPathComponent("whisperkit", isDirectory: true)
    }

    /// Variants offered by `hark models list --available` / `download`. Any
    /// valid WhisperKit variant also works with `download whisperkit:<variant>`.
    static let downloadableVariants = [
        "tiny", "base", "small",
        "large-v3-v20240930_626MB", "large-v3-v20240930_turbo",
    ]

    /// Pre-downloads a variant's CoreML bundles (no load) into the cache.
    static func download(variant: String) throws {
        try Platform.requireAppleSilicon(engine: "whisperkit")
        let base = downloadBase
        Log.notice("downloading whisperkit model \(variant) …")
        try RunLoopBridge.runBlocking(timeout: 3600) {
            _ = try await WhisperKit.download(variant: variant, downloadBase: base)
        }
    }

    /// Loads (and, on first use, downloads) the model. `model` is a WhisperKit
    /// variant name (e.g. `large-v3-v20240930_626MB`); nil loads the SDK default.
    static func make(model: String?) throws -> WhisperKitBackend {
        try Platform.requireAppleSilicon(engine: "whisperkit")
        let base = downloadBase
        let name = model
        Log.verbose("whisperkit: loading model \(name ?? "(default)") from \(base.path)")
        let box: UncheckedSendableBox<WhisperKit> = try RunLoopBridge.runBlocking(timeout: 1800) {
            let pipe = try await WhisperKit(
                WhisperKitConfig(
                    model: name, downloadBase: base, verbose: false, logLevel: .none))
            return UncheckedSendableBox(value: pipe)
        }
        return WhisperKitBackend(pipe: box.value, modelLabel: name ?? "default")
    }

    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String {
        try transcribe(
            wavFile: wavFile, language: language, translate: translate, format: format,
            progress: { _ in })
    }

    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> String {
        let options = DecodingOptions(
            task: translate ? .translate : .transcribe,
            language: Self.languageCode(language),
            detectLanguage: Self.languageCode(language) == nil,
            skipSpecialTokens: true,
            wordTimestamps: false)
        let pipe = self.pipe
        let path = wavFile.path
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        // Fraction-complete comes from segment discovery: WhisperKit decodes
        // the file in sequential ~30 s windows, and each window's last segment
        // carries its position on the file timeline. Its decode-loop callback
        // has no usable position (the timings it reports never track windows).
        let duration = Double(samples.count) / Double(WhisperKit.sampleRate)
        let tracker = SegmentProgressTracker(duration: duration, handler: progress)
        let timeout = RunLoopBridge.transcribeTimeout(audioSeconds: duration)
        let results = try RunLoopBridge.runBlocking(timeout: timeout) {
            try await pipe.value.transcribe(
                audioArray: samples, decodeOptions: options,
                segmentCallback: { tracker.accept($0) })
        }
        let fullText = Self.clean(results.map(\.text).joined(separator: " "))
        let cues = results.flatMap(\.segments).map {
            TranscriptCue(start: Double($0.start), end: Double($0.end), text: Self.clean($0.text))
        }
        return TranscriptFormatting.render(cues: cues, fullText: fullText, format: format)
    }

    func shutdown() {}

    /// Maps a `--language` value to a WhisperKit language code: "auto"/nil →
    /// nil (detect); a code passes through. Pure, for testing.
    static func languageCode(_ language: String?) -> String? {
        guard let language, !language.isEmpty, language.lowercased() != "auto" else { return nil }
        return language.lowercased()
    }

    /// Strips any residual whisper special tokens (e.g. `<|0.00|>`,
    /// `<|transcribe|>`) and trims whitespace. Pure, for testing.
    static func clean(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
