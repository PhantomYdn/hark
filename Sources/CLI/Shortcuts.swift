import Darwin
import Foundation

/// A user-defined interactive shortcut (PRD §6.9, Feature 24): one key that
/// runs a shell command against the transcript captured so far. Bindings are
/// scalar config keys `shortcut.<k>` in `~/.hark/config.json`, outside the
/// typed `ConfigKey` registry (no flag, no `$HARK_*` counterpart).
struct ShortcutBinding: Equatable, Sendable {
    /// One lowercase ASCII letter or digit.
    let key: Character
    let command: String

    static let prefix = "shortcut."
    /// Built-in controls that cannot be rebound. Space and Enter are not
    /// representable as `shortcut.<k>` in the first place.
    static let reserved: Set<Character> = ["m", "y"]

    var configKey: String { Self.prefix + String(key) }
    /// The name used in notices: `shortcut.w`.
    var label: String { configKey }

    /// The shortcut key named by a config key such as `shortcut.w`, lowercased.
    /// Nil when `name` is not a shortcut key at all; a usage error when it is
    /// one but malformed (multi-character suffix, not a letter or digit, or a
    /// reserved control).
    static func key(fromConfigKey name: String) throws -> Character? {
        guard name.lowercased().hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count).lowercased()
        guard suffix.count == 1, let key = suffix.first, key.isASCII, key.isLetter || key.isNumber else {
            throw HarkError.usage(
                "shortcut key must be a single letter or digit, as in shortcut.w (got '\(name)').")
        }
        guard !reserved.contains(key) else {
            throw HarkError.usage(
                "'\(key)' is a built-in control (m = mute, y = yank) and cannot be rebound.")
        }
        return key
    }

    /// Validates a binding being stored: the key as above, the command non-blank.
    static func make(configKey name: String, command: String) throws -> ShortcutBinding {
        guard let key = try key(fromConfigKey: name) else {
            throw HarkError.usage("'\(name)' is not a shortcut key (expected shortcut.<letter or digit>).")
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HarkError.usage("shortcut \(name) needs a command to run.")
        }
        return ShortcutBinding(key: key, command: command)
    }

    /// The key a keypress selects: letters match case-insensitively, like `m`/`M`.
    static func key(forKeypress byte: UInt8) -> Character? {
        let scalar = Unicode.Scalar(byte)
        let character = Character(scalar)
        guard character.isASCII, character.isLetter || character.isNumber else { return nil }
        return Character(character.lowercased())
    }
}

/// What a shortcut command produced once it finished.
struct ShortcutOutcome: Equatable, Sendable {
    let status: Int32
    /// The command's combined stdout and stderr.
    let output: String
}

/// Launches shortcut commands. Abstracted so `InteractiveSession` is testable
/// without spawning processes.
protocol ShortcutRunner: AnyObject, Sendable {
    /// Runs `binding.command` on a snapshot of `transcript` without waiting for
    /// it; `completion` is called once, from a background thread, when the
    /// command exits.
    func run(
        _ binding: ShortcutBinding, transcript: String,
        completion: @escaping @Sendable (ShortcutOutcome) -> Void
    ) throws
    /// Removes the snapshot files. Commands still running keep running.
    func cleanup()
}

/// The real runner: writes the transcript snapshot to a per-session temp
/// directory, spawns `/bin/sh -c <command>` with the snapshot on the child's
/// stdin and its path in `$HARK_TRANSCRIPT`, and collects the child's stdout
/// and stderr until it exits. The child never sees the terminal, so it cannot
/// steal keys from the interactive reader or interleave with the captions.
///
/// The snapshots live until `cleanup()` (end of the interactive session),
/// not until the command exits: a command may hand the path to something that
/// outlives it, such as a `tmux split-window` pane.
final class ProcessShortcutRunner: ShortcutRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL?
    private var serial = 0

    init() {
        // A command that closes its stdin early must surface as a write error,
        // not kill hark.
        signal(SIGPIPE, SIG_IGN)
    }

    func run(
        _ binding: ShortcutBinding, transcript: String,
        completion: @escaping @Sendable (ShortcutOutcome) -> Void
    ) throws {
        let snapshot = try snapshotURL(for: binding)
        let text = transcript.hasSuffix("\n") ? transcript : transcript + "\n"
        do {
            try text.write(to: snapshot, atomically: true, encoding: .utf8)
        } catch {
            throw HarkError.ioError("cannot write the transcript snapshot for \(binding.label): \(error)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", binding.command]
        var environment = ProcessInfo.processInfo.environment
        environment["HARK_TRANSCRIPT"] = snapshot.path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw HarkError.ioError("cannot launch \(binding.label): \(error)")
        }

        // Feed stdin on its own thread while another drains the output: a
        // command that echoes a long transcript back would otherwise fill its
        // stdout pipe while hark is still blocked writing its stdin. A command
        // that never reads stdin just sees the pipe close (EPIPE here, ignored).
        let payload = Data(text.utf8)
        let writer = Thread {
            try? input.fileHandleForWriting.write(contentsOf: payload)
            try? input.fileHandleForWriting.close()
        }
        writer.name = "hark.shortcut.\(binding.key).stdin"
        let reader = Thread {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            completion(ShortcutOutcome(
                status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
        }
        reader.name = "hark.shortcut.\(binding.key)"
        writer.start()
        reader.start()
    }

    func cleanup() {
        lock.lock()
        let directory = self.directory
        self.directory = nil
        lock.unlock()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func snapshotURL(for binding: ShortcutBinding) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if directory == nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "hark-shortcuts-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw HarkError.ioError("cannot create the shortcut snapshot directory: \(error)")
            }
            directory = url
        }
        serial += 1
        return directory!.appendingPathComponent("transcript-\(binding.key)-\(serial).txt")
    }
}

extension ShortcutOutcome {
    /// At most this many lines of a command's output are shown on screen.
    static let shownLines = 200

    /// The notice lines printed when a shortcut command finishes: a header
    /// with the exit status, the output (capped), and a rule; or one line when
    /// there was no output.
    func report(for binding: ShortcutBinding) -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict = status == 0 ? "finished" : "failed (exit \(status))"
        guard !trimmed.isEmpty else { return ["hark: \(binding.label) \(verdict)"] }
        var lines = trimmed.components(separatedBy: "\n")
        var report = ["── \(binding.label) \(verdict) ──"]
        if lines.count > Self.shownLines {
            let hidden = lines.count - Self.shownLines
            lines = Array(lines.prefix(Self.shownLines))
            lines.append("… \(hidden) more line\(hidden == 1 ? "" : "s")")
        }
        report.append(contentsOf: lines)
        report.append("──")
        return report
    }
}
