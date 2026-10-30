import Encoders
import Foundation
import TapEngine
import Testing

@testable import CLI

/// A controllable in-memory capture session: the test pushes PCM through the
/// stored `onAudio` callback and ends the run via the shared `CaptureControl`.
private final class StubSession: CaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var onAudio: (@Sendable (Data) -> Void)?

    func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        lock.lock(); self.onAudio = onAudio; lock.unlock()
    }
    func stop() {}

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return onAudio != nil }
    func emit(_ data: Data) {
        lock.lock(); let cb = onAudio; lock.unlock()
        cb?(data)
    }
}

private final class CollectingSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var finalized = false
    private var lateWrite = false
    let label = "collect"

    func write(_ data: Data) throws {
        lock.lock()
        if finalized { lateWrite = true }
        buffer.append(data)
        lock.unlock()
    }
    func finalize() throws { lock.lock(); finalized = true; lock.unlock() }
    var bytesWritten: UInt64 { lock.lock(); defer { lock.unlock() }; return UInt64(buffer.count) }
    func contains(byte: UInt8) -> Bool { lock.lock(); defer { lock.unlock() }; return buffer.contains(byte) }
    /// True once a chunk reached the sink after it was finalized — a real
    /// writer would be closed by then, so the audio is lost (or worse).
    var wroteAfterFinalize: Bool { lock.lock(); defer { lock.unlock() }; return lateWrite }
}

@Suite("Capture pause drops audio (gap)", .serialized)
struct CaptureControlIntegrationTests {
    /// Paused capture must drop chunks entirely: the paused payload never
    /// reaches the sink (a true gap, and so `--split` never opens a new chunk
    /// while paused — PRD §10 Q10), while pre/post-pause audio is kept.
    @Test func pausedAudioIsDropped() throws {
        let control = CaptureControl()
        let session = StubSession()
        let sink = CollectingSink()
        let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)
        var engine = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 1,
            captureSystem: false, apps: [], excludeApps: [], mix: false)
        engine.control = control

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, sink))
        Thread.detachNewThread {
            let (engine, session, sink) = box.value
            try? engine.run(
                session: session, format: format, into: [sink],
                duration: nil, warnOnSilence: false)
            finished.signal()
        }

        // Wait for run() to install the audio callback.
        while !session.isReady { usleep(1000) }

        session.emit(Data(repeating: 0x01, count: 320)); usleep(30_000)  // recorded
        control.pause(); usleep(10_000)
        session.emit(Data(repeating: 0x02, count: 320)); usleep(30_000)  // dropped (gap)
        control.resume(); usleep(10_000)
        session.emit(Data(repeating: 0x03, count: 320)); usleep(30_000)  // recorded

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)

        #expect(!sink.contains(byte: 0x02))  // paused audio absent
        #expect(sink.contains(byte: 0x03))   // resumed audio present
        #expect(sink.bytesWritten == 640)    // 320 + 320 kept, 320 dropped
    }
}

/// A session whose `stop()` never returns — the shape of a Core Audio teardown
/// that can't reach the audio stream (a stale "System Audio Recording" grant).
private final class WedgedStopSession: CaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var onAudio: (@Sendable (Data) -> Void)?
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        lock.lock(); self.onAudio = onAudio; lock.unlock()
    }

    func stop() {
        entered.signal()
        _ = release.wait(timeout: .now() + 30)  // freed at teardown of the test
    }

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return onAudio != nil }
    func emit(_ data: Data) {
        lock.lock(); let cb = onAudio; lock.unlock()
        cb?(data)
    }
    func unwedge() { release.signal() }
}

@Suite("Bounded capture teardown", .serialized)
struct BoundedTeardownTests {
    /// A wedged `session.stop()` must not hold the recording hostage: capture
    /// finalizes anyway, so the audio captured so far is written and playable.
    @Test func wedgedStopStillFinalizesTheRecording() throws {
        let control = CaptureControl()
        let session = WedgedStopSession()
        let sink = CollectingSink()
        let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)
        var engine = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 1,
            captureSystem: false, apps: [], excludeApps: [], mix: false)
        engine.control = control
        engine.teardownTimeout = 0.3
        defer { session.unwedge() }

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, sink))
        Thread.detachNewThread {
            let (engine, session, sink) = box.value
            try? engine.run(
                session: session, format: format, into: [sink],
                duration: nil, warnOnSilence: false)
            finished.signal()
        }
        while !session.isReady { usleep(1000) }
        session.emit(Data(repeating: 0x07, count: 320))
        usleep(30_000)
        control.stop()

        // run() returns despite stop() still being stuck, and keeps the audio.
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(session.entered.wait(timeout: .now() + 1) == .success)
        #expect(sink.bytesWritten == 320)
    }

    @Test func runBoundedReportsWhetherWorkFinished() {
        #expect(CaptureEngine.runBounded(1, label: "fast") {})
        #expect(!CaptureEngine.runBounded(0.15, label: "slow") { Thread.sleep(forTimeInterval: 1) })
        // 0 keeps the old behavior: run inline, wait as long as it takes.
        let ran = LockBox<Bool>()
        #expect(CaptureEngine.runBounded(0, label: "inline") { ran.set(true) })
        #expect(ran.get() == true)
    }
}

