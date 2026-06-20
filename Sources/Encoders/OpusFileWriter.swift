@preconcurrency import AudioToolbox
import Foundation

/// Writes a packed-PCM capture stream to an Ogg/Opus (`.opus`) file using the
/// native CoreAudio Opus encoder (`AudioConverter`, zero external deps) plus a
/// hand-written Ogg muxer (`OggMuxer`). Input PCM is converted to Float32 and
/// resampled to Opus's internal 48 kHz by the converter; encoded packets (960
/// samples each) are framed into Ogg pages with `OpusHead`/`OpusTags` headers.
public final class OpusFileWriter: @unchecked Sendable {
    public enum WriterError: Error, CustomStringConvertible {
        case encoderUnavailable(OSStatus)
        case cannotCreateFile(String)
        case encodeFailed(OSStatus)
        case alreadyFinalized

        public var description: String {
            switch self {
            case .encoderUnavailable(let s): return "the CoreAudio Opus encoder is unavailable (status \(s))"
            case .cannotCreateFile(let p): return "cannot create Opus file at \(p)"
            case .encodeFailed(let s): return "Opus encoding failed (status \(s))"
            case .alreadyFinalized: return "writer is already finalized"
            }
        }
    }

    private static let opusSampleRate = 48000
    private static let samplesPerPacket: UInt64 = 960  // 20 ms @ 48 kHz
    private static let preSkip: UInt16 = 312  // standard Opus codec delay
    private static let pageBatch = 50  // audio packets per Ogg page

    private let lock = NSLock()
    private let pcmFormat: PCMFormat
    private let channels: Int
    private let handle: FileHandle
    private let muxer: OggMuxer
    private var converter: AudioConverterRef?

    private var input = [Float]()  // interleaved Float32 at the capture rate
    private var readIndex = 0
    private var pending: [(packet: Data, granule: UInt64)] = []
    private var granule: UInt64 = 0
    private var pcmBytes: UInt64 = 0
    private var finalized = false
    /// During streaming the input proc must never report 0 frames — AudioConverter
    /// treats that as end-of-stream and flushes the encoder permanently. Only the
    /// finalize drain sets this so the last partial frame is flushed.
    private var flushing = false

