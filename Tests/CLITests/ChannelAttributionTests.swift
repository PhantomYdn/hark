import AVFoundation
import Encoders
import FluidAudio
import Foundation
import Testing

@testable import CLI

/// Runs `body` and returns the `HarkError` it threw, recording an issue if it
/// throws something else or nothing at all. Used instead of `#expect(throws:)`'s
/// return value, which only carries the error on newer swift-testing versions.
private func harkError(_ body: () throws -> Void) -> HarkError? {
    do {
        try body()
        Issue.record("expected a HarkError, but nothing was thrown")
        return nil
    } catch let error as HarkError {
        return error
    } catch {
        Issue.record("expected a HarkError, got \(error)")
        return nil
    }
}

/// Runs `body` and returns whatever it threw, recording an issue if it threw
/// nothing. Used where *which* error comes out is the assertion.
private func thrownError(_ body: () throws -> Void) -> Error? {
    do {
        try body()
        Issue.record("expected an error, but nothing was thrown")
        return nil
    } catch {
        return error
    }
}

/// `-i FILE --speakers --speaker-mode source` (PRD §6.7c): a two-channel
/// recording holds the microphone on channel 0 and the call on channel 1, so
/// each channel is read on its own and labeled by origin. Anything else has
/// nothing to attribute and is a usage error, as it is on the live path.
@Suite("Source attribution from file channels")
struct ChannelAttributionTests {
    private let sampleRate = 16000.0

    @Test func aMonoFileCannotBeAttributed() throws {
        let error = harkError { try BatchDiarization.requireSourceChannels(1, path: "meeting.wav") }
        #expect(error?.code == .usage)
        #expect(error?.message.contains("'meeting.wav' has 1 channel.") == true)
    }

    @Test func moreThanTwoChannelsCannotBeAttributed() throws {
        let error = harkError {
            try BatchDiarization.requireSourceChannels(6, path: "surround.wav")
        }
        #expect(error?.code == .usage)
        #expect(error?.message.contains("'surround.wav' has 6 channels.") == true)
    }

    @Test func twoChannelsAreAccepted() throws {
        try BatchDiarization.requireSourceChannels(2, path: "call.wav")
    }

