import Encoders
import Foundation
import TapEngine
import Testing

@testable import CLI

/// A sink that keeps everything written to it, and notices a double finalize.
private final class CollectingSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var finalizeCount = 0
    let label: String

    init(label: String = "collect") { self.label = label }

    func write(_ data: Data) throws { lock.lock(); buffer.append(data); lock.unlock() }
    func finalize() throws { lock.lock(); finalizeCount += 1; lock.unlock() }
    var bytesWritten: UInt64 { lock.lock(); defer { lock.unlock() }; return UInt64(buffer.count) }
    var written: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    var finalizations: Int { lock.lock(); defer { lock.unlock() }; return finalizeCount }
}

/// Keeps the chunk sinks a `SplittingSink` asks for, so a test can see the files
/// a `--split` run would have written.
private final class ChunkFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [CollectingSink] = []

    func make(_ index: Int) -> AudioSink {
        lock.lock()
        defer { lock.unlock() }
        let sink = CollectingSink(label: "call_\(String(format: "%03d", index)).wav")
        sinks.append(sink)
        return sink
    }

    var chunks: [CollectingSink] { lock.lock(); defer { lock.unlock() }; return sinks }
}

/// A sink whose every write fails, to prove what the engine does with the error.
private final class FailingSink: AudioSink, @unchecked Sendable {
    private let error: Error
    let label: String

    init(errno code: Int32, label: String = "failing") {
        self.error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        self.label = label
    }

    func write(_ data: Data) throws { throw error }
    func finalize() throws {}
    var bytesWritten: UInt64 { 0 }
}

/// Reads channel `channel` of 16-bit interleaved stereo PCM.
private func samples(_ data: Data, channel: Int) -> [Int16] {
    data.withUnsafeBytes { raw in
        let all = raw.bindMemory(to: Int16.self)
        return stride(from: channel, to: all.count, by: 2).map { all[$0] }
    }
}

