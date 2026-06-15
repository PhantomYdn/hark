import CLame
import Foundation

/// Writes a packed-PCM capture stream to an MP3 file using vendored libmp3lame
/// (CoreAudio cannot encode MP3). Accepts the same interleaved little-endian
/// signed PCM the capture sessions produce, at any chunking (a carry buffer
/// reassembles partial frames). 24/32-bit input is down-converted to 16-bit for
/// the encoder (MP3 is lossy ~16-bit). Writes are serialized by a lock.
public final class MP3FileWriter: @unchecked Sendable {
    public enum WriterError: Error, CustomStringConvertible {
        case initFailed
        case cannotCreateFile(String)
        case encodeFailed(Int32)
        case alreadyFinalized

        public var description: String {
            switch self {
            case .initFailed: return "failed to initialize the MP3 (LAME) encoder"
            case .cannotCreateFile(let path): return "cannot create MP3 file at \(path)"
            case .encodeFailed(let code): return "MP3 encoding failed (LAME code \(code))"
            case .alreadyFinalized: return "writer is already finalized"
            }
        }
    }

    private let lock = NSLock()
    private let pcmFormat: PCMFormat
    private let handle: FileHandle
    private var gfp: OpaquePointer?
    private var carry = Data()
    private var pcmBytes: UInt64 = 0
    private var finalized = false

    public var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return pcmBytes
    }

    public init(url: URL, pcmFormat: PCMFormat) throws {
        self.pcmFormat = pcmFormat

        guard let gfp = lame_init() else { throw WriterError.initFailed }
        lame_set_in_samplerate(gfp, Int32(pcmFormat.sampleRate))
        lame_set_out_samplerate(gfp, Int32(pcmFormat.sampleRate))
        lame_set_num_channels(gfp, Int32(pcmFormat.channels))
        lame_set_mode(gfp, pcmFormat.channels == 1 ? MONO : JOINT_STEREO)
        lame_set_quality(gfp, 2)  // 0 best … 9 fastest; 2 = high quality
        lame_set_VBR(gfp, vbr_default)
        lame_set_VBR_q(gfp, 2)
        guard lame_init_params(gfp) >= 0 else {
            lame_close(gfp)
            throw WriterError.initFailed
        }
        self.gfp = gfp

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            lame_close(gfp)
            self.gfp = nil
            throw WriterError.cannotCreateFile(url.path)
        }
        self.handle = handle
    }

    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized, let gfp else { throw WriterError.alreadyFinalized }

        carry.append(data)
        let frameBytes = pcmFormat.bytesPerFrame
        let frames = carry.count / frameBytes
        guard frames > 0 else { return }
        let consumed = frames * frameBytes
        let chunk = Data(carry.prefix(consumed))

        let samples = Self.toInt16(chunk, format: pcmFormat, frames: frames)
        // LAME's recommended worst-case output size.
        let capacity = (frames * 5) / 4 + 7200
        var mp3 = [UInt8](repeating: 0, count: capacity)
        let written = samples.withUnsafeBufferPointer { source -> Int32 in
            let base = source.baseAddress
            if pcmFormat.channels == 1 {
                // Mono: per-channel API (the interleaved one expects L/R pairs).
                return lame_encode_buffer(gfp, base, base, Int32(frames), &mp3, Int32(capacity))
            }
            return lame_encode_buffer_interleaved(
                gfp, UnsafeMutablePointer(mutating: base), Int32(frames), &mp3, Int32(capacity))
        }
        guard written >= 0 else { throw WriterError.encodeFailed(written) }
        if written > 0 { try handle.write(contentsOf: Data(mp3[0..<Int(written)])) }

        pcmBytes += UInt64(consumed)
        carry.removeFirst(consumed)
    }

    public func finalize() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        finalized = true
        if let gfp {
            var mp3 = [UInt8](repeating: 0, count: 7200)
            let written = lame_encode_flush(gfp, &mp3, Int32(mp3.count))
            if written > 0 { try? handle.write(contentsOf: Data(mp3[0..<Int(written)])) }
            lame_close(gfp)
            self.gfp = nil
        }
        try? handle.close()
        carry.removeAll()
    }

    deinit { try? finalize() }

    /// Converts packed little-endian PCM to interleaved Int16 (LAME's input).
    static func toInt16(_ chunk: Data, format: PCMFormat, frames: Int) -> [Int16] {
        let sampleCount = frames * format.channels
        var out = [Int16](repeating: 0, count: sampleCount)
        chunk.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            switch format.bitsPerSample {
            case 16:
                raw.bindMemory(to: Int16.self).baseAddress.map { src in
                    out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: src, count: sampleCount) }
                }
            case 24:
                for i in 0..<sampleCount {
                    let base = i * 3  // little-endian: low, mid, high(sign)
                    out[i] = Int16(bitPattern: UInt16(bytes[base + 1]) | UInt16(bytes[base + 2]) << 8)
                }
            case 32:
                for i in 0..<sampleCount {
                    let base = i * 4
                    out[i] = Int16(bitPattern: UInt16(bytes[base + 2]) | UInt16(bytes[base + 3]) << 8)
                }
            default:
                break
            }
        }
        return out
    }
}