/// A controllable multi-track session: the test pushes the mixed stream and the
/// per-source stream independently, the way a `--mix` capture delivers both from
/// its IO thread.
private final class StubMultiTrackSession: MultiTrackCaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var onAudio: (@Sendable (Data) -> Void)?
    private var sourceHandler: (@Sendable (CaptureSource, Data) -> Void)?

    var onSourceAudio: (@Sendable (CaptureSource, Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return sourceHandler }
        set { lock.lock(); sourceHandler = newValue; lock.unlock() }
    }

    func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        lock.lock(); self.onAudio = onAudio; lock.unlock()
    }
    func stop() {}

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return onAudio != nil }

    /// Delivers one callback round in session order: the mixed stream first,
    /// then the separated source.
    func emit(mixed: Data?, source: Data?, from tag: CaptureSource = .microphone) {
        lock.lock(); let audio = onAudio; let sources = sourceHandler; lock.unlock()
        if let mixed { audio?(mixed) }
        if let source { sources?(tag, source) }
    }
}

/// A sink whose first write parks until the test releases it, holding the
/// capture's serial IO queue so the test can toggle pause while a later chunk
/// is already queued behind it.
private final class GateSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var gated = true
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    let label = "gate"

    func write(_ data: Data) throws {
        lock.lock()
        let first = gated
        gated = false
        buffer.append(data)
        lock.unlock()
        if first {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
    }
    func finalize() throws {}
    func open() { release.signal() }
    var bytesWritten: UInt64 { lock.lock(); defer { lock.unlock() }; return UInt64(buffer.count) }
    func contains(byte: UInt8) -> Bool { lock.lock(); defer { lock.unlock() }; return buffer.contains(byte) }
}

