import ArgumentParser
import Foundation

/// Errors specific to the remote-control agent's session lifecycle, mapped to
/// HTTP status codes by `RemoteControlAgent`.
enum AgentError: Error {
    case busy            // a recording is already active (409)
    case noActiveSession // pause/resume/stop with nothing running (404)
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
        var error: String?
    }

    private let lock = NSLock()
    private var control: CaptureControl?
    private var snapshot: Snapshot?

    /// True while a recording is active (recording or paused).
    private var isActive: Bool {
        guard let snapshot else { return false }
        return snapshot.state == .recording || snapshot.state == .paused
    }

    /// The last/current session snapshot (nil before the first `begin`).
    func current() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Registers a new active session. Throws `.busy` if one is already running.
    func begin(id: String, control: CaptureControl, audio: String?, transcript: String?) throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard !isActive else { throw AgentError.busy }
        let snap = Snapshot(
            id: id, state: .recording, startedAt: Date(),
            audio: audio, transcript: transcript, error: nil)
        self.control = control
        self.snapshot = snap
        return snap
    }

    func pause() throws -> Snapshot { try transition(to: .paused) { $0.pause() } }
    func resume() throws -> Snapshot { try transition(to: .recording) { $0.resume() } }

    /// Requests a stop on the active session and marks it stopped optimistically;
    /// the worker's `finish` confirms the final state.
    func stop() throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard isActive, var snap = snapshot, let control else { throw AgentError.noActiveSession }
        control.stop()
        snap.state = .stopped
        snapshot = snap
        return snap
    }

    /// Called by the capture worker when `executeLive` returns: records the
    /// terminal state and releases the control.
    func finish(id: String, error: String?) {
        lock.lock(); defer { lock.unlock() }
        guard var snap = snapshot, snap.id == id else { return }
        snap.state = error == nil ? .stopped : .failed
        snap.error = error
        snapshot = snap
        control = nil
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
}
