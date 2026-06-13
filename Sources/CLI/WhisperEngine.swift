import ArgumentParser
import Foundation

/// Transcript output formats (PRD §6.1).
enum TranscriptOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case txt
    case srt
    case json

    /// whisper-cli flag producing this format.
    var whisperFlag: String {
        switch self {
        case .txt: return "-otxt"
        case .srt: return "-osrt"
        case .json: return "-oj"
        }
    }

    /// Extension whisper-cli appends to the output base.
    var fileExtension: String { rawValue }
}

enum TranscriptionError: Error, CustomStringConvertible {
    case engineNotFound
    case modelMissing
    case modelNotFound(String)
    case engineFailed(Int32)
    case outputMissing(String)

    var description: String {
        switch self {
        case .engineNotFound:
            return """
                no Whisper engine found on PATH (searched: \
                \(WhisperEngine.binaryNames.joined(separator: ", "))). Install it with: \
                brew install whisper-cpp — or point AURAL_WHISPER_BIN at the binary.
                """
        case .modelMissing:
            return """
                no Whisper model specified. Pass --model PATH or set \
                AURAL_WHISPER_MODEL. Models: \
                https://huggingface.co/ggerganov/whisper.cpp — e.g.: \
                curl -L -o ~/.aural/models/ggml-base.en.bin \
                'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin'
                """
        case .modelNotFound(let path):
            return "Whisper model not found at '\(path)'"
        case .engineFailed(let code):
            return "transcription engine exited with code \(code)"
        case .outputMissing(let path):
            return "engine reported success but produced no output at \(path)"
        }
    }
}

/// Runs a local whisper.cpp binary on a normalized (16 kHz mono 16-bit)
/// WAV file (PRD §6.6).
///
/// Engine stderr is passed through live for progress/debugging; engine
/// stdout (a duplicate timestamped transcript) is suppressed so aural's
/// stdout carries exactly the requested output format.
struct WhisperEngine {
    /// Binary names probed on PATH, in order of preference.
    static let binaryNames = ["whisper-cli", "whisper-cpp"]

    /// Server binary names probed on PATH, in order of preference.
    static let serverBinaryNames = ["whisper-server"]

    let binary: URL
    let modelPath: String

    /// Locates the whisper binary: $AURAL_WHISPER_BIN override, then PATH.
    static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        discover(
            override: environment["AURAL_WHISPER_BIN"], names: binaryNames,
            path: environment["PATH"] ?? "")
    }

    /// Locates the whisper.cpp server binary: $AURAL_WHISPER_SERVER_BIN
    /// override, then PATH. Used for the model-resident live backend.
    static func discoverServer(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        discover(
            override: environment["AURAL_WHISPER_SERVER_BIN"], names: serverBinaryNames,
            path: environment["PATH"] ?? "")
    }

    private static func discover(override: String?, names: [String], path: String) -> URL? {
        if let override, !override.isEmpty {
            if FileManager.default.isExecutableFile(atPath: override) {
                return URL(fileURLWithPath: override)
            }
            return nil
        }
        for directory in path.split(separator: ":") {
            for name in names {
                let candidate = String(directory) + "/" + name
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }

    /// Resolves the model path: --model flag, then $AURAL_WHISPER_MODEL.
    static func resolveModel(
        flag: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let path = flag ?? environment["AURAL_WHISPER_MODEL"]
        guard let path, !path.isEmpty else { throw TranscriptionError.modelMissing }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw TranscriptionError.modelNotFound(expanded)
        }
        return expanded
    }

    /// Builds the whisper-cli argument list.
    static func buildArguments(
        model: String, wav: String, language: String?,
        format: TranscriptOutputFormat, outputBase: String
    ) -> [String] {
        var arguments = [
            "-m", model,
            "-f", wav,
            "-np",  // no progress prints on stdout
            format.whisperFlag,
            "-of", outputBase,
        ]
        if let language {
            arguments += ["-l", language]
        }
        return arguments
    }

    /// Transcribes the WAV file; returns the transcript in the requested
    /// format. Throws `TranscriptionError.engineFailed` with the engine's
    /// exit code on failure (propagated by the caller, US03).
    ///
    /// `quietStderr` silences the engine's stderr (model-load/timing lines);
    /// used by live transcription, which would otherwise emit one such block
    /// per segment.
    func transcribe(
        wavFile: URL, language: String?, format: TranscriptOutputFormat,
        quietStderr: Bool = false
    ) throws -> String {
        let outputBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-transcript-\(UUID().uuidString)").path
        let outputPath = "\(outputBase).\(format.fileExtension)"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let process = Process()
        process.executableURL = binary
        process.arguments = Self.buildArguments(
            model: modelPath, wav: wavFile.path, language: language,
            format: format, outputBase: outputBase)
        // stdout duplicates the transcript with timestamps — suppress;
        // stderr (model load info, errors) passes through to our stderr
        // unless silenced.
        process.standardOutput = FileHandle.nullDevice
        if quietStderr { process.standardError = FileHandle.nullDevice }

        do {
            try process.run()
        } catch {
            throw TranscriptionError.engineNotFound
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.engineFailed(process.terminationStatus)
        }
        guard let transcript = try? String(contentsOfFile: outputPath, encoding: .utf8) else {
            throw TranscriptionError.outputMissing(outputPath)
        }
        return transcript
    }
}
