import Foundation
import Testing

@testable import CLI

@Suite("Model registry")
struct ModelRegistryTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL, bytes: Int = 1) throws {
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    @Test func fileNameAndDownloadURL() {
        #expect(ModelRegistry.fileName(for: "large-v3-turbo") == "ggml-large-v3-turbo.bin")
        #expect(ModelRegistry.fileName(for: "base.en") == "ggml-base.en.bin")
        #expect(
            ModelRegistry.downloadURL(for: "base.en").absoluteString
                == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")
    }

    @Test func resolvesExistingFilePathDirectly() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("custom.bin")
        try touch(file)
        #expect(ModelRegistry.resolvePath(file.path, directory: dir) == file.path)
    }

    @Test func resolvesShortNameInDirectory() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("ggml-large-v3-turbo.bin")
        try touch(model)
        #expect(ModelRegistry.resolvePath("large-v3-turbo", directory: dir) == model.path)
    }

    @Test func unknownShortNameReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelRegistry.resolvePath("nope", directory: dir) == nil)
    }

    @Test func nonexistentPathReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A path-like value that does not exist is not treated as a short name.
        #expect(ModelRegistry.resolvePath("/no/such/model.bin", directory: dir) == nil)
    }

    @Test func englishOnlyDetection() {
        #expect(ModelRegistry.isEnglishOnly(modelPath: "/x/ggml-base.en.bin"))
        #expect(ModelRegistry.isEnglishOnly(modelPath: "/x/ggml-small.en.bin"))
        #expect(!ModelRegistry.isEnglishOnly(modelPath: "/x/ggml-large-v3-turbo.bin"))
        #expect(!ModelRegistry.isEnglishOnly(modelPath: "/x/ggml-base.bin"))
    }

    @Test func warnsOnEnglishModelWithOtherLanguageOrTranslate() {
        let en = "/x/ggml-base.en.bin"
        // English-only + foreign language or translate => warn.
        #expect(ModelRegistry.shouldWarnEnglishOnly(modelPath: en, language: "de", translate: false))
        #expect(ModelRegistry.shouldWarnEnglishOnly(modelPath: en, language: "auto", translate: true))
        // English-only + English/auto and no translate => no warning.
        #expect(!ModelRegistry.shouldWarnEnglishOnly(modelPath: en, language: "en", translate: false))
        #expect(!ModelRegistry.shouldWarnEnglishOnly(modelPath: en, language: "auto", translate: false))
        // Multilingual model never warns.
        let multi = "/x/ggml-large-v3.bin"
        #expect(!ModelRegistry.shouldWarnEnglishOnly(modelPath: multi, language: "de", translate: true))
    }

    @Test func listsGgmlModelsSortedAndIgnoresOthers() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch(dir.appendingPathComponent("ggml-small.bin"), bytes: 10)
        try touch(dir.appendingPathComponent("ggml-base.en.bin"), bytes: 20)
        try touch(dir.appendingPathComponent("notes.txt"))  // ignored
        try touch(dir.appendingPathComponent("ggml-tiny.en.zip"))  // ignored (not .bin)

        let models = ModelRegistry.localModels(directory: dir)
        #expect(models.map(\.name) == ["base.en", "small"])
        #expect(models.first?.sizeBytes == 20)
    }

    @Test func emptyOrMissingDirectoryYieldsNoModels() throws {
        let dir = try tempDir()
        try? FileManager.default.removeItem(at: dir)  // does not exist
        #expect(ModelRegistry.localModels(directory: dir).isEmpty)
    }

    @Test func currentModelPathResolvesEnvPathAndShortName() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("ggml-small.bin")
        try touch(model)

        let empty = Configuration()
        // Env as an absolute path.
        #expect(
            ModelRegistry.currentModelPath(
                directory: dir, environment: ["AURAL_WHISPER_MODEL": model.path], config: empty)
                == model.path)
        // Env as a short name resolved under the directory.
        #expect(
            ModelRegistry.currentModelPath(
                directory: dir, environment: ["AURAL_WHISPER_MODEL": "small"], config: empty)
                == model.path)
        // Unset / unresolvable.
        #expect(
            ModelRegistry.currentModelPath(directory: dir, environment: [:], config: empty) == nil)
        #expect(
            ModelRegistry.currentModelPath(
                directory: dir, environment: ["AURAL_WHISPER_MODEL": "nope"], config: empty) == nil)
        // Config falls back when env is unset.
        #expect(
            ModelRegistry.currentModelPath(
                directory: dir, environment: [:], config: Configuration(model: "small"))
                == model.path)
    }

    @Test func localModelsFlagsCurrentEntry() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch(dir.appendingPathComponent("ggml-small.bin"))
        try touch(dir.appendingPathComponent("ggml-base.en.bin"))

        let models = ModelRegistry.localModels(
            directory: dir, environment: ["AURAL_WHISPER_MODEL": "small"], config: Configuration())
        #expect(models.first { $0.name == "small" }?.current == true)
        #expect(models.first { $0.name == "base.en" }?.current == false)

        // Config selection when no env.
        let viaConfig = ModelRegistry.localModels(
            directory: dir, environment: [:], config: Configuration(model: "base.en"))
        #expect(viaConfig.first { $0.name == "base.en" }?.current == true)

        // No env or config selection => nothing current.
        let none = ModelRegistry.localModels(
            directory: dir, environment: [:], config: Configuration())
        #expect(none.allSatisfy { !$0.current })
    }

    @Test func shortNameFromPath() {
        #expect(ModelRegistry.shortName(forPath: "/x/ggml-base.en.bin") == "base.en")
        #expect(ModelRegistry.shortName(forPath: "/x/ggml-large-v3-turbo.bin") == "large-v3-turbo")
        #expect(ModelRegistry.shortName(forPath: "/x/notes.txt") == nil)
    }
}
