import AVFoundation
import Encoders
import FluidAudio
import Foundation
import Testing

@testable import CLI

/// A diarized span shorter than the recognizer's own floor used to kill the whole
/// run: hark skipped only spans under 0.1 s, while FluidAudio's Parakeet rejects
/// anything under 0.3 s with "Must be at least 300ms of 16kHz audio". Lowering
/// `minSpeechDuration` to 0.25 s put spans in [0.25, 0.3) straight into that
/// guard. The span is now padded up to whatever floor the backend declares.
///
/// Deterministic: no CoreML, no models, no audio device.
@Suite("Diarized segment padding")
struct DiarizedSegmentPaddingTests {
    /// 0.3 s at 16 kHz, what `ParakeetBackend.minimumAudioSeconds` resolves to.
    private let parakeetFloor = 4800

    private func ramp(_ count: Int) -> [Float] {
        (0..<count).map { Float($0 % 2 == 0 ? 0.5 : -0.5) }
    }

    @Test func quarterSecondSpanIsPaddedToTheEngineFloor() {
        let samples = ramp(16000)
        let slice = BatchDiarization.samplesForTranscription(
            samples, from: 2000, to: 6000, skipBelowSamples: 1600, minimumSamples: parakeetFloor)
        // 4000 samples of real speech (0.25 s) must reach the recognizer, not be
        // dropped and not be handed over below its guard.
        #expect(slice?.count == parakeetFloor)
        #expect(Array(slice![0..<4000]) == Array(samples[2000..<6000]))
        #expect(slice![4000...].allSatisfy { $0 == 0 })
    }

    @Test func spanBelowTheNoiseBoundIsStillSkipped() {
        let slice = BatchDiarization.samplesForTranscription(
            ramp(16000), from: 0, to: 1000, skipBelowSamples: 1600, minimumSamples: parakeetFloor)
        #expect(slice == nil)
    }

    @Test func longEnoughSpanIsHandedOverUntouched() {
        let samples = ramp(16000)
        let slice = BatchDiarization.samplesForTranscription(
            samples, from: 1000, to: 9000, skipBelowSamples: 1600, minimumSamples: parakeetFloor)
        #expect(slice == Array(samples[1000..<9000]))
    }

    @Test func noFloorMeansNoPadding() {
        let samples = ramp(16000)
        let slice = BatchDiarization.samplesForTranscription(
            samples, from: 0, to: 2000, skipBelowSamples: 1600, minimumSamples: 0)
        #expect(slice?.count == 2000)
        #expect(slice == Array(samples[0..<2000]))
    }

    @Test func rangePastTheEndIsClampedInsteadOfTrapping() {
        let samples = ramp(8000)
        let slice = BatchDiarization.samplesForTranscription(
            samples, from: 6000, to: 99_999, skipBelowSamples: 1600, minimumSamples: parakeetFloor)
        #expect(slice?.count == parakeetFloor)
        #expect(Array(slice![0..<2000]) == Array(samples[6000..<8000]))
        // A start past the end yields no span at all rather than a crash.
        #expect(
            BatchDiarization.samplesForTranscription(
                samples, from: 50_000, to: 99_999, skipBelowSamples: 1600,
                minimumSamples: parakeetFloor) == nil)
        // Inverted bounds are clamped to an empty span, not a negative count.
        #expect(
            BatchDiarization.samplesForTranscription(
                samples, from: 5000, to: 1000, skipBelowSamples: 1600,
                minimumSamples: parakeetFloor) == nil)
    }

    @Test func parakeetReportsFluidAudioOwnFloor() {
        // Without this the whole fix is inert: the diarized loop asks the backend
        // for its floor, so a parakeet reporting 0 pads nothing and the run dies
        // on the first sub-0.3 s span again.
        #expect(ParakeetBackend.audioFloorSeconds == ASRConstants.minimumAudioDurationSeconds)
        // That there is a floor at all, and nothing about its value. The point of
        // reading the constant is that a vendor bump moves the padding with it, so
        // any assertion a bump could leave, an upper bound included, reddens the
        // bump this test exists to tolerate.
        #expect(ParakeetBackend.audioFloorSeconds > 0)
    }

    @Test func floorTravelsThroughTheSharedBackendWrapper() {
        let shared = SerializedBackend(FloorBackend(seconds: 0.3))
        #expect(shared.minimumAudioSeconds == 0.3)
        // A backend that declares nothing inherits "no floor" from the protocol
        // extension, so whisper/apple/whisperkit spans stay unpadded.
        #expect(NoFloorBackend().minimumAudioSeconds == 0)
        #expect(SerializedBackend(NoFloorBackend()).minimumAudioSeconds == 0)
    }

    @Test func placeholderTokensFromAPaddedSpanAreNotCues() {
        // A padded 0.25 s span is mostly silence to the recognizer, so the
        // diarized path needs the same placeholder filter the live path has.
        #expect(isNonSpeechPlaceholder("[BLANK_AUDIO]"))
        #expect(isNonSpeechPlaceholder("[silence]"))
        #expect(!isNonSpeechPlaceholder("Sí."))
        #expect(!isNonSpeechPlaceholder("Yes."))
    }
}

