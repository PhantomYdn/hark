import ArgumentParser
import Encoders
import Foundation
import Testing

@testable import CLI

@Suite("Root argument parsing")
struct RootParsingTests {
    @Test func defaults() throws {
        let hark = try Hark.parse([])
        #expect(hark.input == nil)
        #expect(hark.device == nil)
        #expect(hark.audio == nil)
        #expect(hark.transcript == nil)
        #expect(hark.rate == nil)
        #expect(hark.bits == nil)
        #expect(hark.channels == nil)
        #expect(hark.duration == nil)
        #expect(!hark.raw)
        #expect(!hark.noOutput)
        // Defaults are now unset (nil) so config/env can supply them; the
        // effective defaults are applied in ResolvedSettings.
        #expect(hark.engine == nil)
        #expect(hark.language == nil)
        #expect(hark.translate == nil)
        #expect(hark.silenceThreshold == nil)
    }

    @Test func parsesAllOptions() throws {
        let hark = try Hark.parse([
            "-d", "SomeUID", "-a", "x.wav", "-t", "x.srt",
            "-r", "48000", "-b", "24", "-c", "2", "--duration", "30.5",
        ])
        #expect(hark.device == "SomeUID")
        #expect(hark.audio == "x.wav")
        #expect(hark.transcript == "x.srt")
        #expect(hark.rate == 48000)
        #expect(hark.bits == 24)
        #expect(hark.channels == 2)
        #expect(hark.duration == 30.5)
    }

    @Test(arguments: [
        ["-a", "x.wav", "-b", "12"],          // bad bit depth
        ["-a", "x.wav", "-c", "3"],           // bad channel count
        ["--duration", "0"],                   // non-positive duration
        ["-a", "x.wav", "-r", "0"],           // bad rate
        ["-a", "-", "-t", "-"],               // two outputs cannot share stdout
        ["--raw", "-a", "x.wav"],             // --raw requires -a -
        ["--no-output", "-a", "x.wav"],       // dry run conflicts with an output
        ["-i", "f.wav", "--system"],          // -i excludes live flags
        ["-i", "f.wav", "--duration", "5"],   // duration is live-only
        ["-i", "f.wav", "--split", "duration=2"],  // split is live-only
        ["--system", "--app", "foo"],          // system is everything
        ["--app", "a", "--exclude-app", "b"],  // include vs exclude
        ["--mix"],                             // mix needs a tap mode
        ["--system", "-d", "UID"],             // device needs --mix
        ["--split", "duration=2", "-a", "-"],  // split needs a file
        ["--split", "duration=2"],             // split needs an audio output
        ["-e", "bogus"],                        // unknown engine
        ["-e", "apple", "--translate"],         // apple cannot translate
        ["--system", "--capture-backend", "bogus", "-a", "x.wav"],  // bad backend
        ["--speakers", "--speaker-labels", "a,b,c"],  // labels must be a pair
        ["--speakers", "--max-speakers", "0"],        // must be positive
        ["--speakers", "--speaker-threshold", "0"],   // out of (0,1]
        ["--speakers", "--speaker-threshold", "1.5"],  // out of (0,1]
        ["--vad-threshold", "0"],                      // out of (0,1]
        ["--vad-threshold", "1.5"],                    // out of (0,1]
        ["--interactive", "-i", "f.wav"],              // interactive is live-only
        ["--interactive", "-a", "-"],                  // interactive owns the terminal
    ])
    func rejectsInvalidCombinations(_ arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try Hark.parse(arguments)
        }
    }

    @Test(arguments: [
        [],                                     // bare: live mic -> transcript
        ["-a", "rec.m4a"],                      // record only
        ["-a", "rec.m4a", "-t", "notes.txt"],   // record + transcribe
        ["-a", "-"],                            // WAV stream to stdout
        ["--raw", "-a", "-"],                   // raw PCM to stdout
        ["-i", "in.mp3"],                       // transcribe a file
        ["-i", "in.wav", "-a", "out.m4a"],      // convert
        ["--system", "--mix", "-a", "m.m4a", "-t", "m.srt"],
        ["--system", "--mix", "-d", "SomeUID"],
        ["--app", "com.example.app", "--app", "123"],
        ["--exclude-app", "com.example.app"],
        ["--system", "--capture-backend", "coreaudio", "-a", "x.wav"],
        ["--system", "--capture-backend", "sckit", "-a", "x.wav"],
        ["--system", "--capture-backend", "auto", "-a", "x.wav"],
        ["--language", "de", "-i", "x.wav"],    // explicit language
        ["--translate", "-i", "x.wav"],         // whisper supports translate
        ["--no-translate", "-i", "x.wav"],      // explicit opt-out
        ["-e", "whisperkit", "--translate"],    // known engine, capable (impl. pending)
        ["-e", "apple", "-i", "x.wav"],         // known engine parses (run-time unavailable)
        ["--speakers"],                          // opt-in (run-time: planned)
        ["--diarize"],                           // alias of --speakers
        ["--speakers", "--speaker-labels", "Me,Them"],
        ["--system", "--mix", "--speakers", "--speaker-mode", "source"],
        ["--speakers", "--max-speakers", "3"],
        ["--speakers", "--speaker-threshold", "0.5"],
        ["--vad-threshold", "0.5"],                             // general live VAD knob
        ["--no-speakers"], ["--no-vad"], ["--no-gain"],         // three-state toggles
        ["--speaker-mode", "source"],                          // companion flags: ignored if speakers off
        ["--max-speakers", "2"], ["--diarize-engine", "offline"],
        ["-i", "x.wav", "--speakers"],                          // batch diarization
        ["-i", "x.wav", "--speakers", "--speaker-mode", "acoustic", "--diarize-engine", "offline"],
        ["--interactive"],                                      // live UI, transcript to terminal
        ["--interactive", "-a", "rec.m4a"],                     // record + interactive transcript view
        ["--interactive", "--system", "--mix"],                 // interactive meeting capture
    ])
    func acceptsValidCombinations(_ arguments: [String]) throws {
        _ = try Hark.parse(arguments)
    }

    @Test func repeatableAppFlagAccumulates() throws {
        let hark = try Hark.parse(
            ["--app", "com.a", "--app", "com.b", "--app", "42"])
        #expect(hark.apps == ["com.a", "com.b", "42"])
    }

    @Test func captureBackendFlagWins() throws {
        let hark = try Hark.parse(["--system", "--capture-backend", "SCKit", "-a", "x.wav"])
        #expect(hark.resolvedCaptureBackend() == "sckit")  // lowercased
    }

    @Test func captureBackendDefaultsToAutoWithoutEnv() throws {
        let hark = try Hark.parse(["--system", "-a", "x.wav"])
        // Only meaningful when HARK_CAPTURE is unset in the test environment.
        if ProcessInfo.processInfo.environment["HARK_CAPTURE"] == nil {
            #expect(hark.resolvedCaptureBackend() == "auto")
        }
    }
}

