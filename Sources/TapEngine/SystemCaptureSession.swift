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
public final class SystemCaptureSession: MultiTrackCaptureSession, @unchecked Sendable {
    private let scope: TapScope
    private let micDeviceUID: String?
    private let outputFormat: PCMFormat

    private var tap: ProcessTap?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: PCMStreamConverter?
    private var mixer: StreamMixer?
    // Per-source converters (built in start() when source attribution is on).
    private var systemConverter: PCMStreamConverter?
    private var micConverter: PCMStreamConverter?

    /// When set before `start` (and a mic is mixed in), each source is also
    /// delivered separately for attribution (PRD §6.7a).
    public var onSourceAudio: (@Sendable (CaptureSource, Data) -> Void)?
    private let ioQueue = DispatchQueue(label: "hark.tap.io")
    private var started = false
    private var processListListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "hark.tap.lifecycle")
    private let sourceLostLock = NSLock()
    private var sourceLostFired = false

    /// Invoked once (on an arbitrary queue) if every tapped process exits
    /// while capturing (`.processes` scope only). The session keeps running
    /// until `stop()`; callers typically finalize and exit (PRD §6.2).
    public var onSourceLost: (@Sendable () -> Void)?

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
        let tapASBD = tap.format
        sourceFormatDescription =
            "\(Int(tapASBD.mSampleRate)) Hz, \(tapASBD.mChannelsPerFrame) ch (tap)"

        // 2. Build the private aggregate device hosting the tap (and the
        // mic as a drift-compensated sub-device when mixing).
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "hark-capture",
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
            // The mic joins as a drift-compensated sub-device and is the
            // aggregate's *clock master*. A process tap only clocks while the
            // system output is actually playing, so if the tap were the master
            // the IOProc (and the mic) would stall whenever nothing plays —
            // mixing then captured silence until some app made a sound. The
            // mic is a real input device that clocks continuously; the tap is
            // drift-compensated to it, and the nominal rate is pinned below so a
            // low-rate mic doesn't downclock the system-audio capture.
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

        // 3. Pin the aggregate clock to at least the tap's native rate. With
        // the mic as the clock master (for --mix) the aggregate defaults to the
        // mic's rate, so a low-rate mic (e.g. 16 kHz Bluetooth) would otherwise
        // downclock the system-audio capture; take the higher of the mic's
        // default and the tap rate. (System-only capture has no mic and clocks
        // at the tap rate already.) Failure is tolerated; the actual rate is
        // read back below either way.
        let defaultRate = Self.nominalSampleRate(of: newAggregateID) ?? tapASBD.mSampleRate
        Self.setNominalSampleRate(of: newAggregateID, to: max(defaultRate, tapASBD.mSampleRate))
        let actualRate = Self.nominalSampleRate(of: newAggregateID) ?? tapASBD.mSampleRate

        // Converter input = tap stream's channel layout at the aggregate's
        // *actual* clock rate. Neither the tap's own ASBD (pre-aggregate)
        // nor the stream's virtual format (not clock-adjusted) can be
        // trusted alone. The tap stream is the last input stream
        // (sub-devices come first).
        let streamFormats = try Self.inputStreamFormats(of: newAggregateID)
        guard var liveASBD = streamFormats.last else {
            teardown()
            throw TapEngineError.aggregateCreationFailed(noErr)
        }
        liveASBD.mSampleRate = actualRate
        sourceFormatDescription =
            "\(Int(liveASBD.mSampleRate)) Hz, \(liveASBD.mChannelsPerFrame) ch (tap stream)"
        guard let tapFormat = AVAudioFormat(streamDescription: &liveASBD) else {
            teardown()
            throw TapEngineError.converterCreationFailed
        }
        let converter = try PCMStreamConverter(
            inputFormat: tapFormat, outputFormat: outputFormat)
        self.converter = converter

        // When mixing, mic stream(s) are summed into the tap stream before
        // conversion.
        let mixer = micDeviceUID != nil ? StreamMixer(tapChannels: Int(liveASBD.mChannelsPerFrame)) : nil
        self.mixer = mixer

        // Source attribution (`--speakers`): convert the tap-only and mic-only
        // signals separately (both in tap layout) alongside the mix. Built only
        // when mixing and a per-source consumer is attached.
        let deliverSources = micDeviceUID != nil && onSourceAudio != nil
        if deliverSources {
            self.systemConverter = try PCMStreamConverter(
                inputFormat: tapFormat, outputFormat: outputFormat)
            self.micConverter = try PCMStreamConverter(
                inputFormat: tapFormat, outputFormat: outputFormat)
        }

        // 4. IO callback: wrap tap bytes, convert, deliver.
        let debug = ProcessInfo.processInfo.environment["HARK_DEBUG"] != nil
        nonisolated(unsafe) var callbackCount = 0
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let converter = self.converter else { return }

            let ablPointer = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            if debug {
                callbackCount += 1
                if callbackCount <= 3 {
                    var info = "HARK_DEBUG cb#\(callbackCount): buffers=\(ablPointer.count)"
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

            // Source attribution: deliver tap-only and mic-only streams too.
            if let onSourceAudio = self.onSourceAudio, let mixer = self.mixer,
                let systemConverter = self.systemConverter, let micConverter = self.micConverter
            {
                if let systemBuffer = mixer.systemBuffer(from: inInputData, tapFormat: tapFormat),
                    let data = systemConverter.convert(systemBuffer)
                {
                    onSourceAudio(.system, data)
                }
                if let micBuffer = mixer.micBuffer(from: inInputData, tapFormat: tapFormat),
                    let data = micConverter.convert(micBuffer)
                {
                    onSourceAudio(.microphone, data)
                }
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

        // 5. Watch for all tapped processes exiting (PRD §6.2).
        if case .processes(let tappedIDs) = scope {
            installProcessExitWatcher(tappedIDs: Set(tappedIDs))
        }
    }

    private func installProcessExitWatcher(tappedIDs: Set<AudioObjectID>) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let alive = Self.currentProcessObjectIDs()
            guard alive.isDisjoint(with: tappedIDs) else { return }
            self.sourceLostLock.lock()
            let alreadyFired = self.sourceLostFired
            self.sourceLostFired = true
            self.sourceLostLock.unlock()
            if !alreadyFired { self.onSourceLost?() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listener)
        if status == noErr {
            processListListener = listener
        }
    }

    private static func currentProcessObjectIDs() -> Set<AudioObjectID> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemID, &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard ids.withUnsafeMutableBytes({
            AudioObjectGetPropertyData(systemID, &address, 0, nil, &size, $0.baseAddress!)
        }) == noErr else { return [] }
        return Set(ids)
    }

    public func stop() {
        guard started else { return }
        teardown()
    }

    private func teardown() {
        if let processListListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue,
                processListListener)
            self.processListListener = nil
        }
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

    private static func nominalRateAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func setNominalSampleRate(of deviceID: AudioObjectID, to rate: Double) {
        var address = nominalRateAddress()
        var value = rate
        _ = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
    }

    private static func nominalSampleRate(of deviceID: AudioObjectID) -> Double? {
        var address = nominalRateAddress()
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
            value > 0
        else { return nil }
        return value
    }

    /// Virtual formats of a device's input streams, in stream order
    /// (matching the IOProc buffer list).
    private static func inputStreamFormats(
        of deviceID: AudioObjectID
    ) throws -> [AudioStreamBasicDescription] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else { throw TapEngineError.tapPropertyReadFailed(status) }
        let count = Int(size) / MemoryLayout<AudioStreamID>.stride
        guard count > 0 else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: count)
        status = streams.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw TapEngineError.tapPropertyReadFailed(status) }

        return try streams.map { stream in
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var asbd = AudioStreamBasicDescription()
            var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioObjectGetPropertyData(
                stream, &formatAddress, 0, nil, &asbdSize, &asbd)
            guard status == noErr else { throw TapEngineError.tapPropertyReadFailed(status) }
            return asbd
        }
    }
}
