import Foundation
import Testing

@testable import CLI

@Suite("WhisperEngine discovery")
struct WhisperDiscoveryTests {
    private func makeExecutable(named name: String, in dir: URL) throws {
        let path = dir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func findsWhisperCliOnPath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "whisper-cli", in: dir)
        let found = WhisperEngine.discover(environment: ["PATH": dir.path])
        #expect(found?.lastPathComponent == "whisper-cli")
    }

    @Test func prefersWhisperCliOverWhisperCpp() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "whisper-cli", in: dir)
        try makeExecutable(named: "whisper-cpp", in: dir)
        let found = WhisperEngine.discover(environment: ["PATH": dir.path])
        #expect(found?.lastPathComponent == "whisper-cli")
    }

    @Test func fallsBackToWhisperCpp() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "whisper-cpp", in: dir)
        let found = WhisperEngine.discover(environment: ["PATH": dir.path])
        #expect(found?.lastPathComponent == "whisper-cpp")
    }

    @Test func returnsNilWhenAbsent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WhisperEngine.discover(environment: ["PATH": dir.path]) == nil)
    }

    @Test func binOverrideWins() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "my-whisper", in: dir)
        let env = [
            "PATH": "/nonexistent",
            "AURAL_WHISPER_BIN": dir.appendingPathComponent("my-whisper").path,
        ]
        #expect(WhisperEngine.discover(environment: env)?.lastPathComponent == "my-whisper")
    }

    @Test func findsServerOnPath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "whisper-server", in: dir)
        let found = WhisperEngine.discoverServer(environment: ["PATH": dir.path])
        #expect(found?.lastPathComponent == "whisper-server")
    }

    @Test func serverAbsentReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "whisper-cli", in: dir)  // cli present, server not
        #expect(WhisperEngine.discoverServer(environment: ["PATH": dir.path]) == nil)
    }

    @Test func serverBinOverrideWins() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "my-server", in: dir)
        let env = [
            "PATH": "/nonexistent",
            "AURAL_WHISPER_SERVER_BIN": dir.appendingPathComponent("my-server").path,
        ]
        #expect(
            WhisperEngine.discoverServer(environment: env)?.lastPathComponent == "my-server")
    }
}

@Suite("Whisper server backend")
struct WhisperServerTests {
    @Test func freePortIsUsableAndNotYetListening() {
        guard let port = freePort() else {
            Issue.record("freePort returned nil")
            return
        }
        #expect(port > 0)
        // Nothing is listening on the freshly-allocated port.
        #expect(tcpConnectable(port: port) == false)
    }

    @Test func multipartBodyContainsFileAndFields() {
        let wav = Data("RIFFxxxxWAVE".utf8)
        let body = WhisperServerEngine.multipartBody(
            boundary: "BND", wav: wav, responseFormat: "text", language: "en")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("--BND\r\n"))
        #expect(text.contains("name=\"file\"; filename=\"segment.wav\""))
        #expect(text.contains("Content-Type: audio/wav"))
        #expect(text.contains("name=\"response_format\"\r\n\r\ntext\r\n"))
        #expect(text.contains("name=\"language\"\r\n\r\nen\r\n"))
        #expect(text.hasSuffix("--BND--\r\n"))
        #expect(text.contains("RIFFxxxxWAVE"))
    }

    @Test func multipartBodyOmitsLanguageWhenNil() {
        let body = WhisperServerEngine.multipartBody(
            boundary: "B", wav: Data(), responseFormat: "text", language: nil)
        let text = String(decoding: body, as: UTF8.self)
        #expect(!text.contains("name=\"language\""))
    }

    /// Boots a real whisper-server and transcribes one segment over loopback.
    /// Skipped when the server binary, a model, or `say` is unavailable.
    @Test func serverTranscribesSpeechOverLoopback() throws {
        guard let serverBinary = WhisperEngine.discoverServer(),
            let modelPath = try? WhisperEngine.resolveModel(flag: nil)
        else { return }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-srv-it-\(UUID().uuidString)")
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
            return  // `say` unavailable -> skip
        }
        guard say.terminationStatus == 0 else { return }

        let normalized = try AudioPipeline.normalizeFileForWhisper(aiff.path)
        defer { try? FileManager.default.removeItem(at: normalized) }

        let engine = try WhisperServerEngine.start(
            serverBinary: serverBinary, modelPath: modelPath, quiet: true)
        defer { engine.shutdown() }
        let text = try engine.transcribe(wavFile: normalized, language: nil)
        #expect(text.lowercased().contains("quick brown fox"))
    }
}

@Suite("Whisper model resolution")
struct WhisperModelTests {
    @Test func flagWinsOverEnvironment() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-model-\(UUID().uuidString).bin")
        try Data([0x01]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let resolved = try WhisperEngine.resolveModel(
            flag: file.path, environment: ["AURAL_WHISPER_MODEL": "/other.bin"])
        #expect(resolved == file.path)
    }

    @Test func environmentFallback() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-model-\(UUID().uuidString).bin")
        try Data([0x01]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let resolved = try WhisperEngine.resolveModel(
            flag: nil, environment: ["AURAL_WHISPER_MODEL": file.path])
        #expect(resolved == file.path)
    }

    @Test func missingModelThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try WhisperEngine.resolveModel(flag: nil, environment: [:])
        }
    }

    @Test func nonexistentModelPathThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try WhisperEngine.resolveModel(flag: "/no/such/model.bin", environment: [:])
        }
    }
}

@Suite("Whisper arguments")
struct WhisperArgumentTests {
    @Test func buildsBaseArguments() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: nil, format: .txt, outputBase: "/tmp/out")
        #expect(args == ["-m", "/m.bin", "-f", "/a.wav", "-np", "-otxt", "-of", "/tmp/out"])
    }

    @Test func includesLanguageWhenSet() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: "de", format: .srt, outputBase: "/o")
        #expect(args.contains("-osrt"))
        #expect(args.suffix(2) == ["-l", "de"])
    }

    @Test func jsonFormatFlag() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: nil, format: .json, outputBase: "/o")
        #expect(args.contains("-oj"))
    }
}
