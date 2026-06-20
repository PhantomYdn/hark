import Foundation
import Testing

@testable import Encoders

@Suite("OggMuxer")
struct OggMuxerTests {
    @Test func crc32IsDeterministicAndOrderSensitive() {
        let a = OggMuxer.crc32(Data([1, 2, 3, 4]))
        #expect(OggMuxer.crc32(Data([1, 2, 3, 4])) == a)
        #expect(OggMuxer.crc32(Data([4, 3, 2, 1])) != a)
        #expect(OggMuxer.crc32(Data()) == 0)
    }

    @Test func writesAParseablePage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-ogg-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            Issue.record("cannot open temp file")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let muxer = OggMuxer(serial: 42, handle: handle)
        // Two packets: 300 bytes (→ 255 + 45 lacing) and 10 bytes.
        try muxer.writePage(
            packets: [Data(repeating: 1, count: 300), Data(repeating: 2, count: 10)],
            granulePosition: 1920, headerType: OggMuxer.PageType.beginStream)
        try handle.close()

        let data = try Data(contentsOf: url)
        #expect(data.prefix(4).elementsEqual(Data("OggS".utf8)))
        #expect(data[5] == OggMuxer.PageType.beginStream)  // header type
        #expect(data[26] == 3)  // segments: [255,45,10]
        #expect(Array(data[27..<30]) == [255, 45, 10])
    }
}

@Suite("OpusFileWriter")
struct OpusFileWriterTests {
    private func sine48k(seconds: Double, channels: Int = 1) -> Data {
        let rate = 48000
        let frames = Int(Double(rate) * seconds)
        var data = Data(capacity: frames * channels * 2)
        for i in 0..<frames {
            let s = Int16(0.5 * 32767 * sin(2 * .pi * 440 * Double(i) / Double(rate)))
            for _ in 0..<channels {
                withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    /// Parses Ogg pages → [(headerType, granule, segmentCount)].
    private func pages(_ data: Data) -> [(type: UInt8, granule: UInt64, segments: Int)] {
        var result: [(UInt8, UInt64, Int)] = []
        var i = 0
        while i + 27 <= data.count, data[i..<i + 4].elementsEqual(Data("OggS".utf8)) {
            let type = data[i + 5]
            let granule = data.subdata(in: i + 6..<i + 14).withUnsafeBytes { $0.load(as: UInt64.self) }
            let nseg = Int(data[i + 26])
            let body = (0..<nseg).reduce(0) { $0 + Int(data[i + 27 + $1]) }
            result.append((type, granule, nseg))
            i += 27 + nseg + body
        }
        return result
    }

    @Test func opusHeadHasCorrectFields() {
        let head = OpusFileWriter.opusHead(channels: 2, inputSampleRate: 44100)
        #expect(head.prefix(8).elementsEqual(Data("OpusHead".utf8)))
        #expect(head[8] == 1)  // version
        #expect(head[9] == 2)  // channels
        let rate = head.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(rate == 44100)
    }

    @Test func encodesFullLengthOggOpus() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-opus-\(UUID().uuidString).opus")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = PCMFormat(sampleRate: 48000, bitsPerSample: 16, channels: 1)
        let writer = try OpusFileWriter(url: url, pcmFormat: format)
        try writer.write(sine48k(seconds: 2.0))
        try writer.finalize()

        let data = try Data(contentsOf: url)
        let parsed = pages(data)
        // First page is BOS with OpusHead; a final page carries end-of-stream.
        #expect(parsed.first?.type == OggMuxer.PageType.beginStream)
        #expect(parsed.contains { $0.type & OggMuxer.PageType.endStream != 0 })
        // Granules are monotonic and the last reflects ~2 s at 48 kHz.
        let granules = parsed.map(\.granule).filter { $0 > 0 }
        #expect(granules == granules.sorted())
        let last = granules.last ?? 0
        #expect(abs(Double(last) - 96000) < 96000 * 0.05)  // 2 s × 48000, ±5%
    }
}