    @Test func copyChannelTakesOneChannelInsteadOfTheAverage() throws {
        for interleaved in [true, false] {
            let stereoFormat = try #require(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2,
                    interleaved: interleaved))
            let source = try #require(AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4))
            source.frameLength = 4
            let samples = try #require(source.floatChannelData)
            for frame in 0..<4 {
                if interleaved {
                    samples[0][frame * 2] = 0.25  // left
                    samples[0][frame * 2 + 1] = 1  // right
                } else {
                    samples[0][frame] = 0.25
                    samples[1][frame] = 1
                }
            }
            let monoFormat = try #require(
                AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
            let destination = try #require(
                AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 4))

            AudioPipeline.copyChannel(0, of: source, into: destination)
            let mono = try #require(destination.floatChannelData)
            #expect(destination.frameLength == 4)
            // 0.25, not the 0.625 average of both channels.
            for frame in 0..<4 { #expect(abs(mono[0][frame] - 0.25) < 0.0001) }

            AudioPipeline.copyChannel(1, of: source, into: destination)
            for frame in 0..<4 { #expect(abs(mono[0][frame] - 1) < 0.0001) }

            // A channel the file does not have is silence, never a crash.
            AudioPipeline.copyChannel(2, of: source, into: destination)
            for frame in 0..<4 { #expect(mono[0][frame] == 0) }
        }
    }

    @Test func decodingOneChannelLeavesTheOtherOut() throws {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let stereo = work.appendingPathComponent("two-voices.wav")
        let frames = Int(sampleRate)  // 1 s
        let tone = (0..<frames).map { Float(sin(2 * .pi * 440 * Double($0) / sampleRate)) }
        try writeStereo(left: tone.map { $0 * 0.5 }, right: [Float](repeating: 0, count: frames),
            to: stereo)

        // Channel 0 carries the tone at its own level — not the -6 dB the
        // averaged downmix would produce — and channel 1 is silent.
        let left = try monoDBFS(ofFileAt: stereo, channel: 0)
        #expect(abs(left - sineDBFS(0.5)) < 0.5, "got \(left) dBFS")
        let right = try monoDBFS(ofFileAt: stereo, channel: 1)
        #expect(right < -90, "channel 1 was silent but decoded at \(right) dBFS")
        let mixed = try monoDBFS(ofFileAt: stereo, channel: nil)
        #expect(abs(mixed - (sineDBFS(0.5) - 6.02)) < 0.5, "got \(mixed) dBFS")
    }

    // MARK: Helpers

    fileprivate func makeWorkDirectory() throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-source-attr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    /// Writes two equal-length Float channels as a 16 kHz stereo WAV.
    fileprivate func writeStereo(left: [Float], right: [Float], to url: URL) throws {
        try writeWav(channels: [left, right], to: url)
    }

    /// Writes one Float track per channel as a 16 kHz 16-bit WAV. Shorter
    /// tracks are padded with silence.
    fileprivate func writeWav(channels tracks: [[Float]], to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: tracks.count,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        let format = try #require(
            AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: AVAudioChannelCount(tracks.count)))
        let frames = tracks.map(\.count).max() ?? 0
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(buffer.floatChannelData)
        for (index, track) in tracks.enumerated() {
            for frame in 0..<frames {
                channels[index][frame] = frame < track.count ? track[frame] : 0
            }
        }
        try file.write(from: buffer)
    }

    /// Decodes a file through the shared 16 kHz mono pipeline (optionally one
    /// channel of it) and measures the RMS level of the result.
    private func monoDBFS(ofFileAt url: URL, channel: Int?) throws -> Double {
        let normalized = try AudioPipeline.normalizeFileForWhisper(url.path, channel: channel)
        defer { try? FileManager.default.removeItem(at: normalized) }
        let handle = try FileHandle(forReadingFrom: normalized)
        defer { try? handle.close() }
        _ = try WAVStreamParser.parseHeader { handle.readData(ofLength: $0) }
        let pcm = handle.readDataToEndOfFile()
        guard pcm.count >= 2 else { return -.infinity }
        var sumOfSquares = 0.0
        for offset in stride(from: 0, to: pcm.count - 1, by: 2) {
            let sample = pcm.withUnsafeBytes {
                Int16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int16.self))
            }
            let value = Double(sample) / 32768.0
            sumOfSquares += value * value
        }
        return 20 * log10((sumOfSquares / Double(pcm.count / 2)).squareRoot())
    }

    /// RMS level of a full-cycle sine of the given amplitude, in dBFS.
    private func sineDBFS(_ amplitude: Float) -> Double {
        20 * log10(Double(amplitude) / 2.0.squareRoot())
    }
}

/// The dispatch itself, from the command line down: `-i FILE --speakers
/// --speaker-mode source` has to reach the per-channel path, and no other mode
/// may. The probe is the channel rule, which `runBatchDiarization` applies from
/// the file's format before it touches an engine or a model. The model flag
/// points at a path that cannot exist, so anything that gets past that rule
/// fails in the engine preflight with a `TranscriptionError`: which of the two
/// errors comes out says which branch ran. Neither outcome needs a model, a
/// network or Apple Silicon, and the config and environment are left out so the
/// machine's own `hark config` cannot change the answer.
@Suite("Source attribution dispatch")
struct ChannelAttributionDispatchTests {
    private let helpers = ChannelAttributionTests()
    private let missingModel = "/nonexistent/hark-tests/ggml-base.bin"

    @Test func sourceModeRefusesAMonoFileBeforeReachingTheEngine() throws {
        let work = try helpers.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let mono = work.appendingPathComponent("mixed.wav")
        try helpers.writeWav(channels: [tone()], to: mono)
        let transcript = work.appendingPathComponent("out.txt").path

        let error = thrownError {
            try runBatch(["--speaker-mode", "source"], input: mono, transcript: transcript)
        }
        let hark = try #require(error as? HarkError, "got \(String(describing: error))")
        #expect(hark.code == .usage)
        #expect(hark.message.contains("has 1 channel."))
        #expect(!FileManager.default.fileExists(atPath: transcript))
    }

    @Test func sourceModeAcceptsATwoChannelFileAndGoesOnToTheEngine() throws {
        let work = try helpers.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let stereo = work.appendingPathComponent("call.wav")
        try helpers.writeWav(channels: [tone(), tone()], to: stereo)
        let transcript = work.appendingPathComponent("out.txt").path

        let error = thrownError {
            try runBatch(["--speaker-mode", "source"], input: stereo, transcript: transcript)
        }
        // Past the channel rule and into the engine: the missing model, not a
        // usage error about channels.
        #expect(error is TranscriptionError, "got \(String(describing: error))")
    }