@Suite("Output resolution")
struct OutputResolutionTests {
    /// Naming no output transcribes to stdout (the default verb).
    @Test func defaultIsTranscriptToStdout() throws {
        let outputs = try Hark.parse([]).resolveOutputs()
        #expect(outputs.audio == nil)
        guard case .stdout = outputs.transcript else {
            Issue.record("expected transcript -> stdout")
            return
        }
    }

    @Test func audioOnlyHasNoTranscript() throws {
        let outputs = try Hark.parse(["-a", "rec.m4a"]).resolveOutputs()
        #expect(outputs.transcript == nil)
        guard case .file(let path)? = outputs.audio, path == "rec.m4a" else {
            Issue.record("expected audio file rec.m4a")
            return
        }
    }

    @Test func dashAudioIsWavStream() throws {
        let outputs = try Hark.parse(["-a", "-"]).resolveOutputs()
        guard case .stdoutWav? = outputs.audio else {
            Issue.record("expected WAV stream to stdout")
            return
        }
        #expect(outputs.transcript == nil)
    }

    @Test func rawDashAudioIsRawStream() throws {
        let outputs = try Hark.parse(["--raw", "-a", "-"]).resolveOutputs()
        guard case .stdoutRaw? = outputs.audio else {
            Issue.record("expected raw PCM to stdout")
            return
        }
    }

    @Test func explicitTranscriptToStdoutWithAudioFile() throws {
        let outputs = try Hark.parse(["-a", "rec.m4a", "-t", "-"]).resolveOutputs()
        guard case .file? = outputs.audio else {
            Issue.record("expected audio file")
            return
        }
        guard case .stdout = outputs.transcript else {
            Issue.record("expected transcript -> stdout")
            return
        }
    }

    @Test func noOutputDiscardsEverything() throws {
        let outputs = try Hark.parse(["--no-output"]).resolveOutputs()
        #expect(outputs.audio == nil)
        #expect(outputs.transcript == nil)
    }
}

@Suite("Devices argument parsing")
struct DevicesParsingTests {
    @Test func defaultsToAllDevices() throws {
        let devices = try Devices.parse([])
        #expect(!devices.listInputs)
        #expect(!devices.listOutputs)
        #expect(!devices.json)
    }

    @Test func rejectsInputsAndOutputsTogether() {
        #expect(throws: (any Error).self) {
            _ = try Devices.parse(["--list-inputs", "--list-outputs"])
        }
    }
}

@Suite("Exit codes")
struct ExitCodeTests {
    @Test func sysexitsValues() {
        #expect(HarkExitCode.ok.rawValue == 0)
        #expect(HarkExitCode.usage.rawValue == 64)
        #expect(HarkExitCode.noInput.rawValue == 66)
        #expect(HarkExitCode.unavailable.rawValue == 69)
        #expect(HarkExitCode.software.rawValue == 70)
        #expect(HarkExitCode.ioError.rawValue == 74)
        #expect(HarkExitCode.noPermission.rawValue == 77)
    }

    @Test func errorFactoriesCarryCodes() {
        #expect(HarkError.noInput("x").code == .noInput)
        #expect(HarkError.unavailable("x").code == .unavailable)
        #expect(HarkError.ioError("x").code == .ioError)
        #expect(HarkError.noPermission("x").code == .noPermission)
    }
}

@Suite("Byte budget")
struct ByteBudgetTests {
    @Test func trimsFinalChunkToExactBudget() {
        let budget = ByteBudget(bytes: 10, frameSize: 2)
        let first = budget.consume(Data(count: 6))
        #expect(first.chunk.count == 6)
        #expect(!first.exhausted)
        let second = budget.consume(Data(count: 6))
        #expect(second.chunk.count == 4)
        #expect(second.exhausted)
        let third = budget.consume(Data(count: 6))
        #expect(third.chunk.isEmpty)
        #expect(third.exhausted)
    }

    @Test func roundsBudgetDownToFrameBoundary() {
        let budget = ByteBudget(bytes: 7, frameSize: 4)
        let result = budget.consume(Data(count: 8))
        #expect(result.chunk.count == 4)  // 7 rounded down to one 4-byte frame
        #expect(result.exhausted)
    }
}

@Suite("Split parsing")
struct SplitSpecTests {
    @Test func parsesDurationAndSilence() throws {
        let duration = try SplitSpec.parse("duration=300")
        #expect(duration == .duration(300))
        let silence = try SplitSpec.parse("silence=1.5")
        #expect(silence == .silence(1.5))
    }

    @Test(arguments: ["duration", "duration=", "duration=0", "duration=-5",
                      "gap=3", "=5", "duration=abc"])
    func rejectsMalformedSpecs(_ raw: String) {
        #expect(throws: HarkError.self) { _ = try SplitSpec.parse(raw) }
    }

    @Test func chunkPathNumbering() {
        #expect(chunkPath(base: "/x/rec.m4a", index: 1) == "/x/rec_001.m4a")
        #expect(chunkPath(base: "/x/rec.m4a", index: 42) == "/x/rec_042.m4a")
        #expect(chunkPath(base: "rec.wav", index: 1000) == "rec_1000.wav")
        #expect(chunkPath(base: "noext", index: 2) == "noext_002")
    }

