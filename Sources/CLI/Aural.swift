@preconcurrency import AVFoundation
import ArgumentParser
import DeviceManager
import Encoders
import Foundation
import TapEngine

/// Root command. `aural` itself is the verb — "listen and transcribe."
///
/// It takes one input (live capture by default, or `-i FILE/-`) and writes
/// the outputs you name: `-a/--audio` and/or `-t/--transcript`, where `-`
/// means stdout. Name no output and it transcribes to stdout. The utility
/// subcommands (`devices`, `apps`, `info`) are unchanged.
@main
struct Aural: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aural",
        abstract: "Listen and transcribe: capture audio and produce transcripts on macOS.",
        discussion: """
            By default 'aural' captures the system default microphone and \
            prints a transcript to stdout. Choose a source with --system, \
            --app, --exclude-app, -d/--device, or read an existing file with \
            -i. Choose what to keep with -a/--audio (an audio file, or '-' \
            for a WAV stream on stdout) and -t/--transcript (a .txt/.srt/.json \
            file, or '-' for text on stdout). Name no output and the \
            transcript goes to stdout.

            Examples:
              aural                                  listen, transcript -> stdout
              aural -i recording.m4a                 transcribe a file -> stdout
              aural -a rec.m4a                        record only (no transcript)
              aural -a rec.m4a -t notes.txt           record + transcribe to files
              aural --system --mix -a m.m4a -t m.srt  capture a meeting, keep both
              aural -i in.wav -a out.m4a              convert between formats
              aural -a - | ffmpeg -i - ...            stream WAV into a pipe

            Transcription requires a local whisper.cpp (brew install \
            whisper-cpp) and a ggml model (--model or $AURAL_WHISPER_MODEL).
            """,
        version: "0.1.0",
        subcommands: [
            Devices.self,
            Apps.self,
            Info.self,
            Models.self,
            Config.self,
        ]
    )

    // MARK: Input

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Transcode/transcribe an existing audio file, or '-' for stdin. Omit for live capture.",
        valueName: "path|-"))
    var input: String?

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Live: input device UID (see 'aural devices'). Defaults to the system default input "
            + "(or $AURAL_DEVICE / aural config).",
        valueName: "uid"))
    var device: String?

    @Flag(name: .customLong("system"), help: """
        Live: capture all system audio via a Core Audio process tap instead \
        of the microphone.
        """)
    var captureSystem = false

    @Option(name: .customLong("app"), parsing: .singleValue, help: ArgumentHelp(
        "Live: capture only this application's audio (bundle ID or PID; repeatable).",
        valueName: "bundle-id|pid"))
    var apps: [String] = []

    @Option(name: .customLong("exclude-app"), parsing: .singleValue, help: ArgumentHelp(
        "Live: capture all system audio except this application (bundle ID or PID; repeatable).",
        valueName: "bundle-id|pid"))
    var excludeApps: [String] = []

    @Flag(name: .customLong("mix"), help: """
        Live: mix the microphone (default input, or -d) into a system/app \
        capture. Sources are clock-synced with drift compensation.
        """)
    var mix = false

    // MARK: Outputs

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Audio output: a file (.wav/.m4a/.flac), or '-' for a WAV stream on stdout.",
        valueName: "path|-"))
    var audio: String?

    @Option(name: [.customShort("t"), .long], help: ArgumentHelp(
        "Transcript output: a file (.txt/.srt/.json), or '-' for text on stdout.",
        valueName: "path|-"))
    var transcript: String?

    // MARK: Capture format / timing

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Sample rate in Hz (live default 44100; file convert defaults to the source rate).",
        valueName: "hz"))
    var rate: Int?

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Bits per sample: 16, 24, or 32 (live default 16; convert defaults to the source depth).",
        valueName: "bits"))
    var bits: Int?

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Channel count: 1 or 2 (defaults based on the source, capped at 2).",
        valueName: "n"))
    var channels: Int?

    @Option(name: .customLong("duration"), help: ArgumentHelp(
        "Live: stop capturing after this many seconds (otherwise Ctrl+C).",
        valueName: "sec"))
    var duration: Double?

    @Option(name: .customLong("split"), help: ArgumentHelp(
        "Live: split the audio file into numbered chunks: duration=SEC or silence=SEC.",
        valueName: "mode=value"))
    var split: String?

    @Option(name: .customLong("silence-threshold"), help: ArgumentHelp(
        "Peak level (dBFS, negative) below which audio counts as silence for --split silence "
            + "(default -50; or $AURAL_SILENCE_THRESHOLD / aural config).",
        valueName: "dbfs"))
    var silenceThreshold: Double?

    // MARK: Format overrides

    @Option(name: .customLong("format"), help: ArgumentHelp(
        "Force the audio format (wav, m4a, flac), overriding the file extension.",
        valueName: "fmt"))
    var forcedFormat: String?

    @Option(name: .customLong("transcript-format"), help: ArgumentHelp(
        "Force the transcript format (txt, srt, json), overriding the file extension.",
        valueName: "fmt"))
    var forcedTranscriptFormat: TranscriptOutputFormat?

    // MARK: Transcription engine

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Transcription engine: whisper (local). apple/whisperkit are planned; cloud is post-MVP "
            + "(default whisper; or $AURAL_ENGINE / aural config).",
        valueName: "engine"))
    var engine: String?

    @Option(help: ArgumentHelp(
        "ggml Whisper model: a path or a short name resolved under ~/.aural/models "
            + "(e.g. base.en, large-v3-turbo). Default: $AURAL_WHISPER_MODEL, then "
            + "the config 'model' (aural config).",
        valueName: "name|path"))
    var model: String?

    @Option(help: ArgumentHelp(
        "Spoken language code (e.g. en, de), or 'auto' to detect "
            + "(default auto; or $AURAL_LANGUAGE / aural config).",
        valueName: "code"))
    var language: String?

    @Flag(name: .customLong("translate"), inversion: .prefixedNo, help: """
        Translate speech to English regardless of the spoken language \
        (whisper/whisperkit only; or $AURAL_TRANSLATE / aural config). Use \
        --no-translate to override a configured default.
        """)
    var translate: Bool?

    // MARK: Advanced

    @Flag(name: .customLong("raw"), help: """
        With -a -, stream headerless raw PCM to stdout instead of a WAV \
        container.
        """)
    var raw = false

    @Flag(name: .customLong("no-output"), help: ArgumentHelp(
        "Capture but write nothing (dry run).", visibility: .hidden))
    var noOutput = false

    @Option(name: .customLong("input-rate"), help: ArgumentHelp(
        "Sample rate of raw PCM on stdin (ignored when the stream is WAV).",
        valueName: "hz", visibility: .hidden))
    var inputRate: Int = 44100

    @Option(name: .customLong("input-bits"), help: ArgumentHelp(
        "Bits per sample of raw PCM on stdin: 16, 24, or 32.",
        valueName: "bits", visibility: .hidden))
    var inputBits: Int = 16

    @Option(name: .customLong("input-channels"), help: ArgumentHelp(
        "Channels of raw PCM on stdin: 1 or 2.", valueName: "n", visibility: .hidden))
    var inputChannels: Int = 1

    @OptionGroup var options: GlobalOptions

    // MARK: Validation

    func validate() throws {
        if let bits, ![16, 24, 32].contains(bits) {
            throw ValidationError("--bits must be 16, 24, or 32.")
        }
        if let rate, !(1...768_000).contains(rate) {
            throw ValidationError("--rate must be between 1 and 768000 Hz.")
        }
        if let channels, !(1...2).contains(channels) {
            throw ValidationError("--channels must be 1 or 2.")
        }
        if let duration, duration <= 0 {
            throw ValidationError("--duration must be positive.")
        }
        // Validate explicit engine/translate at parse time; config/env-sourced
        // values are re-checked on the merged result in `ResolvedSettings`.
        if let engine {
            guard let engineSpec = EngineSpec.named(engine) else {
                throw ValidationError(
                    "unknown engine '\(engine)' (known: \(EngineSpec.knownNames)).")
            }
            if translate == true && !engineSpec.capabilities.translate {
                throw ValidationError(
                    "the '\(engine)' engine cannot translate to English; drop --translate or "
                        + "choose an engine that supports it (whisper, whisperkit).")
            }
        }
        guard [16, 24, 32].contains(inputBits) else {
            throw ValidationError("--input-bits must be 16, 24, or 32.")
        }
        guard (1...2).contains(inputChannels) else {
            throw ValidationError("--input-channels must be 1 or 2.")
        }
        guard (1...768_000).contains(inputRate) else {
            throw ValidationError("--input-rate must be between 1 and 768000 Hz.")
        }

        // Input mode: live capture flags and -i are mutually exclusive.
        let liveFlags = captureSystem || !apps.isEmpty || !excludeApps.isEmpty || mix
            || device != nil
        if input != nil && liveFlags {
            throw ValidationError("""
                -i/--input reads a file or stdin; it cannot be combined with live \
                capture flags (--system, --app, --exclude-app, --mix, -d).
                """)
        }
        if input != nil && duration != nil {
            throw ValidationError("--duration applies to live capture; it has no effect with -i/--input.")
        }
        if input != nil && split != nil {
            throw ValidationError("--split applies to live capture; it has no effect with -i/--input.")
        }

        // Live source combinations.
        if !apps.isEmpty && captureSystem {
            throw ValidationError("--system captures everything; it cannot be combined with --app.")
        }
        if !apps.isEmpty && !excludeApps.isEmpty {
            throw ValidationError("--app and --exclude-app are mutually exclusive.")
        }
        let tapMode = captureSystem || !apps.isEmpty || !excludeApps.isEmpty
        if mix && !tapMode {
            throw ValidationError(
                "--mix requires a system/app capture (--system, --app, or --exclude-app).")
        }
        if tapMode && !mix && device != nil {
            throw ValidationError(
                "-d/--device selects a microphone; with system/app capture it only applies together with --mix.")
        }

        // Outputs.
        if noOutput && (audio != nil || transcript != nil) {
            throw ValidationError(
                "--no-output discards everything; it cannot be combined with -a/--audio or -t/--transcript.")
        }
        if raw && audio != "-" {
            throw ValidationError("--raw streams headerless PCM to stdout; it requires -a -.")
        }
        let audioToStdout = (audio == "-")
        let transcriptToStdout = (transcript == "-")
            || (transcript == nil && audio == nil && !noOutput)
        if audioToStdout && transcriptToStdout {
            throw ValidationError(
                "only one output can go to stdout ('-'); send the other to a file.")
        }

        if let forcedFormat {
            guard let parsed = AudioFileFormat(rawValue: forcedFormat.lowercased()) else {
                let known = AudioFileFormat.allCases.map(\.rawValue).joined(separator: ", ")
                throw ValidationError("unknown format '\(forcedFormat)' (known: \(known)).")
            }
            if audioToStdout && parsed != .wav {
                throw ValidationError(
                    "encoded formats need a seekable file; use -a FILE with --format \(parsed.rawValue).")
            }
        }

        if let split {
            guard let audio, audio != "-" else {
                throw ValidationError("--split writes numbered files; it requires -a/--audio FILE.")
            }
            do {
                _ = try SplitSpec.parse(split)
            } catch let error as AuralError {
                throw ValidationError(error.message)
            }
        }
        if let silenceThreshold, silenceThreshold >= 0 {
            throw ValidationError("--silence-threshold must be negative (dBFS).")
        }
    }

    // MARK: Run

    func run() throws {
        Log.isVerbose = options.verbose
        do {
            let settings = try ResolvedSettings.resolve(
                engineFlag: engine, languageFlag: language, translateFlag: translate,
                silenceFlag: silenceThreshold, deviceFlag: device)
            try settings.validate()
            let outputs = try resolveOutputs()
            if let input {
                try runFileInput(input, outputs: outputs, settings: settings)
            } else {
                try runLiveInput(outputs: outputs, settings: settings)
            }
        } catch let error as AuralError {
            Log.error(error.message)
            throw error.code.exitCode
        } catch let error as TranscriptionError {
            Log.error(error.description)
            switch error {
            case .engineNotFound:
                throw AuralExitCode.unavailable.exitCode
            case .modelMissing, .modelNotFound:
                throw AuralExitCode.noInput.exitCode
            case .engineFailed(let code):
                // Propagate the engine's exit code through the pipeline (US03).
                throw ExitCode(code)
            case .outputMissing:
                throw AuralExitCode.software.exitCode
            }
        }
    }

    // MARK: Output resolution

    /// Audio output destination resolved from `-a/--audio` and `--raw`.
    enum AudioDestination {
        case stdoutWav
        case stdoutRaw
        case file(String)
    }

    /// The concrete outputs for this invocation. Naming no output yields a
    /// transcript on stdout (the default verb).
    struct ResolvedOutputs {
        let audio: AudioDestination?
        let transcript: TranscriptDestination?
    }

    func resolveOutputs() throws -> ResolvedOutputs {
        if noOutput {
            return ResolvedOutputs(audio: nil, transcript: nil)
        }
        let audioDest: AudioDestination?
        switch audio {
        case .none: audioDest = nil
        case .some("-"): audioDest = raw ? .stdoutRaw : .stdoutWav
        case .some(let path): audioDest = .file(path)
        }
        let transcriptDest: TranscriptDestination?
        if transcript == "-" {
            transcriptDest = .stdout
        } else if let transcript {
            transcriptDest = .file(transcript)
        } else if audio == nil {
            transcriptDest = .stdout  // default verb: transcribe to stdout
        } else {
            transcriptDest = nil
        }
        return ResolvedOutputs(audio: audioDest, transcript: transcriptDest)
    }

    // MARK: Live capture

    private func runLiveInput(outputs: ResolvedOutputs, settings: ResolvedSettings) throws {
        // Fail fast on unwritable audio formats before any permission prompts.
        if case .file(let path)? = outputs.audio {
            let fileFormat = try resolveAudioFileFormat(path: path)
            guard fileFormat.isWritable else {
                throw AuralError.unavailable(
                    "\(fileFormat.rawValue) output is not implemented yet (planned; see PLAN.md). Use wav, m4a, or flac.")
            }
        }

        // Fail fast on a missing transcription engine/model before touching
        // audio permissions or starting capture (and warn once if the model
        // can't honor the requested language/translation).
        if outputs.transcript != nil {
            let whisper = try TranscribeEngine.resolveWhisper(
                engineName: settings.engine, modelFlag: model)
            ModelRegistry.warnIfModelLanguageMismatch(
                modelPath: whisper.modelPath, language: settings.language,
                translate: settings.translate)
        }

        let captureEngine = CaptureEngine(
            deviceUID: settings.micDevice, rate: rate ?? 44100, bits: bits ?? 16,
            channels: channels, captureSystem: captureSystem, apps: apps,
            excludeApps: excludeApps, mix: mix)
        let (session, format, sourceLabel) = try captureEngine.makeCapture()

        let metadata = WAVMetadata(
            creationDate: Date(), software: "aural 0.1.0", title: sourceLabel)

        var sinks: [AudioSink] = []
        if let audioDest = outputs.audio {
            sinks.append(try makeAudioSink(
                audioDest, format: format, metadata: metadata,
                silenceThreshold: settings.silenceThreshold))
        }
        var liveTranscriber: LiveTranscriber?
        if let transcriptDest = outputs.transcript {
            let transcriber = try LiveTranscriber(
                destination: transcriptDest,
                transcriptFormat: transcriptFormat(for: transcriptDest),
                engineName: settings.engine, modelFlag: model, language: settings.language,
                translate: settings.translate,
                captureFormat: format, silenceThresholdDBFS: settings.silenceThreshold)
            sinks.append(transcriber)
            liveTranscriber = transcriber
            if outputs.audio == nil && duration == nil {
                Log.notice("listening — press Ctrl+C to stop")
            }
        }
        if sinks.isEmpty {
            sinks.append(DiscardSink())  // --no-output dry run
        }
        Log.verbose("destination: " + sinks.map(\.label).joined(separator: ", "))

        try captureEngine.run(
            session: session, format: format, into: sinks,
            duration: duration, warnOnSilence: captureSystem)

        // Surface any engine error from the live segments (exit-code-mapped).
        try liveTranscriber?.rethrowErrors()
    }

    // MARK: File input (transcode and/or transcribe)

    private func runFileInput(
        _ inputPath: String, outputs: ResolvedOutputs, settings: ResolvedSettings
    ) throws {
        var sourcePath = inputPath
        var stagedStdin: URL?
        if inputPath == "-" {
            let staged = try TranscribeEngine.stageStdin(
                rate: inputRate, bits: inputBits, channels: inputChannels)
            stagedStdin = staged
            sourcePath = staged.path
        } else {
            guard FileManager.default.fileExists(atPath: inputPath) else {
                throw AuralError.noInput(
                    "input '\(inputPath)' is neither a file nor '-' (stdin). For live capture, omit -i.")
            }
        }
        defer {
            if let stagedStdin { try? FileManager.default.removeItem(at: stagedStdin) }
        }

        if let audioDest = outputs.audio {
            try convert(sourcePath: sourcePath, to: audioDest, settings: settings)
        }
        if let transcriptDest = outputs.transcript {
            try transcribeAndWrite(
                audioPath: sourcePath, to: transcriptDest, settings: settings)
        }
    }

    /// Transcodes `sourcePath` into the given audio destination, defaulting
    /// rate/depth/channels to the source values.
    private func convert(
        sourcePath: String, to destination: AudioDestination, settings: ResolvedSettings
    ) throws {
        let source = try AudioPipeline.openForReading(sourcePath)
        let sourceFormat = source.processingFormat
        let sourceBits = Int(source.fileFormat.streamDescription.pointee.mBitsPerChannel)
        let pcmFormat = PCMFormat(
            sampleRate: rate ?? Int(sourceFormat.sampleRate),
            bitsPerSample: bits ?? ([16, 24, 32].contains(sourceBits) ? sourceBits : 16),
            channels: channels ?? min(2, max(1, Int(sourceFormat.channelCount)))
        )
        let sink = try makeAudioSink(
            destination, format: pcmFormat, metadata: WAVMetadata(),
            silenceThreshold: settings.silenceThreshold)
        Log.verbose("""
            \(sourcePath) (\(Int(sourceFormat.sampleRate)) Hz, \(sourceFormat.channelCount) ch) -> \
            \(sink.label) (\(pcmFormat.sampleRate) Hz, \(pcmFormat.bitsPerSample)-bit, \
            \(pcmFormat.channels) ch)
            """)
        try AudioPipeline.decode(source, to: sink, format: pcmFormat)
        Log.verbose("wrote \(sink.bytesWritten) PCM bytes to \(sink.label)")
    }

    // MARK: Shared helpers

    private func transcribeAndWrite(
        audioPath: String, to destination: TranscriptDestination, settings: ResolvedSettings
    ) throws {
        let format = transcriptFormat(for: destination)
        let transcriber = TranscribeEngine(
            engineName: settings.engine, modelFlag: model, language: settings.language,
            translate: settings.translate, format: format)
        let text = try transcriber.transcribe(audioPath: audioPath)
        try transcriber.write(text, to: destination)
    }

    /// Builds an audio sink for a destination. File destinations honor
    /// `--split` (live only); stdout uses a WAV stream or raw PCM.
    private func makeAudioSink(
        _ destination: AudioDestination, format: PCMFormat, metadata: WAVMetadata,
        silenceThreshold: Double
    ) throws -> AudioSink {
        switch destination {
        case .stdoutRaw:
            return RawStreamSink(handle: .standardOutput, label: "stdout (raw pcm)")
        case .stdoutWav:
            let writer: WAVFileWriter
            do {
                writer = try WAVFileWriter(destination: .stream(.standardOutput), format: format)
            } catch {
                throw AuralError.ioError("cannot write WAV header to stdout: \(error)")
            }
            return WAVSink(writer: writer, label: "stdout (wav stream)")
        case .file(let path):
            let fileFormat = try resolveAudioFileFormat(path: path)
            switch parsedSplit() {
            case .duration(let seconds):
                return SplittingSink(
                    chunkSeconds: seconds, format: format,
                    label: "\(chunkPath(base: path, index: 1)), … (every \(seconds)s)"
                ) { index in
                    try CaptureEngine.makeFileSink(
                        path: chunkPath(base: path, index: index),
                        fileFormat: fileFormat, format: format, metadata: metadata)
                }
            case .silence(let seconds):
                return SilenceSplittingSink(
                    silenceSeconds: seconds, thresholdDBFS: silenceThreshold, format: format,
                    label: "\(chunkPath(base: path, index: 1)), … (on \(seconds)s silence)"
                ) { index in
                    try CaptureEngine.makeFileSink(
                        path: chunkPath(base: path, index: index),
                        fileFormat: fileFormat, format: format, metadata: metadata)
                }
            case nil:
                return try CaptureEngine.makeFileSink(
                    path: path, fileFormat: fileFormat, format: format, metadata: metadata)
            }
        }
    }

    /// Parsed `--split` spec (validated during `validate()`); nil when absent.
    private func parsedSplit() -> SplitSpec? {
        guard let split else { return nil }
        return try? SplitSpec.parse(split)
    }

    /// Audio file format: `--format` override first, then the file extension.
    private func resolveAudioFileFormat(path: String) throws -> AudioFileFormat {
        if let forcedFormat { return AudioFileFormat(rawValue: forcedFormat.lowercased())! }
        if let detected = AudioFileFormat.detect(fromPath: path) { return detected }
        let known = AudioFileFormat.allCases.map(\.rawValue).joined(separator: ", ")
        throw AuralError.usage(
            "cannot infer format from '\(path)'; use a known extension (\(known)) or --format.")
    }

    /// Transcript format: `--transcript-format` override first, then the file
    /// extension, defaulting to plain text.
    private func transcriptFormat(for destination: TranscriptDestination) -> TranscriptOutputFormat {
        if let forcedTranscriptFormat { return forcedTranscriptFormat }
        if case .file(let path) = destination,
            let detected = TranscriptOutputFormat(
                rawValue: (path as NSString).pathExtension.lowercased())
        {
            return detected
        }
        return .txt
    }
}
