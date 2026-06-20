import Foundation

/// Persisted, user-editable defaults (`~/.hark/config.json`). Every field is
/// optional, so an empty/missing file is valid. Each maps to a flag and an
/// environment variable; the effective value follows
/// flag › env (`$HARK_*`) › config › built-in default (see `ResolvedSettings`).
///
/// Storage is plain typed fields (for clean Codable round-trip); all behavior
/// (display, set, unset, defaults, env, validation) is driven by the declarative
/// `Configuration.settings` registry, so adding a key is a one-line addition
/// there plus a field here.
struct Configuration: Codable, Equatable {
    // Transcription
    var model: String?
    var engine: String?
    var language: String?
    var translate: Bool?
    var device: String?

    // General
    var directory: String?

    // Capture
    var captureBackend: String?
    var rate: Int?
    var bits: Int?
    var channels: Int?

    // Segmentation
    var silenceThreshold: Double?
    var vad: Bool?
    var vadThreshold: Double?
    var gain: Bool?

    // Speaker recognition
    var speakers: Bool?
    var speakerMode: String?
    var speakerLabels: String?
    var diarizeEngine: String?
    var maxSpeakers: Int?
    var speakerThreshold: Double?

    /// JSON keys mirror the CLI flag/key names (kebab-case) so the file is
    /// hand-editable with familiar names.
    enum CodingKeys: String, CodingKey {
        case model, engine, language, translate, device
        case directory
        case captureBackend = "capture-backend"
        case rate, bits, channels
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
    }

    /// `~/.hark/config.json`.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hark/config.json", isDirectory: false)
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

