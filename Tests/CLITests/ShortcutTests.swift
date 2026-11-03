import Foundation
import Testing

@testable import CLI

/// A runner that records what it was asked to run and lets a test complete
/// the command by hand.
final class FakeShortcutRunner: ShortcutRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var runs: [(binding: ShortcutBinding, transcript: String)] = []
    private(set) var completions: [@Sendable (ShortcutOutcome) -> Void] = []
    private(set) var cleanedUp = false
    var failure: Error?

    func run(
        _ binding: ShortcutBinding, transcript: String,
        completion: @escaping @Sendable (ShortcutOutcome) -> Void
    ) throws {
        if let failure { throw failure }
        lock.lock(); defer { lock.unlock() }
        runs.append((binding, transcript))
        completions.append(completion)
    }

    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        cleanedUp = true
    }
}

@Suite("Shortcut bindings (PRD §6.9, Feature 24)")
struct ShortcutBindingTests {
    @Test func keyIsOneLetterOrDigitStoredLowercase() throws {
        #expect(try ShortcutBinding.key(fromConfigKey: "shortcut.w") == "w")
        #expect(try ShortcutBinding.key(fromConfigKey: "shortcut.W") == "w")
        #expect(try ShortcutBinding.key(fromConfigKey: "shortcut.7") == "7")
        // Not a shortcut key at all: nil, so the typed registry gets its turn.
        #expect(try ShortcutBinding.key(fromConfigKey: "engine") == nil)
        #expect(try ShortcutBinding.key(fromConfigKey: "shortcuts") == nil)
    }

    @Test func malformedAndReservedKeysAreUsageErrors() {
        for bad in ["shortcut.summarize", "shortcut.", "shortcut.-", "shortcut.é", "shortcut.m", "shortcut.Y"] {
            #expect(throws: HarkError.self) { try ShortcutBinding.key(fromConfigKey: bad) }
        }
    }

    @Test func aBindingNeedsACommand() throws {
        let binding = try ShortcutBinding.make(configKey: "shortcut.W", command: "wc -lm")
        #expect(binding == ShortcutBinding(key: "w", command: "wc -lm"))
        #expect(binding.configKey == "shortcut.w")
        #expect(throws: HarkError.self) { try ShortcutBinding.make(configKey: "shortcut.w", command: "  ") }
        #expect(throws: HarkError.self) { try ShortcutBinding.make(configKey: "engine", command: "x") }
    }

    @Test func keypressesMatchCaseInsensitively() {
        #expect(ShortcutBinding.key(forKeypress: UInt8(ascii: "W")) == "w")
        #expect(ShortcutBinding.key(forKeypress: UInt8(ascii: "w")) == "w")
        #expect(ShortcutBinding.key(forKeypress: UInt8(ascii: "3")) == "3")
        #expect(ShortcutBinding.key(forKeypress: 0x20) == nil)
        #expect(ShortcutBinding.key(forKeypress: 0x0A) == nil)
        #expect(ShortcutBinding.key(forKeypress: 0x1B) == nil)
    }

    @Test func reportShowsOutputCappedAndAVerdict() {
        let binding = ShortcutBinding(key: "w", command: "x")
        #expect(ShortcutOutcome(status: 0, output: "\n").report(for: binding) == ["hark: shortcut.w finished"])
        #expect(ShortcutOutcome(status: 2, output: "").report(for: binding) == ["hark: shortcut.w failed (exit 2)"])
        let short = ShortcutOutcome(status: 0, output: "12 lines\n").report(for: binding)
        #expect(short == ["── shortcut.w finished ──", "12 lines", "──"])
        let long = ShortcutOutcome(
            status: 1, output: (1...250).map(String.init).joined(separator: "\n")
        ).report(for: binding)
        #expect(long.count == ShortcutOutcome.shownLines + 3)
        #expect(long.first == "── shortcut.w failed (exit 1) ──")
        #expect(long[long.count - 2] == "… 50 more lines")
    }
}

