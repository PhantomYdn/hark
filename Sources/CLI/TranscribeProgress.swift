import Foundation

/// Progress feedback for batch transcription (issue #13): a single redrawn
/// stderr line with percent complete and a linear ETA, fed by the engine's
/// fraction-complete updates (whisperkit). Follows the StartupStatus
/// conventions: stderr only, shown only when stderr is a TTY, stdout never
/// touched. No flag: a redirected stderr (a log, `2>file`) never sees a
/// redrawn line, so a TTY is the whole gate.
enum TranscribeProgress {
    /// The linear ETA is extrapolated from elapsed time and fraction; below
    /// this fraction the estimate swings wildly, so it stays hidden.
    static let etaMinFraction = 0.05

    /// Whether the progress line should draw for the current stderr. Pure.
    static func shouldShow(isStderrTTY: Bool) -> Bool {
        isStderrTTY
    }

    /// Builds one redrawn line (no carriage return or newline; the writer
    /// pads to erase earlier wider lines). Pure, for testing.
    static func render(fraction: Double, elapsed: TimeInterval, barWidth: Int = 20) -> String {
        // `max(NaN, 0)` is NaN in Swift (NaN comparisons are false), so a
        // non-finite fraction is rejected up front rather than clamped.
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        let filled = Int((clamped * Double(barWidth)).rounded())
        let bar = String(repeating: "#", count: filled)
            + String(repeating: ".", count: barWidth - filled)
        var line = "hark: transcribing \(Int((clamped * 100).rounded()))% [\(bar)]"
        if clamped >= etaMinFraction {
            let eta = elapsed * (1 - clamped) / clamped
            line += " eta \(formatDuration(eta))"
        }
        return line
    }

    /// "m:ss" up to an hour, then "h:mm:ss". Pure, for testing.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Draws and erases the stderr progress line. The fraction is updated from the
/// engine's callback thread (locked, like LockBox); drawing happens on a timer
/// on the run loop that RunLoopBridge pumps while the engine call blocks.
final class TranscribeProgressLine: @unchecked Sendable {
    private let lock = NSLock()
    private var fraction: Double = 0
    private var lastLineLength = 0
    private var timer: Timer?
    private let startedAt = Date()

    /// Begins redrawing on the current run loop. No-op when stderr is not a
    /// TTY, so update/finish are no-ops too.
    func start() {
        guard TranscribeProgress.shouldShow(isStderrTTY: isatty(STDERR_FILENO) != 0) else {
            return
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.redraw()
        }
        RunLoop.current.add(timer, forMode: .default)
        self.timer = timer
    }

    /// Called from the engine's callback thread with the latest 0...1 fraction.
    func update(fraction: Double) {
        lock.lock()
        self.fraction = fraction
        lock.unlock()
    }

    /// Erases the line and stops the timer. Called on the run-loop thread.
    func finish() {
        lock.lock()
        timer?.invalidate()
        timer = nil
        let blank = String(repeating: " ", count: lastLineLength)
        lock.unlock()
        if !blank.isEmpty {
            FileHandle.standardError.write(Data("\r\(blank)\r".utf8))
        }
    }

    private func redraw() {
        lock.lock()
        let line = TranscribeProgress.render(
            fraction: fraction, elapsed: Date().timeIntervalSince(startedAt))
        let padded = line.padding(
            toLength: max(line.count, lastLineLength), withPad: " ", startingAt: 0)
        lastLineLength = padded.count
        lock.unlock()
        FileHandle.standardError.write(Data("\r\(padded)".utf8))
    }
}
