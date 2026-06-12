@preconcurrency import AVFoundation
import Encoders
import Foundation

/// Converts AVAudioPCMBuffers from a live capture stream into packed
/// little-endian signed PCM in a target `PCMFormat`.
///
/// Handles sample-rate, bit-width, and channel-count conversion. 16/32-bit
/// targets convert directly; 24-bit converts to Int32 and packs to 3 bytes.
/// Stateful across calls (resampler continuity) — feed it one continuous
/// stream.
final class PCMStreamConverter {
    private let converter: AVAudioConverter
    private let converterOutputFormat: AVAudioFormat
    private let bitsPerSample: Int
    private let rateRatio: Double

    init(inputFormat: AVAudioFormat, outputFormat: PCMFormat) throws {
        let commonFormat: AVAudioCommonFormat =
            switch outputFormat.bitsPerSample {
            case 16: .pcmFormatInt16
            case 24, 32: .pcmFormatInt32
            default: throw TapEngineError.unsupportedBitDepth(outputFormat.bitsPerSample)
            }
        guard
            let converterOutput = AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: Double(outputFormat.sampleRate),
                channels: AVAudioChannelCount(outputFormat.channels),
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inputFormat, to: converterOutput)
        else {
            throw TapEngineError.converterCreationFailed
        }
        self.converter = converter
        self.converterOutputFormat = converterOutput
        self.bitsPerSample = outputFormat.bitsPerSample
        self.rateRatio = Double(outputFormat.sampleRate) / inputFormat.sampleRate
    }

    /// Converts one captured buffer; returns nil when nothing was produced.
    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * rateRatio) + 64
        guard
            let outBuffer = AVAudioPCMBuffer(
                pcmFormat: converterOutputFormat, frameCapacity: capacity)
        else { return nil }

        nonisolated(unsafe) var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, outBuffer.frameLength > 0 else {
            return nil
        }
        return Self.packedData(from: outBuffer, bitsPerSample: bitsPerSample)
    }

    /// Extracts packed little-endian PCM bytes from a converted buffer.
    static func packedData(from buffer: AVAudioPCMBuffer, bitsPerSample: Int) -> Data? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleCount = frames * channels
        guard sampleCount > 0 else { return nil }

        switch bitsPerSample {
        case 16:
            guard let int16Data = buffer.int16ChannelData else { return nil }
            return Data(bytes: int16Data[0], count: sampleCount * 2)
        case 32:
            guard let int32Data = buffer.int32ChannelData else { return nil }
            return Data(bytes: int32Data[0], count: sampleCount * 4)
        case 24:
            guard let int32Data = buffer.int32ChannelData else { return nil }
            let samples = UnsafeBufferPointer(start: int32Data[0], count: sampleCount)
            return PCMPacker.pack24(fromInt32: samples)
        default:
            return nil
        }
    }
}
