import Foundation
import WhisperKit

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
        let options = DecodingOptions(
            task: translate ? .translate : .transcribe,
            language: Self.languageCode(language),
            detectLanguage: Self.languageCode(language) == nil,
            skipSpecialTokens: true,
            wordTimestamps: false)
        let pipe = self.pipe
        let path = wavFile.path
        let results = try RunLoopBridge.runBlocking(timeout: 1800) {
            try await pipe.value.transcribe(audioPath: path, decodeOptions: options)
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
