import Foundation

/// Value type of a setting (for display/help; parsing/validation live in the
/// descriptor's `parse`).
enum SettingKind {
    case string
    case int
    case double
    case bool
    case choice([String])
}

/// Where an effective value came from, for `hark config show`.
enum SettingSource: String {
    case `default`
    case config
    case env
}

/// A configurable setting, type-erased over its value. The registry in
/// `Configuration.settings` is the single source of truth for display, parsing,
/// defaults, env names, and source resolution.
protocol Setting: Sendable {
    var key: ConfigKey { get }
    var kind: SettingKind { get }
    var defaultDisplay: String { get }
    /// One-sentence explanation of the setting, for the `config show` DESCRIPTION column.
    var summary: String { get }
    var envName: String { get }
    func configDisplay(_ c: Configuration) -> String?
    func envDisplay(_ env: [String: String]) -> String?
    func set(_ raw: String, into c: inout Configuration) throws
    func clear(from c: inout Configuration)
}

extension Setting {
    /// Effective value + source for `config show` (env › config › default —
    /// `config show` has no invocation flags).
    func effective(config: Configuration, env: [String: String]) -> (value: String, source: SettingSource) {
        if let value = envDisplay(env) { return (value, .env) }
        if let value = configDisplay(config) { return (value, .config) }
        return (defaultDisplay, .default)
    }
}

/// A `Setting` backed by a typed `Configuration` field via a `WritableKeyPath`.
struct TypedSetting<V>: Setting {
    let key: ConfigKey
    let kind: SettingKind
    let defaultDisplay: String
    let summary: String
    private let keyPath: WritableKeyPath<Configuration, V?> & Sendable
    private let parser: @Sendable (String) throws -> V
    private let formatter: @Sendable (V) -> String

    init(
        _ key: ConfigKey, _ kind: SettingKind, _ defaultDisplay: String,
        _ keyPath: WritableKeyPath<Configuration, V?> & Sendable,
        parse: @escaping @Sendable (String) throws -> V, format: @escaping @Sendable (V) -> String,
        summary: String
    ) {
        self.key = key
        self.kind = kind
        self.defaultDisplay = defaultDisplay
        self.summary = summary
        self.keyPath = keyPath
        self.parser = parse
        self.formatter = format
    }

    var envName: String { key.environmentName }

    func configDisplay(_ c: Configuration) -> String? { c[keyPath: keyPath].map(formatter) }

    func envDisplay(_ env: [String: String]) -> String? {
        guard let raw = env[envName], !raw.isEmpty else { return nil }
        return (try? parser(raw)).map(formatter) ?? raw
    }

    func set(_ raw: String, into c: inout Configuration) throws {
        c[keyPath: keyPath] = try parser(raw)
    }

    func clear(from c: inout Configuration) { c[keyPath: keyPath] = nil }
}

/// The configurable keys (kebab-case raw values mirror the flags). Declaration
/// order is the `config show` display order.
enum ConfigKey: String, CaseIterable {
    case engine
    case model
    case language
    case translate
    case device
    case directory
    case captureBackend = "capture-backend"
    case rate
    case bits
    case channels
    case keepAwake = "keep-awake"
    case silenceThreshold = "silence-threshold"
    case vad
    case vadThreshold = "vad-threshold"
    case gain
    case speakers
    case speakerMode = "speaker-mode"
    case speakerLabels = "speaker-labels"
    case diarizeEngine = "diarize-engine"
    case maxSpeakers = "max-speakers"
    case speakerThreshold = "speaker-threshold"
    case remoteControlPort = "remote-control-port"

    static var knownNames: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// Environment variable backing this key. Model and capture-backend keep
    /// their historical names; the rest follow `HARK_<KEY>`.
    var environmentName: String {
        switch self {
        case .model: return "HARK_WHISPER_MODEL"
        case .captureBackend: return "HARK_CAPTURE"
        default: return "HARK_" + rawValue.uppercased().replacingOccurrences(of: "-", with: "_")
        }
    }

