import Foundation

/// The effective capture/transcription/speaker defaults for one invocation,
/// after layering **flag › env (`$HARK_*`) › config › built-in default** for
/// each setting (the same precedence shown by `hark config show`, with flags
/// added). Computed once in `Hark.run()` and threaded into the file/live paths.
///
/// Model resolution stays in `WhisperEngine.resolveModel` (same chain); the
/// model is passed through as a flag.
struct ResolvedSettings: Equatable {
    let engine: String
    let language: String
    let translate: Bool
    let micDevice: String?
    /// Working directory for resolving relative artifact paths (nil = process CWD).
    let directory: String?

    let captureBackend: String
    // Capture format: nil = contextual (live uses 44100/16; convert uses source).
    let rate: Int?
    let bits: Int?
    let channels: Int?

    let silenceThreshold: Double
    let useVad: Bool
    let vadThreshold: Double?  // nil = engine default (FluidVadClassifier.defaultThreshold)
    let useGain: Bool

    let speakers: Bool
    let speakerMode: SpeakerMode
    let speakerLabels: SpeakerLabels
    let diarizeEngine: DiarizeEngine
    let maxSpeakers: Int?
    let speakerThreshold: Double?

    /// Resolves every setting from the parsed command, environment, and config.
    /// Throws a usage error for malformed environment values.
    static func resolve(
        from a: Hark,
        environment env: [String: String] = ProcessInfo.processInfo.environment,
        config: Configuration = .load()
    ) throws -> ResolvedSettings {
        func envStr(_ key: ConfigKey) -> String? {
            env[key.environmentName].flatMap { $0.isEmpty ? nil : $0 }
        }
        func string(_ flag: String?, _ key: ConfigKey, _ cfg: String?, default def: String? = nil) -> String? {
            flag ?? envStr(key) ?? cfg ?? def
        }
        func bool(_ flag: Bool?, _ key: ConfigKey, _ cfg: Bool?, default def: Bool) throws -> Bool {
            if let flag { return flag }
            if let raw = envStr(key) { return try ConfigKey.parseBool(raw, key) }
            return cfg ?? def
        }
        func int(_ flag: Int?, _ key: ConfigKey, _ cfg: Int?, parse: (String) throws -> Int) throws -> Int? {
            if let flag { return flag }
            if let raw = envStr(key) { return try parse(raw) }
            return cfg
        }
        func double(_ flag: Double?, _ key: ConfigKey, _ cfg: Double?, parse: (String) throws -> Double) throws -> Double? {
            if let flag { return flag }
            if let raw = envStr(key) { return try parse(raw) }
            return cfg
        }
        func choice<T: RawRepresentable>(
            _ flag: T?, _ key: ConfigKey, _ cfg: String?, allowed: [String], default def: T
        ) throws -> T where T.RawValue == String {
            let raw = flag?.rawValue ?? envStr(key) ?? cfg ?? def.rawValue
            return T(rawValue: try ConfigKey.parseChoice(raw, key, allowed)) ?? def
        }

        let engine = string(a.engine, .engine, config.engine, default: "whisper")!
        let language = string(a.language, .language, config.language, default: "auto")!
        let translate = try bool(a.translate, .translate, config.translate, default: false)
        let micDevice = string(a.device, .device, config.device)
        let directory = string(a.directory, .directory, config.directory)

        let captureBackend = try ConfigKey.parseChoice(
            string(a.captureBackend, .captureBackend, config.captureBackend, default: "auto")!,
            .captureBackend, ["auto", "sckit", "coreaudio"])
        let rate = try int(a.rate, .rate, config.rate) {
            try ConfigKey.parseInt($0, .rate, in: 1...768_000)
        }
        let bits = try int(a.bits, .bits, config.bits) {
            try ConfigKey.parseInt($0, .bits, oneOf: [16, 24, 32])
        }
        let channels = try int(a.channels, .channels, config.channels) {
            try ConfigKey.parseInt($0, .channels, oneOf: [1, 2])
        }

        let silenceThreshold = try double(a.silenceThreshold, .silenceThreshold, config.silenceThreshold) {
            try ConfigKey.parseThreshold($0, .silenceThreshold)
        } ?? -50
        let useVad = try bool(a.useVad, .vad, config.vad, default: true)
        let vadThreshold = try double(a.vadThreshold, .vadThreshold, config.vadThreshold) {
            try ConfigKey.parseUnit($0, .vadThreshold)
        }
        let useGain = try bool(a.useGain, .gain, config.gain, default: true)

        let speakers = try bool(a.speakers, .speakers, config.speakers, default: false)
        let speakerMode = try choice(
            a.speakerMode, .speakerMode, config.speakerMode,
            allowed: ["auto", "source", "acoustic"], default: SpeakerMode.auto)
        let labelString = string(a.speakerLabels, .speakerLabels, config.speakerLabels, default: "You,Others")!
        let speakerLabels = SpeakerLabels.parse(labelString)
        let diarizeEngine = try choice(
            a.diarizeEngine, .diarizeEngine, config.diarizeEngine,
            allowed: ["auto", "streaming", "offline"], default: DiarizeEngine.auto)
        let maxSpeakers = try int(a.maxSpeakers, .maxSpeakers, config.maxSpeakers) {
            try ConfigKey.parsePositiveInt($0, .maxSpeakers)
        }
        let speakerThreshold = try double(a.speakerThreshold, .speakerThreshold, config.speakerThreshold) {
            try ConfigKey.parseUnit($0, .speakerThreshold)
        }

        return ResolvedSettings(
            engine: engine, language: language, translate: translate, micDevice: micDevice,
            directory: directory,
            captureBackend: captureBackend, rate: rate, bits: bits, channels: channels,
            silenceThreshold: silenceThreshold, useVad: useVad, vadThreshold: vadThreshold,
            useGain: useGain, speakers: speakers, speakerMode: speakerMode,
            speakerLabels: speakerLabels, diarizeEngine: diarizeEngine, maxSpeakers: maxSpeakers,
            speakerThreshold: speakerThreshold)
    }

    /// Validates merged values that flag-only `Hark.validate()` cannot see
    /// (e.g. a configured engine that can't translate, paired with `--translate`).
    func validate() throws {
        guard let spec = EngineSpec.named(engine) else {
            throw HarkError.usage("unknown engine '\(engine)' (known: \(EngineSpec.knownNames)).")
        }
        if translate && !spec.capabilities.translate {
            throw HarkError.usage(
                "the '\(engine)' engine cannot translate to English; drop --translate or "
                    + "choose an engine that supports it (whisper, whisperkit).")
        }
        guard silenceThreshold < 0 else {
            throw HarkError.usage("silence threshold must be negative (dBFS).")
        }
    }

    /// Changes the process working directory so the root verb's **relative**
    /// artifact paths (`-i`, `-a`, `-t`, `--split` outputs) resolve against it.
    /// Absolute paths, `-` (stdin/stdout), and home-anchored state (`~/.hark`)
    /// are unaffected. No-op when unset (stays at the process CWD). A missing
    /// directory is a usage error; Hark never creates it.
    func applyWorkingDirectory(fileManager: FileManager = .default) throws {
        guard let directory else { return }
        let path = (directory as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw HarkError.usage("--directory must be an existing directory (got '\(directory)').")
        }
        guard fileManager.changeCurrentDirectoryPath(path) else {
            throw HarkError.ioError("could not switch to directory '\(directory)'.")
        }
        Log.verbose("working directory: \(path)")
    }
}