    @Test func splitRequiresAudioFile() {
        #expect(throws: (any Error).self) {
            _ = try Hark.parse(["--split", "duration=10", "--no-output"])
        }
    }
}

/// Records writes/finalizes for SplittingSink tests.
private final class RecordingSinkSpy: AudioSink, @unchecked Sendable {
    let label = "spy"
    private(set) var written = Data()
    private(set) var finalized = false
    func write(_ data: Data) throws { written.append(data) }
    func finalize() throws { finalized = true }
    var bytesWritten: UInt64 { UInt64(written.count) }
}

@Suite("SplittingSink")
struct SplittingSinkTests {
    @Test func splitsAtFrameAlignedThreshold() throws {
        // 2-byte frames, threshold 5s at 1 Hz "byte rate" 2 -> 10 bytes.
        let format = PCMFormat(sampleRate: 1, bitsPerSample: 16, channels: 1)
        var chunks: [RecordingSinkSpy] = []
        let sink = SplittingSink(chunkSeconds: 5, format: format, label: "t") { _ in
            let spy = RecordingSinkSpy()
            chunks.append(spy)
            return spy
        }
        try sink.write(Data(count: 25))
        try sink.finalize()

        #expect(chunks.count == 3)
        #expect(chunks[0].written.count == 10)
        #expect(chunks[1].written.count == 10)
        #expect(chunks[2].written.count == 5)
        let allFinalized = chunks.allSatisfy { $0.finalized }
        #expect(allFinalized)
        #expect(sink.bytesWritten == 25)
    }

    @Test func exactMultipleDoesNotOpenEmptyChunk() throws {
        let format = PCMFormat(sampleRate: 1, bitsPerSample: 16, channels: 1)
        var chunks: [RecordingSinkSpy] = []
        let sink = SplittingSink(chunkSeconds: 5, format: format, label: "t") { _ in
            let spy = RecordingSinkSpy()
            chunks.append(spy)
            return spy
        }
        try sink.write(Data(count: 20))  // exactly 2 chunks
        try sink.finalize()
        #expect(chunks.count == 2)
        let allComplete = chunks.allSatisfy { $0.written.count == 10 && $0.finalized }
        #expect(allComplete)
    }

    @Test func chunkIndicesAreSequential() throws {
        let format = PCMFormat(sampleRate: 1, bitsPerSample: 16, channels: 1)
        var indices: [Int] = []
        let sink = SplittingSink(chunkSeconds: 5, format: format, label: "t") { index in
            indices.append(index)
            return RecordingSinkSpy()
        }
        try sink.write(Data(count: 21))
        try sink.finalize()
        #expect(indices == [1, 2, 3])
    }
}

@Suite("Silence splitting")
struct SilenceSplittingTests {
    // 1000 Hz 16-bit mono -> byteRate 2000; 0.5 s blocks are 1000 bytes.
    private let format = PCMFormat(sampleRate: 1000, bitsPerSample: 16, channels: 1)

