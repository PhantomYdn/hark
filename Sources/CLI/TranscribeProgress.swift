import Foundation

/// Progress feedback for batch transcription (issue #13): a single redrawn
/// stderr line with percent complete and a linear ETA, fed by the engine's
/// own position in the file. Follows the StartupStatus conventions: stderr
/// only, shown only when stderr is a TTY, stdout never touched. No flag: a
/// redirected stderr (a log, `2>file`) never sees a redrawn line, so a TTY is
/// the whole gate.
enum TranscribeProgress {
    /// The linear ETA is extrapolated from elapsed time and fraction; below
    /// this fraction the estimate swings wildly, so it stays hidden.
    static let etaMinFraction = 0.05

    /// Nothing is drawn before this much time has passed, so a clip that
    /// transcribes in a moment never flashes a line.
    static let startDelay: TimeInterval = 1.5

    /// Whether the progress line should draw for the current stderr. Pure.
    static func shouldShow(isStderrTTY: Bool) -> Bool {
        isStderrTTY
    }

    /// Builds one redrawn line (no carriage return or newline; the writer
    /// pads to erase earlier wider lines). `fraction` nil means the engine has
    /// not reported a position yet (or never does), so only the elapsed time
    /// is known. `audioSeconds`, when given, adds the position in the audio.
    /// `sinceUpdate` is how long ago `fraction` was reported: engines report in
    /// steps, so the ETA is taken at the step and then counted down by the
    /// clock rather than drifting up until the next one. `baseline` is the
    /// first position the engine reported and when: speed is measured from
    /// there, so the model load and warm-up before it do not inflate the ETA.
    /// Pure, for testing.
    static func render(
        fraction: Double?, elapsed: TimeInterval, audioSeconds: Double? = nil,
        sinceUpdate: TimeInterval = 0,
        baseline: (fraction: Double, elapsed: TimeInterval) = (0, 0), barWidth: Int = 20
    ) -> String {
        guard let fraction else {
            var line = "hark: transcribing… \(formatDuration(elapsed)) elapsed"
            if let audioSeconds, audioSeconds > 0 {
                line += " (\(formatDuration(audioSeconds)) of audio)"
            }
            return line
        }
        // `max(NaN, 0)` is NaN in Swift (NaN comparisons are false), so a
        // non-finite fraction is rejected up front rather than clamped.
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        let filled = Int((clamped * Double(barWidth)).rounded())
        let bar = String(repeating: "#", count: filled)
            + String(repeating: ".", count: barWidth - filled)
        var line = "hark: transcribing \(Int((clamped * 100).rounded()))% [\(bar)]"
        if let audioSeconds, audioSeconds > 0 {
            line += " \(formatDuration(clamped * audioSeconds)) / \(formatDuration(audioSeconds))"
        }
        let covered = clamped - baseline.fraction
        if covered >= etaMinFraction {
            let age = min(max(sinceUpdate, 0), elapsed)
            let measured = max(elapsed - age - baseline.elapsed, 0)
            let eta = measured * (1 - clamped) / covered - age
            line += " eta \(formatDuration(eta))"
        }
        return line
    }

    /// Fraction of the whole run, when it transcribes the audio in several
    /// passes (one per channel, one per recorded track). Nil until the engine
    /// has reported a position at least once. Pure, for testing.
    static func overall(completedPasses: Int, passes: Int, passFraction: Double?) -> Double? {
        guard completedPasses > 0 || passFraction != nil else { return nil }
        let total = Double(max(passes, 1))
        let current = passFraction.map { $0.isFinite ? min(max($0, 0), 1) : 0 } ?? 0
        return min((Double(completedPasses) + current) / total, 1)
    }

    /// "m:ss" up to an hour, then "h:mm:ss". Pure, for testing.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Draws and erases the stderr progress line for one batch run. The run opens
/// it with `begin` and closes it with `finish`; in between, every whole-file
/// engine call made through `TranscribeProgressLine.transcribe` is one pass
/// that feeds it. The fraction is updated from the engine's callback thread;
/// drawing happens on a timer on the run loop that RunLoopBridge (and
/// `Process.waitUntilExit`) pump while the engine call blocks.
///
/// One line is active per process at a time, because stderr is one terminal
/// line: other stderr writers (`Log`, a child engine's own messages) go
/// through `writeStderr`, which erases the drawn line first.
final class TranscribeProgressLine: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var current: TranscribeProgressLine?