/// The separated tracks of `--speakers` are sinks like any other (today a live
/// transcriber or the offline-live temp WAVs), so they must obey the same rules
/// as the mixed stream: no writes after teardown starts, the same view of
/// pause, and the `--duration` budget.
@Suite("Per-source capture writes", .serialized)
struct PerSourceWriteTests {
    private static let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)
    /// How long a queued per-source write is given to reach its sink. Shared by
    /// the teardown test and its positive control so the two cannot disagree.
    private static let writeWindow: UInt32 = 50_000

    private func engine(control: CaptureControl) -> CaptureEngine {
        var engine = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 1,
            captureSystem: false, apps: [], excludeApps: [], mix: true)
        engine.control = control
        return engine
    }

    /// `--duration` is a budget on captured audio, so a per-source sink must be
    /// trimmed at the same limit as the mixed stream — even when its stream is
    /// chunked differently and reaches the limit first.
    @Test func perSourceSinkIsTrimmedToTheDurationBudget() throws {
        let control = CaptureControl()
        let session = StubMultiTrackSession()
        let mixedSink = CollectingSink()
        let micSink = CollectingSink()
        // 16 kHz, 16-bit mono = 32 000 B/s, so 0.03 s is a 960-byte budget.
        let engine = engine(control: control)

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, mixedSink, micSink))
        Thread.detachNewThread {
            let (engine, session, mixedSink, micSink) = box.value
            try? engine.run(
                session: session, format: Self.format, into: [mixedSink],
                duration: 0.03, warnOnSilence: false,
                sourceSinks: [(.microphone, micSink)])
            finished.signal()
        }
        while !session.isReady { usleep(1000) }

        // The mixed stream reaches 960 bytes on the third round; the mic track
        // delivers twice as fast, so its budget runs out mid-capture — well
        // before teardown, which would mask the trim by dropping the chunk.
        for _ in 0..<3 {
            session.emit(
                mixed: Data(repeating: 0x01, count: 320),
                source: Data(repeating: 0x01, count: 640))
            usleep(30_000)
        }

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)

        #expect(mixedSink.bytesWritten == 960)  // unchanged: 0.03 s exactly
        #expect(micSink.bytesWritten == 960)    // 640 + 320 trimmed, then nothing
    }

    /// Pause must be read at the same point in the pipeline for both streams:
    /// a chunk queued before the pause and written after it is dropped from the
    /// mixed stream, so it must be dropped from the per-source track too — read
    /// on the audio thread instead, the track keeps audio the recording lost.
    @Test func pausedChunkIsDroppedFromBothStreams() throws {
        let control = CaptureControl()
        let session = StubMultiTrackSession()
        let mixedSink = GateSink()
        let micSink = CollectingSink()
        let engine = engine(control: control)

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, mixedSink, micSink))
        Thread.detachNewThread {
            let (engine, session, mixedSink, micSink) = box.value
            try? engine.run(
                session: session, format: Self.format, into: [mixedSink],
                duration: nil, warnOnSilence: false,
                sourceSinks: [(.microphone, micSink)])
            finished.signal()
        }
        while !session.isReady { usleep(1000) }

        // Park the IO queue inside the first mixed write.
        session.emit(mixed: Data(repeating: 0xF0, count: 320), source: nil)
        #expect(mixedSink.entered.wait(timeout: .now() + 2) == .success)

        // This round is queued behind the parked write, and pause lands before
        // either stream gets to write it.
        session.emit(
            mixed: Data(repeating: 0x02, count: 320),
            source: Data(repeating: 0x02, count: 320))
        control.pause()
        mixedSink.open()
        usleep(30_000)

        control.resume(); usleep(10_000)
        session.emit(
            mixed: Data(repeating: 0x03, count: 320),
            source: Data(repeating: 0x03, count: 320))
        usleep(30_000)

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)

        #expect(!mixedSink.contains(byte: 0x02))  // paused: absent from the recording
        #expect(!micSink.contains(byte: 0x02))    // …and from the attributed track
        #expect(micSink.contains(byte: 0x03))     // resumed audio still flows
        #expect(micSink.bytesWritten == 320)
    }

    /// Teardown finalizes every sink, so a chunk the audio thread was still
    /// carrying must be dropped rather than written to a closed writer.
    @Test func lateSourceChunkNeverReachesAFinalizedSink() throws {
        let control = CaptureControl()
        let session = StubMultiTrackSession()
        let mixedSink = CollectingSink()
        let micSink = CollectingSink()
        let engine = engine(control: control)

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, mixedSink, micSink))
        Thread.detachNewThread {
            let (engine, session, mixedSink, micSink) = box.value
            try? engine.run(
                session: session, format: Self.format, into: [mixedSink],
                duration: nil, warnOnSilence: false,
                sourceSinks: [(.microphone, micSink)])
            finished.signal()
        }
        while !session.isReady { usleep(1000) }

        session.emit(
            mixed: Data(repeating: 0x01, count: 320),
            source: Data(repeating: 0x01, count: 320))
        usleep(30_000)

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)  // sinks finalized

        // A tap keeps running after a teardown that times out, so late chunks
        // do arrive — they must go nowhere.
        session.emit(
            mixed: Data(repeating: 0x09, count: 320),
            source: Data(repeating: 0x09, count: 320))
        usleep(Self.writeWindow)

        #expect(!micSink.wroteAfterFinalize)
        #expect(!micSink.contains(byte: 0x09))
        #expect(micSink.bytesWritten == 320)
        #expect(!mixedSink.wroteAfterFinalize)  // unchanged: already protected
    }

    /// Positive control for the test above, whose three assertions are all
    /// negative: a wait too short for a queued write to land would pass it for
    /// the wrong reason. The same emit and the same wait on a run that is still
    /// alive must reach the sink, so the window is known to be long enough.
    @Test func aSourceChunkReachesItsSinkWithinThatSameWindow() throws {
        let control = CaptureControl()
        let session = StubMultiTrackSession()
        let mixedSink = CollectingSink()
        let micSink = CollectingSink()
        let engine = engine(control: control)

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, mixedSink, micSink))
        Thread.detachNewThread {
            let (engine, session, mixedSink, micSink) = box.value
            try? engine.run(
                session: session, format: Self.format, into: [mixedSink],
                duration: nil, warnOnSilence: false,
                sourceSinks: [(.microphone, micSink)])
            finished.signal()
        }
        while !session.isReady { usleep(1000) }

        session.emit(
            mixed: Data(repeating: 0x09, count: 320),
            source: Data(repeating: 0x09, count: 320))
        usleep(Self.writeWindow)

        // Read before the stop, so this is the window alone and not teardown
        // flushing the queue on the way out.
        let arrived = micSink.contains(byte: 0x09)
        let bytes = micSink.bytesWritten

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)

        #expect(arrived, "a queued per-source write did not land within the window")
        #expect(bytes == 320)
    }
}