    private func loud(_ bytes: Int = 1000) -> Data {
        var data = Data(capacity: bytes)
        for i in 0..<(bytes / 2) {
            withUnsafeBytes(of: Int16(i % 2 == 0 ? 16000 : -16000).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }

    private func quiet(_ bytes: Int = 1000) -> Data { Data(count: bytes) }

    @Test func peakAmplitudeByDepth() {
        #expect(peakAmplitude(of: loud(), format: format) > 0.4)
        #expect(peakAmplitude(of: quiet(), format: format) == 0)
        let f24 = PCMFormat(sampleRate: 1000, bitsPerSample: 24, channels: 1)
        // One 24-bit sample at half scale: 0x400000 -> bytes [00, 00, 40].
        #expect(abs(peakAmplitude(of: Data([0x00, 0x00, 0x40]), format: f24) - 0.5) < 0.01)
        let f32 = PCMFormat(sampleRate: 1000, bitsPerSample: 32, channels: 1)
        var d32 = Data()
        withUnsafeBytes(of: Int32(1 << 30).littleEndian) { d32.append(contentsOf: $0) }
        #expect(abs(peakAmplitude(of: d32, format: f32) - 0.5) < 0.01)
    }

    @Test func splitsOnSustainedSilence() throws {
        var chunks: [RecordingSinkSpy] = []
        let sink = SilenceSplittingSink(
            silenceSeconds: 1.5, thresholdDBFS: -50, format: format, label: "t"
        ) { _ in
            let spy = RecordingSinkSpy()
            chunks.append(spy)
            return spy
        }
        // loud 1s, silence 2s, loud 1s (0.5 s blocks)
        for block in [loud(), loud(), quiet(), quiet(), quiet(), quiet(), loud(), loud()] {
            try sink.write(block)
        }
        try sink.finalize()

        #expect(chunks.count == 2)
        // Chunk 1: 2 loud + 3 quiet blocks (split at 1.5s of silence).
        #expect(chunks[0].written.count == 5000)
        // Chunk 2: trailing quiet + 2 loud blocks; nothing dropped.
        #expect(chunks[1].written.count == 3000)
        #expect(sink.bytesWritten == 8000)
    }

    @Test func longSilenceYieldsSingleFollowUpChunk() throws {
        var chunks: [RecordingSinkSpy] = []
        let sink = SilenceSplittingSink(
            silenceSeconds: 1.0, thresholdDBFS: -50, format: format, label: "t"
        ) { _ in
            let spy = RecordingSinkSpy()
            chunks.append(spy)
            return spy
        }
        try sink.write(loud())
        for _ in 0..<10 { try sink.write(quiet()) }  // 5s of silence
        try sink.write(loud())
        try sink.finalize()
        // Disarmed after the split: one follow-up chunk, not five.
        #expect(chunks.count == 2)
    }

    @Test func leadingSilenceDoesNotSplit() throws {
        var chunks: [RecordingSinkSpy] = []
        let sink = SilenceSplittingSink(
            silenceSeconds: 1.0, thresholdDBFS: -50, format: format, label: "t"
        ) { _ in
            let spy = RecordingSinkSpy()
            chunks.append(spy)
            return spy
        }
        for _ in 0..<6 { try sink.write(quiet()) }  // 3s leading silence
        try sink.write(loud())
        try sink.finalize()
        // Splitter is disarmed until sound first appears.
        #expect(chunks.count == 1)
    }
}

@Suite("Live segmentation")
struct StreamSegmenterTests {
    // 1000 Hz 16-bit mono -> byteRate 2000, frame 2; 0.5 s == 1000 bytes.
    private let format = PCMFormat(sampleRate: 1000, bitsPerSample: 16, channels: 1)

    private func loud(_ bytes: Int = 1000) -> Data {
        var data = Data(capacity: bytes)
        for i in 0..<(bytes / 2) {
            withUnsafeBytes(of: Int16(i % 2 == 0 ? 16000 : -16000).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }
    private func quiet(_ bytes: Int = 1000) -> Data { Data(count: bytes) }

    private func makeSegmenter() -> (StreamSegmenter, () -> [(Int, Double, Double)]) {
        var captured: [(Int, Double, Double)] = []
        let seg = StreamSegmenter(
            format: format, silenceThresholdDBFS: -50,
            pauseSeconds: 0.5, maxWindowSeconds: 2.0, minSegmentSeconds: 0.2)
        seg.onSegment = { data, start, end in captured.append((data.count, start, end)) }
        return (seg, { captured })
    }

    @Test func speechThenPauseEmitsOneSegment() {
        let (seg, segments) = makeSegmenter()
        seg.consume(loud(1000))   // 0.5 s speech
        seg.consume(quiet(1000))  // 0.5 s silence == pause boundary
        seg.finish()
        let result = segments()
        #expect(result.count == 1)
        #expect(result[0].0 == 2000)            // bytes (speech + trailing pause)
        #expect(abs(result[0].1 - 0.0) < 1e-9)  // start
        #expect(abs(result[0].2 - 1.0) < 1e-9)  // end
    }

    @Test func continuousSpeechCutAtMaxWindow() {
        let (seg, segments) = makeSegmenter()
        for _ in 0..<4 { seg.consume(loud(1000)) }  // 2 s without a pause
        let result = segments()
        #expect(result.count == 1)
        #expect(result[0].0 == 4000)  // forced at the 2 s window cap
    }

    @Test func pureSilenceWindowIsDropped() {
        let (seg, segments) = makeSegmenter()
        for _ in 0..<5 { seg.consume(quiet(1000)) }
        seg.finish()
        #expect(segments().isEmpty)  // no speech -> nothing transcribed
    }

    @Test func finishFlushesTrailingSpeech() {
        let (seg, segments) = makeSegmenter()
        seg.consume(loud(500))  // 0.25 s, no pause yet
        seg.finish()
        let result = segments()
        #expect(result.count == 1)
        #expect(result[0].0 == 500)
        #expect(abs(result[0].2 - 0.25) < 1e-9)
    }

    @Test func clockAdvancesAcrossDroppedSilence() {
        let (seg, segments) = makeSegmenter()
        seg.consume(loud(1000))   // segment A: speech ...
        seg.consume(quiet(1000))  // ... + pause -> [0, 1]
        for _ in 0..<4 { seg.consume(quiet(1000)) }  // 2 s pure silence: dropped
        seg.consume(loud(1000))   // segment B: speech ...
        seg.consume(quiet(1000))  // ... + pause
        seg.finish()
        let result = segments()
        #expect(result.count == 2)
        #expect(abs(result[0].1 - 0.0) < 1e-9)
        #expect(abs(result[0].2 - 1.0) < 1e-9)
        // 2 s of dropped silence advances the clock: B starts at 3 s.
        #expect(abs(result[1].1 - 3.0) < 1e-9)
        #expect(abs(result[1].2 - 4.0) < 1e-9)
    }
}

@Suite("Live transcript writer")
struct LiveTranscriptWriterTests {
    @Test func srtTimestampFormatting() {
        #expect(LiveTranscriptWriter.srtTimestamp(0) == "00:00:00,000")
        #expect(LiveTranscriptWriter.srtTimestamp(1.0) == "00:00:01,000")
        #expect(LiveTranscriptWriter.srtTimestamp(3661.5) == "01:01:01,500")
    }

    @Test func jsonLineIsValidAndEscaped() throws {
        let line = LiveTranscriptWriter.jsonLine(start: 1.5, end: 2.0, text: "he said \"hi\"")
        #expect(!line.contains("\n"))
        let object = try JSONSerialization.jsonObject(
            with: Data(line.utf8)) as? [String: Any]
        #expect(object?["text"] as? String == "he said \"hi\"")
        #expect((object?["start"] as? Double) == 1.5)
        #expect((object?["end"] as? Double) == 2.0)
    }

    @Test func srtFileAppendsNumberedCues() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-test-\(UUID().uuidString).srt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .srt)
        try writer.append(text: "first", start: 0, end: 1)
        try writer.append(text: "second", start: 1, end: 2)
        try writer.close()

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.contains("1\n00:00:00,000 --> 00:00:01,000\nfirst"))
        #expect(contents.contains("2\n00:00:01,000 --> 00:00:02,000\nsecond"))
    }

    @Test func txtFileAppendsLines() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-test-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .txt)
        try writer.append(text: "hello", start: 0, end: 1)
        try writer.append(text: "world", start: 1, end: 2)
        try writer.close()
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents == "hello\nworld\n")
    }
}

