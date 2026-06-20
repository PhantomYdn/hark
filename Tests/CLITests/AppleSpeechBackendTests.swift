import Foundation
import Speech
import Testing

@testable import CLI

@Suite("Apple speech backend")
struct AppleSpeechBackendTests {
    private let supported = [
        Locale(identifier: "en-US"), Locale(identifier: "en-GB"),
        Locale(identifier: "de-DE"), Locale(identifier: "fr-FR"),
    ]

    @Test func languageOnlyMatchesRegionLocale() {
        #expect(AppleSpeechBackend.matchLocale("de", in: supported).identifier == "de-DE")
        #expect(AppleSpeechBackend.matchLocale("fr", in: supported).identifier == "fr-FR")
    }

    @Test func exactIdentifierMatches() {
        #expect(AppleSpeechBackend.matchLocale("en-GB", in: supported).identifier == "en-GB")
        // Underscore form is normalized to a hyphen.
        #expect(AppleSpeechBackend.matchLocale("de_DE", in: supported).identifier == "de-DE")
    }

    @Test func autoAndNilUseCurrentLocale() {
        let current = Locale(identifier: "it-IT")
        #expect(AppleSpeechBackend.matchLocale("auto", in: supported, current: current).identifier == "it-IT")
        #expect(AppleSpeechBackend.matchLocale(nil, in: supported, current: current).identifier == "it-IT")
    }

    @Test func unsupportedLanguageFallsBackToConstructedLocale() {
        // "es" is absent from the supported list -> constructed from the value.
        #expect(AppleSpeechBackend.matchLocale("es", in: supported).identifier == "es")
    }

    @Test func rejectsTranslate() {
        #expect(AppleSpeechBackend.unsupportedRequest(translate: true, format: .txt) != nil)
    }

    @Test func rejectsNonTextFormats() {
        #expect(AppleSpeechBackend.unsupportedRequest(translate: false, format: .srt) != nil)
        #expect(AppleSpeechBackend.unsupportedRequest(translate: false, format: .json) != nil)
    }

    @Test func acceptsPlainText() {
        #expect(AppleSpeechBackend.unsupportedRequest(translate: false, format: .txt) == nil)
    }

    /// On-device recognition of `say`-synthesized speech. Skipped unless Speech
    /// is already authorized (so it never prompts in CI/headless) and `say`
    /// works, keeping the suite green without permissions.
    @Test func transcribesSpeechOnDevice() throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-apple-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let aiff = work.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "the quick brown fox jumps over the lazy dog"]
        do {
            try say.run()
            say.waitUntilExit()
        } catch {
            return
        }
        guard say.terminationStatus == 0 else { return }

        let normalized = try AudioPipeline.normalizeFileForWhisper(aiff.path)
        defer { try? FileManager.default.removeItem(at: normalized) }

        let backend: AppleSpeechBackend
        do {
            backend = try AppleSpeechBackend.make(language: "en")
        } catch {
            return  // on-device asset/locale unavailable -> skip
        }
        let text = try backend.transcribe(
            wavFile: normalized, language: "en", translate: false, format: .txt
        ).lowercased()
        #expect(text.contains("fox"))
    }
}