    /// Writes the configuration, creating `~/.hark` if needed.
    func save(to url: URL = fileURL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            throw HarkError.ioError("cannot write config to \(url.path): \(error)")
        }
    }

    // MARK: Registry-driven access (for `hark config set/unset/show`)

    /// The declarative registry of every configurable setting. Order is the
    /// display order for `config show`.
    static let settings: [Setting] = [
        TypedSetting(.engine, .choice(EngineSpec.all.map(\.name)), "whisper", \.engine,
            parse: ConfigKey.parseEngine, format: { $0 },
            summary: "Transcription engine (whisper, whisperkit, parakeet, apple)."),
        TypedSetting(.model, .string, "(unset)", \.model,
            parse: { try ConfigKey.requireNonEmpty($0, .model) }, format: { $0 },
            summary: "Model the engine uses (ggml name or whisperkit/parakeet variant)."),
        TypedSetting(.language, .string, "auto", \.language,
            parse: { try ConfigKey.requireNonEmpty($0, .language) }, format: { $0 },
            summary: "Spoken-language hint ('auto' detects it)."),
        TypedSetting(.translate, .bool, "false", \.translate,
            parse: { try ConfigKey.parseBool($0, .translate) }, format: ConfigKey.formatBool,
            summary: "Translate the transcript to English instead of verbatim."),
        TypedSetting(.device, .string, "(system default)", \.device,
            parse: { try ConfigKey.requireNonEmpty($0, .device) }, format: { $0 },
            summary: "Input device for capture (defaults to system input)."),
        TypedSetting(.directory, .string, "(current directory)", \.directory,
            parse: { try ConfigKey.parseDirectory($0, .directory) }, format: { $0 },
            summary: "Base directory for relative artifact paths (-i/-a/-t/--split)."),

        TypedSetting(.captureBackend, .choice(["auto", "sckit", "coreaudio"]), "auto", \.captureBackend,
            parse: { try ConfigKey.parseChoice($0, .captureBackend, ["auto", "sckit", "coreaudio"]) },
            format: { $0 },
            summary: "System/app capture backend (auto, sckit, coreaudio)."),
        TypedSetting(.rate, .int, "44100", \.rate,
            parse: { try ConfigKey.parseInt($0, .rate, in: 1...768_000) }, format: { String($0) },
            summary: "Capture sample rate in Hz."),
        TypedSetting(.bits, .int, "16", \.bits,
            parse: { try ConfigKey.parseInt($0, .bits, oneOf: [16, 24, 32]) }, format: { String($0) },
            summary: "Capture bit depth (16, 24, or 32)."),
        TypedSetting(.channels, .int, "(auto)", \.channels,
            parse: { try ConfigKey.parseInt($0, .channels, oneOf: [1, 2]) }, format: { String($0) },
            summary: "Capture channels (1 mono, 2 stereo; auto by default)."),

        TypedSetting(.silenceThreshold, .double, "-50", \.silenceThreshold,
            parse: { try ConfigKey.parseThreshold($0, .silenceThreshold) }, format: ConfigKey.formatNumber,
            summary: "Amplitude (dBFS) treated as silence for segmentation."),
        TypedSetting(.vad, .bool, "true", \.vad,
            parse: { try ConfigKey.parseBool($0, .vad) }, format: ConfigKey.formatBool,
            summary: "Use on-device voice-activity detection for live segmentation."),
        TypedSetting(.vadThreshold, .double, "0.5", \.vadThreshold,
            parse: { try ConfigKey.parseUnit($0, .vadThreshold) }, format: ConfigKey.formatNumber,
            summary: "VAD speech-probability cutoff (0–1; higher = stricter)."),
        TypedSetting(.gain, .bool, "true", \.gain,
            parse: { try ConfigKey.parseBool($0, .gain) }, format: ConfigKey.formatBool,
            summary: "Boost quiet segments before transcription (recording unaffected)."),

        TypedSetting(.speakers, .bool, "false", \.speakers,
            parse: { try ConfigKey.parseBool($0, .speakers) }, format: ConfigKey.formatBool,
            summary: "Label transcript segments by speaker (diarization)."),
        TypedSetting(.speakerMode, .choice(["auto", "source", "acoustic"]), "auto", \.speakerMode,
            parse: { try ConfigKey.parseChoice($0, .speakerMode, ["auto", "source", "acoustic"]) },
            format: { $0 },
            summary: "Labeling mode: auto, source (mic vs system), or acoustic."),
        TypedSetting(.speakerLabels, .string, "You,Others", \.speakerLabels,
            parse: { try ConfigKey.parseLabels($0, .speakerLabels) }, format: { $0 },
            summary: "Names for the two source labels (mic,system)."),
        TypedSetting(.diarizeEngine, .choice(["auto", "streaming", "offline"]), "auto", \.diarizeEngine,
            parse: { try ConfigKey.parseChoice($0, .diarizeEngine, ["auto", "streaming", "offline"]) },
            format: { $0 },
            summary: "Diarizer timing: auto, streaming (live), or offline (at end)."),
        TypedSetting(.maxSpeakers, .int, "(unset)", \.maxSpeakers,
            parse: { try ConfigKey.parsePositiveInt($0, .maxSpeakers) }, format: { String($0) },
            summary: "Cap on distinct speakers for offline/batch diarization."),
        TypedSetting(
            .speakerThreshold, .double, ConfigKey.formatNumber(DiarizationDefaults.clusteringThreshold),
            \.speakerThreshold,
            parse: { try ConfigKey.parseUnit($0, .speakerThreshold) }, format: ConfigKey.formatNumber,
            summary: "Offline/batch clustering sensitivity (0–1; lower splits more)."),
    ]

    static let settingsByKey: [ConfigKey: Setting] = Dictionary(
        uniqueKeysWithValues: settings.map { ($0.key, $0) })

    /// Returns the stored value for `key` rendered as a string, or nil when unset.
    func displayValue(for key: ConfigKey) -> String? {
        Self.settingsByKey[key]?.configDisplay(self)
    }

    /// Parses and stores a string `value` for `key`, throwing a usage error on a
    /// malformed/invalid value (shared with environment parsing).
    mutating func set(_ key: ConfigKey, rawValue value: String) throws {
        try Self.settingsByKey[key]?.set(value, into: &self)
    }

    /// Clears `key`.
    mutating func unset(_ key: ConfigKey) {
        Self.settingsByKey[key]?.clear(from: &self)
    }

    /// All set key/value pairs, in registry order, for display.
    func entries() -> [(key: String, value: String)] {
        ConfigKey.allCases.compactMap { key in
            displayValue(for: key).map { (key.rawValue, $0) }
        }
    }
}
