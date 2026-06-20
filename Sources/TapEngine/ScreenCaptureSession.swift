@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Encoders
import Foundation
import ScreenCaptureKit

/// Captures system/app audio (and, for `--mix`, the microphone) via
/// ScreenCaptureKit (`SCStream`, macOS 15+). Audio is delivered continuously —
/// SCStream emits silence when nothing plays — so `--mix` keeps recording the
/// mic even while system audio is idle (the issue the Core Audio aggregate has).
///
/// Requires the **Screen Recording** TCC permission and a graphical login
/// session; it cannot run headless. The Core Audio `SystemCaptureSession` is the
/// headless-capable fallback.
@available(macOS 15.0, *)
public final class ScreenCaptureSession: NSObject, MultiTrackCaptureSession, SCStreamOutput,
    SCStreamDelegate, @unchecked Sendable
{
    public enum ScreenCaptureError: Error, CustomStringConvertible {
        case permissionDenied
        case noDisplay
        case appNotFound(String)
        case startFailed(String)

        public var description: String {
            switch self {
            case .permissionDenied:
                return """
                    Screen Recording permission denied (required by the \
                    ScreenCaptureKit backend). Enable your terminal under System \
                    Settings > Privacy & Security > Screen & System Audio \
                    Recording, restart it, and retry — or use \
                    --capture-backend coreaudio.
                    """
            case .noDisplay:
                return """
                    ScreenCaptureKit found no display (a graphical login session \
                    is required; it can't run headless). Use --capture-backend \
                    coreaudio for headless capture.
                    """
            case .appNotFound(let spec):
                return "no capturable application matches '\(spec)' (see 'hark apps')"
            case .startFailed(let why):
                return "failed to start ScreenCaptureKit capture: \(why)"
            }
        }
    }

    private let captureSystem: Bool
    private let apps: [String]
    private let excludeApps: [String]
    private let micDeviceUID: String?
    private let mixMic: Bool
    private let outputFormat: PCMFormat

    private let ioQueue = DispatchQueue(label: "hark.sckit.io")
    private var stream: SCStream?
    private var systemConverter: PCMStreamConverter?
    private var micConverter: PCMStreamConverter?
    private var onAudio: (@Sendable (Data) -> Void)?
    private var started = false

    /// When set (and `--mix` is active), each source is also delivered
    /// separately for attribution (PRD §6.7a). The two SCStream outputs are
    /// already separate, so this just tees them before mixing.
    public var onSourceAudio: (@Sendable (CaptureSource, Data) -> Void)?

    // Software mixer state (only used with --mix): converted, output-format
    // packed PCM queued per source and summed by sample position.
    private let mixLock = NSLock()
    private var systemQueue = Data()
    private var micQueue = Data()

    public private(set) var sourceFormatDescription = "ScreenCaptureKit"

    /// Whether the SCKit backend can be used now: Screen Recording is already
    /// granted (which itself requires a GUI grant) and a display is present.
    /// Used by `auto` selection so it never prompts — it falls back to Core
    /// Audio when SCKit isn't usable.
    public static func isAvailable() -> Bool {
        CGPreflightScreenCaptureAccess() && CGMainDisplayID() != 0
    }

    public init(
        captureSystem: Bool, apps: [String], excludeApps: [String],
        micDeviceUID: String?, mixMic: Bool, outputFormat: PCMFormat
    ) {
        self.captureSystem = captureSystem
        self.apps = apps
        self.excludeApps = excludeApps
        self.micDeviceUID = micDeviceUID
        self.mixMic = mixMic
        self.outputFormat = outputFormat
    }

    public func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        precondition(!started, "session already started")
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenCaptureError.permissionDenied
        }

        let content = try Self.shareableContent()
        guard let display = content.displays.first else { throw ScreenCaptureError.noDisplay }
        let filter = try makeFilter(content: content, display: display)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = outputFormat.sampleRate
        config.channelCount = outputFormat.channels
        config.excludesCurrentProcessAudio = true
        // SCStream needs a display in the filter; keep the (unused) video stream
        // tiny and slow since we only consume audio.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        if mixMic {
            config.captureMicrophone = true
            if let micDeviceUID { config.microphoneCaptureDeviceID = micDeviceUID }
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: ioQueue)
        if mixMic {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: ioQueue)
        }
        self.stream = stream
        self.onAudio = onAudio

        try Self.startCapture(stream)
        started = true
    }

    public func stop() {
        guard started, let stream else { return }
        Self.stopCapture(stream)
        self.stream = nil
        started = false
    }

    deinit { stop() }

    // MARK: SCStreamOutput

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .audio:
            guard let data = convert(sampleBuffer, converter: &systemConverter) else { return }
            if mixMic {
                onSourceAudio?(.system, data)
                enqueue(system: data)
            } else {
                onAudio?(data)
            }
        case .microphone:
            guard mixMic, let data = convert(sampleBuffer, converter: &micConverter) else { return }
            onSourceAudio?(.microphone, data)
            enqueue(mic: data)
        default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        if ProcessInfo.processInfo.environment["HARK_DEBUG"] != nil {
            FileHandle.standardError.write(
                Data("hark: ScreenCaptureKit stream stopped: \(error.localizedDescription)\n".utf8))
        }
    }

    // MARK: Mixing

    private func enqueue(system data: Data) {
        mixLock.lock(); systemQueue.append(data); let out = drainMix(); mixLock.unlock()
        out.forEach { onAudio?($0) }
    }

    private func enqueue(mic data: Data) {
        mixLock.lock(); micQueue.append(data); let out = drainMix(); mixLock.unlock()
        out.forEach { onAudio?($0) }
    }

    /// Sums the common prefix of the two queues (same output format) and returns
    /// the mixed chunk; the unmatched tail stays buffered. Caller holds mixLock.
    private func drainMix() -> [Data] {
        let frame = outputFormat.bytesPerFrame
        let n = min(systemQueue.count, micQueue.count) / frame * frame
        guard n > 0 else { return [] }
        let mixed = StreamMixing.sum(
            Data(systemQueue.prefix(n)), Data(micQueue.prefix(n)), format: outputFormat)
        systemQueue.removeFirst(n)
        micQueue.removeFirst(n)
        return [mixed]
    }

    // MARK: Conversion

    /// CMSampleBuffer (Float PCM) → packed output-format PCM via a lazily-built
    /// converter keyed off the buffer's actual format.
    private func convert(_ sampleBuffer: CMSampleBuffer, converter: inout PCMStreamConverter?) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }
        var asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        if converter == nil {
            converter = try? PCMStreamConverter(inputFormat: inputFormat, outputFormat: outputFormat)
        }
        guard let converter,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return converter.convert(buffer)
    }

    // MARK: Content filter

    private func makeFilter(content: SCShareableContent, display: SCDisplay) throws -> SCContentFilter {
        if !apps.isEmpty {
            return SCContentFilter(
                display: display, including: try match(apps, in: content),
                exceptingWindows: [])
        }
        if !excludeApps.isEmpty {
            return SCContentFilter(
                display: display, excludingApplications: try match(excludeApps, in: content),
                exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    }

    private func match(_ specifiers: [String], in content: SCShareableContent) throws
        -> [SCRunningApplication]
    {
        try specifiers.map { spec in
            guard let app = content.applications.first(where: {
                $0.bundleIdentifier == spec || String($0.processID) == spec
            }) else { throw ScreenCaptureError.appNotFound(spec) }
            return app
        }
    }

    // MARK: async → sync bridges

    private static func shareableContent() throws -> SCShareableContent {
        let box = ResultBox<SCShareableContent>()
        let semaphore = DispatchSemaphore(value: 0)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
            content, error in
            if let content { box.set(.success(content)) } else {
                box.set(.failure(error ?? ScreenCaptureError.permissionDenied))
            }
            semaphore.signal()
        }
        semaphore.wait()
        do { return try box.get() } catch { throw ScreenCaptureError.permissionDenied }
    }

    private static func startCapture(_ stream: SCStream) throws {
        let box = ResultBox<Void>()
        let semaphore = DispatchSemaphore(value: 0)
        stream.startCapture { error in
            box.set(error.map { .failure($0) } ?? .success(()))
            semaphore.signal()
        }
        semaphore.wait()
        do { try box.get() } catch { throw ScreenCaptureError.startFailed("\(error)") }
    }

    private static func stopCapture(_ stream: SCStream) {
        let semaphore = DispatchSemaphore(value: 0)
        stream.stopCapture { _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 5)
    }
}

/// Thread-safe one-shot result holder for the async→sync bridges.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error> = .failure(NSError(domain: "hark", code: -1))
    func set(_ result: Result<T, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() throws -> T { lock.lock(); defer { lock.unlock() }; return try value.get() }
}