/// End-to-end check of the live chain (segmenter -> whisper -> writer) using
/// `say`-synthesized speech. Skipped automatically when whisper.cpp, a model,
/// or `say` is unavailable, so it never breaks CI.
@Suite("Live transcription (integration)")
struct LiveTranscriptionIntegrationTests {
    @Test func liveSegmentTranscribesSpeechToFile() throws {
        // Exercise the amplitude segmenter deterministically (no VAD model
        // download); VAD has its own gated test below.
        setenv("HARK_VAD", "0", 1)
        guard WhisperEngine.discover() != nil,
            (try? WhisperEngine.resolveModel(flag: nil)) != nil
        else { return }  // no engine/model -> skip

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-live-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let aiff = work.appendingPathComponent("speech.aiff")
        guard runSay("the quick brown fox jumps over the lazy dog", to: aiff) else { return }

        // Decode the speech to canonical 16 kHz mono PCM via the shared path.
        let normalized = try AudioPipeline.normalizeFileForWhisper(aiff.path)
        defer { try? FileManager.default.removeItem(at: normalized) }
        let handle = try FileHandle(forReadingFrom: normalized)
        let header = try WAVStreamParser.parseHeader { handle.readData(ofLength: $0) }
        let pcm = handle.readDataToEndOfFile()
        try handle.close()
        #expect(!pcm.isEmpty)

        let outputPath = work.appendingPathComponent("out.txt").path
        let transcriber = try LiveTranscriber(
            destination: .file(outputPath), transcriptFormat: .txt,
            engineName: "whisper", modelFlag: nil, language: "auto", translate: false,
            captureFormat: header.format, silenceThresholdDBFS: -50, useVad: false,
            pauseSeconds: 0.5, maxWindowSeconds: 12, minSegmentSeconds: 0.3)

        // Feed the speech in 0.25 s chunks, then a 0.6 s pause to close the
        // segment, mimicking the live capture callback.
        let chunk = header.format.byteRate / 4
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunk, pcm.count)
            try transcriber.write(pcm.subdata(in: offset..<end))
            offset = end
        }
        try transcriber.write(Data(count: (header.format.byteRate * 6) / 10))  // 0.6 s silence
        try transcriber.finalize()
        try transcriber.rethrowErrors()

        let contents = try String(contentsOfFile: outputPath, encoding: .utf8)
        #expect(contents.lowercased().contains("quick brown fox"))
    }

    private func runSay(_ phrase: String, to url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, phrase]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Thread-safe segment collector: `VadSegmenter` emits from its consumer task,
/// the test reads after `finish()` (a semaphore barrier).
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, Double, Double)] = []
    func append(_ item: (Int, Double, Double)) {
        lock.lock(); items.append(item); lock.unlock()
    }
    func all() -> [(Int, Double, Double)] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}

/// Deterministic stand-in for the VAD model: a window is "speech" when its peak
/// exceeds `threshold`; emits speechStart/End on transitions with the absolute
/// sample index. Lets `VadSegmenter`'s boundary logic be tested without CoreML.
private final class ScriptedVAD: VoiceActivityStream, @unchecked Sendable {
    let windowSamples: Int
    private let threshold: Float
    private var processed = 0
    private var active = false

    init(windowSamples: Int, threshold: Float = 0.1) {
        self.windowSamples = windowSamples
        self.threshold = threshold
    }

    func process(_ window: [Float]) async throws -> VoiceActivityEvent? {
        let start = processed
        processed += window.count
        let peak = window.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
        let speech = peak > threshold
        if speech && !active {
            active = true
            return .speechStart(sample: start)
        }
        if !speech && active {
            active = false
            return .speechEnd(sample: start)
        }
        return nil
    }
}

@Suite("VAD segmentation")
struct VadSegmenterTests {
    // 16 kHz mono 16-bit: byteRate 32000; 1600-sample (0.1 s) windows.
    private let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)
    private let windowSamples = 1600

    private func loud(_ seconds: Double) -> Data {
        let samples = Int(seconds * 16000)
        var data = Data(capacity: samples * 2)
        for i in 0..<samples {
            withUnsafeBytes(of: Int16(i % 2 == 0 ? 16000 : -16000).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }
    private func quiet(_ seconds: Double) -> Data { Data(count: Int(seconds * 16000) * 2) }

    private func makeSegmenter(maxWindow: Double = 2.0, minSegment: Double = 0.2)
        -> (VadSegmenter, Captured)
    {
        let captured = Captured()
        let seg = VadSegmenter(
            format: format, classifier: ScriptedVAD(windowSamples: windowSamples),
            resample: { samples, _ in samples }, maxWindowSeconds: maxWindow,
            minSegmentSeconds: minSegment)
        seg.onSegment = { data, start, end in captured.append((data.count, start, end)) }
        return (seg, captured)
    }

    @Test func speechThenPauseEmitsOneSegment() {
        let (seg, captured) = makeSegmenter()
        seg.consume(loud(0.5))
        seg.consume(quiet(0.2))
        seg.finish()
        let result = captured.all()
        #expect(result.count == 1)
        #expect(result[0].0 == 16000)              // 0.5 s of speech (bytes)
        #expect(abs(result[0].1 - 0.0) < 1e-6)     // start
        #expect(abs(result[0].2 - 0.5) < 1e-6)     // end
    }

    @Test func continuousSpeechCutAtMaxWindow() {
        let (seg, captured) = makeSegmenter(maxWindow: 0.4)
        seg.consume(loud(0.7))  // no pause: forced cut at 0.4 s, 0.3 s tail
        seg.finish()
        let result = captured.all()
        #expect(result.count == 2)
        #expect(result[0].0 == 12800)  // forced cut at the 0.4 s window cap
    }

    @Test func pureSilenceEmitsNothing() {
        let (seg, captured) = makeSegmenter()
        seg.consume(quiet(0.5))
        seg.finish()
        #expect(captured.all().isEmpty)
    }

    @Test func finishFlushesTrailingSpeech() {
        let (seg, captured) = makeSegmenter()
        seg.consume(loud(0.25))  // no trailing pause
        seg.finish()
        let result = captured.all()
        #expect(result.count == 1)
        #expect(result[0].0 == 8000)
        #expect(abs(result[0].2 - 0.25) < 1e-6)
    }

    @Test func shortBlipBelowMinSegmentDropped() {
        let (seg, captured) = makeSegmenter(minSegment: 0.3)
        seg.consume(loud(0.1))   // one 0.1 s speech window
        seg.consume(quiet(0.2))  // silence closes the turn
        seg.finish()
        #expect(captured.all().isEmpty)  // 0.1 s < 0.3 s min -> dropped
    }
}

@Suite("Speaker labels")
struct SpeakerLabelTests {
    private let cues = [
        TranscriptCue(start: 0, end: 1, text: "hello", speaker: "You"),
        TranscriptCue(start: 1, end: 2, text: "hi there", speaker: "Speaker 1"),
    ]

    @Test func srtPrefixesSpeaker() {
        let out = TranscriptFormatting.render(
            cues: cues, fullText: "hello hi there", format: .srt)
        #expect(out.contains("[You] hello"))
        #expect(out.contains("[Speaker 1] hi there"))
    }

    @Test func txtPrefixesSpeaker() {
        let out = TranscriptFormatting.render(
            cues: cues, fullText: "hello hi there", format: .txt)
        #expect(out == "You: hello\nSpeaker 1: hi there\n")
    }

    @Test func jsonIncludesSpeaker() throws {
        let out = TranscriptFormatting.render(cues: cues, fullText: "x", format: .json)
        let array = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]]
        #expect(array?.first?["speaker"] as? String == "You")
    }

    @Test func absentSpeakerOmittedFromJSON() throws {
        let plain = [TranscriptCue(start: 0, end: 1, text: "hello")]
        let out = TranscriptFormatting.render(cues: plain, fullText: "hello", format: .json)
        #expect(!out.contains("speaker"))
    }

    @Test func absentSpeakerKeepsPlainText() {
        let plain = [TranscriptCue(start: 0, end: 1, text: "hello world")]
        let out = TranscriptFormatting.render(cues: plain, fullText: "hello world", format: .txt)
        #expect(out == "hello world\n")
    }

    @Test func liveJsonLineIncludesSpeakerOnlyWhenPresent() {
        let withSpeaker = LiveTranscriptWriter.jsonLine(
            start: 0, end: 1, text: "hi", speaker: "You")
        #expect(withSpeaker.contains("\"speaker\":\"You\""))
        let without = LiveTranscriptWriter.jsonLine(start: 0, end: 1, text: "hi")
        #expect(!without.contains("speaker"))
    }

    @Test func liveSrtPrefixesSpeaker() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-spk-\(UUID().uuidString).srt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .srt)
        try writer.append(text: "hello", start: 0, end: 1, speaker: "You")
        try writer.close()
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.contains("[You] hello"))
    }
}