    /// The line of the batch run in flight, if it draws one.
    static var active: TranscribeProgressLine? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return current
    }

    private let lock = NSLock()
    private let passes: Int
    private var completedPasses = 0
    private var passFraction: Double?
    private var updatedAt: Date?
    private var baseline: (fraction: Double, at: Date)?
    private var audioSeconds: Double?
    private var startedAt: Date?
    private var lastLineLength = 0
    private var timer: Timer?

    private init(passes: Int) {
        self.passes = max(passes, 1)
    }

    /// Opens the line for a run that transcribes its audio in `passes`
    /// whole-file engine calls. Returns nil (and nothing is ever drawn) when
    /// stderr is not a TTY or another line is already active. Call on the
    /// thread whose run loop is pumped during the engine call.
    static func begin(
        passes: Int = 1, isStderrTTY: Bool = isatty(STDERR_FILENO) != 0
    ) -> TranscribeProgressLine? {
        guard TranscribeProgress.shouldShow(isStderrTTY: isStderrTTY) else { return nil }
        registryLock.lock()
        defer { registryLock.unlock() }
        guard current == nil else { return nil }
        let line = TranscribeProgressLine(passes: passes)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak line] _ in
            line?.redraw()
        }
        RunLoop.current.add(timer, forMode: .default)
        line.timer = timer
        current = line
        return line
    }

    /// One whole-file engine call. With an active line it is one pass of the
    /// run and reports its position; without one it is the plain call, so a
    /// redirected stderr leaves every engine exactly as it was.
    static func transcribe(
        _ backend: TranscriptionBackend, wavFile: URL, language: String?, translate: Bool,
        format: TranscriptOutputFormat
    ) throws -> String {
        guard let line = active else {
            return try backend.transcribe(
                wavFile: wavFile, language: language, translate: translate, format: format)
        }
        line.beginPass(audioSeconds: AudioPipeline.durationSeconds(of: wavFile))
        defer { line.endPass() }
        return try backend.transcribe(
            wavFile: wavFile, language: language, translate: translate, format: format,
            progress: { line.update(fraction: $0) })
    }

    /// Writes to stderr, erasing the drawn line first so the text starts on a
    /// clean line; the next redraw puts the progress back underneath.
    static func writeStderr(_ text: String) {
        guard let line = active else {
            FileHandle.standardError.write(Data(text.utf8))
            return
        }
        line.lock.lock()
        defer { line.lock.unlock() }
        line.eraseLocked()
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Starts a pass over `audioSeconds` of audio. The clock starts with the
    /// first pass, after the model has loaded.
    func beginPass(audioSeconds: Double?) {
        lock.lock()
        defer { lock.unlock() }
        if startedAt == nil { startedAt = Date() }
        passFraction = nil
        self.audioSeconds = audioSeconds
    }

    /// Called from the engine's callback thread with the latest 0...1 position
    /// in the current pass. Never moves backwards within a pass.
    func update(fraction: Double) {
        guard fraction.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        let next = max(passFraction ?? 0, min(max(fraction, 0), 1))
        guard next != passFraction else { return }
        let now = Date()
        passFraction = next
        updatedAt = now
        if baseline == nil,
            let overall = TranscribeProgress.overall(
                completedPasses: completedPasses, passes: passes, passFraction: next)
        {
            baseline = (overall, now)
        }
    }

    /// Ends the current pass. After the last one the line is erased, so
    /// whatever the run does next (speaker labeling) is not shown as stuck.
    func endPass() {
        lock.lock()
        defer { lock.unlock() }
        completedPasses += 1
        passFraction = nil
        updatedAt = Date()
        if completedPasses >= passes { stopLocked() }
    }

    /// Erases the line, stops the timer and frees the slot for the next run.
    /// Call on the thread that called `begin`.
    func finish() {
        lock.lock()
        stopLocked()
        lock.unlock()
        Self.registryLock.lock()
        if Self.current === self { Self.current = nil }
        Self.registryLock.unlock()
    }

    private func stopLocked() {
        timer?.invalidate()
        timer = nil
        eraseLocked()
    }

    private func eraseLocked() {
        guard lastLineLength > 0 else { return }
        let blank = String(repeating: " ", count: lastLineLength)
        FileHandle.standardError.write(Data("\r\(blank)\r".utf8))
        lastLineLength = 0
    }

    private func redraw() {
        lock.lock()
        defer { lock.unlock() }
        guard timer != nil, let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= TranscribeProgress.startDelay else { return }
        let line = TranscribeProgress.render(
            fraction: TranscribeProgress.overall(
                completedPasses: completedPasses, passes: passes, passFraction: passFraction),
            elapsed: elapsed,
            // The position in the audio only reads right for a single pass.
            audioSeconds: passes == 1 ? audioSeconds : nil,
            sinceUpdate: updatedAt.map { Date().timeIntervalSince($0) } ?? 0,
            baseline: baseline.map { ($0.fraction, $0.at.timeIntervalSince(startedAt)) } ?? (0, 0))
        let padded = line.padding(
            toLength: max(line.count, lastLineLength), withPad: " ", startingAt: 0)
        lastLineLength = padded.count
        FileHandle.standardError.write(Data("\r\(padded)".utf8))
    }
}
