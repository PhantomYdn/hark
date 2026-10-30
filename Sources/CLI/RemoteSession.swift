import ArgumentParser
import Foundation

/// Errors specific to the remote-control agent's session lifecycle, mapped to
/// HTTP status codes by `RemoteControlAgent`.
enum AgentError: Error {
    case busy            // a recording is already active (409)
    case finishing       // the previous capture's worker never returned (409)
    case noActiveSession // pause/resume/stop with nothing running (404)
    case noMicrophone    // mute/unmute on a capture with no mic (422)
}

/// Agent timing knobs.
enum AgentTimeouts {
    /// How long after a stop request the worker gets to finish before the
    /// session is declared wedged. A capture that can't reach the audio stream
    /// (e.g. a stale "System Audio Recording" grant) has been seen to block
    /// forever in teardown; without this the session would sit in `stopped`
    /// with no error while the serial capture queue stayed blocked.
    static var stopTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["HARK_STOP_TIMEOUT"].flatMap(Double.init) ?? 10
    }
}

/// Tracks the agent's **single** active recording session (PRD §6.10). Thread-
/// safe: HTTP handlers (async) and the capture worker thread both touch it. A
/// second `begin` while a session is recording/paused is rejected with `.busy`.
final class RemoteSessionManager: @unchecked Sendable {
    enum State: String, Sendable {
        case recording, paused, stopped, failed
    }

    /// Immutable-ish snapshot of the current/last session for `GET /status`.
    struct Snapshot: Sendable {
        let id: String
        var state: State
        let startedAt: Date
        let audio: String?
        let transcript: String?
        /// Whether a microphone is in this capture (mic-only or `--mix`); gates
        /// `/mute` and `/unmute`.
        let hasMic: Bool
        /// Whether the microphone is currently muted (orthogonal to `state`).
        var muted: Bool
        var error: String?
    }

    /// Schedules the stop-timeout check. Injectable so tests drive it without
    /// waiting on wall-clock time.
    typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    private let lock = NSLock()
    private var control: CaptureControl?
    private var snapshot: Snapshot?
    /// True from `begin` until the capture worker reports back via `finish` —
    /// independent of session `state`, which `stop()` sets optimistically. A
    /// worker that never returns keeps this true, and since captures run on one
    /// serial queue, starting another session would silently queue behind it.
    private var workerRunning = false
    private let stopTimeout: TimeInterval
    private let schedule: Scheduler

    init(
        stopTimeout: TimeInterval = AgentTimeouts.stopTimeout,
        schedule: @escaping Scheduler = { after, work in
            DispatchQueue.global().asyncAfter(deadline: .now() + after, execute: work)
        }
    ) {
        self.stopTimeout = stopTimeout
        self.schedule = schedule
    }

    /// True while a recording is active (recording or paused).
    private var isActive: Bool {
        guard let snapshot else { return false }
        return snapshot.state == .recording || snapshot.state == .paused
    }

