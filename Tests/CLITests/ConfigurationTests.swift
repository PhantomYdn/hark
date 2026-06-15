import Foundation
import Testing

@testable import CLI

@Suite("Configuration")
struct ConfigurationTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-cfg-\(UUID().uuidString)/config.json")
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
        let config = Configuration(
            model: "large-v3-turbo", engine: "whisper", language: "de",
            translate: true, silenceThreshold: -42, device: "MicUID")
        try config.save(to: url)
        #expect(Configuration.load(from: url) == config)
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
        #expect(throws: AuralError.self) { try config.set(.translate, rawValue: "maybe") }
        #expect((try? { var c = Configuration(); try c.set(.translate, rawValue: "yes"); return c.translate }()) == true)
        // silence-threshold: numeric + must be negative
        #expect(throws: AuralError.self) { try config.set(.silenceThreshold, rawValue: "abc") }
        #expect(throws: AuralError.self) { try config.set(.silenceThreshold, rawValue: "10") }
        #expect((try? { var c = Configuration(); try c.set(.silenceThreshold, rawValue: "-40"); return c.silenceThreshold }()) == -40)
        // engine: must be known
        #expect(throws: AuralError.self) { try config.set(.engine, rawValue: "bogus") }
        #expect((try? { var c = Configuration(); try c.set(.engine, rawValue: "apple"); return c.engine }()) == "apple")
        // non-empty strings
        #expect(throws: AuralError.self) { try config.set(.model, rawValue: "") }
    }

    @Test func environmentNameMapping() {
        #expect(ConfigKey.model.environmentName == "AURAL_WHISPER_MODEL")
        #expect(ConfigKey.engine.environmentName == "AURAL_ENGINE")
        #expect(ConfigKey.language.environmentName == "AURAL_LANGUAGE")
        #expect(ConfigKey.translate.environmentName == "AURAL_TRANSLATE")
        #expect(ConfigKey.silenceThreshold.environmentName == "AURAL_SILENCE_THRESHOLD")
        #expect(ConfigKey.device.environmentName == "AURAL_DEVICE")
    }

    @Test func thresholdDisplayTrimsWholeNumbers() {
        #expect(Configuration(silenceThreshold: -50).displayValue(for: .silenceThreshold) == "-50")
        #expect(Configuration(silenceThreshold: -42.5).displayValue(for: .silenceThreshold) == "-42.5")
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
