import Foundation

/// A whisper ggml model present in the local model directory.
struct LocalModel: Codable {
    let name: String
    let path: String
    let sizeBytes: Int
    /// True if this is the active model (`$AURAL_WHISPER_MODEL` resolves here).
    let current: Bool
}

/// Resolves whisper ggml models by short name and manages the local model
/// directory (`~/.aural/models`). Short names map to `ggml-<name>.bin`
/// (PRD §6.1: `--model NAME|PATH`).
enum ModelRegistry {
    /// `~/.aural/models`, where `aural models download` stores ggml files.
    static var modelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aural/models", isDirectory: true)
    }

    /// Hugging Face repo serving ggml whisper models.
    static let huggingFaceBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    /// Curated catalog of common ggml whisper models available from the Hugging
    /// Face repo (`ggerganov/whisper.cpp`). Any valid ggml name there works with
    /// `download`; this list powers `models list --available` for discovery.
    /// `.en` names are English-only; the rest are multilingual.
    static let downloadable: [String] = [
        "tiny", "tiny.en",
        "base", "base.en",
        "small", "small.en",
        "medium", "medium.en",
        "large-v2", "large-v3",
        "large-v3-turbo", "large-v3-turbo-q5_0", "large-v3-turbo-q8_0",
    ]

    /// ggml filename for a short model name ("large-v3-turbo" -> "ggml-large-v3-turbo.bin").
    static func fileName(for name: String) -> String { "ggml-\(name).bin" }

    /// Short name for a ggml model file path ("…/ggml-base.en.bin" -> "base.en"),
    /// or nil if the path is not a `ggml-*.bin` file.
    static func shortName(forPath path: String) -> String? {
        let file = (path as NSString).lastPathComponent
        guard file.hasPrefix("ggml-"), file.hasSuffix(".bin") else { return nil }
        return String(file.dropFirst("ggml-".count).dropLast(".bin".count))
    }

    /// Download URL for a short model name.
    static func downloadURL(for name: String) -> URL {
        URL(string: "\(huggingFaceBase)/\(fileName(for: name))")!
    }

    /// Resolves a `--model` value to an absolute file path. An existing file
    /// path (after `~` expansion) is used as-is; otherwise the value is treated
    /// as a short name and looked up in the model directory. Returns nil when
    /// neither exists.
    static func resolvePath(
        _ value: String, directory: URL = modelsDirectory, fileManager: FileManager = .default
    ) -> String? {
        let expanded = (value as NSString).expandingTildeInPath
        if fileManager.fileExists(atPath: expanded) { return expanded }
        // A value that already looks like a path is not a short name.
        if value.contains("/") { return nil }
        let candidate = directory.appendingPathComponent(fileName(for: value)).path
        return fileManager.fileExists(atPath: candidate) ? candidate : nil
    }

    /// True if the model file is English-only (a `.en` ggml model).
    static func isEnglishOnly(modelPath: String) -> Bool {
        (modelPath as NSString).lastPathComponent.lowercased().contains(".en.")
    }

    /// Whether a request would be silently ignored by an English-only model:
    /// a non-English language or a translation request (PRD §6.6).
    static func shouldWarnEnglishOnly(
        modelPath: String, language: String?, translate: Bool
    ) -> Bool {
        guard isEnglishOnly(modelPath: modelPath) else { return false }
        let wantsOtherLanguage: Bool
        if let language, language != "auto", !language.lowercased().hasPrefix("en") {
            wantsOtherLanguage = true
        } else {
            wantsOtherLanguage = false
        }
        return wantsOtherLanguage || translate
    }

    /// Warns (stderr) when a non-English language or translation is requested
    /// with an English-only model, which ignores both.
    static func warnIfModelLanguageMismatch(
        modelPath: String, language: String?, translate: Bool
    ) {
        guard shouldWarnEnglishOnly(
            modelPath: modelPath, language: language, translate: translate) else { return }
        let model = (modelPath as NSString).lastPathComponent
        Log.notice(
            "warning: '\(model)' is an English-only model; --language/--translate are ignored. "
                + "Use a multilingual model (e.g. --model large-v3-turbo).")
    }

    /// The active default model: the absolute path that `$AURAL_WHISPER_MODEL`,
    /// then the config `model`, resolves to (a path or a short name), or nil when
    /// neither is set/resolvable. This mirrors `WhisperEngine.resolveModel`'s
    /// default (everything below an explicit `--model` flag).
    static func currentModelPath(
        directory: URL = modelsDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        config: Configuration = .load()
    ) -> String? {
        let value = environment["AURAL_WHISPER_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? config.model
        guard let value, !value.isEmpty else { return nil }
        return resolvePath(value, directory: directory)
    }

    /// Lists ggml models present in the model directory, sorted by name. The
    /// entry matching the active default (env or config) is flagged `current`.
    static func localModels(
        directory: URL = modelsDirectory,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        config: Configuration = .load()
    ) -> [LocalModel] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return [] }
        // Canonicalize so the current-model match survives symlinked paths
        // (e.g. /var vs /private/var for temp dirs).
        let currentCanonical = currentModelPath(
            directory: directory, environment: environment, config: config)
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
            .map { url in
                let stripped = url.lastPathComponent
                    .dropFirst("ggml-".count).dropLast(".bin".count)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return LocalModel(
                    name: String(stripped), path: url.path, sizeBytes: size,
                    current: currentCanonical == url.resolvingSymlinksInPath().path)
            }
            .sorted { $0.name < $1.name }
    }

    /// Human-readable byte size (e.g. "142 MB").
    static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