/// Stub backend that returns a fixed transcript regardless of input — for
/// exercising the transcribe→write→label path offline.
private final class FakeBackend: TranscriptionBackend, @unchecked Sendable {
    let capabilities = EngineCapabilities(autoDetect: true, translate: true, usesModelFile: false)
    var label: String { "fake" }
    private let text: String
    init(_ text: String) { self.text = text }
    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String { text }
    func shutdown() {}
}

@Suite("Source attribution labeling")
struct SourceAttributionTests {
    private let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)

    private func loud(_ seconds: Double) -> Data {
        let samples = Int(seconds * 16000)
        var data = Data(capacity: samples * 2)
        for i in 0..<samples {
            withUnsafeBytes(of: Int16(i % 2 == 0 ? 16000 : -16000).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }
    private func quiet(_ seconds: Double) -> Data { Data(count: Int(seconds * 16000) * 2) }

    @Test func twoSourcesShareWriterAndTagSpeakers() throws {
        setenv("HARK_VAD", "0", 1)  // amplitude segmenter (deterministic, offline)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-srcattr-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let writer = try LiveTranscriptWriter(destination: .file(path), format: .txt)
        let backend = SerializedBackend(FakeBackend("hello"))
        func makeSource(_ speaker: String) -> LiveTranscriber {
            LiveTranscriber(
                sharedWriter: writer, sharedBackend: backend, speaker: speaker,
                language: nil, translate: false, captureFormat: format,
                silenceThresholdDBFS: -50, useVad: false, pauseSeconds: 0.5, maxWindowSeconds: 2,
                minSegmentSeconds: 0.2)
        }
        let you = makeSource("You")
        let others = makeSource("Others")

        // One speech turn on each source.
        try you.write(loud(0.5)); try you.write(quiet(0.5)); try you.finalize()
        try others.write(loud(0.5)); try others.write(quiet(0.5)); try others.finalize()
        try you.rethrowErrors(); try others.rethrowErrors()
        try writer.close()
        backend.shutdown()

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.contains("You: hello"))
        #expect(contents.contains("Others: hello"))
    }
}

@Suite("Diarization labeling")
struct SpeakerLabelingTests {
    @Test func numbersByFirstAppearanceAndMerges() {
        let raw: [(start: Double, end: Double, id: String)] = [
            (0, 1, "A"), (1, 2, "B"), (2, 3, "A"), (3.2, 4, "A"),
        ]
        let out = SpeakerLabeling.normalize(raw)
        #expect(out == [
            DiarizedSegment(start: 0, end: 1, speaker: "Speaker 1"),
            DiarizedSegment(start: 1, end: 2, speaker: "Speaker 2"),
            // A's two spans (gap 0.2 s) merge into one Speaker 1 cue [2, 4].
            DiarizedSegment(start: 2, end: 4, speaker: "Speaker 1"),
        ])
    }

    @Test func dropsZeroLengthAndSorts() {
        let raw: [(start: Double, end: Double, id: String)] = [
            (2, 3, "X"), (0, 0, "Y"), (0, 1, "Y"),
        ]
        let out = SpeakerLabeling.normalize(raw)
        #expect(out.map(\.speaker) == ["Speaker 1", "Speaker 2"])  // Y first (sorted), zero-length dropped
        #expect(out[0].start == 0 && out[1].start == 2)
    }
}

@Suite("Diarizer model catalog")
struct DiarizerCatalogTests {
    @Test func parsesFluidAudioTags() {
        #expect(ModelCatalog.parse("fluidaudio:diarizer").engine == "fluidaudio")
        #expect(ModelCatalog.parse("fluidaudio:diarizer").modelId == "diarizer")
        #expect(ModelCatalog.parse("fluidaudio:vad").modelId == "vad")
        #expect(ModelCatalog.parse("fluidaudio").modelId == "diarizer")  // bare -> diarizer
        let names = ModelCatalog.available().map(\.name)
        #expect(names.contains("fluidaudio:diarizer"))
        #expect(names.contains("fluidaudio:vad"))
    }
}

