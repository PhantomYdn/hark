import Encoders
import Foundation

/// Concise startup status for live capture (PRD §6.8): a short block on stderr
/// summarising the resolved configuration so a misconfiguration is caught before
/// a whole meeting is recorded. Shown when stderr is a TTY or with `-v`;
/// suppressed when stderr is redirected, and never written to stdout (so it
/// can't corrupt `-a -`/`-t -` streams).
enum StartupStatus {
    /// Builds the multi-line status text (no trailing newline). Pure — all
    /// inputs are explicit so it is straightforward to test.
    static func render(
        engine: String,
        model: String?,
        language: String,
        translate: Bool,
        source: String,
        captureBackend: String?,
        format: PCMFormat,
        audio: String?,
        transcript: String?,
        speakers: String?,
        vad: Bool,
        duration: Double?,
        split: String?
    ) -> String {
        var lines = ["hark — listening"]
        func row(_ key: String, _ value: String) {
            let padded = key.padding(toLength: 11, withPad: " ", startingAt: 0)
            lines.append("  \(padded) \(value)")
        }

        row("engine", engine + (model.map { " (\($0))" } ?? ""))
        row("language", language + (translate ? " → English" : ""))
        row("source", source + (captureBackend.map { " [\($0)]" } ?? ""))
        row("format", "\(format.sampleRate) Hz · \(format.bitsPerSample)-bit · \(format.channels) ch")
        row("audio", audio ?? "(none)")
        row("transcript", transcript ?? "(none)")
        if let speakers { row("speakers", speakers) }
        row("vad", vad ? "on" : "off")
        if let duration {
            row("duration", String(format: "%g s", duration))
        }
        if let split { row("split", split) }
        return lines.joined(separator: "\n")
    }

    /// Whether the status should be shown for the current stderr: visible when
    /// stderr is a TTY, or whenever `-v` is on. Pure for testing.
    static func shouldShow(isStderrTTY: Bool, verbose: Bool) -> Bool {
        verbose || isStderrTTY
    }

    /// Emits the status to stderr when appropriate. Never touches stdout.
    static func emit(_ text: String) {
        guard shouldShow(isStderrTTY: isatty(STDERR_FILENO) != 0, verbose: Log.isVerbose) else {
            return
        }
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
