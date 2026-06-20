import AVFoundation
import Foundation
import Testing

@testable import Encoders

@Suite("EncodedFileWriter")
struct EncodedFileWriterTests {
    /// 0.5 s of a 440 Hz sine at 0.5 amplitude, 16-bit mono 44.1 kHz.
    private func sinePCM(frames: Int = 22050, rate: Double = 44100) -> Data {
        var data = Data(capacity: frames * 2)
        for i in 0..<frames {
            let sample = Int16(0.5 * 32767 * sin(2 * .pi * 440 * Double(i) / rate))
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func temporaryFile(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-enc-\(UUID().uuidString).\(ext)")
    }

    private func decode(_ url: URL) throws -> (frames: Int, rate: Double, channels: Int, rms: Double) {
        let file = try AVAudioFile(forReading: url)
        let frames = Int(file.length)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
            channels: file.processingFormat.channelCount, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let channel = buffer.floatChannelData![0]
        var sum = 0.0
        for i in 0..<n { sum += Double(channel[i]) * Double(channel[i]) }
        return (
            frames, file.processingFormat.sampleRate,
            Int(file.processingFormat.channelCount), n > 0 ? (sum / Double(n)).squareRoot() : 0
        )
    }

    @Test func m4aRoundTripPreservesSignal() throws {
        let url = temporaryFile("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        let writer = try EncodedFileWriter(url: url, fileFormat: .m4a, pcmFormat: format)
        try writer.write(sinePCM())
        try writer.finalize()

        let decoded = try decode(url)
        #expect(decoded.rate == 44100)
        #expect(decoded.channels == 1)
        // AAC adds priming/remainder frames; duration within 15%.
        #expect(abs(Double(decoded.frames) - 22050) < 22050 * 0.15)
        // 0.5-amplitude sine has RMS ~0.35; lossy but not destroyed.
        #expect(decoded.rms > 0.2)
    }

    @Test func flacRoundTripIsLossless() throws {
        let url = temporaryFile("flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        let writer = try EncodedFileWriter(url: url, fileFormat: .flac, pcmFormat: format)
        try writer.write(sinePCM())
        try writer.finalize()

        let decoded = try decode(url)
        #expect(decoded.frames == 22050)
        #expect(decoded.rate == 44100)
        #expect(abs(decoded.rms - 0.3536) < 0.01)
    }

    @Test func unalignedChunksAreCarried() throws {
        let url = temporaryFile("flac")
        defer { try? FileManager.default.removeItem(at: url) }
        // Stereo 16-bit: 4-byte frames; write in deliberately misaligned
        // chunks. 5000 frames stays above the FLAC encoder-block minimum.
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 2)
        let writer = try EncodedFileWriter(url: url, fileFormat: .flac, pcmFormat: format)
        let payload = Data((0..<20001).map { UInt8($0 % 251) })  // not 4-divisible
        try writer.write(payload.prefix(7))
        try writer.write(payload.dropFirst(7).prefix(9))
        try writer.write(payload.dropFirst(16))
        #expect(writer.bytesWritten == 20000)  // trailing odd byte carried, dropped at finalize
        try writer.finalize()
        #expect(try decode(url).frames == 5000)
    }

    @Test func write24BitUnpacksCorrectly() throws {
        let url = temporaryFile("flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 24, channels: 1)
        let writer = try EncodedFileWriter(url: url, fileFormat: .flac, pcmFormat: format)
        // Two known 24-bit samples (0x123456, -1), then zero-padding to
        // clear the FLAC encoder-block minimum.
        try writer.write(Data([0x56, 0x34, 0x12, 0xFF, 0xFF, 0xFF]))
        try writer.write(Data(count: 4606 * 3))
        try writer.finalize()
        #expect(try decode(url).frames == 4608)
    }

    @Test func shortFlacIsRejectedWithCleanup() throws {
        let url = temporaryFile("flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        let writer = try EncodedFileWriter(url: url, fileFormat: .flac, pcmFormat: format)
        try writer.write(Data(count: 1000 * 2))  // below 4608-frame minimum
        #expect(throws: EncodedFileWriter.WriterError.self) {
            try writer.finalize()
        }
        // The unreadable stub must not be left behind.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func shortM4AIsFine() throws {
        let url = temporaryFile("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        let writer = try EncodedFileWriter(url: url, fileFormat: .m4a, pcmFormat: format)
        try writer.write(sinePCM(frames: 100))
        try writer.finalize()
        #expect(try decode(url).frames == 100)
    }

    @Test func rejectsNonEncodedFormats() {
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        for bad in [AudioFileFormat.wav, .mp3, .opus] {
            #expect(throws: EncodedFileWriter.WriterError.self) {
                _ = try EncodedFileWriter(
                    url: temporaryFile(bad.rawValue), fileFormat: bad, pcmFormat: format)
            }
        }
    }

    @Test func writeAfterFinalizeThrows() throws {
        let url = temporaryFile("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        let writer = try EncodedFileWriter(url: url, fileFormat: .m4a, pcmFormat: format)
        try writer.finalize()
        #expect(throws: EncodedFileWriter.WriterError.self) {
            try writer.write(Data([0, 0]))
        }
    }
}