/// `--tracks stereo` keeps the two capture sources apart in one file: the mic
/// on channel 0, the system audio on channel 1 (PRD §6.7d).
@Suite("Stereo track layout")
struct StereoTrackLayoutTests {
    private static let stereo16 = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 2)

    /// 16-bit interleaved: each source is folded to mono and lands on its own
    /// channel — no summing, so neither source bleeds into the other's channel.
    @Test func foldsEachSourceOntoItsOwnChannel() {
        // Two frames per source, upmixed across both capture channels.
        let mic = Data(fromInt16: [100, 100, 200, 200])
        let system = Data(fromInt16: [-300, -300, -400, -400])
        let out = interleaveAsStereo(left: mic, right: system, format: Self.stereo16)

        #expect(out.count == mic.count)  // 2 frames × 2 ch × 2 B
        #expect(samples(out, channel: 0) == [100, 200])
        #expect(samples(out, channel: 1) == [-300, -400])
    }

    /// A genuinely stereo source (different L and R) is *downmixed* by
    /// averaging, not half-dropped — the documented cost of the layout.
    @Test func averagesAGenuinelyStereoSource() {
        let mic = Data(fromInt16: [0, 0])
        let system = Data(fromInt16: [1000, 2000])
        let out = interleaveAsStereo(left: mic, right: system, format: Self.stereo16)
        #expect(samples(out, channel: 1) == [1500])
    }

    /// Averaging cannot clip, so two full-scale sources stay full-scale
    /// instead of wrapping the way an unclamped sum would.
    @Test func fullScaleSamplesDoNotClip() {
        let loud = Data(fromInt16: [32767, 32767])
        let out = interleaveAsStereo(left: loud, right: loud, format: Self.stereo16)
        #expect(samples(out, channel: 0) == [32767])
        #expect(samples(out, channel: 1) == [32767])
    }

    /// 24- and 32-bit captures work too: every encoder honours
    /// `PCMFormat.channels`, so the layout is not a 16-bit-only feature.
    @Test func handlesEveryBitDepth() {
        let format32 = PCMFormat(sampleRate: 16000, bitsPerSample: 32, channels: 2)
        let mic32 = Data(fromInt32: [1_000_000, 1_000_000])
        let system32 = Data(fromInt32: [-2_000_000, -2_000_000])
        let out32 = interleaveAsStereo(left: mic32, right: system32, format: format32)
        let got32 = out32.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        #expect(got32 == [1_000_000, -2_000_000])

        // 24-bit: 3-byte little-endian samples, two channels per frame.
        let format24 = PCMFormat(sampleRate: 16000, bitsPerSample: 24, channels: 2)
        let mic24 = Data(from24Bit: [4096, 4096])
        let system24 = Data(from24Bit: [-8192, -8192])
        let out24 = interleaveAsStereo(left: mic24, right: system24, format: format24)
        #expect(out24 == Data(from24Bit: [4096, -8192]))
    }

    /// The two sources arrive as separate callbacks, so the writer emits only
    /// their common prefix and keeps the unmatched tail for the next chunk —
    /// a chunk that ran ahead must never be paired with the wrong instant.
    @Test func emitsOnlyTheCommonPrefix() throws {
        let sink = CollectingSink()
        let writer = StereoTrackWriter(sink: sink, format: Self.stereo16)

        try writer.write(Data(fromInt16: [11, 11, 22, 22]), from: .microphone)
        #expect(sink.bytesWritten == 0)  // nothing to pair with yet

        try writer.write(Data(fromInt16: [33, 33]), from: .system)
        #expect(samples(sink.written, channel: 0) == [11])
        #expect(samples(sink.written, channel: 1) == [33])

        // The buffered mic frame pairs up when the system side catches up.
        try writer.write(Data(fromInt16: [44, 44]), from: .system)
        #expect(samples(sink.written, channel: 0) == [11, 22])
        #expect(samples(sink.written, channel: 1) == [33, 44])
    }

    /// Both adapters finalize at teardown, but the file behind them must be
    /// closed exactly once.
    @Test func finalizesTheFileOnce() throws {
        let sink = CollectingSink()
        let writer = StereoTrackWriter(sink: sink, format: Self.stereo16)
        for (_, track) in writer.trackSinks() { try track.finalize() }
        #expect(sink.finalizations == 1)
    }

    /// The adapters carry the tag the writer cannot read off a bare `write`.
    @Test func adaptersRouteBySourceTag() throws {
        let sink = CollectingSink()
        let writer = StereoTrackWriter(sink: sink, format: Self.stereo16)
        let tracks = Dictionary(uniqueKeysWithValues: writer.trackSinks())

        try tracks[.system]?.write(Data(fromInt16: [-500, -500]))
        try tracks[.microphone]?.write(Data(fromInt16: [700, 700]))
        #expect(samples(sink.written, channel: 0) == [700])
        #expect(samples(sink.written, channel: 1) == [-500])
    }

    /// Pause is applied one chunk at a time, so it can drop the mic's chunk for
    /// an instant and keep the system's. Without a realignment the writer would
    /// pair the survivor with the *next* instant of the other source and the two
    /// channels would stay a chunk apart for the rest of the recording.
    @Test func aPauseThatDropsOneSideDoesNotSkewTheChannels() throws {
        let control = CaptureControl()
        let sink = CollectingSink()
        let writer = StereoTrackWriter(
            sink: sink, format: Self.stereo16, pauseGeneration: { control.pauseCount })

        // Instant 1 pairs normally.
        try writer.write(Data(fromInt16: [11, 11]), from: .microphone)
        try writer.write(Data(fromInt16: [-11, -11]), from: .system)

        // Instant 2 straddles the pause: the system chunk gets through, the
        // mic chunk is dropped by the engine's gate and never arrives.
        try writer.write(Data(fromInt16: [-22, -22]), from: .system)
        control.pause()
        control.resume()

        // Instant 3, after the resume.
        try writer.write(Data(fromInt16: [33, 33]), from: .microphone)
        try writer.write(Data(fromInt16: [-33, -33]), from: .system)

        // Mic 33 must meet system -33, not the orphaned -22 from before the pause.
        #expect(samples(sink.written, channel: 0) == [11, 33])
        #expect(samples(sink.written, channel: 1) == [-11, -33])
    }

    /// A source can deliver nothing for a whole recording: on the Core Audio
    /// path the mixed stream still gets audio when the mic buffer is
    /// unavailable, but the per-source callback for the mic never fires. Nothing
    /// then pairs, so the live side must stop growing — and none of it may be
    /// lost: past the cap, and again at finalize, it is written against silence.
    @Test func aSilentSourceIsFilledWithSilenceNotDropped() throws {
        let sink = CollectingSink()
        let writer = StereoTrackWriter(sink: sink, format: Self.stereo16)
        // 16 kHz, 16-bit, 2 ch = 64 000 B/s, so the cap is 128 000 B.
        let cap = Int(StereoTrackWriter.maxUnpairedSeconds * Double(Self.stereo16.byteRate))
        let chunk = Data(fromInt16: Array(repeating: 700, count: 3200))  // 0.1 s
        let seconds = 10.0
        let total = Int(seconds * Double(Self.stereo16.byteRate))

        for _ in 0..<Int(seconds / 0.1) {
            try writer.write(chunk, from: .system)
        }

        // Ten seconds in, the queue holds two, not ten; the rest is on disk.
        #expect(
            writer.unpairedBytes <= cap + chunk.count,
            "queue held \(writer.unpairedBytes) B, cap is \(cap) B")
        #expect(sink.bytesWritten == UInt64(total - writer.unpairedBytes))

        try writer.finalize()
        #expect(sink.bytesWritten == UInt64(total))  // every captured second kept
        #expect(writer.silenceFilledBytes == UInt64(total))
        #expect(writer.unpairedBytes == 0)
        #expect(Set(samples(sink.written, channel: 0)) == [0])  // the silent mic
        #expect(Set(samples(sink.written, channel: 1)) == [700])  // the call, intact
        #expect(sink.finalizations == 1)
    }

    /// The bound must not fire on a normal capture: a skew of a chunk or two
    /// between the two callbacks is ordinary and is waited out, not filled.
    @Test func ordinarySkewIsKeptWhole() throws {
        let sink = CollectingSink()
        let writer = StereoTrackWriter(sink: sink, format: Self.stereo16)
        let chunk = Data(fromInt16: Array(repeating: 500, count: 3200))  // 0.1 s

        for _ in 0..<3 { try writer.write(chunk, from: .microphone) }
        try writer.write(chunk, from: .system)

        #expect(writer.silenceFilledBytes == 0)
        #expect(sink.bytesWritten == UInt64(chunk.count))  // the first 0.1 s paired
        #expect(writer.unpairedBytes == 2 * chunk.count)  // the rest still waiting

        // At the end nothing is thrown away: the waiting tail is flushed too.
        try writer.finalize()
        #expect(sink.bytesWritten == UInt64(3 * chunk.count))
    }

    /// The PRD promises `--split` chunks the interleaved stream, and nothing
    /// covered it. `--split` sits *under* the layout in the real wiring — the
    /// writer's sink is whatever `makeAudioSink` built, including a
    /// `SplittingSink` — and the interleaved stream carries the same byte count
    /// per second as the summed one, so the chunks rotate at the same instant
    /// they would without the layout.
    @Test func splitRotatesTheInterleavedStreamOnTheSameBoundaries() throws {
        let factory = ChunkFactory()
        // 16 kHz 16-bit stereo = 64 000 B/s, so 0.01 s is a 640-byte chunk.
        let split = SplittingSink(
            chunkSeconds: 0.01, format: Self.stereo16, label: "call.wav",
            makeChunkSink: { factory.make($0) })
        let writer = StereoTrackWriter(sink: split, format: Self.stereo16)

        // Five rounds of 320 B per source pair into 320 B of interleaved output
        // each, so 1600 B in total: two full chunks and a third left short.
        for _ in 0..<5 {
            try writer.write(Data(repeating: 0x11, count: 320), from: .microphone)
            try writer.write(Data(repeating: 0x22, count: 320), from: .system)
        }
        try writer.finalize()

        #expect(factory.chunks.map(\.bytesWritten) == [640, 640, 320])
        #expect(factory.chunks.map(\.finalizations) == [1, 1, 1])
        #expect(factory.chunks.map(\.label) == ["call_001.wav", "call_002.wav", "call_003.wav"])
    }
}

