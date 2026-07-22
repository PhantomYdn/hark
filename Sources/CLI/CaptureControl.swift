import Foundation

/// External control over a running live capture (PRD §6.9 interactive mode and
/// §6.10 remote-control agent): pause/resume — which drops captured audio so the
/// paused interval is a true gap, never written — and stop, which ends the
/// capture like Ctrl-C.
///
/// Thread-safe. A single instance is shared between the control front-end (the
/// interactive key reader, or an HTTP handler) and `CaptureEngine.run`, which
/// installs a stop handler to wake its wait loop and consults `isPaused` on the
/// capture I/O path.
final class CaptureControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var muted = false
    private var stopped = false
    private var onStop: (() -> Void)?

    /// True while capture is paused (the I/O path drops chunks).
    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    /// True while the microphone is muted (interactive `m`, PRD §6.9). Unlike
    /// pause this silences **only** the mic — capture keeps running and the
    /// timeline is preserved — so it is read by the capture session, not the
    /// engine's chunk-drop path. Independent of `paused`.
    var isMuted: Bool {
        lock.lock(); defer { lock.unlock() }
        return muted
    }

    /// True once `stop()` has been requested.
    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// `CaptureEngine.run` installs a handler to wake its wait loop. If a stop
    /// was already requested before the handler was set, it fires immediately.
    func setStopHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        onStop = handler
        let fireNow = stopped
        lock.unlock()
        if fireNow { handler() }
    }

    /// Toggles pause/resume; returns the new paused state. A no-op (returns the
    /// current state) once stopped.
    @discardableResult
    func togglePause() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return paused }
        paused.toggle()
        return paused
    }

    /// Toggles microphone mute; returns the new muted state. A no-op (returns
    /// the current state) once stopped. Independent of pause.
    @discardableResult
    func toggleMute() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return muted }
        muted.toggle()
        return muted
    }

    /// Mutes the microphone if not already muted; returns true if the state
    /// changed. A no-op once stopped. Independent of pause. Used by the
    /// remote-control agent's `POST /mute` (idempotent, unlike `toggleMute`).
    @discardableResult
    func mute() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !muted, !stopped else { return false }
        muted = true
        return true
    }

    /// Unmutes the microphone if muted; returns true if the state changed. A
    /// no-op once stopped. Used by the remote-control agent's `POST /unmute`.
    @discardableResult
    func unmute() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard muted, !stopped else { return false }
        muted = false
        return true
    }

    /// Pauses if running; returns true if the state changed.
    @discardableResult
    func pause() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !paused, !stopped else { return false }
        paused = true
        return true
    }

    /// Resumes if paused; returns true if the state changed.
    @discardableResult
    func resume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard paused, !stopped else { return false }
        paused = false
        return true
    }

    /// Requests a graceful stop and wakes the capture wait loop (idempotent).
    func stop() {
        lock.lock()
        let handler: (() -> Void)?
        if stopped {
            handler = nil
        } else {
            stopped = true
            paused = false
            muted = false
            handler = onStop
        }
        lock.unlock()
        handler?()
    }
}
