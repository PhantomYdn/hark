import Darwin
import Foundation

/// Thread-safe accumulator of finalised transcript caption lines for the
/// interactive yank feature (PRD §6.9). `LiveTranscriber` appends each line
/// (plain text, with the speaker label when set); the `y` key copies the joined
/// text to the clipboard.
final class TranscriptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }

    /// The whole transcript so far, one caption per line.
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return lines.isEmpty
    }
}

/// Minimal interactive controller for live capture (PRD §6.9). Puts the
/// terminal into cbreak mode and reads single keys on a background thread —
/// **space** toggles pause/resume, **m** toggles mic mute, **y** yanks the
/// transcript so far to the clipboard, **Enter** finishes — driving a shared
/// `CaptureControl`. Ctrl-C still stops via the normal signal path.
///
/// The UI is deliberately minimal: the transcript streams on stdout while
/// control hints and pause/resume/mute/stop notices print on stderr, so the two
/// never fight over a pinned region. The terminal mode is always restored on
/// `stop()` and on `deinit`.
final class InteractiveSession: @unchecked Sendable {
    private let control: CaptureControl
    private let hasMic: Bool
    private let transcriptLog: TranscriptLog?
    private let clipboard: ClipboardWriter
    /// User-defined `shortcut.<k>` bindings by key (PRD §6.9) and their runner.
    private let shortcuts: [Character: ShortcutBinding]
    private let shortcutRunner: ShortcutRunner
    private let lock = NSLock()
    private var original = termios()
    private var rawEnabled = false
    private var stopReading = false

    init(
        control: CaptureControl,
        hasMic: Bool,
        transcriptLog: TranscriptLog?,
        clipboard: ClipboardWriter = SystemClipboard(),
        shortcuts: [ShortcutBinding] = [],
        shortcutRunner: ShortcutRunner = ProcessShortcutRunner()
    ) {
        self.control = control
        self.hasMic = hasMic
        self.transcriptLog = transcriptLog
        self.clipboard = clipboard
        self.shortcuts = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key, $0) })
        self.shortcutRunner = shortcutRunner
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

        note(Self.controlsHint(hasMic: hasMic, shortcutKeys: shortcuts.keys.sorted()))
    }

    /// The controls hint line. `[m] mute` is shown only when a microphone is
    /// part of the capture; `[y] yank transcript` always appears; bound
    /// shortcut keys are listed when configured.
    static func controlsHint(hasMic: Bool, shortcutKeys: [Character] = []) -> String {
        var parts = ["[space] pause/resume"]
        if hasMic { parts.append("[m] mute mic") }
        parts.append("[y] yank transcript")
        if !shortcutKeys.isEmpty {
            let keys = shortcutKeys.map(String.init).joined(separator: "/")
            parts.append("[\(keys)] shortcut\(shortcutKeys.count == 1 ? "" : "s")")
        }
        parts.append("[enter] finish")
        parts.append("[ctrl-c] stop")
        return "controls: " + parts.joined(separator: "   ")
    }

    private func readLoop() {
        var byte: UInt8 = 0
        while true {
            lock.lock(); let done = stopReading; lock.unlock()
            if done { return }
            let n = read(STDIN_FILENO, &byte, 1)
            if n <= 0 { continue }  // timeout (VTIME) or transient — keep polling
            if handleKey(byte) { return }
        }
    }

    /// Handles one key. Returns true when the reader loop should stop (finish).
    /// Extracted from `readLoop` so it is unit-testable without real stdin.
    @discardableResult
    func handleKey(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20:  // space
            let paused = control.togglePause()
            note(paused ? "paused — [space] to resume" : "resumed")
        case 0x6D, 0x4D:  // m / M
            guard hasMic else {
                note("no microphone in this capture")
                return false
            }
            let muted = control.toggleMute()
            note(muted ? "microphone muted — [m] to unmute" : "microphone unmuted")
        case 0x79, 0x59:  // y / Y
            yankTranscript()
        case 0x0A, 0x0D:  // Enter / Return
            note("finishing…")
            control.stop()
            return true
        default:
            if let key = ShortcutBinding.key(forKeypress: byte), let binding = shortcuts[key] {
                runShortcut(binding)
            }
        }
        return false
    }

    /// Runs a shortcut command on the transcript so far (PRD §6.9): the
    /// snapshot goes to the child's stdin and `$HARK_TRANSCRIPT`; its output is
    /// reported when it exits. Works while paused; a second press while the
    /// first command still runs starts another.
    private func runShortcut(_ binding: ShortcutBinding) {
        let text = transcriptLog?.text ?? ""
        guard !text.isEmpty else {
            note("nothing to pass yet")
            return
        }
        do {
            try shortcutRunner.run(binding, transcript: text) { [weak self] outcome in
                self?.report(outcome.report(for: binding))
            }
            note("\(binding.label) started")
        } catch {
            note("\(binding.label): \(error)")
        }
    }

    /// Prints a shortcut's report as one write, so concurrent notices cannot
    /// interleave inside it.
    private func report(_ lines: [String]) {
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Copies the transcript captured so far to the clipboard (PRD §6.9).
    private func yankTranscript() {
        let log = transcriptLog
        let text = log?.text ?? ""
        guard !text.isEmpty else {
            note("nothing to copy yet")
            return
        }
        if clipboard.copy(text) {
            let lines = log?.count ?? 0
            note("transcript copied to clipboard (\(lines) line\(lines == 1 ? "" : "s"))")
        } else {
            note("could not access the clipboard")
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
        shortcutRunner.cleanup()
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
