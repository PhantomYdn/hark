import Encoders
import Foundation
import TapEngine

/// Where a transcript is written.
enum TranscriptDestination {
    case stdout
    case file(String)

    var label: String {
        switch self {
        case .stdout: return "stdout (transcript)"
        case .file(let path): return path
        }
    }
}

/// Transcription core: turns any readable audio file into a transcript and
/// writes it to the requested destination. Handles engine/model discovery
/// and exit-code propagation (US03). The whisper.cpp backend requires a
/// 16 kHz mono WAV, so input is normalized internally first.
struct TranscribeEngine {
    let engineName: String
    let modelFlag: String?
    let language: String?
    let translate: Bool
    let format: TranscriptOutputFormat

    /// Normalizes `audioPath` to a whisper-ready WAV, runs the engine, and
    /// returns the transcript text in the requested format.
    func transcribe(audioPath: String) throws -> String {
        let whisper = try Self.resolveWhisper(engineName: engineName, modelFlag: modelFlag)
        ModelRegistry.warnIfModelLanguageMismatch(
            modelPath: whisper.modelPath, language: language, translate: translate)
        let backend = WhisperCLIBackend(engine: whisper, quietStderr: false)
        Log.verbose("normalizing '\(audioPath)' to 16 kHz mono WAV")
        let wavFile = try AudioPipeline.normalizeFileForWhisper(audioPath)
        defer { try? FileManager.default.removeItem(at: wavFile) }
        return try backend.transcribe(
            wavFile: wavFile, language: language, translate: translate, format: format)
    }

    /// Resolves the transcription engine: validates the backend is known and
    /// implemented, locates the whisper binary on PATH (or `$AURAL_WHISPER_BIN`),
    /// and the model. Used to fail fast before capture starts and by the live
    /// transcriber.
    static func resolveWhisper(engineName: String, modelFlag: String?) throws -> WhisperEngine {
        guard let spec = EngineSpec.named(engineName) else {
            throw AuralError.usage(
                "unknown engine '\(engineName)' (known: \(EngineSpec.knownNames)).")
        }
        guard spec.isImplemented else {
            throw AuralError.unavailable(
                (spec.plannedNote ?? "engine '\(engineName)' is not available")
                    + "; use --engine whisper.")
        }
        guard let binary = WhisperEngine.discover() else {
            throw TranscriptionError.engineNotFound
        }
        let modelPath = try WhisperEngine.resolveModel(flag: modelFlag)
        Log.verbose("engine: \(binary.path), model: \(modelPath)")
        return WhisperEngine(binary: binary, modelPath: modelPath)
    }

    /// Writes a transcript to its destination: stdout (newline-terminated)
    /// or a file.
    func write(_ transcript: String, to destination: TranscriptDestination) throws {
        switch destination {
        case .stdout:
            print(transcript, terminator: transcript.hasSuffix("\n") ? "" : "\n")
        case .file(let path):
            do {
                try transcript.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                throw AuralError.ioError("cannot write transcript to '\(path)': \(error)")
            }
            Log.verbose("wrote transcript to \(path)")
        }
    }
}

extension TranscribeEngine {
    /// Reads audio from stdin (a WAV stream or raw PCM) into a temporary WAV
    /// in its original format and returns the file URL. The caller owns the
    /// returned file. Raw-PCM streams are interpreted with the supplied
    /// format hints; WAV streams are self-describing.
    static func stageStdin(rate: Int, bits: Int, channels: Int) throws -> URL {
        guard isatty(STDIN_FILENO) == 0 else {
            throw AuralError.usage(
                "refusing to read audio from a terminal; pipe data into 'aural -i -'.")
        }
        let reader = StreamReader(handle: .standardInput)

        // Sniff: WAV stream (aural -a -) or raw PCM (aural --raw -a -)?
        let sniff = reader.peek(4)
        let format: PCMFormat
        var remainingPayload: UInt64 = .max
        if sniff == Data("RIFF".utf8) {
            let header: WAVStreamHeader
            do {
                header = try WAVStreamParser.parseHeader { try reader.next($0) }
            } catch let error as WAVParseError {
                throw AuralError.noInput("stdin: \(error.description)")
            }
            format = header.format
            if !header.dataSizeIsUnknown { remainingPayload = UInt64(header.dataSize) }
            Log.verbose(
                "stdin: WAV stream, \(format.sampleRate) Hz, \(format.bitsPerSample)-bit, \(format.channels) ch")
        } else {
            format = PCMFormat(sampleRate: rate, bitsPerSample: bits, channels: channels)
            Log.verbose(
                "stdin: raw PCM assumed \(format.sampleRate) Hz, \(format.bitsPerSample)-bit, \(format.channels) ch")
        }

        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-stdin-\(UUID().uuidString).wav")
        let writer = try WAVFileWriter(destination: .file(staged), format: format)
        while remainingPayload > 0 {
            let chunk = try reader.next(Int(min(65536, remainingPayload)))
            if chunk.isEmpty { break }
            try writer.write(chunk)
            remainingPayload -= UInt64(chunk.count)
        }
        try writer.finalize()
        Log.verbose("stdin: staged \(writer.bytesWritten) PCM bytes")
        guard writer.bytesWritten > 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw AuralError.noInput("stdin contained no audio payload")
        }
        return staged
    }
}

/// Buffered reader with peek support over a FileHandle.
final class StreamReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Returns the next `n` bytes without consuming (fewer at EOF).
    func peek(_ n: Int) -> Data {
        fill(to: n)
        return buffer.prefix(n)
    }

    /// Consumes and returns up to `n` bytes (fewer only at EOF).
    func next(_ n: Int) throws -> Data {
        fill(to: n)
        let take = min(n, buffer.count)
        let chunk = buffer.prefix(take)
        buffer.removeFirst(take)
        return Data(chunk)
    }

    private func fill(to n: Int) {
        while buffer.count < n {
            let chunk = handle.readData(ofLength: max(n - buffer.count, 65536))
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
    }
}
