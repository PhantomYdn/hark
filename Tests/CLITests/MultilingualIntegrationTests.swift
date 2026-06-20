import Foundation
import Testing

@testable import CLI

/// End-to-end multilingual checks for the whisper engine: transcribe non-English
/// speech in its own language, and translate it to English. Both are skipped
/// automatically unless a local multilingual (non-`.en`) model, the whisper
/// binary, and a German `say` voice are all available — so CI without those
/// stays green. Closes PLAN Phase 6.1's multilingual e2e item.
@Suite("Multilingual transcription (integration)")
struct MultilingualIntegrationTests {
    /// German pangram-ish sentence; its English translation should mention a
    /// fox/dog so the translate assertion has stable anchors.
    private let germanPhrase = "Der schnelle braune Fuchs springt über den faulen Hund."

    @Test func transcribesGermanThenTranslatesToEnglish() throws {
        guard WhisperEngine.discover() != nil,
            let model = multilingualModelPath(),
            let voice = firstVoice(forLanguage: "de_DE")
        else { return }  // prerequisites absent -> skip

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-ml-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let aiff = work.appendingPathComponent("de.aiff")
        guard runSay(germanPhrase, voice: voice, to: aiff) else { return }

        // 1) Transcribe in German -> expect a German token.
        let german = try TranscribeEngine(
            engineName: "whisper", modelFlag: model, language: "de", translate: false,
            format: .txt
        ).transcribe(audioPath: aiff.path).lowercased()
        #expect(["fuchs", "hund", "braune", "schnelle"].contains { german.contains($0) })

        // 2) Translate the same audio to English -> exercises the -tr path and
        //    must produce output. The `large-v3-turbo` model is transcription-only
        //    (it doesn't translate), so only assert English content for models
        //    that actually support translation.
        let english = try TranscribeEngine(
            engineName: "whisper", modelFlag: model, language: "de", translate: true,
            format: .txt
        ).transcribe(audioPath: aiff.path).lowercased()
        #expect(!english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let isTurbo = (model as NSString).lastPathComponent.contains("turbo")
        if !isTurbo {
            #expect(["fox", "dog", "brown", "quick", "fast", "lazy"].contains { english.contains($0) })
        }
    }

    /// First locally installed non-English ggml model, if any.
    private func multilingualModelPath() -> String? {
        ModelRegistry.localModels()
            .first { !ModelRegistry.isEnglishOnly(modelPath: $0.path) }?
            .path
    }

    /// Name of the first `say` voice for a BCP/locale tag (e.g. "de_DE"), or nil.
    private func firstVoice(forLanguage tag: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let listing = String(decoding: data, as: UTF8.self)
        for line in listing.split(separator: "\n") where line.contains(tag) {
            // Format: "Anna                de_DE    # Hello, ...".
            let name = line.prefix { $0 != " " }
            if !name.isEmpty { return String(name) }
        }
        return nil
    }

    private func runSay(_ phrase: String, voice: String, to url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, phrase]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
