import Foundation

/// Persisted, user-editable defaults (`~/.aural/config.json`). Every field is
/// optional, so an empty/missing file is valid. Each maps to a flag and an
/// environment variable; the effective value follows
/// flag › env (`$AURAL_*`) › config › built-in default (see `ResolvedSettings`).
struct Configuration: Codable, Equatable {
    /// Default model: a ggml path or a short name (resolved like `--model`).
    var model: String?
    /// Default transcription engine (`whisper`, …).
    var engine: String?
    /// Default spoken-language code, or "auto".
    var language: String?
    /// Default translate-to-English behavior.
    var translate: Bool?
    /// Default silence threshold in dBFS (negative).
    var silenceThreshold: Double?
    /// Default input device UID for live mic capture.
    var device: String?

    /// JSON keys mirror the CLI flag/key names (kebab-case) so the file is
    /// hand-editable with familiar names.
    enum CodingKeys: String, CodingKey {
        case model
        case engine
        case language
        case translate
        case silenceThreshold = "silence-threshold"
        case device
    }

    /// `~/.aural/config.json`.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aural/config.json", isDirectory: false)
    }

    /// Loads the configuration, returning an empty one when the file is absent.
    /// A corrupt file is reported on stderr and treated as empty rather than
    /// failing every command.
    static func load(from url: URL = fileURL) -> Configuration {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return Configuration()
        }
        do {
            return try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            Log.notice("warning: ignoring malformed config at \(url.path): \(error)")
            return Configuration()
        }
    }

    /// Writes the configuration, creating `~/.aural` if needed.
    func save(to url: URL = fileURL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            throw AuralError.ioError("cannot write config to \(url.path): \(error)")
        }
    }

    // MARK: Key access (for `aural config set/unset/show`)

    /// Returns the stored value for `key` rendered as a string, or nil when unset.
    func displayValue(for key: ConfigKey) -> String? {
        switch key {
        case .model: return model
        case .engine: return engine
        case .language: return language
        case .translate: return translate.map { $0 ? "true" : "false" }
        case .silenceThreshold: return silenceThreshold.map { ConfigKey.formatThreshold($0) }
        case .device: return device
        }
    }

    /// Parses and stores a string `value` for `key`, throwing a usage error on a
    /// malformed/invalid value (shared with environment parsing).
    mutating func set(_ key: ConfigKey, rawValue value: String) throws {
        switch key {
        case .model: model = try ConfigKey.requireNonEmpty(value, key)
        case .engine: engine = try ConfigKey.parseEngine(value)
        case .language: language = try ConfigKey.requireNonEmpty(value, key)
        case .translate: translate = try ConfigKey.parseBool(value, key)
        case .silenceThreshold: silenceThreshold = try ConfigKey.parseThreshold(value, key)
        case .device: device = try ConfigKey.requireNonEmpty(value, key)
        }
    }

    /// Clears `key`.
    mutating func unset(_ key: ConfigKey) {
        switch key {
        case .model: model = nil
        case .engine: engine = nil
        case .language: language = nil
        case .translate: translate = nil
        case .silenceThreshold: silenceThreshold = nil
        case .device: device = nil
        }
    }

    /// All set key/value pairs, in stable key order, for display.
    func entries() -> [(key: String, value: String)] {
        ConfigKey.allCases.compactMap { key in
            displayValue(for: key).map { (key.rawValue, $0) }
        }
    }
}

/// The configurable keys. Adding a key here (plus a `Configuration` field and
/// `ResolvedSettings` wiring) is all that's needed to expose a new default.
enum ConfigKey: String, CaseIterable {
    case model
    case engine
    case language
    case translate
    case silenceThreshold = "silence-threshold"
    case device

    static var knownNames: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// Environment variable backing this key. Model keeps its historical name.
    var environmentName: String {
        switch self {
        case .model: return "AURAL_WHISPER_MODEL"
        default: return "AURAL_" + rawValue.uppercased().replacingOccurrences(of: "-", with: "_")
        }
    }

    // MARK: Shared value parsing (used by `config set` and env resolution)

    static func requireNonEmpty(_ value: String, _ key: ConfigKey) throws -> String {
        guard !value.isEmpty else {
            throw AuralError.usage("\(key.rawValue) must not be empty.")
        }
        return value
    }

    static func parseEngine(_ value: String) throws -> String {
        guard EngineSpec.named(value) != nil else {
            throw AuralError.usage(
                "unknown engine '\(value)' (known: \(EngineSpec.knownNames)).")
        }
        return value
    }

    static func parseBool(_ value: String, _ key: ConfigKey) throws -> Bool {
        switch value.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default:
            throw AuralError.usage("\(key.rawValue) must be true or false (got '\(value)').")
        }
    }

    static func parseThreshold(_ value: String, _ key: ConfigKey) throws -> Double {
        guard let number = Double(value) else {
            throw AuralError.usage("\(key.rawValue) must be a number in dBFS (got '\(value)').")
        }
        guard number < 0 else {
            throw AuralError.usage("\(key.rawValue) must be negative (dBFS).")
        }
        return number
    }

    /// Renders a threshold without a trailing ".0" for whole numbers.
    static func formatThreshold(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
