import ArgumentParser
import CoreAudio
import DeviceManager
import Encoders
import Foundation
import TapEngine

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record audio from a microphone, the system, or specific apps.",
        discussion: """
            By default records from the default input device, or from a \
            specific device selected with -d/--device (UIDs are listed by \
            'aural devices'). With --system, captures all system audio via a \
            Core Audio process tap instead (requires the System Audio \
            Recording permission). Recording stops after -t/--duration \
            seconds, or on Ctrl+C (SIGINT/SIGTERM), finalizing the file so \
            it remains playable.
            """
    )

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Input device UID (see 'aural devices'). Defaults to the system default input.",
        valueName: "uid"))
    var device: String?

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Output file path (.wav).", valueName: "path"))
    var output: String?

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Sample rate in Hz.", valueName: "hz"))
    var rate: Int = 44100

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Bits per sample: 16, 24, or 32.", valueName: "bits"))
    var bits: Int = 16

    @Option(name: [.short, .long], help: ArgumentHelp(
        "Channel count: 1 or 2. Defaults to the device's input channels (capped at 2).",
        valueName: "n"))
    var channels: Int?

    @Option(name: [.customShort("t"), .long], help: ArgumentHelp(
        "Stop recording after this many seconds.", valueName: "sec"))
    var duration: Double?

    @Flag(name: .customLong("stdout"), help: """
        Stream a WAV container to stdout (unknown-length header). \
        Without this flag and without -o, raw headerless PCM is piped.
        """)
    var wavToStdout = false

    @Flag(name: .customLong("no-output"), help: "Capture but write nothing (dry run).")
    var noOutput = false

    @Flag(name: .customLong("system"), help: """
        Capture all system audio via a Core Audio process tap instead of \
        the microphone.
        """)
    var captureSystem = false

    @OptionGroup var options: GlobalOptions

    func validate() throws {
        guard [16, 24, 32].contains(bits) else {
            throw ValidationError("--bits must be 16, 24, or 32.")
        }
        guard (1...768_000).contains(rate) else {
            throw ValidationError("--rate must be between 1 and 768000 Hz.")
        }
        if let channels, !(1...2).contains(channels) {
            throw ValidationError("--channels must be 1 or 2.")
        }
        if let duration, duration <= 0 {
            throw ValidationError("--duration must be positive.")
        }
        if output != nil && wavToStdout {
            throw ValidationError("-o/--output and --stdout are mutually exclusive.")
        }
        if output != nil && noOutput {
            throw ValidationError("-o/--output and --no-output are mutually exclusive.")
        }
        if wavToStdout && noOutput {
            throw ValidationError("--stdout and --no-output are mutually exclusive.")
        }
        if captureSystem && device != nil {
            throw ValidationError(
                "-d/--device selects a microphone and does not apply to --system capture.")
        }
    }

    func run() throws {
        try runMapped(verbose: options.verbose) {
            try RecordingSession(
                deviceUID: device,
                outputPath: output,
                rate: rate,
                bits: bits,
                channels: channels,
                duration: duration,
                wavToStdout: wavToStdout,
                noOutput: noOutput,
                captureSystem: captureSystem
            ).run()
        }
    }
}

/// Drives a capture session: device resolution, writer setup, lifetime
/// control (duration/signals), and final stats.
struct RecordingSession {
    let deviceUID: String?
    let outputPath: String?
    let rate: Int
    let bits: Int
    let channels: Int?
    let duration: Double?
    let wavToStdout: Bool
    let noOutput: Bool
    let captureSystem: Bool