    /// True while the capture worker of the last session hasn't returned.
    func isFinishing() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return workerRunning && !isActive
    }

    /// The last/current session snapshot (nil before the first `begin`).
    func current() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Registers a new active session. Throws `.busy` if one is already running,
    /// `.finishing` if the previous session's worker hasn't returned (its
    /// capture would otherwise queue behind a wedged one and never run), or
    /// `.noMicrophone` if `muted` is requested for a capture with no mic.
    func begin(
        id: String, control: CaptureControl, hasMic: Bool, muted: Bool,
        audio: String?, transcript: String?
    ) throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard !isActive else { throw AgentError.busy }
        guard !workerRunning else { throw AgentError.finishing }
        if muted {
            guard hasMic else { throw AgentError.noMicrophone }
            control.mute()  // start muted; the capture reads isMuted from the off
        }
        let snap = Snapshot(
            id: id, state: .recording, startedAt: Date(),
            audio: audio, transcript: transcript, hasMic: hasMic, muted: muted, error: nil)
        self.control = control
        self.snapshot = snap
        self.workerRunning = true
        return snap
    }

    func pause() throws -> Snapshot { try transition(to: .paused) { $0.pause() } }
    func resume() throws -> Snapshot { try transition(to: .recording) { $0.resume() } }

    /// Mutes/unmutes the active session's microphone. Throws `.noActiveSession`
    /// (404) when nothing is running, or `.noMicrophone` (422) when the capture
    /// has no mic. Mute is orthogonal to `state` — it does not pause capture.
    func mute() throws -> Snapshot { try setMuted(true) }
    func unmute() throws -> Snapshot { try setMuted(false) }

    private func setMuted(_ value: Bool) throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard isActive, var snap = snapshot, let control else { throw AgentError.noActiveSession }
        guard snap.hasMic else { throw AgentError.noMicrophone }
        if value { control.mute() } else { control.unmute() }
        snap.muted = value
        snapshot = snap
        return snap
    }

    /// Requests a stop on the active session and marks it stopped optimistically;
    /// the worker's `finish` confirms the final state. If the worker doesn't
    /// report back within `stopTimeout`, the session is marked `failed` so
    /// `GET /status` reflects a wedged capture instead of a clean stop.
    func stop() throws -> Snapshot {
        lock.lock()
        guard isActive, var snap = snapshot, let control else {
            lock.unlock()
            throw AgentError.noActiveSession
        }
        control.stop()
        snap.state = .stopped
        snapshot = snap
        let id = snap.id
        lock.unlock()

        schedule(stopTimeout) { [weak self] in
            self?.failIfUnfinished(id: id)
        }
        return snap
    }

    /// Marks a stopped-but-unfinished session as failed (the stop-timeout
    /// watchdog). Returns true when it transitioned, i.e. the worker really is
    /// wedged. Leaves `workerRunning` set: the thread is still stuck, so a new
    /// session must keep being refused rather than queue behind it.
    @discardableResult
    func failIfUnfinished(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var snap = snapshot, snap.id == id, workerRunning, snap.state == .stopped
        else { return false }
        snap.state = .failed
        snap.error = Self.wedgedMessage(after: stopTimeout)
        snapshot = snap
        Log.error(snap.error!)
        return true
    }

    /// Message for a capture that never finished after a stop request.
    static func wedgedMessage(after seconds: TimeInterval) -> String {
        """
        capture did not finish within \(ConfigKey.formatNumber(seconds))s — the audio stream \
        appears wedged (most often a missing or stale "System Audio Recording" grant; see \
        docs/permissions.md). New recordings are refused while it is stuck; restart the agent \
        if this persists (e.g. brew services restart hark).
        """
    }

    /// Called by the capture worker when `executeLive` returns: records the
    /// terminal state and releases the control. A session already declared
    /// wedged by the stop-timeout keeps that verdict — the client was told it
    /// failed — but the worker slot is released either way.
    func finish(id: String, error: String?) {
        lock.lock(); defer { lock.unlock() }
        guard var snap = snapshot, snap.id == id else { return }
        workerRunning = false
        control = nil
        guard snap.state != .failed || snap.error == nil else { return }
        snap.state = error == nil ? .stopped : .failed
        snap.error = error
        snapshot = snap
    }

    /// Stops whatever is active (used on agent shutdown / SIGINT).
    func stopActive() {
        lock.lock(); let control = self.control; lock.unlock()
        control?.stop()
    }

    private func transition(to state: State, _ action: (CaptureControl) -> Bool) throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard isActive, var snap = snapshot, let control else { throw AgentError.noActiveSession }
        _ = action(control)
        snap.state = state
        snapshot = snap
        return snap
    }
}

/// The JSON body of `POST /start`: every field is optional and mirrors a CLI
/// flag/output. Provided fields override the agent's launch-time defaults.
struct StartRequest: Decodable {
    var audio: String?
    var transcript: String?
    /// Existing-output policy for this session: `error`, `overwrite`, or
    /// `unique`. Defaults to `unique` (auto-numbered) so a session never blocks
    /// and never clobbers; `ask` is rejected — the agent has no terminal.
    var ifExists: String?
    /// Begin with the microphone muted (requires a mic in the capture, else 422).
    /// Not a CLI flag — handled by the agent, not `makeCommand`.
    var muted: Bool?
    var system: Bool?
    var apps: [String]?
    var excludeApps: [String]?
    var device: String?
    var mix: Bool?
    var captureBackend: String?
    var engine: String?
    var model: String?
    var language: String?
    var translate: Bool?
    var duration: Double?
    var format: String?
    var transcriptFormat: String?
    var rate: Int?
    var bits: Int?
    var channels: Int?
    var split: String?
    var silenceThreshold: Double?
    var speakers: Bool?
    var speakerMode: String?
    var speakerLabels: String?
    var diarizeEngine: String?
    var maxSpeakers: Int?
    var speakerThreshold: Double?
    var vad: Bool?
    var vadThreshold: Double?
    var segmentPause: Double?
    var segmentWindow: Double?
    var gain: Bool?