/// The same regression at the real call site: a `say` clip whose short turns land
/// in [0.25, 0.30) s used to abort `diarizeToCues` with FluidAudio's
/// "Must be at least 300ms of 16kHz audio" and write no transcript at all.
///
/// Gated (runs `say`, loads the diarizer and Parakeet CoreML models): enable with
/// `HARK_TEST_DIARIZE=1` on Apple Silicon. SKIPs if a `say` voice is missing.
/// Asserts completion, never a particular span length, because the diarizer picks its own
/// boundaries.
@Suite("Diarized short turns (say, integration)")
struct SayShortTurnDiarizationTests {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["HARK_TEST_DIARIZE"] == "1" && Platform.isAppleSilicon
    }

    /// One line to 16 kHz mono Float via `say -o` (a file, never the speakers).
    private func synth(voice: String, text: String) -> [Float] {
        let aiff = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-shortturn-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", aiff.path, text]
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return (try? AudioConverter().resampleAudioFile(aiff)) ?? []
    }

    /// `seconds` of speech taken from the onset, so the diarized span it produces
    /// is short enough to cross the recognizer's floor.
    private func clipped(_ samples: [Float], seconds: Double) -> [Float] {
        let onset = samples.firstIndex { abs($0) > 0.015 } ?? 0
        let end = min(onset + Int(seconds * 16000), samples.count)
        return Array(samples[onset..<end])
    }

    private func writeWav(_ samples: [Float]) throws -> URL {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-shortturn-\(UUID().uuidString).wav")
        let writer = try WAVFileWriter(
            destination: .file(url),
            format: PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1))
        try writer.write(data)
        try writer.finalize()
        return url
    }

    @Test func shortAnswersDoNotAbortTheRun() throws {
        guard enabled else { return }
        let opening = synth(
            voice: "Daniel",
            text: "Good morning, I wanted to discuss the quarterly numbers with you today "
                + "before the board meeting starts.")
        let yes = synth(voice: "Paulina", text: "Sí.")
        let no = synth(voice: "Samantha", text: "No.")
        guard !opening.isEmpty, !yes.isEmpty, !no.isEmpty else { return }

        // A ladder of onset-trimmed answers: the diarizer widens each burst to its
        // own grid, so a range of speech lengths is what reliably lands one span in
        // the window that used to abort. Gaps stay above the 1.0 s label merge.
        var samples = [Float](repeating: 0, count: 9600)  // 0.6 s lead-in
        samples.append(contentsOf: opening)
        for (source, seconds) in [(no, 0.19), (yes, 0.21), (no, 0.23), (yes, 0.25)] {
            samples.append(contentsOf: [Float](repeating: 0, count: 25600))  // 1.6 s
            samples.append(contentsOf: clipped(source, seconds: seconds))
        }
        samples.append(contentsOf: [Float](repeating: 0, count: 9600))

        let wav = try writeWav(samples)
        defer { try? FileManager.default.removeItem(at: wav) }

        let cues = try BatchDiarization.diarizeToCues(
            audioPath: wav.path, engineName: "parakeet", modelFlag: nil, language: nil,
            translate: false, maxSpeakers: nil, threshold: nil)
        // Before the fix this line was never reached: the throw came out of the
        // per-span transcribe call and the whole run exited 1.
        #expect(!cues.isEmpty)
        #expect(cues.contains { $0.text.localizedCaseInsensitiveContains("quarterly") })
    }
}

