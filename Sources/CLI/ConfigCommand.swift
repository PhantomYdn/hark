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
            // For the model key, warn (non-fatal) when the value can't be
            // resolved yet, so a typo is visible but pre-download setup still works.
            if configKey == .model, ModelRegistry.resolvePath(value) == nil {
                Log.notice(
                    "note: model '\(value)' is not present yet; "
                        + "download it with 'aural models download \(value)'.")
            }
            var config = Configuration.load()
            try config.set(configKey, rawValue: value)  // typed; throws on bad value
            try config.save()
            print("\(configKey.rawValue) = \(config.displayValue(for: configKey) ?? value)")
        }
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