/// Gated: loads the real diarizer model and runs it. Only when
/// HARK_TEST_DIARIZE=1 and on Apple Silicon (downloads CoreML on first use).
@Suite("Diarization (integration)")
struct DiarizationIntegrationTests {
    @Test func loadsAndRunsOffline() throws {
        guard ProcessInfo.processInfo.environment["HARK_TEST_DIARIZE"] == "1",
            Platform.isAppleSilicon
        else { return }
        let diarizer = try SpeakerDiarizer.makeOffline(maxSpeakers: nil, threshold: nil)
        var samples = [Float](repeating: 0, count: 16000 * 12)
        for i in 0..<samples.count {
            samples[i] = 0.3 * sin(2 * .pi * 200 * Float(i) / 16000)
        }
        _ = try diarizer.diarize(samples)  // must run without throwing
    }
}

/// Always returns a fixed label, to test that an acoustic resolver overrides
/// the transcriber's fixed speaker.
private final class FixedResolver: LiveSpeakerResolver, @unchecked Sendable {
    private let value: String
    init(_ value: String) { self.value = value }
    func label(start: Double, end: Double) -> String? { value }
}

@Suite("Streaming diarization labeling")
struct StreamingDiarizationTests {
    private let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)
    private func loud(_ seconds: Double) -> Data {
        let samples = Int(seconds * 16000)
        var data = Data(capacity: samples * 2)
        for i in 0..<samples {
            withUnsafeBytes(of: Int16(i % 2 == 0 ? 16000 : -16000).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }
    private func quiet(_ seconds: Double) -> Data { Data(count: Int(seconds * 16000) * 2) }

    @Test func speakerNumberingStableByFirstAppearance() {
        var numbering = SpeakerNumbering()
        #expect(numbering.label(for: "a") == "Speaker 1")
        #expect(numbering.label(for: "b") == "Speaker 2")
        #expect(numbering.label(for: "a") == "Speaker 1")  // stable across calls
        #expect(numbering.label(for: "c") == "Speaker 3")
        #expect(numbering.label(for: "b") == "Speaker 2")
    }

    @Test func mergeOrdersCuesByStart() {
        let mic = [
            TranscriptCue(start: 0, end: 1, text: "x", speaker: "You"),
            TranscriptCue(start: 4, end: 5, text: "z", speaker: "You"),
        ]
        let system = [TranscriptCue(start: 2, end: 3, text: "y", speaker: "Speaker 1")]
        let merged = BatchDiarization.merge([mic, system])
        #expect(merged.map(\.start) == [0, 2, 4])
        #expect(merged.map(\.speaker) == ["You", "Speaker 1", "You"])
    }

    @Test func resolverOverridesFixedLabel() throws {
        setenv("HARK_VAD", "0", 1)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-resolve-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .txt)
        let backend = SerializedBackend(FakeBackend("hi"))
        let transcriber = LiveTranscriber(
            backend: backend, writer: writer, ownsBackend: false, ownsWriter: false,
            speaker: "Others", language: nil, translate: false, captureFormat: format,
            silenceThresholdDBFS: -50, labelName: "t", resolver: FixedResolver("Speaker 2"),
            useVad: false, pauseSeconds: 0.5, maxWindowSeconds: 2, minSegmentSeconds: 0.2)

        try transcriber.write(loud(0.5)); try transcriber.write(quiet(0.5))
        try transcriber.finalize(); try transcriber.rethrowErrors()
        try writer.close()

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.contains("Speaker 2: hi"))  // resolver overrode the fixed "Others"
        #expect(!contents.contains("Others"))
    }
}

@Suite("Interactive captions")
struct InteractiveCaptionTests {
    private let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)

    private func loud(_ seconds: Double) -> Data {
        let samples = Int(seconds * 16000)
        var data = Data(capacity: samples * 2)
        for i in 0..<samples {
            withUnsafeBytes(of: Int16(i % 2 == 0 ? 16000 : -16000).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }
    private func quiet(_ seconds: Double) -> Data { Data(count: Int(seconds * 16000) * 2) }

    /// Builds a transcriber that persists to `transcriptPath` and (when
    /// `screenEcho`) mirrors captions to `screenURL`, feeds one speech turn, and
    /// returns (screen text, transcript-file text).
    private func run(
        screenEcho: Bool, speaker: String?, transcriptPath: String, screenURL: URL
    ) throws -> (screen: String, file: String) {
        setenv("HARK_VAD", "0", 1)  // deterministic amplitude segmenter (offline)
        FileManager.default.createFile(atPath: screenURL.path, contents: nil)
        let screen = try FileHandle(forWritingTo: screenURL)

        let writer = try LiveTranscriptWriter(destination: .file(transcriptPath), format: .txt)
        let backend = SerializedBackend(FakeBackend("hello"))
        let transcriber = LiveTranscriber(
            backend: backend, writer: writer, ownsBackend: false, ownsWriter: false,
            speaker: speaker, language: nil, translate: false, captureFormat: format,
            silenceThresholdDBFS: -50, labelName: "t", useVad: false,
            screenEcho: screenEcho, screen: screen,
            pauseSeconds: 0.5, maxWindowSeconds: 2, minSegmentSeconds: 0.2)

        try transcriber.write(loud(0.5)); try transcriber.write(quiet(0.5))
        try transcriber.finalize(); try transcriber.rethrowErrors()
        try writer.close()
        backend.shutdown()
        try screen.close()  // flush before reading

        return (
            try String(contentsOf: screenURL, encoding: .utf8),
            try String(contentsOfFile: transcriptPath, encoding: .utf8)
        )
    }

    /// PRD §6.9: interactive mirrors each segment to the screen while the
    /// transcript writer still persists to the file (the labeled variant).
    @Test func echoesLabeledCaptionToScreenWhileWritingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-caption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (screen, file) = try run(
            screenEcho: true, speaker: "You",
            transcriptPath: dir.appendingPathComponent("out.txt").path,
            screenURL: dir.appendingPathComponent("screen.txt"))
        #expect(screen.contains("You: hello"))  // shown on screen
        #expect(file.contains("You: hello"))     // and persisted
    }

    /// Without a speaker the caption is plain text (no label prefix).
    @Test func echoesPlainCaptionWhenNoSpeaker() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-caption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (screen, file) = try run(
            screenEcho: true, speaker: nil,
            transcriptPath: dir.appendingPathComponent("out.txt").path,
            screenURL: dir.appendingPathComponent("screen.txt"))
        #expect(screen.contains("hello"))
        #expect(!screen.contains(":"))  // no label prefix
        #expect(file.contains("hello"))
    }

    /// With echo disabled the screen stays empty while the file is still written.
    @Test func noScreenEchoWhenDisabled() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-caption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (screen, file) = try run(
            screenEcho: false, speaker: "You",
            transcriptPath: dir.appendingPathComponent("out.txt").path,
            screenURL: dir.appendingPathComponent("screen.txt"))
        #expect(screen.isEmpty)             // nothing mirrored to the screen
        #expect(file.contains("You: hello"))  // transcript still persisted
    }
}

