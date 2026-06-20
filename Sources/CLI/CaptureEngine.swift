import ArgumentParser
import CoreAudio
import DeviceManager
import Encoders
import Foundation
import TapEngine

/// Live capture core: resolves a source (microphone, system, or per-app
/// tap), runs the capture session, and tees PCM to one or more sinks with
/// exact-duration trimming and signal handling.
///
/// Shared by the root command's record and live-transcribe paths: a pure
/// recording uses a single file/stream sink, while a record+transcribe run
/// tees the same PCM to the audio sink and a temporary capture WAV.
struct CaptureEngine {
    let deviceUID: String?
    let rate: Int
    let bits: Int
    let channels: Int?
    let captureSystem: Bool
    let apps: [String]
    let excludeApps: [String]
    let mix: Bool
    /// System/app capture backend: "auto", "sckit", or "coreaudio".
    var captureBackend: String = "auto"
    /// Optional external control (interactive keys / remote agent): pause drops
    /// captured chunks (a true gap); stop ends capture like a signal. nil for
    /// the plain one-shot CLI path.
    var control: CaptureControl? = nil

    /// Builds the capture session, output PCM format, and a human-readable
    /// source label for the requested source.
    func makeCapture() throws -> (CaptureSession, PCMFormat, String) {
        if captureSystem || !apps.isEmpty || !excludeApps.isEmpty {
            // System/app capture: stereo by default.
            let channelCount = channels ?? 2
            let format = PCMFormat(
                sampleRate: rate, bitsPerSample: bits, channels: channelCount)

            var micUID: String? = nil
            var micSuffix = ""
            if mix {
                let micDevice = try resolveInputDevice()
                // The mic is mixed in, so mic TCC applies for either backend.
                do {
                    try MicCaptureSession.ensureMicrophonePermission()
                } catch let error as TapEngineError {
                    throw HarkError.noPermission(error.description)
                }
                micUID = micDevice.uid
                micSuffix = " + mic (\(micDevice.name))"
            }

            let backend = resolveCaptureBackend()
            if backend == .screenCaptureKit {
                guard #available(macOS 15.0, *) else {
                    throw HarkError.unavailable(
                        "the ScreenCaptureKit backend needs macOS 15+; use --capture-backend coreaudio.")
                }
                let label = screenCaptureLabel() + micSuffix
                Log.verbose("source: \(label) [sckit] -> \(rate) Hz, \(bits)-bit, \(channelCount) ch")
                let session = ScreenCaptureSession(
                    captureSystem: captureSystem, apps: apps, excludeApps: excludeApps,
                    micDeviceUID: micUID, mixMic: mix, outputFormat: format)
                return (session, format, label)
            }

            // Core Audio process tap (headless-capable).
            guard let (scope, label) = try makeTapScope() else {
                throw HarkError.software("no capture scope")
            }
            let sourceLabel = label + micSuffix
            Log.verbose(
                "source: \(sourceLabel) [coreaudio] -> \(rate) Hz, \(bits)-bit, \(channelCount) ch")
            let session = SystemCaptureSession(
                scope: scope, micDeviceUID: micUID, outputFormat: format)
            return (session, format, sourceLabel)
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
            throw HarkError.noPermission(error.description)
        }
        return (MicCaptureSession(deviceID: deviceID, outputFormat: format), format, inputDevice.name)
    }

    /// Runs capture, teeing each chunk to every sink until the duration
    /// budget elapses, a signal (SIGINT/SIGTERM) arrives, the tapped source
    /// is lost, or a write fails. Finalizes all sinks. `warnOnSilence`
    /// enables the all-zero TCC warning used for system/app taps.
    func run(
        session: CaptureSession, format: PCMFormat, into sinks: [AudioSink],
        duration: Double?, warnOnSilence: Bool,
        sourceSinks: [(CaptureSource, AudioSink)] = []
    ) throws {
        // SIGPIPE is ignored so a closed downstream pipe surfaces as a write
        // error (EPIPE) and is handled as graceful completion.
        signal(SIGPIPE, SIG_IGN)

        // Source attribution: route each separated source to its sink(s) in
        // addition to the mixed stream. The session delivers these on its IO
        // thread; sink writes are forwarded directly (errors surface later via
        // each sink's own error path).
        let control = self.control
        if !sourceSinks.isEmpty, let multi = session as? MultiTrackCaptureSession {
            let routes = sourceSinks
            multi.onSourceAudio = { source, data in
                // Paused capture drops per-source chunks too, so attribution
                // tracks gap in lock-step with the mixed stream.
                if control?.isPaused == true { return }
                for (tag, sink) in routes where tag == source {
                    try? sink.write(data)
                }
            }
        }
        let ioQueue = DispatchQueue(label: "hark.capture.io")
        let failure = FailureBox()
        let done = DispatchSemaphore(value: 0)

        // --duration counts captured audio, not wall clock: the budget trims
        // the final chunk so the output holds exactly the requested length
        // regardless of engine spin-up latency.
        let budget = duration.map { seconds in
            ByteBudget(bytes: UInt64(seconds * Double(format.byteRate)), frameSize: format.bytesPerFrame)
        }

        // macOS delivers pure silence from a tap when the System Audio
        // Recording permission is missing (no error, no prompt for terminal-
        // attributed CLIs), so track whether anything non-zero ever arrives.
        let silenceDetector = warnOnSilence ? SilenceDetector() : nil

        // If every tapped app exits mid-recording, finalize cleanly (PRD §6.2).
        if let tapSession = session as? SystemCaptureSession {
            tapSession.onSourceLost = {
                Log.notice("all tapped applications exited; stopping recording")
                done.signal()
            }
        }

        do {
            try session.start { data in
                ioQueue.async {
                    // Paused (interactive/remote): drop the chunk entirely — no
                    // write, no duration budget consumed — so the output holds a
                    // true gap and --duration still counts only captured audio.
                    if control?.isPaused == true { return }
                    silenceDetector?.observe(data)
                    let (chunk, exhausted) = budget?.consume(data) ?? (data, false)
                    if !chunk.isEmpty {
                        do {
                            for sink in sinks { try sink.write(chunk) }
                        } catch {
                            if failure.store(error) { done.signal() }
                            return
                        }
                    }
                    if exhausted { done.signal() }
                }
            }
        } catch let error as TapEngineError {
            throw mapped(error)
        }
        Log.verbose("recording started")

        let watcher = SignalWatcher()
        watcher.watch([SIGINT, SIGTERM]) {
            Log.verbose("signal received, stopping")
            done.signal()
        }
        // An external stop (interactive Enter / remote /stop) wakes the same
        // wait loop as a signal.
        control?.setStopHandler { done.signal() }
        let startedAt = Date()
        done.wait()
        watcher.cancel()

        // Tear down: stop capture, drain pending writes, finalize sinks
        // (mixed first, then the per-source attribution sinks).
        session.stop()
        ioQueue.sync {}
        for sink in sinks + sourceSinks.map(\.1) {
            do {
                try sink.finalize()
            } catch {
                throw HarkError.ioError("failed to finalize output: \(error)")
            }
        }

        if let error = failure.take() {
            if isBrokenPipe(error) {
                Log.verbose("downstream pipe closed, stopping")
            } else {
                throw HarkError.ioError("write failed: \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let totalBytes = sinks.map(\.bytesWritten).max() ?? 0
        Log.verbose(
            "captured \(totalBytes) bytes (\(String(format: "%.1f", elapsed)) s) to "
                + sinks.map(\.label).joined(separator: ", "))

        if let silenceDetector, silenceDetector.isAllSilence, totalBytes > 0 {
            Log.error("""
                captured only silence. If audio was playing, the "System \
                Audio Recording" permission is likely missing: open System \
                Settings > Privacy & Security > Screen & System Audio \
                Recording, click "+" under "System Audio Recording Only", \
                add your terminal app, restart it, and retry.
                """)
        }
    }

    /// Creates a single-file sink for the given format. Metadata is embedded
    /// for WAV (LIST/INFO); MP4 atoms and ID3 are deferred.
    static func makeFileSink(
        path: String, fileFormat: AudioFileFormat, format: PCMFormat,
        metadata: WAVMetadata = WAVMetadata()
    ) throws -> AudioSink {
        let url = URL(fileURLWithPath: path)
        switch fileFormat {
        case .wav:
            do {
                let writer = try WAVFileWriter(
                    destination: .file(url), format: format, metadata: metadata)
                return WAVSink(writer: writer, label: url.path)
            } catch {
                throw HarkError.ioError("cannot open output file: \(error)")
            }
        case .m4a, .flac:
            do {
                let writer = try EncodedFileWriter(
                    url: url, fileFormat: fileFormat, pcmFormat: format)
                return EncodedSink(writer: writer, label: "\(url.path) (\(fileFormat.rawValue))")
            } catch {
                throw HarkError.ioError("cannot open output file: \(error)")
            }
        case .mp3:
            do {
                let writer = try MP3FileWriter(url: url, pcmFormat: format)
                return MP3Sink(writer: writer, label: "\(url.path) (mp3)")
            } catch {
                throw HarkError.ioError("cannot open output file: \(error)")
            }
        case .opus:
            do {
                let writer = try OpusFileWriter(url: url, pcmFormat: format)
                return OpusSink(writer: writer, label: "\(url.path) (opus)")
            } catch {
                throw HarkError.ioError("cannot open output file: \(error)")
            }
        }
    }

    enum CaptureBackendChoice { case screenCaptureKit, coreAudio }

    /// Picks the system/app capture backend. `coreaudio`/`sckit` force one;
    /// `auto` prefers ScreenCaptureKit when it can run (macOS 15+, a GUI session,
    /// Screen Recording granted) and otherwise falls back to the headless-capable
    /// Core Audio tap, with a one-line notice.
    private func resolveCaptureBackend() -> CaptureBackendChoice {
        switch captureBackend {
        case "coreaudio": return .coreAudio
        case "sckit": return .screenCaptureKit
        default:
            if #available(macOS 15.0, *), ScreenCaptureSession.isAvailable() {
                return .screenCaptureKit
            }
            Log.verbose("ScreenCaptureKit unavailable (no GUI session / permission); using coreaudio")
            return .coreAudio
        }
    }

    /// Human-readable label for the ScreenCaptureKit source (from the raw flags).
    private func screenCaptureLabel() -> String {
        if !apps.isEmpty { return "app audio (" + apps.joined(separator: ", ") + ")" }
        if !excludeApps.isEmpty {
            return "system audio excluding " + excludeApps.joined(separator: ", ")
        }
        return "system audio (ScreenCaptureKit)"
    }

    /// Resolves --system/--app/--exclude-app into a tap scope, or nil for
    /// plain microphone capture.
    private func makeTapScope() throws -> (TapScope, String)? {
        if !apps.isEmpty {
            let resolved = try resolveApps(apps)
            let label = "app audio (" + resolved.map(\.name).joined(separator: ", ") + ")"
            return (.processes(resolved.map { AudioObjectID($0.objectID) }), label)
        }
        if !excludeApps.isEmpty {
            let resolved = try resolveApps(excludeApps)
            let label = "system audio excluding " + resolved.map(\.name).joined(separator: ", ")
            return (.system(excluding: resolved.map { AudioObjectID($0.objectID) }), label)
        }
        if captureSystem {
            return (.system(excluding: []), "system audio (tap)")
        }
        return nil
    }

    private func resolveApps(_ specifiers: [String]) throws -> [CapturableApp] {
        do {
            let resolved = try DeviceManager.resolveApps(specifiers: specifiers)
            for app in resolved {
                Log.verbose("resolved '\(app.name)' [\(app.bundleID)] pid \(app.pid)")
            }
            return resolved
        } catch let error as AppResolutionError {
            throw HarkError.noInput(error.description)
        } catch {
            throw HarkError.software("failed to resolve applications: \(error)")
        }
    }

    /// Maps TapEngine failures to user-facing errors with exit codes. Tap
    /// creation failures most commonly mean a System Audio Recording TCC
    /// denial, so they carry the permission guidance (exit 77).
    private func mapped(_ error: TapEngineError) -> HarkError {
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
                throw HarkError.software("failed to enumerate devices: \(error)")
            }
            guard let device = devices.first(where: { $0.uid == deviceUID }) else {
                throw HarkError.noInput(
                    "no device with UID '\(deviceUID)' (see 'hark devices')")
            }
            guard device.inputChannels > 0 else {
                throw HarkError.noInput(
                    "device '\(device.name)' has no input channels")
            }
            return device
        }
        do {
            guard let device = try DeviceManager.defaultInputDevice() else {
                throw HarkError.noInput("no default input device available")
            }
            return device
        } catch let error as HarkError {
            throw error
        } catch {
            throw HarkError.noInput("no default input device available (\(error))")
        }
    }
}

/// Tracks whether a capture stream has produced any non-zero sample. Stops
/// scanning after the first non-zero byte.
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