/// The same padding on the live path. `LiveTranscriber` caught the engine's throw
/// per segment and dropped the span with a verbose line, so a sub-floor segment
/// was lost silently rather than aborting the run — the mirror of the batch bug,
/// and the live VAD segmenter does emit spans under its own minimum.
///
/// Deterministic: a stand-in backend, the amplitude segmenter, no models.
@Suite("Live segment padding", .serialized)
struct LiveSegmentPaddingTests {
    private let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)
    /// Well above anything the segmenter can emit here, so the segment is
    /// certainly short of it and the padding is what closes the gap.
    private let floorSeconds = 1.5

    private func loud(_ seconds: Double) -> Data {
        let samples = Int(seconds * 16000)
        var data = Data(capacity: samples * 2)
        for index in 0..<samples {
            withUnsafeBytes(of: Int16(index % 2 == 0 ? 16000 : -16000).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }

    private func quiet(_ seconds: Double) -> Data { Data(count: Int(seconds * 16000) * 2) }

    /// Feeds one short speech turn to a transcriber over `backend` and returns the
    /// transcript it wrote.
    private func transcript(over backend: FloorEnforcingBackend) throws -> String {
        setenv("HARK_VAD", "0", 1)  // the deterministic amplitude segmenter
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-livepad-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .txt)
        let transcriber = LiveTranscriber(
            backend: SerializedBackend(backend), writer: writer, ownsBackend: false,
            ownsWriter: false, speaker: nil, language: nil, translate: false,
            captureFormat: format, silenceThresholdDBFS: -50, labelName: "t",
            useVad: false, pauseSeconds: 0.3, maxWindowSeconds: 2, minSegmentSeconds: 0.2)

        try transcriber.write(loud(0.25))
        try transcriber.write(quiet(0.4))
        try transcriber.finalize()
        try transcriber.rethrowErrors()
        try writer.close()
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// A segment under the engine's floor reaches the engine padded, so the speech
    /// in it lands in the transcript instead of being dropped with a log line.
    @Test func aShortSegmentIsPaddedInsteadOfLost() throws {
        let backend = FloorEnforcingBackend(seconds: floorSeconds)

        let contents = try transcript(over: backend)

        #expect(contents.contains("No."), "the short turn never reached the transcript")
        let handed = backend.handedFrames
        #expect(handed.count == 1, "handed \(handed)")
        // Padded to exactly the floor, which also proves the segment was under it.
        #expect(handed.first == Int((floorSeconds * 16000).rounded(.up)))
    }

    /// whisper, apple and whisperkit declare no floor, so their segments must reach
    /// them exactly as the segmenter cut them.
    @Test func aBackendWithNoFloorGetsTheSegmentUntouched() throws {
        let backend = FloorEnforcingBackend(seconds: 0)

        let contents = try transcript(over: backend)

        #expect(contents.contains("No."))
        let handed = try #require(backend.handedFrames.first)
        #expect(handed > 0)
        #expect(handed < Int((floorSeconds * 16000).rounded(.up)))
    }

    @Test func paddingIsFrameAlignedInTheCaptureFormat() {
        // 44.1 kHz 16-bit stereo: 4 bytes a frame, 0.3 s is 52 920 B, already aligned.
        let stereo = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 2)
        let padded = LiveTranscriber.padToEngineFloor(Data(count: 1000), format: stereo, seconds: 0.3)
        #expect(padded.count == 52_920)
        #expect(padded.count % stereo.bytesPerFrame == 0)
        #expect(padded.prefix(1000).allSatisfy { $0 == 0 })

        // A segment already past the floor is returned as it came.
        let long = Data(repeating: 7, count: 60_000)
        #expect(LiveTranscriber.padToEngineFloor(long, format: stereo, seconds: 0.3) == long)
        // No floor, no padding.
        #expect(
            LiveTranscriber.padToEngineFloor(Data(count: 10), format: stereo, seconds: 0).count == 10)
    }
}

/// Refuses a clip under its floor the way FluidAudio's Parakeet does — a throw,
/// not an empty result — and remembers how many frames it was handed.
private final class FloorEnforcingBackend: TranscriptionBackend, @unchecked Sendable {
    let capabilities = EngineCapabilities(autoDetect: true, translate: false, usesModelFile: false)
    var label: String { "floor-enforcing" }
    let minimumAudioSeconds: Double
    private let lock = NSLock()
    private var frames: [Int] = []

    init(seconds: Double) { self.minimumAudioSeconds = seconds }

    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String {
        let length = Int((try? AVAudioFile(forReading: wavFile).length) ?? 0)
        lock.lock()
        frames.append(length)
        lock.unlock()
        guard Double(length) / 16000 >= minimumAudioSeconds else {
            throw HarkError.software(
                "Invalid audio data provided. Must be at least 300ms of 16kHz audio")
        }
        return "No."
    }

    func shutdown() {}

    var handedFrames: [Int] { lock.lock(); defer { lock.unlock() }; return frames }
}

/// Declares a floor; stands in for `ParakeetBackend` without loading CoreML.
private final class FloorBackend: TranscriptionBackend {
    let capabilities = EngineCapabilities(autoDetect: true, translate: false, usesModelFile: false)
    var label: String { "floor" }
    let minimumAudioSeconds: Double
    init(seconds: Double) { self.minimumAudioSeconds = seconds }
    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String { "" }
    func shutdown() {}
}

/// Declares no floor, like whisper/apple/whisperkit.
private final class NoFloorBackend: TranscriptionBackend {
    let capabilities = EngineCapabilities(autoDetect: true, translate: true, usesModelFile: false)
    var label: String { "no floor" }
    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String { "" }
    func shutdown() {}
}