    @Test func theChannelRuleIsSourceModeOnly() throws {
        let work = try helpers.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let mono = work.appendingPathComponent("mixed.wav")
        try helpers.writeWav(channels: [tone()], to: mono)
        let transcript = work.appendingPathComponent("out.txt").path

        // The same mono file `source` refuses: `auto` diarizes it acoustically,
        // so it must reach the engine instead.
        for mode in ["auto", "acoustic"] {
            let error = thrownError {
                try runBatch(["--speaker-mode", mode], input: mono, transcript: transcript)
            }
            #expect(error is TranscriptionError, "\(mode): got \(String(describing: error))")
        }
    }

    /// The mode resolves from the environment and the config file too, so a
    /// `source` set once for live captures refuses every mono file from then on.
    /// That is the breaking half of this change and it must not depend on the
    /// flag being typed.
    @Test func aConfiguredSourceModeRefusesAMonoFileToo() throws {
        let work = try helpers.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let mono = work.appendingPathComponent("mixed.wav")
        try helpers.writeWav(channels: [tone()], to: mono)
        let transcript = work.appendingPathComponent("out.txt").path

        var config = Configuration()
        config.speakerMode = "source"
        for (environment, configuration) in [
            (["HARK_SPEAKER_MODE": "source"], Configuration()),
            ([:], config),
        ] {
            let error = thrownError {
                try runBatch(
                    [], input: mono, transcript: transcript,
                    environment: environment, config: configuration)
            }
            let hark = try #require(error as? HarkError, "got \(String(describing: error))")
            #expect(hark.code == .usage)
            #expect(hark.message.contains("has 1 channel."))
        }
    }

    // MARK: Helpers

    /// Parses real CLI arguments and runs the `-i FILE --speakers` dispatch on
    /// them, with the user's config and environment left out of it unless the
    /// caller supplies them.
    private func runBatch(
        _ arguments: [String], input: URL, transcript: String,
        environment: [String: String] = [:], config: Configuration = Configuration()
    ) throws {
        let hark = try Hark.parse(
            ["-i", input.path, "-t", transcript, "--speakers", "--model", missingModel]
                + arguments)
        let settings = try ResolvedSettings.resolve(
            from: hark, environment: environment, config: config)
        try hark.runBatchDiarization(
            audioPath: input.path, to: .file(transcript), settings: settings)
    }

    /// A quarter-second 440 Hz tone: enough to be a real audio file.
    private func tone() -> [Float] {
        // Spelled out with explicit types: as one expression the CI runner's
        // compiler gives up type-checking it ("unable to type-check this
        // expression in reasonable time") and the whole suite fails to build.
        let step: Double = 2.0 * Double.pi * 440.0 / 16000.0
        return (0..<4000).map { (i: Int) -> Float in Float(sin(Double(i) * step)) * 0.5 }
    }
}