@Suite("Shortcuts in config (PRD §6.9)")
struct ShortcutConfigTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-shortcut-config-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    @Test func bindingsRoundTripBesideTypedKeys() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = Configuration()
        config.engine = "parakeet"
        config.shortcuts["w"] = "fabric-ai -p summarize"
        config.shortcuts["3"] = "wc -lm"
        try config.save(to: url)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains("\"shortcut.w\" : \"fabric-ai -p summarize\""))
        #expect(json.contains("\"shortcut.3\" : \"wc -lm\""))
        let loaded = Configuration.load(from: url)
        #expect(loaded == config)
        #expect(loaded.shortcutBindings.map(\.key) == ["3", "w"])
    }

    @Test func malformedBindingsAreSkippedOnLoad() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
            {"engine": "apple", "shortcut.W": "echo hi", "shortcut.summarize": "x",
             "shortcut.m": "x", "shortcut.q": "   ", "shortcut.k": 5}
            """
        try json.write(to: url, atomically: true, encoding: .utf8)
        let loaded = Configuration.load(from: url)
        #expect(loaded.engine == "apple")
        #expect(loaded.shortcuts == ["w": "echo hi"])
    }

    @Test func configSetRecognisesShortcutKeys() throws {
        #expect(try ConfigSet.shortcut(key: "engine", command: "apple") == nil)
        #expect(try ConfigSet.shortcut(key: "shortcut.a", command: "ls") == ShortcutBinding(key: "a", command: "ls"))
        #expect(throws: HarkError.self) { try ConfigSet.shortcut(key: "shortcut.ab", command: "ls") }
        #expect(throws: HarkError.self) { try ConfigSet.shortcut(key: "shortcut.y", command: "ls") }
        #expect(throws: HarkError.self) { try ConfigSet.shortcut(key: "shortcut.a", command: "") }
    }
}

@Suite("Shortcut keys in the interactive session (PRD §6.9)")
struct ShortcutSessionTests {
    private func session(
        log: TranscriptLog?, runner: FakeShortcutRunner, bindings: [ShortcutBinding]
    ) -> InteractiveSession {
        InteractiveSession(
            control: CaptureControl(), hasMic: true, transcriptLog: log, clipboard: FakeClipboard(),
            shortcuts: bindings, shortcutRunner: runner)
    }

    @Test func aBoundKeyRunsTheCommandOnTheTranscriptSoFar() {
        let log = TranscriptLog()
        log.append("You: hello")
        log.append("Others: world")
        let runner = FakeShortcutRunner()
        let ui = session(log: log, runner: runner, bindings: [ShortcutBinding(key: "w", command: "wc -lm")])
        #expect(!ui.handleKey(UInt8(ascii: "w")))
        #expect(runner.runs.count == 1)
        #expect(runner.runs[0].binding.command == "wc -lm")
        #expect(runner.runs[0].transcript == "You: hello\nOthers: world")
        // Case-insensitive, and re-entrant: a second press runs again.
        #expect(!ui.handleKey(UInt8(ascii: "W")))
        #expect(runner.runs.count == 2)
        // Completing the first command must not crash or re-run anything.
        runner.completions[0](ShortcutOutcome(status: 0, output: "2 lines"))
        #expect(runner.runs.count == 2)
    }

    @Test func unboundKeysAndEmptyLogsDoNotSpawn() {
        let runner = FakeShortcutRunner()
        let ui = session(log: TranscriptLog(), runner: runner, bindings: [ShortcutBinding(key: "w", command: "x")])
        #expect(!ui.handleKey(UInt8(ascii: "q")))  // unbound
        #expect(!ui.handleKey(UInt8(ascii: "w")))  // bound, but nothing to pass yet
        #expect(runner.runs.isEmpty)
        let none = session(log: nil, runner: runner, bindings: [ShortcutBinding(key: "w", command: "x")])
        #expect(!none.handleKey(UInt8(ascii: "w")))
        #expect(runner.runs.isEmpty)
    }

    @Test func builtInKeysWinAndStopCleansUp() {
        let log = TranscriptLog()
        log.append("x")
        let runner = FakeShortcutRunner()
        // `m` and `y` cannot be bound by config; even if a binding sneaks in,
        // the built-in control takes the key.
        let ui = session(log: log, runner: runner, bindings: [ShortcutBinding(key: "y", command: "x")])
        #expect(!ui.handleKey(UInt8(ascii: "y")))
        #expect(runner.runs.isEmpty)
        ui.stop()
        #expect(runner.cleanedUp)
    }

    @Test func hintListsBoundKeys() {
        #expect(InteractiveSession.controlsHint(hasMic: false, shortcutKeys: ["w"]).contains("[w] shortcut   "))
        #expect(InteractiveSession.controlsHint(hasMic: true, shortcutKeys: ["a", "w"]).contains("[a/w] shortcuts"))
        #expect(!InteractiveSession.controlsHint(hasMic: true).contains("shortcut"))
    }
}

@Suite("Shortcut process runner (PRD §6.9)")
struct ShortcutProcessRunnerTests {
    /// Runs a real `/bin/sh` command: the transcript arrives on stdin and at
    /// `$HARK_TRANSCRIPT`, output and status come back, the snapshot outlives
    /// the command until cleanup.
    @Test func feedsStdinAndPathAndCollectsOutput() async throws {
        let runner = ProcessShortcutRunner()
        let binding = ShortcutBinding(
            key: "t", command: "wc -l | tr -d ' '; cat \"$HARK_TRANSCRIPT\"; echo \"$HARK_TRANSCRIPT\"; exit 3")
        let outcome: ShortcutOutcome = try await withCheckedThrowingContinuation { continuation in
            do {
                try runner.run(binding, transcript: "one\ntwo") { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(outcome.status == 3)
        let lines = outcome.output.split(separator: "\n").map(String.init)
        #expect(lines.prefix(3) == ["2", "one", "two"])
        let path = try #require(lines.last)
        #expect(path.contains("hark-shortcuts-"))
        #expect(FileManager.default.fileExists(atPath: path))
        runner.cleanup()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aCommandThatEchoesALongTranscriptDoesNotDeadlock() async throws {
        let runner = ProcessShortcutRunner()
        defer { runner.cleanup() }
        let big = String(repeating: "a line of transcript text\n", count: 20_000)  // ~500 KB each way
        let outcome: ShortcutOutcome = try await withCheckedThrowingContinuation { continuation in
            try? runner.run(ShortcutBinding(key: "c", command: "cat"), transcript: big) {
                continuation.resume(returning: $0)
            }
        }
        #expect(outcome.status == 0)
        #expect(outcome.output.count == big.count)
    }

    @Test func aCommandThatIgnoresStdinStillFinishes() async throws {
        let runner = ProcessShortcutRunner()
        defer { runner.cleanup() }
        let big = String(repeating: "a line of transcript text\n", count: 20_000)  // ~500 KB, past a pipe buffer
        let outcome: ShortcutOutcome = try await withCheckedThrowingContinuation { continuation in
            try? runner.run(ShortcutBinding(key: "n", command: "echo done"), transcript: big) {
                continuation.resume(returning: $0)
            }
        }
        #expect(outcome == ShortcutOutcome(status: 0, output: "done\n"))
    }
}
