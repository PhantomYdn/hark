@preconcurrency import AVFoundation
import ArgumentParser
import DeviceManager
import Encoders
import Foundation
import TapEngine

/// The hark version — the single source of truth, used by `--version`, the
/// WAV-metadata software tag, and the remote-control agent's `GET /status`.
/// Release bumps edit only this constant.
let harkVersion = "0.4.0"

/// Root command. `hark` itself is the verb — "listen and transcribe."
///
/// It takes one input (live capture by default, or `-i FILE/-`) and writes
/// the outputs you name: `-a/--audio` and/or `-t/--transcript`, where `-`
/// means stdout. Name no output and it transcribes to stdout. The utility
/// subcommands (`devices`, `apps`, `info`) are unchanged.
@main
struct Hark: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hark",
        abstract: "Listen and transcribe: capture audio and produce transcripts on macOS.",
        discussion: """
            By default 'hark' captures the system default microphone and \
            prints a transcript to stdout. Choose a source with --system, \
            --app, --exclude-app, -d/--device, or read an existing file with \
            -i. Choose what to keep with -a/--audio (an audio file, or '-' \
            for a WAV stream on stdout) and -t/--transcript (a .txt/.srt/.json \
            file, or '-' for text on stdout). Name no output and the \
            transcript goes to stdout.

            Examples:
              hark                                  listen, transcript -> stdout
              hark -i recording.m4a                 transcribe a file -> stdout
              hark -a rec.m4a                        record only (no transcript)
              hark -a rec.m4a -t notes.txt           record + transcribe to files
              hark --system --mix -a m.m4a -t m.srt  capture a meeting, keep both
              hark -i in.wav -a out.m4a              convert between formats
              hark -a - | ffmpeg -i - ...            stream WAV into a pipe

            The default 'whisper' engine needs a local whisper.cpp + ggml \
            model; apple/whisperkit/parakeet are alternatives (see --engine, \
            'hark models').
            """,
        version: harkVersion,
        subcommands: [
            Devices.self,
            Apps.self,
            Info.self,
            Models.self,
            Config.self,
        ]
    )

    /// Entry point. ArgumentParser options can't carry an *optional* value, so a
    /// bare `--remote-control` (no following `[host:]port`) would be a parse
    /// error. Normalize argv first: when `--remote-control` is the last token or
    /// is followed by another option, inject an empty-string sentinel so the
    /// agent binds the configured `remote-control-port`. An explicit value
    /// (`--remote-control 8473`) is left untouched.
    static func main() {
        Hark.main(normalizeRemoteControl(Array(CommandLine.arguments.dropFirst())))
    }

    /// Inserts an empty sentinel after a value-less `--remote-control`. Visible
    /// for testing.
    static func normalizeRemoteControl(_ args: [String]) -> [String] {
        var out = args
        var i = 0
        while i < out.count {
            if out[i] == "--remote-control" {
                let isBare = i + 1 >= out.count || out[i + 1].hasPrefix("-")
                if isBare {
                    out.insert("", at: i + 1)
                    i += 1  // skip the sentinel we just inserted
                }
            }
            i += 1
        }
        return out
    }

    // MARK: Input

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Transcode/transcribe an existing audio file, or '-' for stdin. Omit for live capture.",
        valueName: "path|-"))
    var input: String?

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Live: input device UID (see 'hark devices'). Defaults to the system default input "
            + "(or $HARK_DEVICE / hark config).",
        valueName: "uid"))
    var device: String?

    @Option(name: [.customShort("C"), .customLong("directory")], help: ArgumentHelp(
        "Base directory for resolving relative artifact paths (-i/-a/-t and --split outputs); "
            + "absolute paths and '-' are unaffected. Defaults to the current directory "
            + "(or $HARK_DIRECTORY / hark config). Must exist.",
        valueName: "path"))
    var directory: String?

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

    @Option(name: .customLong("capture-backend"), help: ArgumentHelp(
        "System/app capture backend: auto (default), sckit (ScreenCaptureKit, "
            + "macOS 15+, Screen Recording), or coreaudio (process tap, headless). "
            + "Or $HARK_CAPTURE.",
        valueName: "auto|sckit|coreaudio"))
    var captureBackend: String?

    // MARK: Outputs

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Audio output: a file (.wav/.m4a/.flac/.mp3/.opus), or '-' for a WAV stream on stdout.",
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

    @Flag(name: .customLong("keep-awake"), inversion: .prefixedNo, help: """
        Keep the machine awake while recording so sleep can't interrupt capture \
        (also keeps the display on with --interactive). Default off; --no-keep-awake \
        forces it off. Or $HARK_KEEP_AWAKE / hark config.
        """)
    var keepAwake: Bool?

    @Option(name: .customLong("duration"), help: ArgumentHelp(
        "Live: stop capturing after this many seconds (otherwise Ctrl+C).",
        valueName: "sec"))
    var duration: Double?

    @Option(name: .customLong("split"), help: ArgumentHelp(
        "Live: split the audio file into numbered chunks: duration=SEC or silence=SEC.",
        valueName: "mode=value"))
    var split: String?

    @Option(name: .customLong("silence-threshold"), help: ArgumentHelp(
        "Peak dBFS (negative) below which audio is silence — for --split silence and "
            + "live-transcription segmentation (default -50; or $HARK_SILENCE_THRESHOLD / config).",
        valueName: "dbfs"))
    var silenceThreshold: Double?

    @Option(name: .customLong("vad-threshold"), help: ArgumentHelp(
        "Live VAD speech-detection sensitivity (0–1; default 0.5). Lower catches quieter "
            + "speech (fewer dropped phrases); higher is stricter. Apple Silicon only.",
        valueName: "0..1"))
    var vadThreshold: Double?

    // MARK: Format overrides

    @Option(name: .customLong("format"), help: ArgumentHelp(
        "Force the audio format (wav, m4a, flac, mp3, opus), overriding the file extension.",
        valueName: "fmt"))
    var forcedFormat: String?

    @Option(name: .customLong("transcript-format"), help: ArgumentHelp(
        "Force the transcript format (txt, srt, json), overriding the file extension.",
        valueName: "fmt"))
    var forcedTranscriptFormat: TranscriptOutputFormat?

    // MARK: Transcription engine

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Transcription engine: whisper (local), apple (on-device), whisperkit or parakeet "
            + "(CoreML, Apple Silicon). cloud is post-MVP. Default whisper; "
            + "or $HARK_ENGINE / hark config.",
        valueName: "engine"))
    var engine: String?

    @Option(help: ArgumentHelp(
        "Model for the chosen engine; form varies. Default: $HARK_WHISPER_MODEL "
            + "or config. See 'hark models list --available'.",
        valueName: "name|path"))
    var model: String?

    @Option(help: ArgumentHelp(
        "Spoken language code or 'auto' (default). Varies by engine — apple uses a "
            + "locale, parakeet always auto-detects. Or $HARK_LANGUAGE / config.",
        valueName: "code"))
    var language: String?

    @Flag(name: .customLong("translate"), inversion: .prefixedNo, help: """
        Translate speech to English regardless of the spoken language \
        (whisper/whisperkit only; or $HARK_TRANSLATE / hark config). Use \
        --no-translate to override a configured default.
        """)
    var translate: Bool?

    // MARK: Speaker recognition (PRD §6.7)

    @Flag(name: [.customLong("speakers"), .customLong("diarize")], inversion: .prefixedNo, help: """
        Label transcript segments by speaker: by capture source ("You" = mic, \
        "Others" = system) and/or acoustic diarization ("Speaker N"). Acoustic \
        diarization needs Apple Silicon; source attribution works anywhere. \
        Or $HARK_SPEAKERS / hark config.
        """)
    var speakers: Bool?

    @Option(name: .customLong("speaker-mode"), help: ArgumentHelp(
        "With --speakers: auto (source + diarization), source (mic vs system), "
            + "or acoustic (diarize one stream). Or $HARK_SPEAKER_MODE / config.",
        valueName: "auto|source|acoustic"))
    var speakerMode: SpeakerMode?

    @Option(name: .customLong("speaker-labels"), help: ArgumentHelp(
        "With --speakers: rename the two source labels (default 'You,Others').",
        valueName: "you,others"))
    var speakerLabels: String?

    @Option(name: .customLong("diarize-engine"), help: ArgumentHelp(
        "Acoustic diarizer: auto (default: streaming live / offline batch), streaming "
            + "(real-time live, LS-EEND neural model), or offline (accurate, diarized "
            + "at end of capture).",
        valueName: "auto|streaming|offline"))
    var diarizeEngine: DiarizeEngine?

    @Option(name: .customLong("max-speakers"), help: ArgumentHelp(
        "Offline/batch diarization only: cap the number of distinct speakers "
            + "(no effect on the live streaming EEND diarizer).",
        valueName: "n"))
    var maxSpeakers: Int?

    @Option(name: .customLong("speaker-threshold"), help: ArgumentHelp(
        "Offline/batch clustering sensitivity (0–1; default ~0.65). Lower splits "
            + "speakers more readily, higher merges them. No effect on the live "
            + "streaming EEND diarizer.",
        valueName: "0..1"))
    var speakerThreshold: Double?

    // MARK: Advanced

    @Flag(name: .customLong("vad"), inversion: .prefixedNo, help: """
        Use the on-device VAD for live segmentation (default on, Apple Silicon); \
        --no-vad falls back to the amplitude --silence-threshold method. Or \
        $HARK_VAD / hark config.
        """)
    var useVad: Bool?

    @Flag(name: .customLong("gain"), inversion: .prefixedNo, help: """
        Peak-normalize each segment before the engine to recognize quiet captures \
        (default on; the recording is unaffected). --no-gain disables. Or \
        $HARK_GAIN / hark config.
        """)
    var useGain: Bool?

    @Flag(name: .customLong("raw"), help: """
        With -a -, stream headerless raw PCM to stdout instead of a WAV \
        container.
        """)
    var raw = false

    @Flag(name: .customLong("interactive"), help: """
        Live: run in a minimal terminal UI showing the transcript, with \
        single-key controls — space to pause/resume (the paused interval is \
        not recorded), m to mute/unmute the mic (only the mic is silenced; \
        recording continues), y to yank the transcript so far to the clipboard, \
        Enter to finish (Ctrl-C also stops). Needs a terminal; not combined \
        with -i or stdout output.
        """)
    var interactive = false

    // Holds the `--remote-control` value. An empty string is the sentinel for
    // "given without a value" (bare `--remote-control`), injected by `main()`
    // below, since ArgumentParser options can't have an optional value. Bare =>
    // bind loopback on the resolved remote-control-port; a value => [host:]port.
    @Option(name: .customLong("remote-control"), help: ArgumentHelp(
        "Run as a control agent (no immediate capture): serve a small HTTP/JSON "
            + "API so scripts can start/stop/pause/resume/query a recording. Omit "
            + "the value to bind 127.0.0.1 on the configured remote-control-port "
            + "(default 8473); or pass [host:]port (e.g. 8473 or 0.0.0.0:8473). "
            + "Non-loopback binds require $HARK_REMOTE_TOKEN. See docs/remote-control.md.",
        valueName: "[host:]port"))
    var remoteControl: String?

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

    /// Whether a microphone is part of this capture: a mic-only capture, or a
    /// system/app capture with `--mix`. Drives the interactive `m` control
    /// (§6.9) and the remote-control `/mute` verb (§6.10).
    var capturesMicrophone: Bool {
        mix || !(captureSystem || !apps.isEmpty || !excludeApps.isEmpty)
    }

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

        // Interactive mode is a live-capture terminal UI: it can't read a file
        // and it owns the terminal, so it can't also stream to stdout. (The TTY
        // requirement itself is checked at runtime so it stays unit-testable.)
        if interactive {
            if input != nil {
                throw ValidationError(
                    "--interactive is for live capture; it can't be combined with -i/--input.")
            }
            if audio == "-" {
                throw ValidationError(
                    "--interactive uses the terminal for the transcript; it can't also stream audio to stdout (-a -).")
            }
        }

        // Remote-control runs an agent instead of capturing on launch, so it
        // can't combine with the interactive UI or a file input. (Launch-time
        // capture flags are allowed — they become per-session defaults.)
        if remoteControl != nil {
            if interactive {
                throw ValidationError("--remote-control and --interactive are mutually exclusive.")
            }
            if input != nil {
                throw ValidationError(
                    "--remote-control starts an agent; it can't be combined with -i/--input.")
            }
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
        let backend = resolvedCaptureBackend()
        if !["auto", "sckit", "coreaudio"].contains(backend) {
            throw ValidationError(
                "--capture-backend must be auto, sckit, or coreaudio (got '\(backend)').")
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
            } catch let error as HarkError {
                throw ValidationError(error.message)
            }
        }
        if let silenceThreshold, silenceThreshold >= 0 {
            throw ValidationError("--silence-threshold must be negative (dBFS).")
        }
        if let vadThreshold, !(vadThreshold > 0 && vadThreshold <= 1) {
            throw ValidationError("--vad-threshold must be between 0 and 1.")
        }

        // Speaker recognition value formats (flag-level). Cross-cutting checks
        // that depend on the resolved mode (which may come from env/config) —
        // e.g. "source needs two sources" — run in `resolveLivePlan`.
        if let maxSpeakers, maxSpeakers < 1 {
            throw ValidationError("--max-speakers must be a positive integer.")
        }
        if let speakerThreshold, !(speakerThreshold > 0 && speakerThreshold <= 1) {
            throw ValidationError("--speaker-threshold must be between 0 and 1.")
        }
        if let speakerLabels {
            let parts = speakerLabels.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count != 2 || parts.contains(where: \.isEmpty) {
                throw ValidationError(
                    "--speaker-labels needs two comma-separated names, e.g. 'You,Others'.")
            }
        }
    }

    /// Capture backend from --capture-backend, else $HARK_CAPTURE, else "auto".
    func resolvedCaptureBackend() -> String {
        if let backend = captureBackend?.lowercased(), !backend.isEmpty {
            return backend
        }
        if let env = ProcessInfo.processInfo.environment["HARK_CAPTURE"]?.lowercased(),
            !env.isEmpty
        {
            return env
        }
        return "auto"
    }

    // MARK: Run

    func run() throws {
        Log.isVerbose = options.verbose
        do {
            let settings = try ResolvedSettings.resolve(from: self)
            try settings.validate()
            try settings.applyWorkingDirectory()
            // Remote-control agent (PRD §6.10): serve the control API instead of
            // capturing on launch. Per-session output paths resolve under the
            // working directory just applied.
            if let remoteControl {
                // Bare `--remote-control` (empty sentinel) binds loopback on the
                // resolved remote-control-port; an explicit [host:]port wins.
                let address = remoteControl.isEmpty
                    ? String(settings.remoteControlPort) : remoteControl
                try RemoteControlAgent(defaults: self, address: address).run()
                return
            }
            let outputs = try resolveOutputs()
            if let input {
                try runFileInput(input, outputs: outputs, settings: settings)
            } else {
                try runLiveInput(outputs: outputs, settings: settings)
            }
        } catch let error as HarkError {
            Log.error(error.message)
            throw error.code.exitCode
        } catch let error as TranscriptionError {
            Log.error(error.description)
            switch error {
            case .engineNotFound:
                throw HarkExitCode.unavailable.exitCode
            case .modelMissing, .modelNotFound:
                throw HarkExitCode.noInput.exitCode
            case .engineFailed(let code):
                // Propagate the engine's exit code through the pipeline (US03).
                throw ExitCode(code)
            case .outputMissing:
                throw HarkExitCode.software.exitCode
            }
        }
    }

    /// Programmatic live-capture entry for the remote-control agent (PRD §6.10):
    /// resolves settings and runs the live pipeline with an injected control,
    /// throwing `HarkError`/`TranscriptionError` for the agent to map to HTTP.
    /// The working directory is already applied by the agent at launch.
    func executeLive(control: CaptureControl) throws {
        let settings = try ResolvedSettings.resolve(from: self)
        try settings.validate()
        let outputs = try resolveOutputs()
        try runLiveInput(outputs: outputs, settings: settings, externalControl: control)
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
        } else if interactive {
            // Record-only + interactive: still show the transcript in the UI.
            transcriptDest = .stdout
        } else {
            transcriptDest = nil
        }
        return ResolvedOutputs(audio: audioDest, transcript: transcriptDest)
    }

    // MARK: Live capture

    private func runLiveInput(
        outputs: ResolvedOutputs, settings: ResolvedSettings,
        externalControl: CaptureControl? = nil
    ) throws {
        // Interactive mode (PRD §6.9) needs a real terminal: stdin for keys,
        // stdout for the transcript. Checked here (not in validate()) so the
        // arg-combination rules stay unit-testable off a TTY; checked before the
        // engine preflight so the terminal requirement fails fast.
        if interactive {
            guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
                throw HarkError.usage(
                    "--interactive needs an interactive terminal (stdin and stdout must be a TTY).")
            }
        }

        // Fail fast on unwritable audio formats before any permission prompts.
        if case .file(let path)? = outputs.audio {
            let fileFormat = try resolveAudioFileFormat(path: path)
            guard fileFormat.isWritable else {
                throw HarkError.unavailable(
                    "\(fileFormat.rawValue) output is not implemented yet (planned; see PLAN.md). Use wav, m4a, or flac.")
            }
        }

        // Resolve speaker labeling up front (downgrading to source-only on Intel
        // where acoustic diarization can't run) so it's settled before capture.
        let speakerPlan = try resolveLivePlan(settings: settings)

        // Fail fast on an unusable transcription engine before touching audio
        // permissions or starting capture: whisper resolves its binary+model
        // (and warns on a .en/language mismatch); apple checks Speech
        // authorization + locale, so its prompt happens before recording.
        if outputs.transcript != nil {
            try TranscriptionEngine.preflight(
                engineName: settings.engine, modelFlag: model,
                language: settings.language, translate: settings.translate)
        }

        var captureEngine = CaptureEngine(
            deviceUID: settings.micDevice, rate: settings.rate ?? 44100, bits: settings.bits ?? 16,
            channels: settings.channels, captureSystem: captureSystem, apps: apps,
            excludeApps: excludeApps, mix: mix, captureBackend: settings.captureBackend)
        // Keep-awake (display too in interactive mode); held for the capture only.
        captureEngine.sleepMode = SleepPreventionMode.resolve(
            keepAwake: settings.keepAwake, interactive: interactive)
        let (session, format, sourceLabel) = try captureEngine.makeCapture()

        // Startup status (PRD §6.8): summarise the resolved configuration on
        // stderr (when a TTY, or with -v) before capture begins.
        StartupStatus.emit(liveStatusText(
            settings: settings, source: sourceLabel, format: format, outputs: outputs))

        // Interactive controls (PRD §6.9): `m` mutes the mic only when one is in
        // the capture (mic-only, or `--mix`); `y` yanks the transcript so far.
        let hasMic = capturesMicrophone
        let transcriptLog: TranscriptLog? = interactive ? TranscriptLog() : nil

        // Controls: interactive (PRD §6.9) shares a CaptureControl between the
        // key reader and the capture loop; the remote-control agent (PRD §6.10)
        // injects its own control. Both pause/resume/stop the same loop.
        var interactiveSession: InteractiveSession?
        if interactive {
            let control = CaptureControl()
            captureEngine.control = control
            let ui = InteractiveSession(
                control: control, hasMic: hasMic, transcriptLog: transcriptLog)
            ui.start()
            interactiveSession = ui
        } else if let externalControl {
            captureEngine.control = externalControl
        }
        defer { interactiveSession?.stop() }

        let metadata = WAVMetadata(
            creationDate: Date(), software: "hark \(harkVersion)", title: sourceLabel)

        var sinks: [AudioSink] = []
        if let audioDest = outputs.audio {
            sinks.append(try makeAudioSink(
                audioDest, format: format, metadata: metadata,
                silenceThreshold: settings.silenceThreshold))
        }

        // Speaker labeling (PRD §6.7): dispatch on the resolved plan.
        switch speakerPlan {
        case .none:
            break  // fall through to the plain single-stream path below
        case .sourceOnly(let labels):
            try runSourceAttributedLive(
                outputs: outputs, settings: settings, captureEngine: captureEngine,
                session: session, format: format, mixedSinks: sinks, labels: labels,
                systemDiarizer: nil, transcriptLog: transcriptLog)
            return
        case .sourceDiarized(let labels, .streaming):
            let diarizer = try makeStreamingDiarizer(settings: settings)
            try runSourceAttributedLive(
                outputs: outputs, settings: settings, captureEngine: captureEngine,
                session: session, format: format, mixedSinks: sinks, labels: labels,
                systemDiarizer: diarizer, transcriptLog: transcriptLog)
            return
        case .singleDiarized(.streaming):
            let diarizer = try makeStreamingDiarizer(settings: settings)
            try runSingleDiarizedLive(
                outputs: outputs, settings: settings, captureEngine: captureEngine,
                session: session, format: format, mixedSinks: sinks, diarizer: diarizer,
                transcriptLog: transcriptLog)
            return
        case .sourceDiarized(let labels, .offline):
            try runOfflineLive(
                outputs: outputs, settings: settings, captureEngine: captureEngine,
                session: session, format: format, mixedSinks: sinks, labels: labels)
            return
        case .singleDiarized(.offline):
            try runOfflineLive(
                outputs: outputs, settings: settings, captureEngine: captureEngine,
                session: session, format: format, mixedSinks: sinks, labels: nil)
            return
        }

        var liveTranscriber: LiveTranscriber?
        if let transcriptDest = outputs.transcript {
            let transcriber = try LiveTranscriber(
                destination: transcriptDest,
                transcriptFormat: transcriptFormat(for: transcriptDest),
                engineName: settings.engine, modelFlag: model, language: settings.language,
                translate: settings.translate,
                captureFormat: format, silenceThresholdDBFS: settings.silenceThreshold,
                useVad: settings.useVad, vadThreshold: settings.vadThreshold, useGain: settings.useGain,
                // Interactive: a file destination never reaches the UI, so echo
                // captions to the screen too (PRD §6.9).
                screenEcho: interactive && transcriptDest.isFile,
                transcriptLog: transcriptLog)
            sinks.append(transcriber)
            liveTranscriber = transcriber
            if !interactive && externalControl == nil && outputs.audio == nil && duration == nil {
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

    /// Resolves how `--speakers` labels live capture (PRD §6.7). `--speaker-mode
    /// source` is the deterministic You/Others split; `auto`/`acoustic` add
    /// acoustic diarization of the system (or single) stream (`Speaker N`), in
    /// real time (`--diarize-engine streaming`, default) or as an end-of-capture
    /// offline pass (`--diarize-engine offline`). On Intel (no CoreML diarizer)
    /// diarized modes downgrade to source-only with a notice.
    private func resolveLivePlan(settings: ResolvedSettings) throws -> LivePlan {
        guard settings.speakers else { return .none }
        let twoSources = mix && (captureSystem || !apps.isEmpty || !excludeApps.isEmpty)
        let labels = settings.speakerLabels
        let mode: DiarizeMode = settings.diarizeEngine == .offline ? .offline : .streaming

        if settings.speakerMode == .source {
            guard twoSources else {
                throw HarkError.usage("""
                    speaker-mode 'source' attributes the mic vs the call, so it needs two \
                    sources: combine --mix with --system/--app/--exclude-app.
                    """)
            }
            return .sourceOnly(labels)
        }
        // auto / acoustic want diarization; fall back to source-only on Intel.
        if !Platform.isAppleSilicon {
            if twoSources {
                Log.notice(
                    "acoustic diarization needs Apple Silicon; using deterministic \(labels.you)/\(labels.others) attribution.")
                return .sourceOnly(labels)
            }
            Log.notice("acoustic diarization needs Apple Silicon; labeling disabled for this single source.")
            return .none
        }
        return twoSources ? .sourceDiarized(labels, mode) : .singleDiarized(mode)
    }

    /// Loads the streaming EEND diarizer for the system/single stream, or returns
    /// nil (with a notice) if it can't load — callers fall back to a fixed label.
    private func makeStreamingDiarizer(settings: ResolvedSettings) throws -> EENDStreamingDiarizer? {
        do {
            return try EENDStreamingDiarizer.make()
        } catch let error as HarkError {
            Log.notice("acoustic diarization unavailable (\(error.message)); falling back to a single label.")
            return nil
        }
    }

    /// Two-source live attribution: one shared transcript + engine; a mic
    /// transcriber labeled `you`, and a system transcriber labeled `others` —
    /// or, when `systemDiarizer` is given, the system side is diarized into
    /// `Speaker 1..N` by the streaming EEND timeline.
    private func runSourceAttributedLive(
        outputs: ResolvedOutputs, settings: ResolvedSettings, captureEngine: CaptureEngine,
        session: CaptureSession, format: PCMFormat, mixedSinks: [AudioSink], labels: SpeakerLabels,
        systemDiarizer: EENDStreamingDiarizer?, transcriptLog: TranscriptLog? = nil
    ) throws {
        guard let transcriptDest = outputs.transcript else {
            throw HarkError.usage("""
                --speakers labels a transcript; name one with -t FILE (or omit -a to \
                transcribe to stdout).
                """)
        }

        let writer = try LiveTranscriptWriter(
            destination: transcriptDest, format: transcriptFormat(for: transcriptDest))
        let base = try TranscriptionEngine.makeLive(
            engineName: settings.engine, modelFlag: model, language: settings.language,
            quiet: !Log.isVerbose)
        let backend = SerializedBackend(base)

        // Interactive: a file destination never reaches the UI, so each side
        // echoes its labeled captions to the screen too (PRD §6.9).
        let echoToScreen = interactive && transcriptDest.isFile
        let micTranscriber = LiveTranscriber(
            sharedWriter: writer, sharedBackend: backend, speaker: labels.you,
            language: settings.language, translate: settings.translate,
            captureFormat: format, silenceThresholdDBFS: settings.silenceThreshold,
            useVad: settings.useVad, vadThreshold: settings.vadThreshold, useGain: settings.useGain,
            screenEcho: echoToScreen, transcriptLog: transcriptLog)
        let systemTranscriber = LiveTranscriber(
            sharedWriter: writer, sharedBackend: backend, speaker: labels.others,
            resolver: systemDiarizer, language: settings.language, translate: settings.translate,
            captureFormat: format, silenceThresholdDBFS: settings.silenceThreshold,
            useVad: settings.useVad, vadThreshold: settings.vadThreshold, useGain: settings.useGain,
            screenEcho: echoToScreen, transcriptLog: transcriptLog)

        let othersDesc = systemDiarizer != nil ? "Speaker N" : labels.others
        if outputs.audio == nil && duration == nil {
            Log.notice(
                "listening (speakers: \(labels.you) + \(othersDesc)) — press Ctrl+C to stop")
        }
        Log.verbose("destination: \(transcriptDest.label) [\(labels.you)/\(othersDesc)]")

        // Route the system track to the diarizer (continuous, ahead of the
        // transcriber so the timeline is advanced first) and to its transcriber.
        var sourceSinks: [(CaptureSource, AudioSink)] = [(.microphone, micTranscriber)]
        if let systemDiarizer {
            sourceSinks.append((.system, TimelineDiarizerSink(diarizer: systemDiarizer, format: format)))
        }
        sourceSinks.append((.system, systemTranscriber))

        try captureEngine.run(
            session: session, format: format, into: mixedSinks,
            duration: duration, warnOnSilence: captureSystem,
            sourceSinks: sourceSinks)

        try? writer.close()
        backend.shutdown()
        try micTranscriber.rethrowErrors()
        try systemTranscriber.rethrowErrors()
    }

    /// Single-stream live acoustic diarization: one transcriber whose segments
    /// are labeled `Speaker 1..N` by the streaming diarizer.
    private func runSingleDiarizedLive(
        outputs: ResolvedOutputs, settings: ResolvedSettings, captureEngine: CaptureEngine,
        session: CaptureSession, format: PCMFormat, mixedSinks: [AudioSink],
        diarizer: EENDStreamingDiarizer?, transcriptLog: TranscriptLog? = nil
    ) throws {
        guard let transcriptDest = outputs.transcript else {
            throw HarkError.usage(
                "--speakers labels a transcript; name one with -t FILE (or omit -a).")
        }
        let writer = try LiveTranscriptWriter(
            destination: transcriptDest, format: transcriptFormat(for: transcriptDest))
        let base = try TranscriptionEngine.makeLive(
            engineName: settings.engine, modelFlag: model, language: settings.language,
            quiet: !Log.isVerbose)
        let backend = SerializedBackend(base)
        let transcriber = LiveTranscriber(
            backend: backend, writer: writer, ownsBackend: false, ownsWriter: false,
            speaker: nil, language: settings.language, translate: settings.translate,
            captureFormat: format, silenceThresholdDBFS: settings.silenceThreshold,
            labelName: "live transcript [Speaker N]", resolver: diarizer,
            useVad: settings.useVad, vadThreshold: settings.vadThreshold, useGain: settings.useGain,
            // Interactive: echo captions to the screen too (PRD §6.9).
            screenEcho: interactive && transcriptDest.isFile, transcriptLog: transcriptLog)

        if outputs.audio == nil && duration == nil {
            Log.notice("listening (speakers: Speaker N) — press Ctrl+C to stop")
        }

        // Feed the single stream to the diarizer (ahead of the transcriber so
        // the timeline is advanced first), then transcribe.
        var sinks = mixedSinks
        if let diarizer {
            sinks.append(TimelineDiarizerSink(diarizer: diarizer, format: format))
        }
        sinks.append(transcriber)

        try captureEngine.run(
            session: session, format: format, into: sinks,
            duration: duration, warnOnSilence: captureSystem)
        try? writer.close()
        backend.shutdown()
        try transcriber.rethrowErrors()
    }

    /// Offline-live (`--diarize-engine offline`): record the stream(s) to temp
    /// WAVs during capture, then run the accurate offline diarizer at stop. With
    /// `labels` (two sources) the mic track is forced to `you` and merged with
    /// the diarized system track; otherwise the single stream is diarized.
    private func runOfflineLive(
        outputs: ResolvedOutputs, settings: ResolvedSettings, captureEngine: CaptureEngine,
        session: CaptureSession, format: PCMFormat, mixedSinks: [AudioSink], labels: SpeakerLabels?
    ) throws {
        guard let transcriptDest = outputs.transcript else {
            throw HarkError.usage(
                "--speakers labels a transcript; name one with -t FILE (or omit -a).")
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-offline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        func wavSink(_ name: String) throws -> AudioSink {
            try CaptureEngine.makeFileSink(
                path: work.appendingPathComponent(name).path, fileFormat: .wav, format: format)
        }

        Log.notice("recording for offline diarization — press Ctrl+C to stop (transcript at end)")
        let micPath = work.appendingPathComponent("mic.wav").path
        let systemPath = work.appendingPathComponent("system.wav").path

        if labels != nil {
            try captureEngine.run(
                session: session, format: format, into: mixedSinks,
                duration: duration, warnOnSilence: captureSystem,
                sourceSinks: [(.microphone, try wavSink("mic.wav")), (.system, try wavSink("system.wav"))])
        } else {
            try captureEngine.run(
                session: session, format: format, into: mixedSinks + [try wavSink("system.wav")],
                duration: duration, warnOnSilence: captureSystem)
        }

        Log.notice("diarizing the recording…")
        var cueLists: [[TranscriptCue]] = []
        if FileManager.default.fileExists(atPath: systemPath) {
            cueLists.append(try BatchDiarization.diarizeToCues(
                audioPath: systemPath, engineName: settings.engine, modelFlag: model,
                language: settings.language, translate: settings.translate,
                maxSpeakers: maxSpeakers, threshold: speakerThreshold))
        }
        if let labels, FileManager.default.fileExists(atPath: micPath) {
            cueLists.append(try BatchDiarization.diarizeToCues(
                audioPath: micPath, engineName: settings.engine, modelFlag: model,
                language: settings.language, translate: settings.translate,
                maxSpeakers: 1, threshold: speakerThreshold, relabel: labels.you))
        }
        let cues = BatchDiarization.merge(cueLists)
        let format = transcriptFormat(for: transcriptDest)
        let rendered = TranscriptFormatting.render(
            cues: cues, fullText: cues.map(\.text).joined(separator: " "), format: format)
        try TranscribeEngine(
            engineName: settings.engine, modelFlag: model, language: settings.language,
            translate: settings.translate, format: format
        ).write(rendered, to: transcriptDest)
    }

    /// Builds the §6.8 startup-status text for a live capture from the resolved
    /// settings, the capture source label/format, and the chosen outputs.
    private func liveStatusText(
        settings: ResolvedSettings, source: String, format: PCMFormat, outputs: ResolvedOutputs
    ) -> String {
        let tapMode = captureSystem || !apps.isEmpty || !excludeApps.isEmpty
        let audioDesc: String?
        switch outputs.audio {
        case .none: audioDesc = nil
        case .stdoutWav: audioDesc = "stdout (wav stream)"
        case .stdoutRaw: audioDesc = "stdout (raw pcm)"
        case .file(let path): audioDesc = path + (split.map { " (split \($0))" } ?? "")
        }
        let transcriptDesc: String?
        switch outputs.transcript {
        case .none: transcriptDesc = nil
        case .stdout: transcriptDesc = "stdout (\(transcriptFormat(for: .stdout).rawValue))"
        case .file(let path):
            transcriptDesc = "\(path) (\(transcriptFormat(for: .file(path)).rawValue))"
        }
        let speakersDesc: String? = settings.speakers
            ? "\(settings.speakerMode.rawValue) (\(settings.speakerLabels.you)/\(settings.speakerLabels.others))"
            : nil
        let keepAwakeDesc = SleepPreventionMode.resolve(
            keepAwake: settings.keepAwake, interactive: interactive).statusDescription
        return StartupStatus.render(
            engine: settings.engine, model: model, language: settings.language,
            translate: settings.translate, source: source,
            captureBackend: tapMode ? settings.captureBackend : nil,
            format: format, audio: audioDesc, transcript: transcriptDesc,
            speakers: speakersDesc, vad: settings.useVad, keepAwake: keepAwakeDesc,
            duration: duration, split: split)
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
                throw HarkError.noInput(
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
            if settings.speakers {
                try runBatchDiarization(
                    audioPath: sourcePath, to: transcriptDest, settings: settings)
            } else {
                try transcribeAndWrite(
                    audioPath: sourcePath, to: transcriptDest, settings: settings)
            }
        } else if settings.speakers {
            throw HarkError.usage(
                "--speakers labels a transcript; name one with -t FILE (or omit -a).")
        }
    }

    /// Batch acoustic diarization (`-i FILE --speakers`): diarize, transcribe
    /// each speaker span, and write a labeled transcript (PRD §6.7b).
    private func runBatchDiarization(
        audioPath: String, to destination: TranscriptDestination, settings: ResolvedSettings
    ) throws {
        // Fail fast on an unusable engine before loading the diarizer model.
        try TranscriptionEngine.preflight(
            engineName: settings.engine, modelFlag: model,
            language: settings.language, translate: settings.translate)
        if settings.diarizeEngine == .streaming {
            Log.notice(
                "note: diarize-engine streaming applies to live capture; using the offline diarizer for files.")
        }
        let format = transcriptFormat(for: destination)
        let rendered = try BatchDiarization.diarizeAndTranscribe(
            audioPath: audioPath, engineName: settings.engine, modelFlag: model,
            language: settings.language, translate: settings.translate,
            maxSpeakers: settings.maxSpeakers, threshold: settings.speakerThreshold, format: format)
        try TranscribeEngine(
            engineName: settings.engine, modelFlag: model, language: settings.language,
            translate: settings.translate, format: format
        ).write(rendered, to: destination)
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
            sampleRate: settings.rate ?? Int(sourceFormat.sampleRate),
            bitsPerSample: settings.bits ?? ([16, 24, 32].contains(sourceBits) ? sourceBits : 16),
            channels: settings.channels ?? min(2, max(1, Int(sourceFormat.channelCount)))
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
                throw HarkError.ioError("cannot write WAV header to stdout: \(error)")
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
        throw HarkError.usage(
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
