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
            .appendingPathComponent("hark-whisper-\(UUID().uuidString)")
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
            "HARK_WHISPER_BIN": dir.appendingPathComponent("my-whisper").path,
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
            "HARK_WHISPER_SERVER_BIN": dir.appendingPathComponent("my-server").path,
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
            boundary: "BND", wav: wav, responseFormat: "text", translate: false, language: "en")
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
            boundary: "B", wav: Data(), responseFormat: "text", translate: false, language: nil)
        let text = String(decoding: body, as: UTF8.self)
        #expect(!text.contains("name=\"language\""))
    }

    @Test func multipartBodyAddsTranslateFieldOnlyWhenRequested() {
        let off = WhisperServerEngine.multipartBody(
            boundary: "B", wav: Data(), responseFormat: "text", translate: false, language: "de")
        #expect(!String(decoding: off, as: UTF8.self).contains("name=\"translate\""))

        let on = WhisperServerEngine.multipartBody(
            boundary: "B", wav: Data(), responseFormat: "text", translate: true, language: "de")
        #expect(String(decoding: on, as: UTF8.self).contains("name=\"translate\"\r\n\r\ntrue\r\n"))
    }

    @Test func responseFormatMapping() {
        #expect(WhisperServerEngine.responseFormat(for: .txt) == "text")
        #expect(WhisperServerEngine.responseFormat(for: .srt) == "srt")
        #expect(WhisperServerEngine.responseFormat(for: .json) == "json")
    }

    /// Boots a real whisper-server and transcribes one segment over loopback.
    /// Skipped when the server binary, a model, or `say` is unavailable.
    @Test func serverTranscribesSpeechOverLoopback() throws {
        guard let serverBinary = WhisperEngine.discoverServer(),
            let modelPath = try? WhisperEngine.resolveModel(flag: nil)
        else { return }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-srv-it-\(UUID().uuidString)")
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
        let text = try engine.transcribe(
            wavFile: normalized, language: nil, translate: false, format: .txt)
        #expect(text.lowercased().contains("quick brown fox"))
    }
}

@Suite("Whisper model resolution")
struct WhisperModelTests {
    @Test func flagWinsOverEnvironment() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-model-\(UUID().uuidString).bin")
        try Data([0x01]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let resolved = try WhisperEngine.resolveModel(
            flag: file.path, environment: ["HARK_WHISPER_MODEL": "/other.bin"])
        #expect(resolved == file.path)
    }

    @Test func environmentFallback() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-model-\(UUID().uuidString).bin")
        try Data([0x01]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let resolved = try WhisperEngine.resolveModel(
            flag: nil, environment: ["HARK_WHISPER_MODEL": file.path])
        #expect(resolved == file.path)
    }

    @Test func missingModelThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try WhisperEngine.resolveModel(
                flag: nil, environment: [:], config: Configuration())
        }
    }

    @Test func nonexistentModelPathThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try WhisperEngine.resolveModel(
                flag: "/no/such/model.bin", environment: [:], config: Configuration())
        }
    }

    @Test func configModelUsedWhenNoFlagOrEnv() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-cfg-model-\(UUID().uuidString).bin")
        try Data([0x01]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let resolved = try WhisperEngine.resolveModel(
            flag: nil, environment: [:], config: Configuration(model: file.path))
        #expect(resolved == file.path)
    }

    @Test func precedenceFlagBeatsEnvBeatsConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-prec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let flagFile = dir.appendingPathComponent("flag.bin")
        let envFile = dir.appendingPathComponent("env.bin")
        let cfgFile = dir.appendingPathComponent("cfg.bin")
        for f in [flagFile, envFile, cfgFile] { try Data([0x01]).write(to: f) }

        let env = ["HARK_WHISPER_MODEL": envFile.path]
        let config = Configuration(model: cfgFile.path)
        // Flag wins over everything.
        #expect(
            try WhisperEngine.resolveModel(flag: flagFile.path, environment: env, config: config)
                == flagFile.path)
        // Env wins over config when no flag.
        #expect(
            try WhisperEngine.resolveModel(flag: nil, environment: env, config: config)
                == envFile.path)
        // Config used when neither flag nor env.
        #expect(
            try WhisperEngine.resolveModel(flag: nil, environment: [:], config: config)
                == cfgFile.path)
    }
}

@Suite("Whisper arguments")
struct WhisperArgumentTests {
    @Test func buildsBaseArguments() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: nil, translate: false,
            format: .txt, outputBase: "/tmp/out")
        #expect(args == ["-m", "/m.bin", "-f", "/a.wav", "-np", "-otxt", "-of", "/tmp/out"])
    }

    @Test func includesLanguageWhenSet() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: "de", translate: false,
            format: .srt, outputBase: "/o")
        #expect(args.contains("-osrt"))
        #expect(args.suffix(2) == ["-l", "de"])
    }

    @Test func autoLanguagePassesThrough() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: "auto", translate: false,
            format: .txt, outputBase: "/o")
        #expect(args.suffix(2) == ["-l", "auto"])
    }

    @Test func jsonFormatFlag() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: nil, translate: false,
            format: .json, outputBase: "/o")
        #expect(args.contains("-oj"))
    }

    @Test func translateAddsFlagBeforeLanguage() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: "de", translate: true,
            format: .txt, outputBase: "/o")
        #expect(args.contains("-tr"))
        // Language must remain the trailing pair so callers can rely on it.
        #expect(args.suffix(2) == ["-l", "de"])
        let tr = args.firstIndex(of: "-tr")!
        let l = args.firstIndex(of: "-l")!
        #expect(tr < l)
    }

    @Test func noTranslateFlagByDefault() {
        let args = WhisperEngine.buildArguments(
            model: "/m.bin", wav: "/a.wav", language: nil, translate: false,
            format: .txt, outputBase: "/o")
        #expect(!args.contains("-tr"))
    }
}

@Suite("Engine selection")
struct EngineSpecTests {
    @Test func whisperIsImplementedAndCapable() {
        let spec = EngineSpec.named("whisper")
        #expect(spec?.isImplemented == true)
        #expect(spec?.capabilities.translate == true)
        #expect(spec?.capabilities.autoDetect == true)
    }

    @Test func appleIsImplementedButCannotTranslateOrAutoDetect() {
        let spec = EngineSpec.named("apple")
        #expect(spec != nil)
        #expect(spec?.isImplemented == true)
        #expect(spec?.capabilities.translate == false)
        #expect(spec?.capabilities.autoDetect == false)
    }

    @Test func whisperkitImplementedAndCapable() {
        #expect(EngineSpec.named("whisperkit")?.isImplemented == true)
        #expect(EngineSpec.named("whisperkit")?.capabilities.translate == true)
        #expect(EngineSpec.named("whisperkit")?.capabilities.autoDetect == true)
    }

    @Test func unknownEngineIsNil() {
        #expect(EngineSpec.named("bogus") == nil)
    }

    @Test func knownNamesListsEveryEngine() {
        let names = EngineSpec.knownNames
        for engine in ["whisper", "apple", "whisperkit", "cloud"] {
            #expect(names.contains(engine))
        }
    }

    @Test func resolveRejectsUnknownEngine() {
        #expect(throws: HarkError.self) {
            _ = try TranscribeEngine.resolveWhisper(engineName: "bogus", modelFlag: nil)
        }
    }

    @Test func resolveRejectsUnimplementedEngine() {
        #expect(throws: HarkError.self) {
            _ = try TranscribeEngine.resolveWhisper(engineName: "cloud", modelFlag: nil)
        }
    }
}