/// End to end on a real two-channel recording: two `say` voices, one per
/// channel, talking over each other once. Attribution must keep both sides and
/// both overlapping turns — the case a mixed single-channel file cannot
/// represent at all, since one track can only carry one voice at a time.
///
/// Gated like `SayDiarizationTests`: it runs `say` and loads the CoreML
/// diarization and ASR models, so it is off in the normal suite. Enable with
/// `HARK_TEST_DIARIZE=1` on Apple Silicon. SKIPs cleanly when `say` or a voice
/// is unavailable.
@Suite("Source attribution from file channels (integration)")
struct ChannelAttributionIntegrationTests {
    /// Parakeet: on-device, needs no ggml model in `~/.hark` and no Speech
    /// authorization, so the gate alone decides whether this runs.
    private let engine = "parakeet"
    private let sampleRate = 16000.0

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["HARK_TEST_DIARIZE"] == "1" && Platform.isAppleSilicon
    }

    @Test func eachChannelKeepsItsOwnSpeakerEvenWhenTheyOverlap() throws {
        guard enabled else { return }
        let helpers = ChannelAttributionTests()
        let work = try helpers.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }

        // The mic (channel 0) and the call (channel 1) talk over each other from
        // 8.5 s: the second turn of each is simultaneous.
        guard let micFirst = synth(voice: "Daniel", text: "Hi there, thanks for joining today."),
            let micSecond = synth(
                voice: "Daniel", text: "Yes, I pushed the fix to the branch this morning."),
            let callFirst = synth(
                voice: "Samantha", text: "Good morning, can everybody hear me clearly?"),
            let callSecond = synth(
                voice: "Samantha", text: "Great, then let us ship it before the release.")
        else { return }  // `say` or a voice unavailable -> skip

        let file = work.appendingPathComponent("call.wav")
        try helpers.writeStereo(
            left: lay([(micFirst, 0.0), (micSecond, 7.0)], seconds: 13),
            right: lay([(callFirst, 3.3), (callSecond, 8.5)], seconds: 13),
            to: file)

        let cues = try BatchDiarization.attributeChannels(
            audioPath: file.path, engineName: engine, modelFlag: nil, language: nil,
            translate: false, threshold: nil, labels: .default)

        #expect(cues.allSatisfy { $0.speaker == "You" || $0.speaker == "Others" })
        #expect(cues.map(\.start) == cues.map(\.start).sorted(), "cues are not in time order")
        let you = text(of: cues, speaker: "You")
        let others = text(of: cues, speaker: "Others")
        #expect(you.contains("joining"), "You: \(you)")
        #expect(you.contains("branch"), "You: \(you)")
        #expect(others.contains("clearly"), "Others: \(others)")
        // The overlapping turn: a mixed track loses it behind the mic's voice.
        #expect(others.contains("ship"), "Others: \(others)")
        #expect(!you.contains("ship"), "the call's words leaked into You: \(you)")

        // And the two simultaneous turns really do overlap in time.
        let branch = try #require(cues.first { $0.text.lowercased().contains("branch") })
        let ship = try #require(cues.first { $0.text.lowercased().contains("ship") })
        #expect(ship.start < branch.end, "the overlapping turns were serialized")
    }

    // MARK: Helpers

    /// Synthesizes one line to 16 kHz mono Float via `say`. Nil if the
    /// voice/synthesis is unavailable (→ test SKIPs).
    private func synth(voice: String, text: String) -> [Float]? {
        let aiff = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-say-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", aiff.path, text]
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let samples = (try? AudioConverter().resampleAudioFile(aiff)) ?? []
        return samples.isEmpty ? nil : samples
    }

    /// Lays each utterance into a silent track of `seconds` at its start time.
    private func lay(_ utterances: [([Float], Double)], seconds: Double) -> [Float] {
        var track = [Float](repeating: 0, count: Int(seconds * sampleRate))
        for (samples, start) in utterances {
            let offset = Int(start * sampleRate)
            for (index, sample) in samples.enumerated() where offset + index < track.count {
                track[offset + index] += sample
            }
        }
        return track
    }

    private func text(of cues: [TranscriptCue], speaker: String) -> String {
        cues.filter { $0.speaker == speaker }.map(\.text).joined(separator: " ").lowercased()
    }
}

/// Two tracks of the same recording can put cues at the same instant — that is
/// what overlapping speech is — and `sorted` is not stable, so the merge has to
/// decide the order itself or the same file can produce two different
/// transcripts.
@Suite("Attributed cue merge order")
struct CueMergeOrderTests {
    private func cues(_ label: String, starts: [Double]) -> [TranscriptCue] {
        starts.enumerated().map {
            TranscriptCue(start: $1, end: $1 + 1, text: "\(label) \($0)", speaker: label)
        }
    }

    /// Enough cues sharing one start to leave an unstable sort no room to get
    /// away with it: the microphone's track comes first, in its own order.
    @Test func cuesAtTheSameInstantFollowTheTrackOrder() {
        let mic = cues("You", starts: Array(repeating: 4.0, count: 64))
        let call = cues("Others", starts: Array(repeating: 4.0, count: 64))

        let merged = BatchDiarization.merge([mic, call])

        #expect(merged.map(\.text) == (mic + call).map(\.text))
    }

    /// The offline-live path writes the same two tracks from a live capture, and
    /// it used to append the call first, so one convention held on a file and the
    /// opposite one on a recording. `mergeTracks` is now the only place that
    /// decides, and it decides microphone first.
    @Test func offlineLiveTracksComeOutMicrophoneFirst() {
        let mic = cues("You", starts: Array(repeating: 4.0, count: 16))
        let system = cues("Others", starts: Array(repeating: 4.0, count: 16))

        let merged = BatchDiarization.mergeTracks(mic: mic, system: system)

        #expect(merged.map(\.text) == (mic + system).map(\.text))
    }

    /// A capture without `--speakers` has no microphone track at all, so the
    /// helper has to leave a single track exactly as it found it.
    @Test func aMissingMicrophoneTrackLeavesTheCallUntouched() {
        let system = cues("Others", starts: [0, 1, 2])

        let merged = BatchDiarization.mergeTracks(mic: [], system: system)

        #expect(merged.map(\.text) == system.map(\.text))
    }

