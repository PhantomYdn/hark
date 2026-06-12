@preconcurrency import AVFoundation
import CoreAudio
import Encoders
import Foundation

public enum TapEngineError: Error, CustomStringConvertible {
    case microphonePermissionDenied
    case systemAudioPermissionDenied(OSStatus)
    case deviceSelectionFailed(OSStatus)
    case converterCreationFailed
    case engineStartFailed(Error)
    case unsupportedBitDepth(Int)
    case tapCreationFailed(OSStatus)
    case tapPropertyReadFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)

    public var description: String {
        switch self {
        case .microphonePermissionDenied:
            return """
                microphone access denied. Grant access to your terminal in \
                System Settings > Privacy & Security > Microphone, then retry.
                """
        case .systemAudioPermissionDenied(let status):
            return """
                system audio capture was refused (CoreAudio error \(status)). \
                This usually means the "System Audio Recording" permission is \
                missing: open System Settings > Privacy & Security > Screen & \
                System Audio Recording, allow your terminal under "System \
                Audio Recording Only", then retry. Note: for command-line \
                tools, macOS attributes the permission to the terminal \
                application that launched them.
                """
        case .deviceSelectionFailed(let status):
            return "failed to select input device (CoreAudio error \(status))"
        case .converterCreationFailed:
            return "failed to create audio format converter"
        case .engineStartFailed(let error):
            return "failed to start audio engine: \(error.localizedDescription)"
        case .unsupportedBitDepth(let bits):
            return "unsupported bit depth \(bits) (expected 16, 24, or 32)"
        case .tapCreationFailed(let status):
            return "failed to create process tap (CoreAudio error \(status))"
        case .tapPropertyReadFailed(let status):
            return "failed to read tap properties (CoreAudio error \(status))"
        case .aggregateCreationFailed(let status):
            return "failed to create capture device (CoreAudio error \(status))"
        case .ioProcFailed(let status):
            return "failed to start capture I/O (CoreAudio error \(status))"
        }
    }
}

/// Captures audio from a microphone/input device and delivers interleaved
/// little-endian signed PCM in the requested format.
///
/// Capture pipeline: AVAudioEngine input tap (hardware format) ->
/// AVAudioConverter (rate/width/channel conversion) -> packed PCM bytes.
public final class MicCaptureSession: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let deviceID: AudioDeviceID?
    private let outputFormat: PCMFormat
    private var converter: AVAudioConverter?
    private var started = false

    /// - Parameters:
    ///   - deviceID: HAL device to capture from; `nil` uses the default input.
    ///   - outputFormat: desired PCM stream format (rate/bits/channels).
    public init(deviceID: AudioDeviceID?, outputFormat: PCMFormat) {
        self.deviceID = deviceID
        self.outputFormat = outputFormat
    }

    /// Requests microphone permission if needed; throws if denied.
    public static func ensureMicrophonePermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            if !granted { throw TapEngineError.microphonePermissionDenied }
        case .denied, .restricted:
            throw TapEngineError.microphonePermissionDenied
        @unknown default:
            throw TapEngineError.microphonePermissionDenied
        }
    }

    /// The hardware format of the selected input, for diagnostics.
    public var hardwareFormatDescription: String {
        let format = engine.inputNode.inputFormat(forBus: 0)
        return "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(format.commonFormat == .pcmFormatFloat32 ? "float32" : "pcm")"
    }

    /// Starts capture. `onAudio` is invoked on an audio/render thread with
    /// packed PCM chunks in the requested output format; keep it fast and
    /// hand data off to another queue for I/O.
    public func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        precondition(!started, "session already started")
        started = true

        let inputNode = engine.inputNode
        if let deviceID {
            var id = deviceID
            guard let audioUnit = inputNode.audioUnit else {
                throw TapEngineError.deviceSelectionFailed(-1)
            }
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw TapEngineError.deviceSelectionFailed(status)
            }
        }

        let hardwareFormat = inputNode.inputFormat(forBus: 0)

        // Converter target: 16/32-bit go straight to the wire format;
        // 24-bit converts to Int32 and is packed to 3 bytes afterwards.
        let commonFormat: AVAudioCommonFormat =
            switch outputFormat.bitsPerSample {
            case 16: .pcmFormatInt16
            case 24, 32: .pcmFormatInt32
            default: throw TapEngineError.unsupportedBitDepth(outputFormat.bitsPerSample)
            }
        guard
            let converterOutputFormat = AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: Double(outputFormat.sampleRate),
                channels: AVAudioChannelCount(outputFormat.channels),
                interleaved: true
            ),
            let converter = AVAudioConverter(from: hardwareFormat, to: converterOutputFormat)
        else {
            throw TapEngineError.converterCreationFailed
        }
        self.converter = converter

        let bitsPerSample = outputFormat.bitsPerSample
        let rateRatio = Double(outputFormat.sampleRate) / hardwareFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) {
            [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }

            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * rateRatio) + 64
            guard
                let outBuffer = AVAudioPCMBuffer(
                    pcmFormat: converterOutputFormat, frameCapacity: capacity)
            else { return }

            nonisolated(unsafe) var consumed = false
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) {
                _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, conversionError == nil, outBuffer.frameLength > 0 else {
                return
            }
            if let data = Self.packedData(from: outBuffer, bitsPerSample: bitsPerSample) {
                onAudio(data)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw TapEngineError.engineStartFailed(error)
        }
    }

    /// Stops capture and tears down the tap.
    public func stop() {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Extracts packed little-endian PCM bytes from a converted buffer.
    private static func packedData(
        from buffer: AVAudioPCMBuffer, bitsPerSample: Int
    ) -> Data? {
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
