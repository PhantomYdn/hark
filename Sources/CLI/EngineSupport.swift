import Foundation

/// Minimal thread-safe one-shot holder for bridging callbacks / async results
/// to the synchronous CLI flow. The first value set wins.
final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func set(_ newValue: T) {
        lock.lock()
        defer { lock.unlock() }
        if value == nil { value = newValue }
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Bridges callback- and `async`-based engine SDKs (Speech, WhisperKit,
/// FluidAudio) into Hark's synchronous command flow without deadlocking the
/// main thread: it spins the current run loop while waiting, so work delivered
/// on the main queue (or main actor) still runs.
enum RunLoopBridge {
    /// Spins the current run loop until `until()` is true or `timeout` elapses.
    @discardableResult
    static func waitPumping(timeout: TimeInterval, until: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !until() {
            if Date() >= deadline { return false }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// Runs an `async` operation to completion synchronously, returning its
    /// result or rethrowing its error. Throws on timeout.
    static func runBlocking<T: Sendable>(
        timeout: TimeInterval = 1800,
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = LockBox<Result<T, Error>>()
        Task {
            do { box.set(.success(try await operation())) } catch { box.set(.failure(error)) }
        }
        guard waitPumping(timeout: timeout, until: { box.get() != nil }) else {
            throw HarkError.software("engine operation timed out after \(Int(timeout))s.")
        }
        return try box.get()!.get()
    }
}

/// Wraps a non-`Sendable` value so it can cross a concurrency boundary when the
/// caller guarantees single-consumer use (created and awaited on one flow). Used
/// to hand a resident engine instance into `runBlocking`'s `Task`.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// One transcript segment with timing, used to render srt/json from an engine
/// that returns timestamped segments (whisperkit, parakeet). `speaker` is an
/// optional label (e.g. "You", "Speaker 1") attached by the speaker pipeline
/// (PRD §6.7); nil leaves output identical to the no-speaker case.
struct TranscriptCue {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?

    init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// Renders a whole-file transcript in the requested format from an engine's
/// joined text plus timed cues. Shared by the CoreML batch backends.
enum TranscriptFormatting {
    static func render(
        cues: [TranscriptCue], fullText: String, format: TranscriptOutputFormat
    ) -> String {
        switch format {
        case .txt:
            // Plain text carries speakers as line prefixes only when present;
            // otherwise the engine's joined text is returned unchanged.
            if cues.contains(where: { $0.speaker != nil }) {
                let lines = cues.map { cue -> String in
                    let body = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return cue.speaker.map { "\($0): \(body)" } ?? body
                }
                return lines.joined(separator: "\n") + "\n"
            }
            return fullText.hasSuffix("\n") ? fullText : fullText + "\n"
        case .srt:
            var out = ""
            for (index, cue) in cues.enumerated() {
                out += "\(index + 1)\n"
                out += "\(LiveTranscriptWriter.srtTimestamp(cue.start)) --> "
                out += "\(LiveTranscriptWriter.srtTimestamp(cue.end))\n"
                let body = cue.text.trimmingCharacters(in: .whitespaces)
                out += (cue.speaker.map { "[\($0)] \(body)" } ?? body) + "\n\n"
            }
            return out
        case .json:
            // `speaker` is optional: nil omits the key (synthesized
            // encodeIfPresent), keeping default output byte-identical.
            struct Segment: Encodable {
                let start: Double
                let end: Double
                let text: String
                let speaker: String?
            }
            let segments = cues.map {
                Segment(
                    start: $0.start, end: $0.end,
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    speaker: $0.speaker)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(segments) else { return "[]\n" }
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    }
}

/// Architecture gating for CoreML/ANE engines (whisperkit, parakeet) that are
/// Apple-Silicon-first.
enum Platform {
    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Throws an actionable error when running on Intel.
    static func requireAppleSilicon(engine: String) throws {
        guard isAppleSilicon else {
            throw HarkError.unavailable(
                "the '\(engine)' engine is Apple-Silicon-only; use --engine whisper or apple "
                    + "on an Intel Mac.")
        }
    }
}
