import Foundation
import Testing

@testable import CLI

@Suite("Configuration")
struct ConfigurationTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-cfg-\(UUID().uuidString)/config.json")
    }

    @Test func saveThenLoadRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = Configuration()
        config.model = "large-v3-turbo"
        try config.save(to: url)
        #expect(Configuration.load(from: url) == config)
    }

    @Test func loadMissingFileYieldsEmpty() {
        #expect(Configuration.load(from: tempURL()) == Configuration())
    }

    @Test func loadMalformedFileYieldsEmpty() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{ not json".utf8).write(to: url)
        #expect(Configuration.load(from: url) == Configuration())
    }

    @Test func saveCreatesParentDirectory() throws {
        let url = tempURL()  // parent does not exist yet
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Configuration(model: "base.en").save(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func setUnsetAndEntries() throws {
        var config = Configuration()
        #expect(config.entries().isEmpty)
        try config.set(.model, rawValue: "small")
        #expect(config.displayValue(for: .model) == "small")
        #expect(config.entries().map(\.key) == ["model"])
        #expect(config.entries().first?.value == "small")
        config.unset(.model)
        #expect(config.displayValue(for: .model) == nil)
        #expect(config.entries().isEmpty)
    }

    @Test func unknownConfigKeyIsRejected() {
        #expect(ConfigKey(rawValue: "bogus") == nil)
        #expect(ConfigKey(rawValue: "model") == .model)
        #expect(ConfigKey(rawValue: "silence-threshold") == .silenceThreshold)
        for key in ["model", "engine", "language", "translate", "silence-threshold", "device"] {
            #expect(ConfigKey.knownNames.contains(key))
        }
    }

    @Test func roundTripsAllKeys() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = Configuration()
        for key in ConfigKey.allCases {
            // A value valid for each key's type.
            let raw: String
            switch key {
            case .engine: raw = "whisper"
            case .model, .language, .device: raw = "x"
            case .directory: raw = NSTemporaryDirectory()  // must be an existing directory
            case .translate, .vad, .gain, .speakers: raw = "true"
            case .captureBackend: raw = "sckit"
            case .rate: raw = "48000"
            case .bits: raw = "24"
            case .channels: raw = "1"
            case .silenceThreshold: raw = "-42"
            case .vadThreshold, .speakerThreshold: raw = "0.6"
            case .speakerMode: raw = "source"
            case .speakerLabels: raw = "Me,Them"
            case .diarizeEngine: raw = "offline"
            case .maxSpeakers: raw = "5"
            }
            try config.set(key, rawValue: raw)
        }
        try config.save(to: url)
        #expect(Configuration.load(from: url) == config)
        // Every key is now set, so entries() covers them all.
        #expect(config.entries().count == ConfigKey.allCases.count)
    }

    @Test func showResolvesValueAndSource() {
        var config = Configuration()
        config.engine = "parakeet"
        let env = ["HARK_VAD_THRESHOLD": "0.4"]
        func effective(_ key: ConfigKey) -> (value: String, source: SettingSource) {
            Configuration.settingsByKey[key]!.effective(config: config, env: env)
        }
        #expect(effective(.engine) == ("parakeet", .config))
        #expect(effective(.vadThreshold) == ("0.4", .env))
        #expect(effective(.language) == ("auto", .default))
        #expect(effective(.channels) == ("(auto)", .default))
        // The registry and the key enum stay in sync.
        #expect(Configuration.settings.count == ConfigKey.allCases.count)
    }

    @Test func jsonUsesKebabCaseKeys() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Configuration(silenceThreshold: -40).save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"silence-threshold\""))
        #expect(!text.contains("silenceThreshold"))
    }

    @Test func typedSetValidatesValues() {
        var config = Configuration()
        // translate: bool parsing
        #expect(throws: HarkError.self) { try config.set(.translate, rawValue: "maybe") }
        #expect((try? { var c = Configuration(); try c.set(.translate, rawValue: "yes"); return c.translate }()) == true)
        // silence-threshold: numeric + must be negative
        #expect(throws: HarkError.self) { try config.set(.silenceThreshold, rawValue: "abc") }
        #expect(throws: HarkError.self) { try config.set(.silenceThreshold, rawValue: "10") }
        #expect((try? { var c = Configuration(); try c.set(.silenceThreshold, rawValue: "-40"); return c.silenceThreshold }()) == -40)
        // engine: must be known
        #expect(throws: HarkError.self) { try config.set(.engine, rawValue: "bogus") }
        #expect((try? { var c = Configuration(); try c.set(.engine, rawValue: "apple"); return c.engine }()) == "apple")
        // non-empty strings
        #expect(throws: HarkError.self) { try config.set(.model, rawValue: "") }
    }

    @Test func environmentNameMapping() {
        #expect(ConfigKey.model.environmentName == "HARK_WHISPER_MODEL")
        #expect(ConfigKey.engine.environmentName == "HARK_ENGINE")
        #expect(ConfigKey.language.environmentName == "HARK_LANGUAGE")
        #expect(ConfigKey.translate.environmentName == "HARK_TRANSLATE")
        #expect(ConfigKey.silenceThreshold.environmentName == "HARK_SILENCE_THRESHOLD")
        #expect(ConfigKey.device.environmentName == "HARK_DEVICE")
    }

    @Test func thresholdDisplayTrimsWholeNumbers() {
        #expect(Configuration(silenceThreshold: -50).displayValue(for: .silenceThreshold) == "-50")
        #expect(Configuration(silenceThreshold: -42.5).displayValue(for: .silenceThreshold) == "-42.5")
    }

    // MARK: `config set model` engine-aware note

    @Test func modelNoteSilentWhenValueMatchesConfiguredEngine() {
        // whisper model + whisper engine (default) -> no note.
        #expect(ConfigSet.modelNote(value: "base.en", configuredEngine: nil, installedEngine: "whisper") == nil)
        // parakeet model + parakeet engine -> no note.
        #expect(ConfigSet.modelNote(value: "v3", configuredEngine: "parakeet", installedEngine: "parakeet") == nil)
    }

    @Test func modelNoteFlagsDifferentEngine() {
        // The reported bug: a parakeet model set while the engine is still whisper.
        let note = ConfigSet.modelNote(
            value: "parakeet-tdt-0.6b-v3", configuredEngine: nil, installedEngine: "parakeet")
        #expect(note?.contains("is a parakeet model") == true)
        #expect(note?.contains("hark config set engine parakeet") == true)
        // whisperkit model while engine is whisper.
        let wk = ConfigSet.modelNote(
            value: "openai_whisper-base", configuredEngine: "whisper", installedEngine: "whisperkit")
        #expect(wk?.contains("hark config set engine whisperkit") == true)
    }

    @Test func configSetRecognizesHelpRequest() {
        #expect(ConfigSet.isHelpRequest(["--help"]))
        #expect(ConfigSet.isHelpRequest(["-h"]))
        #expect(ConfigSet.isHelpRequest(["model", "--help"]))
        // Real set commands (incl. negative values) are not help requests.
        #expect(!ConfigSet.isHelpRequest(["model", "base.en"]))
        #expect(!ConfigSet.isHelpRequest(["silence-threshold", "-40"]))
        #expect(!ConfigSet.isHelpRequest([]))
    }

    @Test func modelNoteWhisperNotPresentOnlyForWhisperEngine() {
        // Unknown value, whisper engine -> "not present" download hint.
        let whisper = ConfigSet.modelNote(value: "nope", configuredEngine: nil, installedEngine: nil)
        #expect(whisper?.contains("not present yet") == true)
        #expect(whisper?.contains("hark models download nope") == true)
        // Unknown value, parakeet engine -> no note (CoreML engines auto-download).
        #expect(ConfigSet.modelNote(value: "v3", configuredEngine: "parakeet", installedEngine: nil) == nil)
    }
}

@Suite("Default-model adoption")
struct DefaultModelTests {
    @Test func explicitAlwaysSets() {
        #expect(ModelDownloader.shouldSetDefault(explicit: true, existing: "base.en"))
        #expect(ModelDownloader.shouldSetDefault(explicit: true, existing: nil))
    }

    @Test func firstModelAutoBecomesDefault() {
        #expect(ModelDownloader.shouldSetDefault(explicit: false, existing: nil))
        #expect(ModelDownloader.shouldSetDefault(explicit: false, existing: ""))
    }

    @Test func keepsExistingDefaultWithoutFlag() {
        #expect(!ModelDownloader.shouldSetDefault(explicit: false, existing: "base.en"))
    }
}