    func run() throws {
        // 1. Build the capture session for the requested source.
        let (session, format) = try makeCapture()

        // 2. Set up the output sink.
        let sink = try makeSink(format: format)
        Log.verbose("destination: \(sink.label)")

        // 3. Capture. SIGPIPE is ignored so a closed downstream pipe surfaces
        // as a write error (EPIPE) and is handled as graceful completion.
        signal(SIGPIPE, SIG_IGN)
        let ioQueue = DispatchQueue(label: "aural.record.io")
        let failure = FailureBox()
        let done = DispatchSemaphore(value: 0)

        // -t/--duration counts captured audio, not wall clock: the budget
        // trims the final chunk so the output holds exactly the requested
        // length regardless of engine spin-up latency.
        let budget = duration.map { seconds in
            ByteBudget(bytes: UInt64(seconds * Double(format.byteRate)), frameSize: format.bytesPerFrame)
        }

        // macOS delivers pure silence from a tap when the System Audio
        // Recording permission is missing (no error, no prompt for
        // terminal-attributed CLIs), so track whether anything non-zero
        // ever arrives and warn at the end.
        let silenceDetector = captureSystem ? SilenceDetector() : nil

        do {
            try session.start { data in
                ioQueue.async {
                    silenceDetector?.observe(data)
                    let (chunk, exhausted) = budget?.consume(data) ?? (data, false)
                    do {
                        if !chunk.isEmpty { try sink.write(chunk) }
                    } catch {
                        if failure.store(error) { done.signal() }
                        return
                    }
                    if exhausted { done.signal() }
                }
            }
        } catch let error as TapEngineError {
            throw mapped(error)
        }
        Log.verbose("recording started")

        // 5. Wait for the duration budget, Ctrl+C/SIGTERM, or a write failure.
        let watcher = SignalWatcher()
        watcher.watch([SIGINT, SIGTERM]) {
            Log.verbose("signal received, stopping")
            done.signal()
        }
        let startedAt = Date()
        done.wait()
        watcher.cancel()

        // 6. Tear down: stop capture, drain pending writes, finalize header.
        session.stop()
        ioQueue.sync {}
        try? sink.finalize()

        if let error = failure.take() {
            if isBrokenPipe(error) {
                Log.verbose("downstream pipe closed, stopping")
            } else {
                throw AuralError.ioError("write failed: \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        Log.verbose(
            "wrote \(sink.bytesWritten) bytes (\(String(format: "%.1f", elapsed)) s) to \(sink.label)")

        if let silenceDetector, silenceDetector.isAllSilence, sink.bytesWritten > 0 {
            Log.error("""
                captured only silence. If audio was playing, the "System \
                Audio Recording" permission is likely missing: open System \
                Settings > Privacy & Security > Screen & System Audio \
                Recording, click "+" under "System Audio Recording Only", \
                add your terminal app, restart it, and retry.
                """)
        }
    }

    /// Builds the output sink from the flag combination:
    /// -o FILE -> WAV file; --stdout -> WAV stream; --no-output -> discard;
    /// none -> raw PCM to stdout (refused on a terminal).
    private func makeSink(format: PCMFormat) throws -> AudioSink {
        if noOutput {
            return DiscardSink()
        }
        if let outputPath {
            let url = URL(fileURLWithPath: outputPath)
            do {
                let writer = try WAVFileWriter(destination: .file(url), format: format)
                return WAVSink(writer: writer, label: url.path)
            } catch {
                throw AuralError.ioError("cannot open output file: \(error)")
            }
        }
        if wavToStdout {
            let writer: WAVFileWriter
            do {
                writer = try WAVFileWriter(
                    destination: .stream(.standardOutput), format: format)
            } catch {
                throw AuralError.ioError("cannot write WAV header to stdout: \(error)")
            }
            return WAVSink(writer: writer, label: "stdout (wav stream)")
        }
        guard isatty(STDOUT_FILENO) == 0 else {
            throw AuralError.usage("""
                refusing to write raw audio to a terminal. Pipe stdout, \
                use --stdout for a WAV stream, or -o FILE for a file.
                """)
        }
        return RawStreamSink(handle: .standardOutput, label: "stdout (raw pcm)")
    }

    /// Builds the capture session and output format for the requested source.
    private func makeCapture() throws -> (CaptureSession, PCMFormat) {
        if captureSystem {
            // System tap: stereo by default; mic TCC not needed.
            let channelCount = channels ?? 2
            let format = PCMFormat(
                sampleRate: rate, bitsPerSample: bits, channels: channelCount)
            Log.verbose("source: system audio (tap) -> \(rate) Hz, \(bits)-bit, \(channelCount) ch")
            let session = SystemCaptureSession(
                scope: .system(excluding: []), micDeviceUID: nil, outputFormat: format)
            return (session, format)
        }

        let inputDevice = try resolveInputDevice()
        let deviceID: AudioDeviceID? = deviceUID.map { _ in AudioDeviceID(inputDevice.objectID) }
        let channelCount = channels ?? min(2, max(1, inputDevice.inputChannels))
        let format = PCMFormat(sampleRate: rate, bitsPerSample: bits, channels: channelCount)
        Log.verbose(
            "source: \(inputDevice.name) [\(inputDevice.uid)] -> \(rate) Hz, \(bits)-bit, \(channelCount) ch")
        do {
            try MicCaptureSession.ensureMicrophonePermission()
        } catch let error as TapEngineError {
            throw AuralError.noPermission(error.description)
        }
        return (MicCaptureSession(deviceID: deviceID, outputFormat: format), format)
    }

    /// Maps TapEngine failures to user-facing errors with exit codes.
    /// Tap creation failures most commonly mean a System Audio Recording
    /// TCC denial, so they carry the permission guidance (exit 77).
    private func mapped(_ error: TapEngineError) -> AuralError {
        switch error {
        case .tapCreationFailed(let status):
            return .noPermission(
                TapEngineError.systemAudioPermissionDenied(status).description)
        case .microphonePermissionDenied, .systemAudioPermissionDenied:
            return .noPermission(error.description)
        default:
            return .software(error.description)
        }
    }

    private func resolveInputDevice() throws -> AudioDevice {
        if let deviceUID {
            let devices: [AudioDevice]
            do {
                devices = try DeviceManager.listDevices(scope: .all)
            } catch {
                throw AuralError.software("failed to enumerate devices: \(error)")
            }
            guard let device = devices.first(where: { $0.uid == deviceUID }) else {
                throw AuralError.noInput(
                    "no device with UID '\(deviceUID)' (see 'aural devices')")
            }
            guard device.inputChannels > 0 else {
                throw AuralError.noInput(
                    "device '\(device.name)' has no input channels")
            }
            return device
        }
        do {
            guard let device = try DeviceManager.defaultInputDevice() else {
                throw AuralError.noInput("no default input device available")
            }
            return device
        } catch let error as AuralError {
            throw error
        } catch {
            throw AuralError.noInput("no default input device available (\(error))")
        }
    }
}

/// Tracks whether a capture stream has produced any non-zero sample.
/// Stops scanning after the first non-zero byte.
final class SilenceDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var sawSignal = false

    func observe(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !sawSignal else { return }
        if data.contains(where: { $0 != 0 }) { sawSignal = true }
    }

    var isAllSilence: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !sawSignal
    }
}

/// Frame-aligned byte budget for exact-duration capture.
final class ByteBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: UInt64

    init(bytes: UInt64, frameSize: Int) {
        // Round down to a whole frame so trimming never splits a frame.
        let frame = UInt64(max(1, frameSize))
        self.remaining = bytes - (bytes % frame)
    }

    /// Returns the portion of `data` that fits the budget and whether the
    /// budget is now exhausted.
    func consume(_ data: Data) -> (chunk: Data, exhausted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return (Data(), true) }
        if UInt64(data.count) <= remaining {
            remaining -= UInt64(data.count)
            return (data, remaining == 0)
        }
        let chunk = data.prefix(Int(remaining))
        remaining = 0
        return (Data(chunk), true)
    }
}

/// Thread-safe single-error container.
final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    /// Stores the first error; returns true if this call stored it.
    func store(_ newError: Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard error == nil else { return false }
        error = newError
        return true
    }

    func take() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}
