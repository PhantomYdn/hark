import Foundation
import Testing

@testable import CLI

@Suite("Model catalog")
struct ModelCatalogTests {
    @Test func parsesParakeetTaggedNames() {
        #expect(ModelCatalog.parse("parakeet:v3") == DownloadableModel(engine: "parakeet", name: "parakeet:v3", modelId: "v3"))
        #expect(ModelCatalog.parse("parakeet-v2").modelId == "v2")
        #expect(ModelCatalog.parse("parakeet-v2").engine == "parakeet")
        // Bare engine name selects the default variant (ultra).
        #expect(ModelCatalog.parse("parakeet").modelId == "ultra")
        // Aliases canonicalize to the variant name.
        #expect(ModelCatalog.parse("parakeet:bark-clean").modelId == "bark3-clean")
        #expect(ModelCatalog.parse("parakeet:en").modelId == "v2")
    }

    @Test func parsesWhisperkitTaggedNames() {
        let m = ModelCatalog.parse("whisperkit:large-v3-v20240930_626MB")
        #expect(m.engine == "whisperkit")
        #expect(m.modelId == "large-v3-v20240930_626MB")
        #expect(ModelCatalog.parse("whisperkit:tiny").modelId == "tiny")
    }

    @Test func bareNamesAreWhisper() {
        #expect(ModelCatalog.parse("base.en") == DownloadableModel(engine: "whisper", name: "base.en", modelId: "base.en"))
        #expect(ModelCatalog.parse("large-v3-turbo").engine == "whisper")
    }

    @Test func englishOnlyClassification() {
        #expect(ModelCatalog.parse("base.en").isEnglishOnly)
        #expect(!ModelCatalog.parse("large-v3-turbo").isEnglishOnly)
        #expect(!ModelCatalog.parse("parakeet:v3").isEnglishOnly)
        #expect(ModelCatalog.parse("parakeet:v2").isEnglishOnly)
        #expect(!ModelCatalog.parse("parakeet:ultra").isEnglishOnly)
        #expect(ModelCatalog.parse("parakeet:bark3").isEnglishOnly)
        #expect(ModelCatalog.parse("parakeet:ja").languages == "japanese")
        #expect(ModelCatalog.parse("fluidaudio:vad").languages == "speaker pipeline")
        #expect(ModelCatalog.parse("whisperkit:small.en").isEnglishOnly)
        #expect(!ModelCatalog.parse("whisperkit:tiny").isEnglishOnly)
    }

    @Test func availableCoversEveryEngine() {
        let catalog = ModelCatalog.available()
        let engines = Set(catalog.map(\.engine))
        #expect(engines == ["whisper", "whisperkit", "parakeet", "fluidaudio"])
        #expect(catalog.contains { $0.name == "parakeet:v3" })
        #expect(catalog.contains { $0.name == "parakeet:v2" })
        #expect(catalog.filter { $0.engine == "parakeet" }.map(\.name) == [
            "parakeet:ultra", "parakeet:v3", "parakeet:redux", "parakeet:v2",
            "parakeet:phonon2", "parakeet:bark3", "parakeet:bark3-clean",
            "parakeet:tdt-ctc-110m", "parakeet:ja",
        ])
        #expect(catalog.contains { $0.name == "whisperkit:tiny" })
        #expect(catalog.contains { $0.engine == "whisper" && $0.name == "base.en" })
    }

    @Test func downloadDispatchRoutesByEngine() {
        // Round-trips: a parsed name maps to the engine whose download path runs.
        #expect(ModelCatalog.parse("parakeet:v3").engine == "parakeet")
        #expect(ModelCatalog.parse("whisperkit:tiny").engine == "whisperkit")
        #expect(ModelCatalog.parse("small").engine == "whisper")
    }
}
