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
        var line = "hark: transcribing \(percentAndBar(clamped, barWidth: barWidth))"
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

    /// `42% [########............]` for a fraction already clamped to 0...1.
    static func percentAndBar(_ fraction: Double, barWidth: Int = 20) -> String {
        let filled = Int((fraction * Double(barWidth)).rounded())
        let bar = String(repeating: "#", count: filled)
            + String(repeating: ".", count: barWidth - filled)
        return "\(Int((fraction * 100).rounded()))% [\(bar)]"
    }

    /// "m:ss" up to an hour, then "h:mm:ss". Pure, for testing.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// One redrawn line on stderr: the shared mechanics under the transcription
/// and model-download progress lines. `content` is asked for the text four
/// times a second on the line's own queue (so it draws whether or not the
/// caller pumps a run loop); returning nil erases the line until there is
/// something to show again.
///
/// One line is active per process at a time, because stderr is one terminal
/// line: other stderr writers (`Log`, a child engine's own messages) go
/// through `write`, which erases the drawn line first.
final class StderrStatusLine: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var current: StderrStatusLine?
    private static let queue = DispatchQueue(label: "hark.stderr-status-line")

    private let lock = NSLock()
    private let content: @Sendable () -> String?
    private var lastLineLength = 0
    private var timer: DispatchSourceTimer?

    private init(content: @escaping @Sendable () -> String?) {
        self.content = content
    }

    /// Opens the line. Returns nil (and nothing is ever drawn) when stderr is
    /// not a TTY or another line is already active.
    static func begin(
        isStderrTTY: Bool = isatty(STDERR_FILENO) != 0,
        content: @escaping @Sendable () -> String?
    ) -> StderrStatusLine? {
        guard TranscribeProgress.shouldShow(isStderrTTY: isStderrTTY) else { return nil }
        registryLock.lock()
        defer { registryLock.unlock() }
        guard current == nil else { return nil }
        let line = StderrStatusLine(content: content)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak line] in line?.redraw() }
        line.timer = timer
        current = line
        timer.resume()
        return line
    }

    /// Writes to stderr, erasing the drawn line first so the text starts on a
    /// clean line; the next redraw puts the line back underneath.
    static func write(_ text: String) {
        registryLock.lock()
        let line = current
        registryLock.unlock()
        guard let line else {
            FileHandle.standardError.write(Data(text.utf8))
            return
        }
        line.lock.lock()
        defer { line.lock.unlock() }
        line.eraseLocked()
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Erases the line, stops redrawing and frees the slot for the next one.
    func finish() {
        lock.lock()
        timer?.cancel()
        timer = nil
        eraseLocked()
        lock.unlock()
        Self.registryLock.lock()
        if Self.current === self { Self.current = nil }
        Self.registryLock.unlock()
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
        guard timer != nil else { return }
        guard let line = content() else {
            eraseLocked()
            return
        }
        let padded = line.padding(
            toLength: max(line.count, lastLineLength), withPad: " ", startingAt: 0)
        lastLineLength = padded.count
        FileHandle.standardError.write(Data("\r\(padded)".utf8))
    }
}

