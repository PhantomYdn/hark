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
                brew install whisper-cpp — or point HARK_WHISPER_BIN at the binary.
                """
        case .modelMissing:
            return """
                no Whisper model specified. Pass --model NAME|PATH, set \
                HARK_WHISPER_MODEL, or configure a default: \
                hark models download base.en --default \
                (or hark config set model <name>).
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
/// Engine stderr is passed through live for debugging; engine stdout (a
/// duplicate timestamped transcript) is suppressed so hark's stdout carries
/// exactly the requested output format. When the caller asks for progress,
/// the engine's own percent lines are read off its stderr and everything
/// else is still passed through.
struct WhisperEngine {
    /// Binary names probed on PATH, in order of preference.
    static let binaryNames = ["whisper-cli", "whisper-cpp"]

    /// Server binary names probed on PATH, in order of preference.
    static let serverBinaryNames = ["whisper-server"]

    let binary: URL
    let modelPath: String

    /// Locates the whisper binary: $HARK_WHISPER_BIN override, then PATH.
    static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        discover(
            override: environment["HARK_WHISPER_BIN"], names: binaryNames,
            path: environment["PATH"] ?? "")
    }

    /// Locates the whisper.cpp server binary: $HARK_WHISPER_SERVER_BIN
    /// override, then PATH. Used for the model-resident live backend.
    static func discoverServer(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        discover(
            override: environment["HARK_WHISPER_SERVER_BIN"], names: serverBinaryNames,
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

    /// Resolves the model in precedence order: `--model` flag, then
    /// `$HARK_WHISPER_MODEL`, then the config default (`~/.hark/config.json`).
    /// Each value may be a ggml path or a short name resolved under
    /// `~/.hark/models` (see `ModelRegistry`).
    static func resolveModel(
        flag: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        config: Configuration = .load()
    ) throws -> String {
        let value = flag
            ?? environment["HARK_WHISPER_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? config.model
        guard let value, !value.isEmpty else { throw TranscriptionError.modelMissing }
        if let resolved = ModelRegistry.resolvePath(value) { return resolved }
        // Not found as a path nor a known short name.
        if value.contains("/") {
            throw TranscriptionError.modelNotFound((value as NSString).expandingTildeInPath)
        }
        throw TranscriptionError.modelNotFound(
            "\(ModelRegistry.modelsDirectory.path)/\(ModelRegistry.fileName(for: value)) "
                + "(run 'hark models download \(value)')")
    }

    /// Builds the whisper-cli argument list. `language` nil omits `-l` (whisper
    /// default); "auto" enables detection. `translate` adds `-tr` (English out).
    /// `printProgress` adds `-pp`, which makes the engine report its position
    /// on stderr (it does so even under `-np`).
    static func buildArguments(
        model: String, wav: String, language: String?, translate: Bool,
        format: TranscriptOutputFormat, outputBase: String, printProgress: Bool = false
    ) -> [String] {
        var arguments = [
            "-m", model,
            "-f", wav,
            "-np",  // no progress prints on stdout
            format.whisperFlag,
            "-of", outputBase,
        ]
        if translate {
            arguments.append("-tr")
        }
        if let language {
            arguments += ["-l", language]
        }
        if printProgress {
            arguments.append("-pp")
        }
        return arguments
    }

    /// The 0...1 position in a whisper.cpp progress line
    /// (`whisper_print_progress_callback: progress =  35%`), or nil for any
    /// other stderr line. Pure, for testing.
    static func progressFraction(fromStderrLine line: String) -> Double? {
        guard let marker = line.range(of: "progress =") else { return nil }
        let digits = line[marker.upperBound...]
            .drop { $0 == " " }
            .prefix { $0.isNumber }
        guard !digits.isEmpty, let percent = Double(digits) else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    /// Transcribes the WAV file; returns the transcript in the requested
    /// format. Throws `TranscriptionError.engineFailed` with the engine's
    /// exit code on failure (propagated by the caller, US03).
    ///
    /// `quietStderr` silences the engine's stderr (model-load/timing lines);
    /// used by live transcription, which would otherwise emit one such block
    /// per segment. `progress`, when given, receives the engine's 0...1
    /// position; its other stderr lines still reach hark's stderr.
    func transcribe(
        wavFile: URL, language: String?, translate: Bool = false,
        format: TranscriptOutputFormat, quietStderr: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> String {
        let outputBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-transcript-\(UUID().uuidString)").path
        let outputPath = "\(outputBase).\(format.fileExtension)"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let process = Process()
        process.executableURL = binary
        process.arguments = Self.buildArguments(
            model: modelPath, wav: wavFile.path, language: language, translate: translate,
            format: format, outputBase: outputBase, printProgress: progress != nil)
        // stdout duplicates the transcript with timestamps — suppress;
        // stderr (model load info, errors) passes through to our stderr
        // unless silenced.
        process.standardOutput = FileHandle.nullDevice
        var stderrReader: EngineStderrReader?
        if let progress {
            let reader = EngineStderrReader(forwardOtherLines: !quietStderr, progress: progress)
            process.standardError = reader.pipe
            stderrReader = reader
        } else if quietStderr {
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw TranscriptionError.engineNotFound
        }
        stderrReader?.start()
        process.waitUntilExit()
        stderrReader?.finish()
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.engineFailed(process.terminationStatus)
        }
        guard let transcript = try? String(contentsOfFile: outputPath, encoding: .utf8) else {
            throw TranscriptionError.outputMissing(outputPath)
        }
        return transcript
    }
}

/// Reads a whisper.cpp child's stderr line by line while it runs: progress
/// lines feed `progress`, every other line is passed on to hark's stderr (or
/// dropped when the caller silenced the engine). Lines are split on the
/// reader's own queue; `finish` drains what is left once the child has exited.
private final class EngineStderrReader: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var pending = Data()
    private let forwardOtherLines: Bool
    private let progress: @Sendable (Double) -> Void

    init(forwardOtherLines: Bool, progress: @escaping @Sendable (Double) -> Void) {
        self.forwardOtherLines = forwardOtherLines
        self.progress = progress
    }

    func start() {
        // The parent's copy of the write end must close, or the read never
        // sees end-of-file once the child exits.
        try? pipe.fileHandleForWriting.close()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, atEnd: false)
        }
    }

    func finish() {
        pipe.fileHandleForReading.readabilityHandler = nil
        consume(pipe.fileHandleForReading.readDataToEndOfFile(), atEnd: true)
    }

    private func consume(_ data: Data, atEnd: Bool) {
        lock.lock()
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
        }
        if atEnd, !pending.isEmpty {
            lines.append(pending)
            pending = Data()
        }
        lock.unlock()
        for line in lines {
            let text = String(decoding: line, as: UTF8.self)
            if let fraction = WhisperEngine.progressFraction(fromStderrLine: text) {
                progress(fraction)
            } else if forwardOtherLines {
                TranscribeProgressLine.writeStderr(text + "\n")
            }
        }
    }
}
