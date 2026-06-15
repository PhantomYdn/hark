import AVFoundation
import Foundation
import Testing

@testable import Encoders

@Suite("MP3FileWriter")
struct MP3FileWriterTests {
    /// `seconds` of a 440 Hz sine at 0.5 amplitude, 16-bit mono.
    private func sinePCM(seconds: Double = 1.0, rate: Int = 44100) -> Data {
        let frames = Int(Double(rate) * seconds)
        var data = Data(capacity: frames * 2)
        for i in 0..<frames {
            let sample = Int16(0.5 * 32767 * sin(2 * .pi * 440 * Double(i) / Double(rate)))
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-mp3-\(UUID().uuidString).mp3")
    }

    private func decode(_ url: URL) throws -> (rate: Double, channels: Int, frames: Int, rms: Double) {
        let file = try AVAudioFile(forReading: url)
        let frames = Int(file.length)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
            channels: file.processingFormat.channelCount, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let channel = buffer.floatChannelData![0]
        var sum = 0.0
        for i in 0..<n { sum += Double(channel[i]) * Double(channel[i]) }
        return (
            file.processingFormat.sampleRate, Int(file.processingFormat.channelCount),
            frames, n > 0 ? (sum / Double(n)).squareRoot() : 0)
    }

    @Test func monoRoundTripIsDecodableWithSignal() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1)
        let writer = try MP3FileWriter(url: url, pcmFormat: format)
        try writer.write(sinePCM())
        try writer.finalize()

        // Valid MPEG audio: starts with an MPEG frame sync (0xFF Ex) or an
        // ID3 tag ("ID3").
        let head = try Data(contentsOf: url).prefix(3)
        let isMPEG = (head.count >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0)
            || head.elementsEqual(Data("ID3".utf8))
        #expect(isMPEG)

        let decoded = try decode(url)
        #expect(decoded.rate == 44100)
        #expect(decoded.channels == 1)
        #expect(abs(Double(decoded.frames) - 44100) < 44100 * 0.2)  // encoder padding
        #expect(decoded.rms > 0.2)  // 0.5-amplitude sine survives lossy encode
    }

    @Test func stereoEncodesTwoChannels() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 2)
        // Interleave the mono sine into L/R.
        let mono = sinePCM()
        var stereo = Data(capacity: mono.count * 2)
        mono.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for v in s { withUnsafeBytes(of: v.littleEndian) { stereo.append(contentsOf: $0) }
                withUnsafeBytes(of: v.littleEndian) { stereo.append(contentsOf: $0) } }
        }
        let writer = try MP3FileWriter(url: url, pcmFormat: format)
        try writer.write(stereo)
        try writer.finalize()
        #expect(try decode(url).channels == 2)
    }

    @Test func toInt16DownconvertsBitDepths() {
        // 32-bit: top 16 bits are kept.
        let s32: Int32 = 0x1234_5678
        var d32 = Data()
        withUnsafeBytes(of: s32.littleEndian) { d32.append(contentsOf: $0) }
        #expect(MP3FileWriter.toInt16(d32, format: PCMFormat(sampleRate: 44100, bitsPerSample: 32, channels: 1), frames: 1)[0] == 0x1234)

        // 16-bit: passes through.
        var d16 = Data()
        withUnsafeBytes(of: Int16(-12345).littleEndian) { d16.append(contentsOf: $0) }
        #expect(MP3FileWriter.toInt16(d16, format: PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 1), frames: 1)[0] == -12345)
    }
}