    /// Builds the per-session `Hark` command from the agent's launch defaults
    /// plus this request's overrides. The capture path runs exactly as the CLI
    /// would, so it has full parity (sources, formats, engines, speakers).
    /// Throws `HarkError.usage` (→ HTTP 400) for invalid values.
    func makeCommand(defaults: Hark) throws -> Hark {
        var cmd = defaults
        // Never recurse into the agent / interactive UI / file input from a
        // session command.
        cmd.remoteControl = nil
        cmd.interactive = false
        cmd.input = nil
        cmd.noOutput = false

        if let audio { cmd.audio = audio }
        if let transcript { cmd.transcript = transcript }
        cmd.ifExists = try resolvedPolicy(defaults: defaults)
        if let system { cmd.captureSystem = system }
        if let apps { cmd.apps = apps }
        if let excludeApps { cmd.excludeApps = excludeApps }
        if let device { cmd.device = device }
        if let mix { cmd.mix = mix }
        if let captureBackend { cmd.captureBackend = captureBackend }
        if let engine { cmd.engine = engine }
        if let model { cmd.model = model }
        if let language { cmd.language = language }
        if let translate { cmd.translate = translate }
        if let duration { cmd.duration = duration }
        if let format { cmd.forcedFormat = format }
        if let transcriptFormat {
            guard let parsed = TranscriptOutputFormat(rawValue: transcriptFormat.lowercased()) else {
                throw HarkError.usage("invalid transcriptFormat '\(transcriptFormat)' (txt, srt, json).")
            }
            cmd.forcedTranscriptFormat = parsed
        }
        if let rate { cmd.rate = rate }
        if let bits { cmd.bits = bits }
        if let channels { cmd.channels = channels }
        if let split { cmd.split = split }
        if let silenceThreshold { cmd.silenceThreshold = silenceThreshold }
        if let speakers { cmd.speakers = speakers }
        if let speakerMode {
            guard let parsed = SpeakerMode(rawValue: speakerMode.lowercased()) else {
                throw HarkError.usage("invalid speakerMode '\(speakerMode)' (auto, source, acoustic).")
            }
            cmd.speakerMode = parsed
        }
        if let speakerLabels { cmd.speakerLabels = speakerLabels }
        if let diarizeEngine {
            guard let parsed = DiarizeEngine(rawValue: diarizeEngine.lowercased()) else {
                throw HarkError.usage("invalid diarizeEngine '\(diarizeEngine)' (auto, streaming, offline).")
            }
            cmd.diarizeEngine = parsed
        }
        if let maxSpeakers { cmd.maxSpeakers = maxSpeakers }
        if let speakerThreshold { cmd.speakerThreshold = speakerThreshold }
        if let vad { cmd.useVad = vad }
        if let vadThreshold { cmd.vadThreshold = vadThreshold }
        if let segmentPause { cmd.segmentPause = segmentPause }
        if let segmentWindow { cmd.segmentWindow = segmentWindow }
        if let gain { cmd.useGain = gain }

        // The agent writes to files under the working directory and never to the
        // client; reject stdout/streaming outputs and require at least one file.
        if cmd.audio == "-" || cmd.transcript == "-" || cmd.raw {
            throw HarkError.usage("the remote agent writes files; stdout ('-') output isn't supported.")
        }
        guard cmd.audio != nil || cmd.transcript != nil else {
            throw HarkError.usage("specify 'audio' and/or 'transcript' (a file path) to start a recording.")
        }

        // Run the same flag-combination validation the CLI does (→ HTTP 400).
        do {
            try cmd.validate()
        } catch let error as ValidationError {
            throw HarkError.usage("\(error)")
        }
        return cmd
    }

    /// The existing-output policy for this session. An explicit request value
    /// wins, else the agent's launch flag, else `unique`. `ask` can never apply
    /// (nothing would answer the prompt), so it becomes `unique`.
    private func resolvedPolicy(defaults: Hark) throws -> ExistingFilePolicy {
        if let raw = ifExists {
            guard let parsed = ExistingFilePolicy(rawValue: raw.lowercased()) else {
                throw HarkError.usage(
                    "invalid ifExists '\(raw)' (error, overwrite, unique).")
            }
            guard parsed != .ask else {
                throw HarkError.usage(
                    "ifExists 'ask' needs a terminal; use error, overwrite, or unique.")
            }
            return parsed
        }
        if let launch = defaults.ifExists, launch != .ask { return launch }
        return .unique
    }
}
