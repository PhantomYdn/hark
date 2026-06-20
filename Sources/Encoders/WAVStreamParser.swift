import Foundation

/// Result of parsing a WAV header from a (possibly non-seekable) stream.
public struct WAVStreamHeader: Equatable, Sendable {
    public let format: PCMFormat
    /// Payload size from the `data` chunk; `0xFFFFFFFF` means unknown
    /// (streaming convention) — read until EOF.
    public let dataSize: UInt32

    public var dataSizeIsUnknown: Bool { dataSize == .max }
}

public enum WAVParseError: Error, CustomStringConvertible {
    case notRIFF
    case truncated
    case unsupportedCodec(UInt16)
    case unsupportedBitDepth(Int)
    case missingDataChunk

    public var description: String {
        switch self {
        case .notRIFF: return "stream is not a RIFF/WAVE file"
        case .truncated: return "WAV stream ended before the data chunk"
        case .unsupportedCodec(let tag):
            return "unsupported WAV codec tag \(tag) (only integer PCM is supported)"
        case .unsupportedBitDepth(let bits):
            return "unsupported WAV bit depth \(bits) (expected 16, 24, or 32)"
        case .missingDataChunk: return "WAV stream has no data chunk"
        }
    }
}

/// Sequentially parses a WAV header from a stream, stopping right at the
/// start of the PCM payload — suitable for piped input where seeking is
/// impossible (PRD §6.3: `hark -i -`).
public enum WAVStreamParser {
    /// `read(n)` must return up to `n` bytes (fewer only at EOF).
    /// On success the stream is positioned at the first payload byte.
    public static func parseHeader(
        read: (Int) throws -> Data
    ) throws -> WAVStreamHeader {
        func exactly(_ n: Int) throws -> Data {
            let data = try read(n)
            guard data.count == n else { throw WAVParseError.truncated }
            return data
        }
        func le32(_ data: Data) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func le16(_ data: Data) -> UInt16 {
            data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }

        guard try exactly(4) == Data("RIFF".utf8) else { throw WAVParseError.notRIFF }
        _ = try exactly(4)  // RIFF size (untrustworthy for streams)
        guard try exactly(4) == Data("WAVE".utf8) else { throw WAVParseError.notRIFF }

        var format: PCMFormat?
        while true {
            let header = try read(8)
            guard header.count == 8 else { throw WAVParseError.missingDataChunk }
            let chunkID = header.prefix(4)
            let chunkSize = le32(header.suffix(4))

            if chunkID == Data("fmt ".utf8) {
                let body = try exactly(Int(chunkSize) + (chunkSize % 2 == 1 ? 1 : 0))
                let codec = le16(body.subdata(in: 0..<2))
                guard codec == 1 else { throw WAVParseError.unsupportedCodec(codec) }
                let channels = Int(le16(body.subdata(in: 2..<4)))
                let rate = Int(le32(body.subdata(in: 4..<8)))
                let bits = Int(le16(body.subdata(in: 14..<16)))
                guard [16, 24, 32].contains(bits) else {
                    throw WAVParseError.unsupportedBitDepth(bits)
                }
                format = PCMFormat(sampleRate: rate, bitsPerSample: bits, channels: channels)
            } else if chunkID == Data("data".utf8) {
                guard let format else { throw WAVParseError.truncated }
                return WAVStreamHeader(format: format, dataSize: chunkSize)
            } else {
                // Skip unknown chunks (LIST, fact, …) including pad byte.
                let skip = Int(chunkSize) + (chunkSize % 2 == 1 ? 1 : 0)
                _ = try exactly(skip)
            }
        }
    }
}