/// `--tracks` resolves like every other setting (flag › env › config ›
/// built-in), and `stereo` is refused rather than silently downgraded when the
/// capture cannot supply two sources or two channels.
@Suite("Track layout resolution")
struct TrackLayoutResolutionTests {
    private func layout(
        _ args: [String], env: [String: String] = [:], config: Configuration = Configuration()
    ) throws -> TrackLayout {
        let command = try Hark.parse(args)
        let settings = try ResolvedSettings.resolve(from: command, environment: env, config: config)
        return try command.resolveTrackLayout(
            settings: settings, outputs: try command.resolveOutputs())
    }

    private static let twoSources = ["--system", "--mix", "-a", "m.wav"]

    @Test func defaultsToMixed() throws {
        #expect(try layout(Self.twoSources) == .mixed)
    }

    @Test func flagBeatsEnvironmentBeatsConfig() throws {
        var config = Configuration()
        config.tracks = "stereo"
        #expect(try layout(Self.twoSources, config: config) == .stereo)
        #expect(try layout(Self.twoSources, env: ["HARK_TRACKS": "mixed"], config: config) == .mixed)
        #expect(
            try layout(
                Self.twoSources + ["--tracks", "stereo"], env: ["HARK_TRACKS": "mixed"],
                config: config) == .stereo)
    }

    /// One source has nothing to separate, so `stereo` is a usage error rather
    /// than a file whose two channels are identical.
    @Test(arguments: [
        ["--system", "-a", "m.wav"],  // no mic mixed in
        ["-a", "m.wav"],              // mic only
    ])
    func stereoNeedsTwoSources(_ args: [String]) throws {
        #expect(throws: HarkError.self) { _ = try layout(args + ["--tracks", "stereo"]) }
    }

    /// A mono file cannot hold two channels; say so instead of dropping one
    /// source or quietly re-summing them.
    @Test func stereoNeedsTwoChannels() throws {
        #expect(throws: HarkError.self) {
            _ = try layout(Self.twoSources + ["--tracks", "stereo", "-c", "1"])
        }
        // Both stored: neither was typed for this run, so it stays an error.
        var config = Configuration()
        config.channels = 1
        config.tracks = "stereo"
        #expect(throws: HarkError.self) { _ = try layout(Self.twoSources, config: config) }
    }

    /// A typed `--tracks stereo` beats a stored mono default: the user asked for
    /// two channels on this run, and `channels 1` in config or env was not.
    @Test func typedStereoOverridesAStoredMonoChannelCount() throws {
        var config = Configuration()
        config.channels = 1
        #expect(try layout(Self.twoSources + ["--tracks", "stereo"], config: config) == .stereo)
        #expect(
            try layout(Self.twoSources + ["--tracks", "stereo"], env: ["HARK_CHANNELS": "1"])
                == .stereo)
        let settings = try ResolvedSettings.resolve(
            from: try Hark.parse(Self.twoSources + ["--tracks", "stereo"]),
            environment: [:], config: config)
        #expect(settings.channels == nil)  // back to the capture's own default
    }

    /// The default layout stays valid everywhere, so a configured `channels 1`
    /// never breaks a capture that didn't ask for separate tracks.
    @Test func mixedIsAlwaysAllowed() throws {
        #expect(try layout(["-a", "m.wav", "-c", "1"]) == .mixed)
    }

    /// The layout describes the -a file, so a run without one has nothing to
    /// refuse: `tracks stereo` sitting in the config or the environment must not
    /// break an unrelated transcript-only capture (the refusals above all reach
    /// a run that really was going to write audio).
    @Test(arguments: [
        ["-t", "notes.txt"],        // transcript only: no -a at all
        ["--system", "-t", "-"],    // one source, but still no -a
        ["--no-output"],            // dry run: nothing is written
    ])
    func stereoIsIgnoredWithoutAnAudioFile(_ args: [String]) throws {
        var config = Configuration()
        config.tracks = "stereo"
        #expect(try layout(args, config: config) == .mixed)
        #expect(try layout(args, env: ["HARK_TRACKS": "stereo"]) == .mixed)
    }
}

