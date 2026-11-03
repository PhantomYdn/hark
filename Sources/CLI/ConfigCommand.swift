import ArgumentParser
import Foundation

/// `hark config` — view and edit persisted defaults (`~/.hark/config.json`).
struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "View and edit persisted defaults (~/.hark/config.json).",
        discussion: """
            Stores defaults that apply when not overridden. Model precedence is \
            --model flag › $HARK_WHISPER_MODEL › config 'model'. Known keys: \
            \(ConfigKey.knownNames).
            """,
        subcommands: [ConfigShow.self, ConfigSet.self, ConfigUnset.self, ConfigPath.self],
        defaultSubcommand: ConfigShow.self
    )
}

struct ConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print every setting, its effective value, and its source.",
        discussion: """
            Shows all settings — including ones at their built-in default. SOURCE \
            is 'default' (built-in), 'config' (set in ~/.hark/config.json), or \
            'env' ($HARK_* override, which outranks config). Invocation flags are \
            not shown here (they apply per run and outrank both).
            """)

    /// One row of `config show` (also the `--json` element shape).
    struct Entry: Encodable {
        let value: String
        let source: String
        let description: String
    }

    @Flag(help: "Output as JSON for scripting.")
    var json = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            let config = Configuration.load()
            let environment = ProcessInfo.processInfo.environment
            var resolved = Configuration.settings.map { setting -> (key: String, entry: Entry) in
                let (value, source) = setting.effective(config: config, env: environment)
                return (
                    setting.key.rawValue,
                    Entry(value: value, source: source.rawValue, description: setting.summary)
                )
            }
            // Shortcut bindings follow the typed settings (PRD §6.9).
            for binding in config.shortcutBindings {
                resolved.append((
                    binding.configKey,
                    Entry(
                        value: binding.command, source: "config",
                        description: "Interactive shortcut: runs this command on the transcript so far.")
                ))
            }
            if json {
                let object = Dictionary(uniqueKeysWithValues: resolved.map { ($0.key, $0.entry) })
                print(try OutputFormatting.json(object))
                return
            }
            let rows = resolved.map { [$0.key, $0.entry.value, $0.entry.source, $0.entry.description] }
            print(OutputFormatting.table(header: ["KEY", "VALUE", "SOURCE", "DESCRIPTION"], rows: rows))
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
              hark config set silence-threshold -40
            """)

    // Captured together so a value beginning with '-' (e.g. -40) isn't mistaken
    // for an option by the parser.
    @Argument(
        parsing: .captureForPassthrough,
        help: ArgumentHelp("Key and value, e.g. 'model base.en'.", valueName: "key value"))
    var arguments: [String] = []

    @OptionGroup var options: GlobalOptions

    /// True if the captured arguments are a help request. Needed because
    /// `.captureForPassthrough` (used so values like `-40` aren't parsed as
    /// options) also swallows `-h`/`--help` before ArgumentParser sees them.
    /// The validated shortcut binding when `key` is `shortcut.<k>`; nil for a
    /// typed key. A malformed shortcut key or blank command is a usage error.
    static func shortcut(key: String, command: String) throws -> ShortcutBinding? {
        guard try ShortcutBinding.key(fromConfigKey: key) != nil else { return nil }
        return try ShortcutBinding.make(configKey: key, command: command)
    }

    static func isHelpRequest(_ arguments: [String]) -> Bool {
        arguments.contains("-h") || arguments.contains("--help")
    }

    func run() throws {
        if Self.isHelpRequest(arguments) {
            throw CleanExit.helpRequest(self)
        }
        try runMapped(verbose: options.verbose) {
            guard arguments.count == 2 else {
                throw HarkError.usage(
                    "usage: hark config set <key> <value> (keys: \(ConfigKey.knownNames)).")
            }
            let key = arguments[0]
            let value = arguments[1]
            // Interactive shortcuts (PRD §6.9) live outside the typed registry.
            if let binding = try Self.shortcut(key: key, command: value) {
                var config = Configuration.load()
                config.shortcuts[binding.key] = binding.command
                try config.save()
                print("\(binding.configKey) = \(binding.command)")
                return
            }
            guard let configKey = ConfigKey(rawValue: key) else {
                throw HarkError.usage("unknown config key '\(key)' (known: \(ConfigKey.knownNames)).")
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
            let versionHint = owner == "parakeet" ? " (parakeet selects a variant, e.g. ultra or v2)" : ""
            return "note: '\(value)' is a \(owner) model; also set the engine — "
                + "hark config set engine \(owner)\(versionHint)"
        }
        if owner == nil, effective == "whisper" {
            return "note: model '\(value)' is not present yet; "
                + "download it with 'hark models download \(value)'."
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
        if parakeet.contains(where: { $0.name == value || $0.name.hasSuffix("-\(value)") })
            || ParakeetBackend.resolve(value).map(ParakeetBackend.isCached) == true
        {
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
            if let shortcut = try ShortcutBinding.key(fromConfigKey: key) {
                var config = Configuration.load()
                guard config.shortcuts.removeValue(forKey: shortcut) != nil else {
                    throw HarkError.usage("shortcut.\(shortcut) is not set.")
                }
                try config.save()
                print("unset shortcut.\(shortcut)")
                return
            }
            guard let configKey = ConfigKey(rawValue: key) else {
                throw HarkError.usage("unknown config key '\(key)' (known: \(ConfigKey.knownNames)).")
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
