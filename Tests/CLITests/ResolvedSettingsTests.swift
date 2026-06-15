import Foundation
import Testing

@testable import CLI

@Suite("Resolved settings")
struct ResolvedSettingsTests {
    private func resolve(
        engineFlag: String? = nil, languageFlag: String? = nil, translateFlag: Bool? = nil,
        silenceFlag: Double? = nil, deviceFlag: String? = nil,
        env: [String: String] = [:], config: Configuration = Configuration()
    ) throws -> ResolvedSettings {
        try ResolvedSettings.resolve(
            engineFlag: engineFlag, languageFlag: languageFlag, translateFlag: translateFlag,
            silenceFlag: silenceFlag, deviceFlag: deviceFlag, environment: env, config: config)
    }

    @Test func builtInDefaultsWhenNothingSet() throws {
        let s = try resolve()
        #expect(s.engine == "whisper")
        #expect(s.language == "auto")
        #expect(s.translate == false)
        #expect(s.silenceThreshold == -50)
        #expect(s.micDevice == nil)
    }

    @Test func configProvidesDefaults() throws {
        let config = Configuration(
            model: "x", engine: "whisperkit", language: "de", translate: true,
            silenceThreshold: -42, device: "MicUID")
        let s = try resolve(config: config)
        #expect(s.engine == "whisperkit")
        #expect(s.language == "de")
        #expect(s.translate == true)
        #expect(s.silenceThreshold == -42)
        #expect(s.micDevice == "MicUID")
    }

    @Test func envOverridesConfig() throws {
        let config = Configuration(
            engine: "whisper", language: "de", translate: false,
            silenceThreshold: -42, device: "CfgMic")
        let env = [
            "AURAL_ENGINE": "whisperkit", "AURAL_LANGUAGE": "fr",
            "AURAL_TRANSLATE": "true", "AURAL_SILENCE_THRESHOLD": "-30",
            "AURAL_DEVICE": "EnvMic",
        ]
        let s = try resolve(env: env, config: config)
        #expect(s.engine == "whisperkit")
        #expect(s.language == "fr")
        #expect(s.translate == true)
        #expect(s.silenceThreshold == -30)
        #expect(s.micDevice == "EnvMic")
    }

    @Test func flagOverridesEverything() throws {
        let config = Configuration(
            engine: "whisper", language: "de", translate: false,
            silenceThreshold: -42, device: "CfgMic")
        let env = [
            "AURAL_ENGINE": "apple", "AURAL_LANGUAGE": "fr",
            "AURAL_TRANSLATE": "true", "AURAL_SILENCE_THRESHOLD": "-30",
            "AURAL_DEVICE": "EnvMic",
        ]
        let s = try resolve(
            engineFlag: "whisperkit", languageFlag: "es", translateFlag: false,
            silenceFlag: -25, deviceFlag: "FlagMic", env: env, config: config)
        #expect(s.engine == "whisperkit")
        #expect(s.language == "es")
        #expect(s.translate == false)  // --no-translate beats env/config
        #expect(s.silenceThreshold == -25)
        #expect(s.micDevice == "FlagMic")
    }

    @Test func emptyEnvValuesAreIgnored() throws {
        let s = try resolve(
            env: ["AURAL_ENGINE": "", "AURAL_LANGUAGE": ""],
            config: Configuration(engine: "whisperkit", language: "de"))
        #expect(s.engine == "whisperkit")
        #expect(s.language == "de")
    }

    @Test func malformedEnvTranslateThrows() {
        #expect(throws: AuralError.self) {
            _ = try resolve(env: ["AURAL_TRANSLATE": "maybe"])
        }
    }

    @Test func malformedEnvThresholdThrows() {
        #expect(throws: AuralError.self) {
            _ = try resolve(env: ["AURAL_SILENCE_THRESHOLD": "loud"])
        }
        #expect(throws: AuralError.self) {
            _ = try resolve(env: ["AURAL_SILENCE_THRESHOLD": "5"])  // not negative
        }
    }

    @Test func validateRejectsMergedConflicts() {
        // Unknown engine from config.
        #expect(throws: AuralError.self) {
            try ResolvedSettings(
                engine: "bogus", language: "auto", translate: false,
                silenceThreshold: -50, micDevice: nil).validate()
        }
        // Translate requested for an engine that can't (apple via config + flag).
        #expect(throws: AuralError.self) {
            try ResolvedSettings(
                engine: "apple", language: "auto", translate: true,
                silenceThreshold: -50, micDevice: nil).validate()
        }
        // Non-negative threshold.
        #expect(throws: AuralError.self) {
            try ResolvedSettings(
                engine: "whisper", language: "auto", translate: false,
                silenceThreshold: 0, micDevice: nil).validate()
        }
    }

    @Test func validateAcceptsValidMerged() throws {
        try ResolvedSettings(
            engine: "whisper", language: "de", translate: true,
            silenceThreshold: -40, micDevice: "Mic").validate()
    }
}
