import AVFoundation
import Encoders
import Foundation
import Testing

@testable import CLI

/// Stereo input must be averaged into mono, not reduced to channel 0 — a
/// recording with the speaker only on the right channel used to decode as
/// silence.
@Suite("Stereo downmix")
struct StereoDownmixTests {
    private let sampleRate = 16000.0
    private let frames = 16000  // 1 s
    private let amplitude: Float = 0.5  // -9.03 dBFS RMS as a sine

    @Test func rightChannelOnlySurvivesAtHalfLevel() throws {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let stereo = work.appendingPathComponent("right-only.wav")
        try writeStereoTone(left: 0, right: amplitude, to: stereo)

        let level = try monoDBFS(ofFileAt: stereo)
        #expect(level > -60, "right-channel-only input decoded as silence (\(level) dBFS)")
        // Averaging two channels where only one carries signal halves it: -6 dB
        // against the -9.03 dBFS source channel. Selecting channel 0 would be
        // silence, selecting channel 1 would be -9.03.
        #expect(abs(level - (sineDBFS(amplitude) - 6.02)) < 0.5, "got \(level) dBFS")
    }

    @Test func identicalChannelsKeepTheirLevel() throws {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let stereo = work.appendingPathComponent("dual-mono.wav")
        try writeStereoTone(left: amplitude, right: amplitude, to: stereo)

        // Averaging (not summing) leaves a dual-mono file at its original level.
        let level = try monoDBFS(ofFileAt: stereo)
        #expect(abs(level - sineDBFS(amplitude)) < 0.5, "got \(level) dBFS")
    }

    @Test func downmixAveragesInterleavedChannels() throws {
        let stereoFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2,
                interleaved: true))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4))
        source.frameLength = 4
        let samples = try #require(source.floatChannelData)
        for frame in 0..<4 {
            samples[0][frame * 2] = 0  // left silent
            samples[0][frame * 2 + 1] = 1  // right full scale
        }
        let monoFormat = try #require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let destination = try #require(AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 4))

        AudioPipeline.downmixToMono(source, into: destination)

        #expect(destination.frameLength == 4)
        let mono = try #require(destination.floatChannelData)
        for frame in 0..<4 { #expect(abs(mono[0][frame] - 0.5) < 0.0001) }
    }

    /// The destination buffer is reused for every chunk, so a downmix that
    /// cannot read the source must not leave a frame count behind: the caller
    /// would hand the converter the samples of the previous chunk.
    @Test func unreadableSourceLeavesNoStaleFrameCount() throws {
        let monoFormat = try #require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let destination = try #require(AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 8))
        destination.frameLength = 4
        let previous = try #require(destination.floatChannelData)
        for frame in 0..<4 { previous[0][frame] = 0.25 }

        // Int16 input has no floatChannelData, so averaging cannot run.
        let int16Format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 2,
                interleaved: true))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: 8))
        source.frameLength = 8

        AudioPipeline.downmixToMono(source, into: destination)

        #expect(
            destination.frameLength == 0,
            "downmix advertised \(destination.frameLength) frames it never wrote")
    }

    // MARK: Helpers

    private func makeWorkDirectory() throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-downmix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    /// Writes a 1 s 16 kHz stereo WAV carrying a 440 Hz tone scaled per channel.
    private func writeStereoTone(left: Float, right: Float, to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            let tone = Float(sin(2 * .pi * 440 * Double(frame) / sampleRate))
            channels[0][frame] = left * tone
            channels[1][frame] = right * tone
        }
        try file.write(from: buffer)
    }

    /// Decodes a file through the shared 16 kHz mono pipeline and measures the
    /// RMS level of the result.
    private func monoDBFS(ofFileAt url: URL) throws -> Double {
        let normalized = try AudioPipeline.normalizeFileForWhisper(url.path)
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

/// The offline diarized batch path must fold channels the same way plain
/// transcription does. `BatchDiarization.diarizeToCues` used to hand the file
/// straight to FluidAudio's `AudioConverter`, which resolves a multi-channel
/// source through `AVAudioConverter` and so keeps channel 0 — a speaker
/// recorded only on the right channel diarized as silence and produced no cues.
///
/// Gated like `SayDiarizationTests`: it runs `say` and loads the CoreML
/// diarization and ASR models, so it is off in the normal suite. Enable with
/// `HARK_TEST_DIARIZE=1` on Apple Silicon. SKIPs cleanly when `say` is
/// unavailable.
@Suite("Stereo downmix (diarized batch, integration)")
struct StereoDownmixDiarizationTests {
    /// Parakeet: on-device, needs no ggml model in `~/.hark` and no Speech
    /// authorization, so the gate alone decides whether this runs.
    private let engine = "parakeet"

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["HARK_TEST_DIARIZE"] == "1" && Platform.isAppleSilicon
    }

    @Test func rightChannelOnlySpeechStillDiarizesAndTranscribes() throws {
        guard enabled else { return }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-downmix-diar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let aiff = work.appendingPathComponent("speech.aiff")
        guard say(
            "The quick brown fox jumps over the lazy dog. "
                + "This speaker was recorded on the right channel only, "
                + "and the transcript must still contain these words.",
            to: aiff)
        else { return }  // `say` unavailable -> skip

        let stereo = work.appendingPathComponent("right-only.wav")
        try writeRightChannelOnly(decoding: aiff, to: stereo)

        let cues = try BatchDiarization.diarizeToCues(
            audioPath: stereo.path, engineName: engine, modelFlag: nil, language: nil,
            translate: false, maxSpeakers: nil, threshold: nil)

        #expect(!cues.isEmpty, "right-channel-only speech produced no diarized cues")
        let transcript = cues.map(\.text).joined(separator: " ").lowercased()
        #expect(!transcript.isEmpty, "diarized cues carried no transcript")
        #expect(transcript.contains("fox"), "got: \(transcript)")
    }

    // MARK: Helpers

    /// Synthesizes `text` to `url` with `say`. False if it is unavailable.
    private func say(_ text: String, to url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Re-encodes `source` as a stereo WAV holding silence on the left channel
    /// and the speech on the right — the recording shape that used to decode as
    /// silence.
    private func writeRightChannelOnly(decoding source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let sampleRate = input.processingFormat.sampleRate
        let frames = AVAudioFrameCount(input.length)
        let mono = try #require(
            AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frames))
        try input.read(into: mono)

        let stereoFormat = try #require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let stereo = try #require(
            AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: mono.frameLength))
        stereo.frameLength = mono.frameLength
        let speech = try #require(mono.floatChannelData)
        let channels = try #require(stereo.floatChannelData)
        for frame in 0..<Int(mono.frameLength) {
            channels[0][frame] = 0  // left silent
            channels[1][frame] = speech[0][frame]
        }

        let file = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        try file.write(from: stereo)
    }
}
