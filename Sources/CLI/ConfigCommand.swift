import ArgumentParser
import Foundation

/// `aural config` — view and edit persisted defaults (`~/.aural/config.json`).
struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "View and edit persisted defaults (~/.aural/config.json).",
        discussion: """
            Stores defaults that apply when not overridden. Model precedence is \
            --model flag › $AURAL_WHISPER_MODEL › config 'model'. Known keys: \
            \(ConfigKey.knownNames).
            """,
        subcommands: [ConfigShow.self, ConfigSet.self, ConfigUnset.self, ConfigPath.self],
        defaultSubcommand: ConfigShow.self
    )
}

struct ConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Print the current configuration.")

    @Flag(help: "Output as JSON for scripting.")
    var json = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            let config = Configuration.load()
            if json {
                print(try OutputFormatting.json(config))
                return
            }
            let entries = config.entries()
            guard !entries.isEmpty else {
                print("no configuration set (\(Configuration.fileURL.path))")
                print("set a default model with: aural config set model base.en")
                return
            }
            let rows = entries.map { [$0.key, $0.value] }
            print(OutputFormatting.table(header: ["KEY", "VALUE"], rows: rows))
        }
    }
}

struct ConfigSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a configuration value.",
        discussion: """
            Keys: \(ConfigKey.knownNames). Values that begin with '-' (e.g. a \
            negative silence threshold) are taken verbatim:
              aural config set silence-threshold -40
            """)

    // Captured together so a value beginning with '-' (e.g. -40) isn't mistaken
    // for an option by the parser.
    @Argument(
        parsing: .captureForPassthrough,
        help: ArgumentHelp("Key and value, e.g. 'model base.en'.", valueName: "key value"))
    var arguments: [String] = []

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            guard arguments.count == 2 else {
                throw AuralError.usage(
                    "usage: aural config set <key> <value> (keys: \(ConfigKey.knownNames)).")
            }
            let key = arguments[0]
            let value = arguments[1]
            guard let configKey = ConfigKey(rawValue: key) else {
                throw AuralError.usage("unknown config key '\(key)' (known: \(ConfigKey.knownNames)).")
            }
            var config = Configuration.load()
            // A non-fatal, engine-aware hint for the model key (the value is set
            // regardless): catches a missing whisper model and points out when
            // the value belongs to an engine other than the configured one.
            if configKey == .model {
                let owner = Self.installedEngine(of: value)
                if let note = Self.modelNote(
                    value: value, configuredEngine: config.engine, installedEngine: owner)
                {
                    Log.notice(note)
                }
            }
            try config.set(configKey, rawValue: value)  // typed; throws on bad value
            try config.save()
            print("\(configKey.rawValue) = \(config.displayValue(for: configKey) ?? value)")
        }
    }

    /// Hint for `config set model` (pure, for testing). `installedEngine` is the
    /// engine whose installed models include `value` (nil if none). Returns nil
    /// when the value matches the configured engine; otherwise flags a value
    /// owned by a different engine (set `engine` too), or — only for whisper — a
    /// model that isn't downloaded yet (the CoreML engines auto-download).
    static func modelNote(
        value: String, configuredEngine: String?, installedEngine owner: String?
    ) -> String? {
        let effective = configuredEngine ?? "whisper"
        if let owner, owner != effective {
            let versionHint = owner == "parakeet" ? " (parakeet selects a version, e.g. v2 or v3)" : ""
            return "note: '\(value)' is a \(owner) model; also set the engine — "
                + "aural config set engine \(owner)\(versionHint)"
        }
        if owner == nil, effective == "whisper" {
            return "note: model '\(value)' is not present yet; "
                + "download it with 'aural models download \(value)'."
        }
        return nil
    }

    /// The engine whose installed models include `value`, or nil. whisper matches
    /// a resolvable ggml path/name; whisperkit/parakeet match a cached bundle.
    static func installedEngine(of value: String) -> String? {
        if ModelRegistry.resolvePath(value) != nil
            || ModelRegistry.localModels().contains(where: { $0.name == value })
        {
            return "whisper"
        }
        let whisperkit = ModelRegistry.coreMLModels(
            engine: "whisperkit", directory: WhisperKitBackend.downloadBase)
        if whisperkit.contains(where: { $0.name == value || $0.name == "openai_whisper-\(value)" }) {
            return "whisperkit"
        }
        let parakeet = ModelRegistry.coreMLModels(
            engine: "parakeet", directory: ParakeetBackend.downloadBase)
        if parakeet.contains(where: { $0.name == value || $0.name.hasSuffix("-\(value)") }) {
            return "parakeet"
        }
        return nil
    }
}

struct ConfigUnset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unset", abstract: "Remove a configuration value.")

    @Argument(help: ArgumentHelp("Configuration key to clear.", valueName: "key"))
    var key: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            guard let configKey = ConfigKey(rawValue: key) else {
                throw AuralError.usage("unknown config key '\(key)' (known: \(ConfigKey.knownNames)).")
            }
            var config = Configuration.load()
            config.unset(configKey)
            try config.save()
            print("unset \(key)")
        }
    }
}

struct ConfigPath: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path", abstract: "Print the configuration file path.")

    func run() {
        print(Configuration.fileURL.path)
    }
}
