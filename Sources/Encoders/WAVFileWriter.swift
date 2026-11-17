import Foundation

/// Writes interleaved little-endian signed PCM into a WAV (RIFF) container.
///
/// Two modes:
/// - **Seekable file**: a placeholder header is written first and the RIFF
///   and `data` chunk sizes are patched on `finalize()` (PRD §6.3: the file
///   stays playable after graceful shutdown).
/// - **Stream** (non-seekable, e.g. stdout): the header carries `0xFFFFFFFF`
///   ("unknown size") chunk lengths, a convention accepted by ffmpeg, sox,
///   and most decoders for piped WAV.
///
/// Thread-safety: all mutating methods are serialized by an internal lock so
/// audio-thread writes and main-thread finalize cannot interleave.
public final class WAVFileWriter: @unchecked Sendable {
    public enum Destination {
        /// Seekable file at the given path; created/truncated on init.
        case file(URL)
        /// Non-seekable stream (e.g., `FileHandle.standardOutput`).
        case stream(FileHandle)
    }

    public enum WriterError: Error, CustomStringConvertible {
        case unsupportedBitDepth(Int)
        case cannotCreateFile(String)
        case alreadyFinalized

        public var description: String {
            switch self {
            case .unsupportedBitDepth(let bits):
                return "unsupported bit depth \(bits) (expected 16, 24, or 32)"
            case .cannotCreateFile(let path):
                return "cannot create file at \(path)"
            case .alreadyFinalized:
                return "writer is already finalized"
            }
        }
    }

    private let handle: FileHandle
    private let seekable: Bool
    private let format: PCMFormat
    private let metadata: RecordingMetadata
    private let lock = NSLock()
    private var dataBytes: UInt64 = 0
    private var finalized = false

    /// Total PCM payload bytes written so far.
    public var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return dataBytes
    }

    /// - Parameter metadata: embedded as a trailing LIST/INFO chunk on
    ///   finalize (seekable files only; ignored for streams, where readers
    ///   consume until EOF and would treat trailing chunks as audio).
    public init(
        destination: Destination, format: PCMFormat, metadata: RecordingMetadata = RecordingMetadata()
    ) throws {
        guard [16, 24, 32].contains(format.bitsPerSample) else {
            throw WriterError.unsupportedBitDepth(format.bitsPerSample)
        }
        self.format = format
        self.metadata = metadata
        switch destination {
        case .file(let url):
            guard let handle = OutputFile.truncatingHandle(at: url) else {
                throw WriterError.cannotCreateFile(url.path)
            }
            self.handle = handle
            self.seekable = true
        case .stream(let streamHandle):
            self.handle = streamHandle
            self.seekable = false
        }
        try writeAll(Self.header(format: format, dataSize: seekable ? 0 : .max))
    }

    /// Appends raw interleaved PCM bytes.
    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { throw WriterError.alreadyFinalized }
        try writeAll(data)
        dataBytes += UInt64(data.count)
    }

    /// Finishes the file. For seekable destinations, appends the metadata
    /// LIST/INFO chunk (if any) and patches the RIFF and `data` chunk sizes
    /// so the file is valid; for streams this is a no-op. Safe to call more
    /// than once.
    public func finalize() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        finalized = true
        guard seekable else { return }

        var trailing = Data()
        if !metadata.isEmpty {
            trailing = Self.infoListChunk(metadata)
            try handle.seekToEnd()
            try handle.write(contentsOf: trailing)
        }

        // Sizes are capped at UInt32.max per the RIFF format.
        let data32 = UInt32(clamping: dataBytes)
        let riff32 = UInt32(
            clamping: dataBytes + UInt64(Self.headerSize) - 8 + UInt64(trailing.count))
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.le32(riff32))
        try handle.seek(toOffset: UInt64(Self.headerSize - 4))
        try handle.write(contentsOf: Self.le32(data32))
        try handle.synchronize()
        try handle.close()
    }

    /// Builds a RIFF LIST chunk with INFO subchunks (ICRD/ISFT/INAM).
    static func infoListChunk(_ metadata: RecordingMetadata) -> Data {
        var entries: [(String, String)] = []
        if let date = metadata.dateString { entries.append(("ICRD", date)) }
        if let software = metadata.software { entries.append(("ISFT", software)) }
        if let title = metadata.title { entries.append(("INAM", title)) }

        var body = Data("INFO".utf8)
        for (id, value) in entries {
            var content = Data(value.utf8)
            content.append(0)  // NUL terminator
            if content.count % 2 != 0 { content.append(0) }  // even padding
            body.append(contentsOf: Array(id.utf8))
            body.append(le32(UInt32(content.count)))
            body.append(content)
        }
        var chunk = Data("LIST".utf8)
        chunk.append(le32(UInt32(body.count)))
        chunk.append(body)
        return chunk
    }

    private func writeAll(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    // MARK: - Header

    /// Canonical 44-byte PCM WAV header size.
    public static let headerSize = 44

    /// Builds a 44-byte canonical PCM WAV header.
    /// `dataSize == .max` produces the "unknown length" streaming header.
    public static func header(format: PCMFormat, dataSize: UInt32) -> Data {
        let riffSize: UInt32 =
            dataSize == .max ? .max : dataSize + UInt32(headerSize) - 8
        var header = Data(capacity: headerSize)
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(le32(riffSize))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(le32(16))  // fmt chunk size
        header.append(le16(1))  // audio format: 1 = integer PCM
        header.append(le16(UInt16(format.channels)))
        header.append(le32(UInt32(format.sampleRate)))
        header.append(le32(UInt32(format.byteRate)))
        header.append(le16(UInt16(format.bytesPerFrame)))  // block align
        header.append(le16(UInt16(format.bitsPerSample)))
        header.append(contentsOf: Array("data".utf8))
        header.append(le32(dataSize))
        return header
    }

    static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