    // MARK: Shared value parsing (used by `config set`, env resolution, registry)

    static func requireNonEmpty(_ value: String, _ key: ConfigKey) throws -> String {
        guard !value.isEmpty else { throw HarkError.usage("\(key.rawValue) must not be empty.") }
        return value
    }

    /// Validates a path is an existing directory (tilde-expanded). Used by the
    /// `directory` working-directory setting; the value is stored verbatim.
    static func parseDirectory(_ value: String, _ key: ConfigKey) throws -> String {
        let trimmed = try requireNonEmpty(value, key)
        var isDir: ObjCBool = false
        let path = (trimmed as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw HarkError.usage("\(key.rawValue) must be an existing directory (got '\(value)').")
        }
        return trimmed
    }

    static func parseEngine(_ value: String) throws -> String {
        guard EngineSpec.named(value) != nil else {
            throw HarkError.usage("unknown engine '\(value)' (known: \(EngineSpec.knownNames)).")
        }
        return value
    }

    static func parseBool(_ value: String, _ key: ConfigKey) throws -> Bool {
        switch value.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default:
            throw HarkError.usage("\(key.rawValue) must be true or false (got '\(value)').")
        }
    }

    static func parseThreshold(_ value: String, _ key: ConfigKey) throws -> Double {
        guard let number = Double(value) else {
            throw HarkError.usage("\(key.rawValue) must be a number in dBFS (got '\(value)').")
        }
        guard number < 0 else { throw HarkError.usage("\(key.rawValue) must be negative (dBFS).") }
        return number
    }

    static func parseChoice(_ value: String, _ key: ConfigKey, _ allowed: [String]) throws -> String {
        let lowered = value.lowercased()
        guard allowed.contains(lowered) else {
            throw HarkError.usage(
                "\(key.rawValue) must be one of \(allowed.joined(separator: ", ")) (got '\(value)').")
        }
        return lowered
    }

    static func parseInt(_ value: String, _ key: ConfigKey, in range: ClosedRange<Int>) throws -> Int {
        guard let n = Int(value) else {
            throw HarkError.usage("\(key.rawValue) must be an integer (got '\(value)').")
        }
        guard range.contains(n) else {
            throw HarkError.usage(
                "\(key.rawValue) must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return n
    }

    static func parseInt(_ value: String, _ key: ConfigKey, oneOf allowed: [Int]) throws -> Int {
        guard let n = Int(value) else {
            throw HarkError.usage("\(key.rawValue) must be an integer (got '\(value)').")
        }
        guard allowed.contains(n) else {
            throw HarkError.usage(
                "\(key.rawValue) must be one of \(allowed.map(String.init).joined(separator: ", ")).")
        }
        return n
    }

    static func parsePositiveInt(_ value: String, _ key: ConfigKey) throws -> Int {
        guard let n = Int(value), n >= 1 else {
            throw HarkError.usage("\(key.rawValue) must be a positive integer (got '\(value)').")
        }
        return n
    }

    static func parseUnit(_ value: String, _ key: ConfigKey) throws -> Double {
        guard let n = Double(value) else {
            throw HarkError.usage("\(key.rawValue) must be a number (got '\(value)').")
        }
        guard n > 0 && n <= 1 else {
            throw HarkError.usage("\(key.rawValue) must be between 0 and 1.")
        }
        return n
    }

    static func parseLabels(_ value: String, _ key: ConfigKey) throws -> String {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw HarkError.usage("\(key.rawValue) needs two comma-separated names, e.g. 'You,Others'.")
        }
        return "\(parts[0]),\(parts[1])"
    }

    // MARK: Formatting

    static func formatBool(_ value: Bool) -> String { value ? "true" : "false" }

    /// Renders a number without a trailing ".0" for whole values.
    static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