    public var bytesWritten: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return pcmBytes
    }

    public init(url: URL, pcmFormat: PCMFormat) throws {
        self.pcmFormat = pcmFormat
        self.channels = pcmFormat.channels

        var source = AudioStreamBasicDescription(
            mSampleRate: Double(pcmFormat.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var dest = AudioStreamBasicDescription(
            mSampleRate: Double(Self.opusSampleRate), mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)

        var conv: AudioConverterRef?
        let status = AudioConverterNew(&source, &dest, &conv)
        guard status == noErr, let conv else { throw WriterError.encoderUnavailable(status) }
        self.converter = conv

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            AudioConverterDispose(conv)
            self.converter = nil
            throw WriterError.cannotCreateFile(url.path)
        }
        self.handle = handle
        self.muxer = OggMuxer(serial: UInt32.random(in: 1...UInt32.max), handle: handle)

        // RFC 7845: OpusHead in its own BOS page, OpusTags in the next page.
        try muxer.writePage(
            packets: [Self.opusHead(channels: channels, inputSampleRate: UInt32(pcmFormat.sampleRate))],
            granulePosition: 0, headerType: OggMuxer.PageType.beginStream)
        try muxer.writePage(packets: [Self.opusTags()], granulePosition: 0, headerType: 0)
    }

    public func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finalized, converter != nil else { throw WriterError.alreadyFinalized }

        let frameBytes = pcmFormat.bytesPerFrame
        let frames = data.count / frameBytes
        guard frames > 0 else { return }
        let consumed = frames * frameBytes
        input.append(contentsOf: Self.toFloat32(data.prefix(consumed), format: pcmFormat, frames: frames))
        pcmBytes += UInt64(consumed)
        try drain(flush: false)
    }

    public func finalize() throws {
        lock.lock(); defer { lock.unlock() }
        guard !finalized else { return }
        finalized = true
        if converter != nil {
            try? drain(flush: true)
            // Trailing audio packets go on the final page, flagged end-of-stream.
            if !pending.isEmpty {
                try? muxer.writePage(
                    packets: pending.map(\.packet), granulePosition: pending.last!.granule,
                    headerType: OggMuxer.PageType.endStream)
            } else {
                try? muxer.writePage(
                    packets: [Data()], granulePosition: granule,
                    headerType: OggMuxer.PageType.endStream)
            }
            pending.removeAll()
            AudioConverterDispose(converter!)
            converter = nil
        }
        try? handle.close()
    }

    deinit { try? finalize() }

    // MARK: Encoding

    /// Pulls encoded Opus packets from the converter and frames them into pages.
    /// When `flush` is set the input proc may report end-of-stream so the final
    /// (partial, padded) frame is emitted; otherwise only whole frames are fed.
    private func drain(flush: Bool) throws {
        guard let converter else { return }
        flushing = flush
        let perCall = 64
        while true {
            let wholeFrames = (input.count - readIndex) / channels / Int(Self.samplesPerPacket)
            if !flush && wholeFrames == 0 { break }  // wait for a full frame
            var ioPackets = UInt32(min(flush ? max(wholeFrames, perCall) : wholeFrames, perCall))
            if ioPackets == 0 { ioPackets = 1 }  // flush: force the final partial frame

            let capacity = 4000 * Int(ioPackets)
            let out = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
            defer { out.deallocate() }
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(capacity), mData: out))
            var descs = [AudioStreamPacketDescription](repeating: .init(), count: Int(ioPackets))

            _ = AudioConverterFillComplexBuffer(
                converter, Self.inputProc, Unmanaged.passUnretained(self).toOpaque(),
                &ioPackets, &abl, &descs)

            for i in 0..<Int(ioPackets) {
                let offset = Int(descs[i].mStartOffset)
                let length = Int(descs[i].mDataByteSize)
                granule += Self.samplesPerPacket
                pending.append((Data(bytes: out.advanced(by: offset), count: length), granule))
            }
            // Stream out full pages, always leaving a tail for the EOS page.
            while pending.count >= Self.pageBatch * 2 {
                let batch = Array(pending.prefix(Self.pageBatch))
                try muxer.writePage(
                    packets: batch.map(\.packet), granulePosition: batch.last!.granule, headerType: 0)
                pending.removeFirst(Self.pageBatch)
            }

            if ioPackets == 0 { break }  // converter produced nothing more
        }
        if readIndex > 0 {
            input.removeFirst(readIndex)
            readIndex = 0
        }
    }

    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberPackets, ioData, _, context in
        let me = Unmanaged<OpusFileWriter>.fromOpaque(context!).takeUnretainedValue()
        return me.provideInput(ioNumberPackets, ioData)
    }

    private func provideInput(
        _ ioNumberPackets: UnsafeMutablePointer<UInt32>,
        _ ioData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        var availableFrames = (input.count - readIndex) / channels
        // Streaming: only ever hand over whole frames so we never report 0
        // mid-stream (which would permanently flush the encoder).
        if !flushing {
            availableFrames -= availableFrames % Int(Self.samplesPerPacket)
        }
        guard availableFrames > 0 else {
            ioNumberPackets.pointee = 0
            return noErr
        }
        let give = min(Int(ioNumberPackets.pointee), availableFrames)
        input.withUnsafeMutableBufferPointer { buffer in
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = UInt32(channels)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(give * channels * 4)
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(
                buffer.baseAddress!.advanced(by: readIndex))
        }
        readIndex += give * channels
        ioNumberPackets.pointee = UInt32(give)
        return noErr
    }

    // MARK: Headers

    static func opusHead(channels: Int, inputSampleRate: UInt32) -> Data {
        var head = Data("OpusHead".utf8)
        head.append(1)  // version
        head.append(UInt8(channels))
        appendLE(&head, preSkip)
        appendLE(&head, inputSampleRate)
        appendLE(&head, UInt16(0))  // output gain
        head.append(0)  // channel mapping family 0 (mono/stereo)
        return head
    }

    static func opusTags() -> Data {
        var tags = Data("OpusTags".utf8)
        let vendor = Data("hark".utf8)
        appendLE(&tags, UInt32(vendor.count))
        tags.append(vendor)
        appendLE(&tags, UInt32(0))  // user comment count
        return tags
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Converts packed little-endian PCM to interleaved Float32 in [-1, 1].
    static func toFloat32(_ chunk: Data, format: PCMFormat, frames: Int) -> [Float] {
        let count = frames * format.channels
        var out = [Float](repeating: 0, count: count)
        chunk.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            switch format.bitsPerSample {
            case 16:
                let src = raw.bindMemory(to: Int16.self)
                for i in 0..<count { out[i] = Float(src[i]) / 32768.0 }
            case 24:
                for i in 0..<count {
                    let b = i * 3
                    let v = Int32(bitPattern:
                        UInt32(bytes[b]) << 8 | UInt32(bytes[b + 1]) << 16 | UInt32(bytes[b + 2]) << 24)
                    out[i] = Float(v) / 2147483648.0
                }
            case 32:
                let src = raw.bindMemory(to: Int32.self)
                for i in 0..<count { out[i] = Float(src[i]) / 2147483648.0 }
            default:
                break
            }
        }
        return out
    }
}
