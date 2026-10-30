import FluidAudio
import Foundation
import Testing

@testable import CLI

@Suite("Parakeet backend")
struct ParakeetBackendTests {
    @Test func resolvesVariantsByNameAndAlias() {
        #expect(ParakeetBackend.resolve("ultra")?.version == .ultra)
        #expect(ParakeetBackend.resolve("v3")?.version == .v3)
        #expect(ParakeetBackend.resolve("redux")?.version == .redux)
        #expect(ParakeetBackend.resolve("v2")?.version == .v2)
        #expect(ParakeetBackend.resolve("en")?.version == .v2)
        #expect(ParakeetBackend.resolve("phonon-2")?.version == .phonon2)
        #expect(ParakeetBackend.resolve("bark")?.version == .bark3)
        #expect(ParakeetBackend.resolve("bark-clean")?.version == .bark3Clean)
        #expect(ParakeetBackend.resolve("110m")?.version == .tdtCtc110m)
        #expect(ParakeetBackend.resolve("JA")?.version == .tdtJa)
        // Engine-prefixed names, as `parakeet-v2` used to be accepted.
        #expect(ParakeetBackend.resolve("parakeet-v2")?.version == .v2)
        #expect(ParakeetBackend.resolve("parakeet:ultra")?.version == .ultra)
    }

    @Test func resolvesCachedBundleNames() {
        // FluidAudio's cache dir names (what `config set model` users copy from
        // `hark models list`), with or without the HF repo's -coreml suffix.
        #expect(ParakeetBackend.resolve("parakeet-tdt-0.6b-v3")?.version == .v3)
        #expect(ParakeetBackend.resolve("parakeet-tdt-0.6b-v3-coreml")?.version == .v3)
        for model in ParakeetBackend.models {
            #expect(ParakeetBackend.resolve(model.bundleName) == model)
        }
    }

    @Test func unknownNamesFallBackToUltraDefault() {
        #expect(ParakeetBackend.defaultModel.version == .ultra)
        #expect(ParakeetBackend.resolve(nil) == nil)
        #expect(ParakeetBackend.resolve("base.en") == nil)
        #expect(ParakeetBackend.resolveOrDefault(nil).version == .ultra)
        #expect(ParakeetBackend.resolveOrDefault("base.en").version == .ultra)
    }

    @Test func variantTableIsConsistent() {
        let models = ParakeetBackend.models
        // Every name/alias is unique, and every FluidAudio version is exposed once.
        let keys = models.flatMap { [$0.name] + $0.aliases }
        #expect(Set(keys).count == keys.count)
        #expect(Set(models.map(\.bundleName)).count == models.count)
        #expect(models.count == 9)
        // Bundle dirs that don't say "parakeet" still classify as the parakeet engine.
        for model in models {
            #expect(FluidAudioCache.engine(forBundle: model.bundleName) == "parakeet")
        }
        // tdt-ctc-110m has a single-layer decoder (TdtDecoderState must match).
        #expect(ParakeetBackend.resolve("tdt-ctc-110m")?.version.decoderLayers == 1)
    }

    @Test func languageNoticeOnlyForSpecificLanguage() {
        #expect(ParakeetBackend.languageNotice("auto") == nil)
        #expect(ParakeetBackend.languageNotice(nil) == nil)
        #expect(ParakeetBackend.languageNotice("") == nil)
        #expect(ParakeetBackend.languageNotice("de") != nil)
    }

    @Test func downloadBaseIsFluidAudioCache() {
        #expect(ParakeetBackend.downloadBase.path.hasSuffix("/FluidAudio/Models"))
    }

    @Test func cuesGroupTokenTimingsOnSentenceEnd() {
        let timings = [
            TokenTiming(token: "▁Hello", tokenId: 1, startTime: 0.0, endTime: 0.5, confidence: 1),
            TokenTiming(token: "▁world", tokenId: 2, startTime: 0.5, endTime: 1.0, confidence: 1),
            TokenTiming(token: ".", tokenId: 3, startTime: 1.0, endTime: 1.1, confidence: 1),
            TokenTiming(token: "▁Bye", tokenId: 4, startTime: 1.5, endTime: 2.0, confidence: 1),
        ]
        let result = ASRResult(
            text: "Hello world. Bye", confidence: 1, duration: 2.0, processingTime: 0.1,
            tokenTimings: timings)
        let cues = ParakeetBackend.cues(from: result)
        #expect(cues.count == 2)
        #expect(cues[0].text == "Hello world.")
        #expect(cues[0].start == 0.0)
        #expect(cues[0].end == 1.1)
        #expect(cues[1].text == "Bye")
        #expect(cues[1].end == 2.0)
    }

    @Test func cuesFallBackToWholeClipWithoutTimings() {
        let result = ASRResult(
            text: "no timings here", confidence: 1, duration: 3.0, processingTime: 0.1,
            tokenTimings: nil)
        let cues = ParakeetBackend.cues(from: result)
        #expect(cues.count == 1)
        #expect(cues[0].text == "no timings here")
        #expect(cues[0].end == 3.0)
    }
}

@Suite("Parakeet engine spec")
struct ParakeetEngineSpecTests {
    @Test func implementedAutoDetectNoTranslate() {
        let spec = EngineSpec.named("parakeet")
        #expect(spec?.isImplemented == true)
        #expect(spec?.capabilities.autoDetect == true)
        #expect(spec?.capabilities.translate == false)
    }
}

/// On-device Parakeet transcription. Heavy (downloads CoreML models), so it only
/// runs when HARK_TEST_PARAKEET=1 and on Apple Silicon.
@Suite("Parakeet transcription (integration)")
struct ParakeetIntegrationTests {
    @Test func transcribesSpeech() throws {
        guard Platform.isAppleSilicon,
            ProcessInfo.processInfo.environment["HARK_TEST_PARAKEET"] == "1"
        else { return }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-pk-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let aiff = work.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "the quick brown fox jumps over the lazy dog"]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { return }

        let normalized = try AudioPipeline.normalizeFileForWhisper(aiff.path)
        defer { try? FileManager.default.removeItem(at: normalized) }

        let backend = try ParakeetBackend.make(model: nil, language: nil)
        let text = try backend.transcribe(
            wavFile: normalized, language: nil, translate: false, format: .txt
        ).lowercased()
        #expect(text.contains("fox"))
    }
}