/// A multi-track session the test drives by hand, delivering the mixed stream
/// and both separated sources the way a `--mix` capture does.
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

    func emit(_ tag: CaptureSource, _ data: Data) {
        lock.lock(); let sources = sourceHandler; lock.unlock()
        sources?(tag, data)
    }
    func emitMixed(_ data: Data) {
        lock.lock(); let audio = onAudio; lock.unlock()
        audio?(data)
    }
}

/// The stereo layout runs through the real capture pipeline, so it has to work
/// with the guards `CaptureEngine` applies to every per-source write.
@Suite("Stereo tracks through the capture engine", .serialized)
struct StereoTracksCaptureTests {
    private static let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 2)

    /// End to end: two sources in, one interleaved file out, mic left and
    /// system right, finalized exactly once.
    @Test func capturesBothSourcesIntoOneInterleavedFile() throws {
        let control = CaptureControl()
        let session = StubMultiTrackSession()
        let sink = CollectingSink()
        let writer = StereoTrackWriter(
            sink: sink, format: Self.format, pauseGeneration: { control.pauseCount })
        var engine = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 2,
            captureSystem: true, apps: [], excludeApps: [], mix: true)
        engine.control = control

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, writer.trackSinks()))
        Thread.detachNewThread {
            let (engine, session, tracks) = box.value
            try? engine.run(
                session: session, format: Self.format, into: [],
                duration: nil, warnOnSilence: false, sourceSinks: tracks)
            finished.signal()
        }
        while !session.isReady { usleep(1000) }

        session.emit(.microphone, Data(fromInt16: [1000, 1000]))
        session.emit(.system, Data(fromInt16: [-2000, -2000]))
        usleep(30_000)

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)

        #expect(samples(sink.written, channel: 0) == [1000])
        #expect(samples(sink.written, channel: 1) == [-2000])
        #expect(sink.finalizations == 1)
    }

    /// `--duration` trims each source at the same byte count, and the paired
    /// output carries the capture's own byte rate, so the stereo file holds
    /// exactly the requested length.
    @Test func durationTrimsTheInterleavedFileToTheBudget() throws {
        let control = CaptureControl()
        let session = StubMultiTrackSession()
        let sink = CollectingSink()
        let writer = StereoTrackWriter(
            sink: sink, format: Self.format, pauseGeneration: { control.pauseCount })
        var engine = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 2,
            captureSystem: true, apps: [], excludeApps: [], mix: true)
        engine.control = control

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, writer.trackSinks()))
        Thread.detachNewThread {
            let (engine, session, tracks) = box.value
            // 16 kHz, 16-bit stereo = 64 000 B/s, so 0.01 s is a 640-byte budget.
            try? engine.run(
                session: session, format: Self.format, into: [],
                duration: 0.01, warnOnSilence: false, sourceSinks: tracks)
            finished.signal()
        }
        while !session.isReady { usleep(1000) }

        for _ in 0..<3 {
            session.emit(.microphone, Data(repeating: 0x11, count: 320))
            session.emit(.system, Data(repeating: 0x22, count: 320))
            usleep(20_000)
        }

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(sink.bytesWritten == 640)
    }

    /// The -a file is the artifact, wherever it is written from: a failed write
    /// has to stop the capture and exit 74, exactly as it does on the mixed
    /// stream. The per-source path drops write errors because its usual sinks
    /// are feeds, and `--tracks stereo` moves the recording onto it — untreated,
    /// a disk filling mid-meeting would leave a truncated file and exit 0.
    @Test func aFailedWriteToTheStereoFileStopsTheRunWithAnError() throws {
        let control = CaptureControl()
        let session = StubMultiTrackSession()
        // ENOSPC: the disk filled while the meeting was being recorded.
        let writer = StereoTrackWriter(
            sink: FailingSink(errno: ENOSPC), format: Self.format,
            pauseGeneration: { control.pauseCount })
        var engine = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 2,
            captureSystem: true, apps: [], excludeApps: [], mix: true)
        engine.control = control

        let thrown = LockBox<HarkExitCode>()
        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, writer.trackSinks(), thrown))
        Thread.detachNewThread {
            let (engine, session, tracks, thrown) = box.value
            do {
                try engine.run(
                    session: session, format: Self.format, into: [],
                    duration: nil, warnOnSilence: false, sourceSinks: tracks)
            } catch let error as HarkError {
                thrown.set(error.code)
            } catch {}
            finished.signal()
        }
        while !session.isReady { usleep(1000) }

        session.emit(.microphone, Data(fromInt16: [1000, 1000]))
        session.emit(.system, Data(fromInt16: [-2000, -2000]))

        // Nothing stops this capture but the failed write itself.
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(thrown.get() == .ioError)
    }

    /// `-a -` piped into a reader that exits is a normal end, not a failure:
    /// EPIPE stops the capture quietly and the run still succeeds, the same
    /// call the mixed stream makes.
    @Test func aClosedDownstreamPipeEndsTheStereoRunQuietly() throws {
        let control = CaptureControl()
        let session = StubMultiTrackSession()
        let writer = StereoTrackWriter(
            sink: FailingSink(errno: EPIPE), format: Self.format,
            pauseGeneration: { control.pauseCount })
        var engine = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 2,
            captureSystem: true, apps: [], excludeApps: [], mix: true)
        engine.control = control

        let thrown = LockBox<HarkExitCode>()
        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, writer.trackSinks(), thrown))
        Thread.detachNewThread {
            let (engine, session, tracks, thrown) = box.value
            do {
                try engine.run(
                    session: session, format: Self.format, into: [],
                    duration: nil, warnOnSilence: false, sourceSinks: tracks)
            } catch let error as HarkError {
                thrown.set(error.code)
            } catch {}
            finished.signal()
        }
        while !session.isReady { usleep(1000) }

        session.emit(.microphone, Data(fromInt16: [1000, 1000]))
        session.emit(.system, Data(fromInt16: [-2000, -2000]))

        #expect(finished.wait(timeout: .now() + 5) == .success)  // stopped on its own
        #expect(thrown.get() == nil)  // …and said nothing about it
    }

    /// The same path still carries best-effort feeds — a transcriber's stream, a
    /// temporary diarization WAV — whose loss costs a word of transcript. One of
    /// those failing must not kill a recording that is going fine.
    @Test func aFailedWriteToAFeedLetsTheCaptureCarryOn() throws {
        let control = CaptureControl()
        let session = StubMultiTrackSession()
        let recording = CollectingSink()
        var engine = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 2,
            captureSystem: true, apps: [], excludeApps: [], mix: true)
        engine.control = control

        let thrown = LockBox<HarkExitCode>()
        let finished = DispatchSemaphore(value: 0)
        let feed = FailingSink(errno: ENOSPC, label: "transcriber feed")
        let box = UncheckedSendableBox(value: (engine, session, recording, feed, thrown))
        Thread.detachNewThread {
            let (engine, session, recording, feed, thrown) = box.value
            do {
                try engine.run(
                    session: session, format: Self.format, into: [recording],
                    duration: nil, warnOnSilence: false,
                    sourceSinks: [(.microphone, feed)])
            } catch let error as HarkError {
                thrown.set(error.code)
            } catch {}
            finished.signal()
        }
        while !session.isReady { usleep(1000) }

        session.emit(.microphone, Data(fromInt16: [1000, 1000]))
        session.emitMixed(Data(fromInt16: [1000, 1000]))
        usleep(30_000)
        #expect(finished.wait(timeout: .now() + 0.2) == .timedOut)  // still recording

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(thrown.get() == nil)
        #expect(recording.bytesWritten == 4)  // the mixed stream kept its chunk
    }

    /// The verbose teardown line reports what was captured and where it went.
    /// With the recording on the per-source path it has to look there too, or a
    /// run that did write a file reports "captured 0 bytes … to " and no
    /// destination at all.
    @Test func theTeardownStatsNameTheStereoFile() throws {
        let sink = CollectingSink(label: "call.wav")
        let writer = StereoTrackWriter(sink: sink, format: Self.format)
        try writer.write(Data(fromInt16: [1000, 1000]), from: .microphone)
        try writer.write(Data(fromInt16: [-2000, -2000]), from: .system)

        let stats = CaptureEngine.captureStats(
            mixed: [], perSource: writer.trackSinks().map(\.1))
        #expect(stats.bytes == 4)  // one interleaved frame
        #expect(stats.labels == ["call.wav"])  // both adapters, one file, named once

        // A feed is nothing the user asked for, so it stays out of the line.
        let feed = CollectingSink(label: "transcriber feed")
        #expect(CaptureEngine.captureStats(mixed: [], perSource: [feed]).labels.isEmpty)
    }
}

extension Data {
    fileprivate init(fromInt16 samples: [Int16]) {
        self = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    fileprivate init(fromInt32 samples: [Int32]) {
        self = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Packs signed values as 3-byte little-endian samples.
    fileprivate init(from24Bit samples: [Int32]) {
        var data = Data(capacity: samples.count * 3)
        for sample in samples {
            let u = UInt32(bitPattern: sample)
            data.append(UInt8(u & 0xFF))
            data.append(UInt8((u >> 8) & 0xFF))
            data.append(UInt8((u >> 16) & 0xFF))
        }
        self = data
    }
}