    /// The tiebreak must not disturb the ordering that matters: later audio
    /// still comes later, whichever track it arrived on.
    @Test func startTimeStillWins() {
        let mic = cues("You", starts: [0, 2, 4])
        let call = cues("Others", starts: [1, 3, 5])

        let merged = BatchDiarization.merge([mic, call])

        #expect(merged.map(\.start) == [0, 1, 2, 3, 4, 5])
        #expect(merged.map(\.speaker) == ["You", "Others", "You", "Others", "You", "Others"])
    }
}

/// Where the per-channel diarizer cannot run — Intel, or its model failing to
/// load — source attribution must not depend on it: each channel is transcribed
/// whole by the ordinary backend and labeled by origin. Driven with a throwing
/// diarizer factory and a stub backend, so no model or Apple Silicon is needed.
@Suite("Source attribution without a diarizer")
struct ChannelAttributionFallbackTests {
    private let helpers = ChannelAttributionTests()

    /// Answers by the level of the channel it is handed: the loud one (the
    /// mic) speaks at 2 s, the quiet one (the call) at 1 s, each followed by a
    /// placeholder the transcript must not keep.
    private final class LevelBackend: TranscriptionBackend {
        let capabilities = EngineCapabilities(autoDetect: true, translate: true, usesModelFile: true)
        let label = "level stub"
        var formats: [TranscriptOutputFormat] = []

        func transcribe(
            wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
        ) throws -> String {
            formats.append(format)
            let file = try AVAudioFile(forReading: wavFile)
            let buffer = try #require(
                AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = try #require(buffer.floatChannelData)
            let peak = (0..<Int(buffer.frameLength)).map { abs(samples[0][$0]) }.max() ?? 0
            let cue =
                peak > 0.3
                ? TranscriptCue(start: 2, end: 3, text: "mic words")
                : TranscriptCue(start: 1, end: 2, text: "call words")
            return TranscriptFormatting.render(
                cues: [cue, TranscriptCue(start: 4, end: 5, text: "[BLANK_AUDIO]")],
                fullText: "", format: format)
        }

        func shutdown() {}
    }

    @Test func eachChannelIsTranscribedWholeWhenTheDiarizerCannotLoad() throws {
        let work = try helpers.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let stereo = work.appendingPathComponent("call.wav")
        let step: Double = 2.0 * Double.pi * 440.0 / 16000.0
        let tone = (0..<8000).map { (i: Int) -> Float in Float(sin(Double(i) * step)) }
        try helpers.writeStereo(left: tone.map { $0 * 0.8 }, right: tone.map { $0 * 0.1 }, to: stereo)
        let backend = LevelBackend()
        var attempts = 0

        let cues = try BatchDiarization.attributeChannels(
            audioPath: stereo.path, backend: backend, language: nil, translate: false,
            labels: SpeakerLabels(you: "Me", others: "Them")
        ) {
            attempts += 1
            throw HarkError.unavailable("no diarizer in tests")
        }

        // One try at the diarizer, then one whole-file srt call per channel.
        #expect(attempts == 1)
        #expect(backend.formats == [.srt, .srt])
        // Labeled by channel, merged by time, placeholders dropped.
        #expect(cues.map(\.speaker) == ["Them", "Me"])
        #expect(cues.map(\.text) == ["call words", "mic words"])
        #expect(cues.map(\.start) == [1, 2])
    }

    @Test func srtOutputReadsBackIntoCues() {
        let srt = TranscriptFormatting.render(
            cues: [
                TranscriptCue(start: 0.5, end: 1.25, text: "Hello there."),
                TranscriptCue(start: 3661.001, end: 3662, text: "An hour later."),
            ], fullText: "", format: .srt)
        let cues = TranscriptFormatting.cues(fromSRT: srt + "\n\n")
        #expect(cues.map(\.text) == ["Hello there.", "An hour later."])
        #expect(cues.map(\.start) == [0.5, 3661.001])
        #expect(cues.map(\.end) == [1.25, 3662])
        // whisper-cli's own srt: a leading space and a cue split over two lines.
        let whisper = "1\r\n00:00:01,000 --> 00:00:02,500\r\n Two\r\nlines\r\n\r\n"
        let parsed = TranscriptFormatting.cues(fromSRT: whisper)
        #expect(parsed.map(\.text) == ["Two lines"])
        #expect(parsed.map(\.start) == [1])
    }
}