/// The stderr progress line of one batch transcription run. The run opens it
/// with `begin` and closes it with `finish`; in between, every whole-file
/// engine call made through `TranscribeProgressLine.transcribe` is one pass
/// that feeds it. The fraction is updated from the engine's callback thread.
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
    private var status: StderrStatusLine?

    private init(passes: Int) {
        self.passes = max(passes, 1)
    }

    /// Opens the line for a run that transcribes its audio in `passes`
    /// whole-file engine calls. Returns nil (and nothing is ever drawn) when
    /// stderr is not a TTY or another line is already active.
    static func begin(
        passes: Int = 1, isStderrTTY: Bool = isatty(STDERR_FILENO) != 0
    ) -> TranscribeProgressLine? {
        let line = TranscribeProgressLine(passes: passes)
        guard
            let status = StderrStatusLine.begin(
                isStderrTTY: isStderrTTY, content: { [weak line] in line?.text() })
        else { return nil }
        line.status = status
        registryLock.lock()
        current = line
        registryLock.unlock()
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
    }

    /// Erases the line and frees the slot for the next run.
    func finish() {
        status?.finish()
        Self.registryLock.lock()
        if Self.current === self { Self.current = nil }
        Self.registryLock.unlock()
    }

    /// The line to draw now, or nil before the first pass, during the start
    /// delay, and once every pass is done.
    private func text() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt, completedPasses < passes else { return nil }
        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= TranscribeProgress.startDelay else { return nil }
        return TranscribeProgress.render(
            fraction: TranscribeProgress.overall(
                completedPasses: completedPasses, passes: passes, passFraction: passFraction),
            elapsed: elapsed,
            // The position in the audio only reads right for a single pass.
            audioSeconds: passes == 1 ? audioSeconds : nil,
            sinceUpdate: updatedAt.map { now.timeIntervalSince($0) } ?? 0,
            baseline: baseline.map { ($0.fraction, $0.at.timeIntervalSince(startedAt)) } ?? (0, 0))
    }
}

/// Progress of a model download: a name, a percent and bar, the bytes when
/// the source reports them, and a linear ETA.
enum ModelDownloadProgress {
    /// Builds one redrawn line. `fraction` nil means the size is not known
    /// yet, so only the elapsed time is. Pure, for testing.
    static func render(
        name: String, fraction: Double?, receivedBytes: Int64? = nil, totalBytes: Int64? = nil,
        elapsed: TimeInterval, barWidth: Int = 20
    ) -> String {
        guard let fraction, fraction.isFinite else {
            return "hark: downloading \(name)… \(TranscribeProgress.formatDuration(elapsed)) elapsed"
        }
        let clamped = min(max(fraction, 0), 1)
        var line =
            "hark: downloading \(name) "
            + TranscribeProgress.percentAndBar(clamped, barWidth: barWidth)
        if let receivedBytes, let totalBytes, totalBytes > 0 {
            line += " \(formatBytes(receivedBytes)) / \(formatBytes(totalBytes))"
        }
        if clamped >= TranscribeProgress.etaMinFraction {
            let eta = elapsed * (1 - clamped) / clamped
            line += " eta \(TranscribeProgress.formatDuration(eta))"
        }
        return line
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The stderr progress line of one model download. Like the transcription
/// line it is drawn only on a terminal; without one `begin` returns nil and
/// the download's one-line notice is all there is.
final class ModelDownloadLine: @unchecked Sendable {
    private let lock = NSLock()
    private let name: String
    private let startedAt = Date()
    private var fraction: Double?
    private var receivedBytes: Int64?
    private var totalBytes: Int64?
    private var status: StderrStatusLine?

    private init(name: String) {
        self.name = name
    }

    static func begin(
        name: String, isStderrTTY: Bool = isatty(STDERR_FILENO) != 0
    ) -> ModelDownloadLine? {
        let line = ModelDownloadLine(name: name)
        guard
            let status = StderrStatusLine.begin(
                isStderrTTY: isStderrTTY, content: { [weak line] in line?.text() })
        else { return nil }
        line.status = status
        return line
    }

    /// Called from the downloader's callback thread. Never moves backwards.
    func update(fraction: Double, receivedBytes: Int64? = nil, totalBytes: Int64? = nil) {
        guard fraction.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        self.fraction = max(self.fraction ?? 0, min(max(fraction, 0), 1))
        if let receivedBytes { self.receivedBytes = receivedBytes }
        if let totalBytes, totalBytes > 0 { self.totalBytes = totalBytes }
    }

    func finish() {
        status?.finish()
    }

    private func text() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= TranscribeProgress.startDelay else { return nil }
        return ModelDownloadProgress.render(
            name: name, fraction: fraction, receivedBytes: receivedBytes, totalBytes: totalBytes,
            elapsed: elapsed)
    }
}
