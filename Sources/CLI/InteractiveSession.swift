import Darwin
import Foundation

/// Minimal interactive controller for live capture (PRD §6.9). Puts the
/// terminal into cbreak mode and reads single keys on a background thread —
/// **space** toggles pause/resume, **Enter** finishes — driving a shared
/// `CaptureControl`. Ctrl-C still stops via the normal signal path.
///
/// The UI is deliberately minimal: the transcript streams on stdout while
/// control hints and pause/resume/stop notices print on stderr, so the two
/// never fight over a pinned region. The terminal mode is always restored on
/// `stop()` and on `deinit`.
final class InteractiveSession: @unchecked Sendable {
    private let control: CaptureControl
    private let lock = NSLock()
    private var original = termios()
    private var rawEnabled = false
    private var stopReading = false

    init(control: CaptureControl) {
        self.control = control
    }

    /// Enables cbreak mode and starts the key-reader thread. Prints the control
    /// hint. No-op when stdin is not a TTY.
    func start() {
        guard isatty(STDIN_FILENO) != 0 else { return }

        var raw = termios()
        tcgetattr(STDIN_FILENO, &original)
        raw = original
        // Disable canonical mode and echo so single keys arrive immediately and
        // aren't printed.
        raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
        // VMIN=0, VTIME=1: read() returns after 0.1s even with no input, so the
        // loop can observe stopReading and exit instead of blocking forever.
        withUnsafeMutablePointer(to: &raw.c_cc) { ccTuple in
            ccTuple.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 1
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        lock.lock(); rawEnabled = true; lock.unlock()

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "hark.interactive.keys"
        thread.start()

        note("controls: [space] pause/resume   [enter] finish   [ctrl-c] stop")
    }

    private func readLoop() {
        var byte: UInt8 = 0
        while true {
            lock.lock(); let done = stopReading; lock.unlock()
            if done { return }
            let n = read(STDIN_FILENO, &byte, 1)
            if n <= 0 { continue }  // timeout (VTIME) or transient — keep polling
            switch byte {
            case 0x20:  // space
                let paused = control.togglePause()
                note(paused ? "paused — [space] to resume" : "resumed")
            case 0x0A, 0x0D:  // Enter / Return
                note("finishing…")
                control.stop()
                return
            default:
                break
            }
        }
    }

    /// Stops the key reader and restores the terminal. Idempotent.
    func stop() {
        lock.lock()
        let wasRaw = rawEnabled
        stopReading = true
        rawEnabled = false
        lock.unlock()
        if wasRaw {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
        }
    }

    deinit {
        lock.lock(); let wasRaw = rawEnabled; lock.unlock()
        if wasRaw { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
    }

    /// A control notice on stderr (keeps stdout — the transcript — clean).
    private func note(_ message: String) {
        FileHandle.standardError.write(Data("hark: \(message)\n".utf8))
    }
}