@Suite("Gain normalization")
struct GainNormalizerTests {
    private let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)

    private func pcm16(_ samples: [Int16]) -> Data {
        var d = Data(capacity: samples.count * 2)
        for s in samples { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }
    private func peak16(_ data: Data) -> Int {
        stride(from: 0, to: data.count, by: 2).reduce(0) { m, i in
            let s = Int16(littleEndian: data.subdata(in: i..<(i + 2)).withUnsafeBytes { $0.load(as: Int16.self) })
            return max(m, abs(Int(s)))
        }
    }

    @Test func boostsQuietTowardTargetWithinCap() {
        // peak 328 ≈ -40 dBFS; target -3 dBFS wants ~70x, but +20 dB cap = 10x.
        let quiet = pcm16(Array(repeating: 0, count: 0) + [328, -300, 200, -328, 150, -100])
        let out = GainNormalizer.normalize(quiet, format: format)
        #expect(peak16(out) > peak16(quiet))      // boosted
        #expect(peak16(out) <= 3290)               // capped at ~10x (328*10)
        #expect(peak16(out) >= 3270)               // ~10x applied
    }

    @Test func leavesLoudUnchanged() {
        let loud = pcm16([30000, -30000, 25000])   // already above -3 dBFS target
        #expect(GainNormalizer.normalize(loud, format: format) == loud)
    }

    @Test func leavesSilenceUnchanged() {
        let silence = Data(count: 2000)
        #expect(GainNormalizer.normalize(silence, format: format) == silence)
    }

    @Test func envOptOut() {
        #expect(GainNormalizer.isEnabled(environment: ["HARK_GAIN": "off"]) == false)
        #expect(GainNormalizer.isEnabled(environment: ["HARK_GAIN": "OFF"]) == false)
        #expect(GainNormalizer.isEnabled(environment: [:]) == true)
    }
}

/// Gated: replays the committed quiet recording through the real VAD at the
/// (lowered) default threshold and asserts the previously-dropped quiet phrase
/// now opens a segment. Runs only with HARK_TEST_VAD=1 on Apple Silicon.
@Suite("VAD threshold recovery (integration)")
struct VadThresholdRecoveryTests {
    @Test func lowThresholdSegmentsQuietRegion() throws {
        guard ProcessInfo.processInfo.environment["HARK_TEST_VAD"] == "1",
            Platform.isAppleSilicon
        else { return }
        let mp3 = "Tests/ManualTests/test3.mp3"
        guard FileManager.default.fileExists(atPath: mp3) else { return }

        let wav = try AudioPipeline.normalizeFileForWhisper(mp3)  // 16 kHz mono 16-bit
        defer { try? FileManager.default.removeItem(at: wav) }
        let handle = try FileHandle(forReadingFrom: wav)
        _ = try WAVStreamParser.parseHeader { handle.readData(ofLength: $0) }
        let pcm = handle.readDataToEndOfFile()
        try handle.close()

        let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)
        let byteRate = format.byteRate  // 32000
        let start = min(pcm.count, 80 * byteRate)
        let end = min(pcm.count, 94 * byteRate)
        guard end > start else { return }
        let slice = pcm.subdata(in: start..<end)  // the quiet dropped region

        let classifier = try FluidVadClassifier.makeLoading(
            pauseSeconds: 0.7, maxWindowSeconds: 12, threshold: 0.5)
        let captured = Captured()
        let segmenter = VadSegmenter(
            format: format, classifier: classifier, resample: { samples, _ in samples },
            maxWindowSeconds: 12, minSegmentSeconds: 0.4)
        segmenter.onSegment = { data, s, e in captured.append((data.count, s, e)) }

        var offset = 0
        while offset < slice.count {
            let n = min(8192, slice.count - offset)
            segmenter.consume(slice.subdata(in: offset..<(offset + n)))
            offset += n
        }
        segmenter.finish()
        #expect(!captured.all().isEmpty)  // quiet phrase now opens a segment at threshold 0.5
    }
}

@Suite("Speaker labels parsing")
struct SpeakerLabelsParseTests {
    @Test func defaultsAndOverrides() {
        #expect(SpeakerLabels.parse(nil).you == "You")
        #expect(SpeakerLabels.parse(nil).others == "Others")
        let custom = SpeakerLabels.parse("Me, Them")
        #expect(custom.you == "Me")
        #expect(custom.others == "Them")
        // Malformed -> defaults (validation rejects these before we get here).
        #expect(SpeakerLabels.parse("solo").you == "You")
    }
}

/// Gated check that the real Silero VAD model loads and runs. Runs only when
/// HARK_TEST_VAD=1 and on Apple Silicon (downloads CoreML on first use).
@Suite("VAD (integration)")
struct VadIntegrationTests {
    @Test func loadsAndProcessesARealWindow() throws {
        guard ProcessInfo.processInfo.environment["HARK_TEST_VAD"] == "1",
            Platform.isAppleSilicon
        else { return }
        let classifier = try FluidVadClassifier.makeLoading(
            pauseSeconds: 0.7, maxWindowSeconds: 12, threshold: 0.5)
        let window = [Float](repeating: 0, count: classifier.windowSamples)
        let box = UncheckedSendableBox(value: classifier)
        _ = try RunLoopBridge.runBlocking(timeout: 60) {
            try await box.value.process(window)
        }
    }
}
