import Foundation
import Testing

@testable import CLI

@Suite("WhisperKit backend")
struct WhisperKitBackendTests {
    @Test func languageCodeMapping() {
        #expect(WhisperKitBackend.languageCode("auto") == nil)
        #expect(WhisperKitBackend.languageCode("") == nil)
        #expect(WhisperKitBackend.languageCode(nil) == nil)
        #expect(WhisperKitBackend.languageCode("de") == "de")
        #expect(WhisperKitBackend.languageCode("DE") == "de")
    }

    @Test func downloadBaseIsUnderHarkModels() {
        #expect(WhisperKitBackend.downloadBase.path.hasSuffix("/.hark/models/whisperkit"))
    }

    @Test func cleanStripsSpecialTokens() {
        let raw = "<|startoftranscript|><|en|><|transcribe|><|0.00|> Hello world.<|2.50|><|endoftext|>"
        #expect(WhisperKitBackend.clean(raw) == "Hello world.")
        #expect(WhisperKitBackend.clean("  plain text  ") == "plain text")
    }
}

@Suite("Transcript formatting")
struct TranscriptFormattingTests {
    private let cues = [
        TranscriptCue(start: 0, end: 1.5, text: "Hello world"),
        TranscriptCue(start: 1.5, end: 3, text: "second line"),
    ]

    @Test func txtUsesFullText() {
        let out = TranscriptFormatting.render(cues: cues, fullText: "Hello world second line", format: .txt)
        #expect(out == "Hello world second line\n")
    }

    @Test func srtNumbersCuesWithTimestamps() {
        let out = TranscriptFormatting.render(cues: cues, fullText: "", format: .srt)
        #expect(out.hasPrefix("1\n00:00:00,000 --> 00:00:01,500\nHello world\n\n"))
        #expect(out.contains("2\n00:00:01,500 --> 00:00:03,000\nsecond line"))
    }

    @Test func jsonIsValidArray() throws {
        let out = TranscriptFormatting.render(cues: cues, fullText: "", format: .json)
        let data = Data(out.utf8)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(decoded?.count == 2)
        #expect(decoded?.first?["text"] as? String == "Hello world")
        #expect(decoded?.first?["end"] as? Double == 1.5)
    }
}

@Suite("CoreML model cache listing")
struct CoreMLModelsTests {
    @Test func listsVariantDirectoriesContainingMlmodelc() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-coreml-\(UUID().uuidString)")
        // root/variantA/Encoder.mlmodelc/<file> and root/variantB/Decoder.mlmodelc/<file>
        let fm = FileManager.default
        for variant in ["variantA", "variantB"] {
            let bundle = root.appendingPathComponent("\(variant)/Model.mlmodelc", isDirectory: true)
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 1024).write(to: bundle.appendingPathComponent("weights.bin"))
        }
        // A stray non-model directory is ignored.
        try fm.createDirectory(
            at: root.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let models = ModelRegistry.coreMLModels(engine: "whisperkit", directory: root)
        #expect(models.map(\.name) == ["variantA", "variantB"])
        #expect(models.allSatisfy { $0.engine == "whisperkit" })
        #expect((models.first?.sizeBytes ?? 0) >= 1024)
    }

    @Test func missingDirectoryYieldsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-none-\(UUID().uuidString)")
        #expect(ModelRegistry.coreMLModels(engine: "whisperkit", directory: missing).isEmpty)
    }
}

/// On-device WhisperKit transcription. Heavy (downloads a CoreML model), so it
/// only runs when HARK_TEST_WHISPERKIT=1 and on Apple Silicon.
@Suite("WhisperKit transcription (integration)")
struct WhisperKitIntegrationTests {
    @Test func transcribesSpeech() throws {
        guard Platform.isAppleSilicon,
            ProcessInfo.processInfo.environment["HARK_TEST_WHISPERKIT"] == "1"
        else { return }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-wk-it-\(UUID().uuidString)")
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

        let backend = try WhisperKitBackend.make(model: "tiny")
        let text = try backend.transcribe(
            wavFile: normalized, language: "en", translate: false, format: .txt
        ).lowercased()
        #expect(text.contains("fox"))
    }
}
