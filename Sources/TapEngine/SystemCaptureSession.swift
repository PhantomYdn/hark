@preconcurrency import AVFoundation
import CoreAudio
import Encoders
import Foundation

/// Captures system or per-application audio through a Core Audio process
/// tap (macOS 14.4+), delivering packed PCM in the requested format.
///
/// Pipeline: process tap -> private aggregate device (tap in the tap list,
/// optionally the microphone as a drift-compensated sub-device for `--mix`)
/// -> IOProc -> PCMStreamConverter -> packed PCM bytes.
///
/// Reading a tap requires the "System Audio Recording" TCC permission; for
/// command-line tools macOS attributes it to the launching terminal.
public final class SystemCaptureSession: CaptureSession, @unchecked Sendable {
    private let scope: TapScope
    private let micDeviceUID: String?
    private let outputFormat: PCMFormat

    private var tap: ProcessTap?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: PCMStreamConverter?
    private var mixer: StreamMixer?
    private let ioQueue = DispatchQueue(label: "aural.tap.io")
    private var started = false

    /// - Parameters:
    ///   - scope: what to capture (global system audio or specific processes).
    ///   - micDeviceUID: input device to mix in (`--mix`); nil for tap only.
    ///   - outputFormat: desired PCM stream format.
    public init(scope: TapScope, micDeviceUID: String?, outputFormat: PCMFormat) {
        self.scope = scope
        self.micDeviceUID = micDeviceUID
        self.outputFormat = outputFormat
    }

    /// Tap stream format, for diagnostics. Empty before `start`.
    public private(set) var sourceFormatDescription = ""

    public func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        precondition(!started, "session already started")
        started = true

        // 1. Create the tap. A TCC denial surfaces here or at IO start.
        let tap = try ProcessTap(scope: scope)
        self.tap = tap
        var tapASBD = tap.format
        sourceFormatDescription =
            "\(Int(tapASBD.mSampleRate)) Hz, \(tapASBD.mChannelsPerFrame) ch (tap)"

        // 2. Build the private aggregate device hosting the tap (and the
        // mic as a drift-compensated sub-device when mixing).
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "aural-capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tap.uid,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        if let micDeviceUID {
            composition[kAudioAggregateDeviceSubDeviceListKey] = [
                [
                    kAudioSubDeviceUIDKey: micDeviceUID,
                    kAudioSubDeviceDriftCompensationKey: true,
                ]
            ]
            composition[kAudioAggregateDeviceMainSubDeviceKey] = micDeviceUID
        }

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            teardown()
            throw TapEngineError.aggregateCreationFailed(status)
        }
        aggregateID = newAggregateID

        // 3. Converter from the tap format to the requested output format.
        guard let tapFormat = AVAudioFormat(streamDescription: &tapASBD) else {
            teardown()
            throw TapEngineError.converterCreationFailed
        }
        let converter = try PCMStreamConverter(
            inputFormat: tapFormat, outputFormat: outputFormat)
        self.converter = converter

        // When mixing, mic stream(s) are summed into the tap stream before
        // conversion. Stream layout is resolved lazily from the first IO
        // callback's buffer list.
        let mixer = micDeviceUID != nil ? StreamMixer(tapChannels: Int(tapASBD.mChannelsPerFrame)) : nil
        self.mixer = mixer

        // 4. IO callback: wrap tap bytes, convert, deliver.
        let debug = ProcessInfo.processInfo.environment["AURAL_DEBUG"] != nil
        nonisolated(unsafe) var callbackCount = 0
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let converter = self.converter else { return }

            let ablPointer = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            if debug {
                callbackCount += 1
                if callbackCount <= 3 {
                    var info = "AURAL_DEBUG cb#\(callbackCount): buffers=\(ablPointer.count)"
                    for (i, b) in ablPointer.enumerated() {
                        var nonZero = false
                        if let p = b.mData?.assumingMemoryBound(to: Float32.self) {
                            let n = Int(b.mDataByteSize) / 4
                            for j in 0..<min(n, 4096) where p[j] != 0 { nonZero = true; break }
                        }
                        info += " [\(i)] ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize) nonzero=\(nonZero)"
                    }
                    FileHandle.standardError.write(Data((info + "\n").utf8))
                }
            }
            guard ablPointer.count > 0 else { return }

            let buffer: AVAudioPCMBuffer?
            if let mixer = self.mixer {
                buffer = mixer.mixedBuffer(from: inInputData, tapFormat: tapFormat)
            } else {
                buffer = AVAudioPCMBuffer(
                    pcmFormat: tapFormat,
                    bufferListNoCopy: inInputData,
                    deallocator: nil)
            }
            guard let buffer, buffer.frameLength > 0 else { return }
            if let data = converter.convert(buffer) {
                onAudio(data)
            }
        }
        guard status == noErr, ioProcID != nil else {
            teardown()
            throw TapEngineError.ioProcFailed(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw TapEngineError.ioProcFailed(status)
        }
    }

    public func stop() {
        guard started else { return }
        teardown()
    }

    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        tap?.destroy()
        tap = nil
    }

    deinit {
        teardown()
    }
}
