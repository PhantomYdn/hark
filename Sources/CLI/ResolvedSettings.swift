import Foundation

/// The effective transcription/capture defaults for one invocation, after
/// layering the precedence chain **flag › env (`$AURAL_*`) › config › built-in
/// default** for each setting. Computed once in `Aural.run()` and threaded into
/// the file/live paths so every consumer sees the same resolved values.
///
/// Model resolution stays in `WhisperEngine.resolveModel` (which applies the
/// same chain); the model is passed through as a flag.
struct ResolvedSettings: Equatable {
    let engine: String
    let language: String
    let translate: Bool
    let silenceThreshold: Double
    /// Input device for the live mic path; nil = system default input.
    let micDevice: String?

    /// Resolves each setting via flag › env › config › default. Throws a usage
    /// error for malformed environment values (non-bool `$AURAL_TRANSLATE`,
    /// non-numeric/non-negative `$AURAL_SILENCE_THRESHOLD`).
    static func resolve(
        engineFlag: String?,
        languageFlag: String?,
        translateFlag: Bool?,
        silenceFlag: Double?,
        deviceFlag: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        config: Configuration = .load()
    ) throws -> ResolvedSettings {
        func env(_ key: ConfigKey) -> String? {
            environment[key.environmentName].flatMap { $0.isEmpty ? nil : $0 }
        }

        let engine = engineFlag ?? env(.engine) ?? config.engine ?? "whisper"
        let language = languageFlag ?? env(.language) ?? config.language ?? "auto"

        let translate: Bool
        if let translateFlag {
            translate = translateFlag
        } else if let raw = env(.translate) {
            translate = try ConfigKey.parseBool(raw, .translate)
        } else {
            translate = config.translate ?? false
        }

        let silenceThreshold: Double
        if let silenceFlag {
            silenceThreshold = silenceFlag
        } else if let raw = env(.silenceThreshold) {
            silenceThreshold = try ConfigKey.parseThreshold(raw, .silenceThreshold)
        } else {
            silenceThreshold = config.silenceThreshold ?? -50
        }

        let micDevice = deviceFlag ?? env(.device) ?? config.device

        return ResolvedSettings(
            engine: engine, language: language, translate: translate,
            silenceThreshold: silenceThreshold, micDevice: micDevice)
    }

    /// Validates the merged values — covers env/config-driven combinations that
    /// the flag-only `Aural.validate()` cannot see (e.g. a configured engine
    /// that can't translate, paired with `--translate`).
    func validate() throws {
        guard let spec = EngineSpec.named(engine) else {
            throw AuralError.usage("unknown engine '\(engine)' (known: \(EngineSpec.knownNames)).")
        }
        if translate && !spec.capabilities.translate {
            throw AuralError.usage(
                "the '\(engine)' engine cannot translate to English; drop --translate or "
                    + "choose an engine that supports it (whisper, whisperkit).")
        }
        guard silenceThreshold < 0 else {
            throw AuralError.usage("silence threshold must be negative (dBFS).")
        }
    }
}
