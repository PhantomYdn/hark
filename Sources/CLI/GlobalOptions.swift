import ArgumentParser
import Foundation

/// Options shared by every subcommand.
struct GlobalOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "Log diagnostic details to stderr.")
    var verbose = false
}

/// Stderr logging (PRD §7 Auditability: paths/durations logged when -v is on).
enum Log {
    nonisolated(unsafe) static var isVerbose = false

    /// Diagnostic output, shown only with `--verbose`.
    static func verbose(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        TranscribeProgressLine.writeStderr("hark: \(message())\n")
    }

    /// Error output, always shown.
    static func error(_ message: String) {
        TranscribeProgressLine.writeStderr("hark: error: \(message)\n")
    }

    /// Notice output, always shown (no error prefix).
    static func notice(_ message: String) {
        TranscribeProgressLine.writeStderr("hark: \(message)\n")
    }
}

extension ParsableCommand {
    /// Runs `body`, mapping thrown `HarkError`s to stderr output + exit code.
    func runMapped(verbose: Bool, _ body: () throws -> Void) throws {
        Log.isVerbose = verbose
        do {
            try body()
        } catch let error as HarkError {
            Log.error(error.message)
            throw error.code.exitCode
        }
    }
}
