import Encoders
import FluidAudio
import Foundation

/// `VoiceActivityStream` backed by FluidAudio's streaming Silero VAD (CoreML/ANE).
/// Loads the model once (downloaded from Hugging Face on first use into
/// FluidAudio's cache) and carries the Silero hysteresis state across windows.
/// Single-consumer: driven serially by `VadSegmenter`'s consumer task.
final class FluidVadClassifier: VoiceActivityStream, @unchecked Sendable {
    private let manager: VadManager
    private let config: VadSegmentationConfig
    private var state: VadStreamState = .initial()

    var windowSamples: Int { VadManager.chunkSize }

    private init(manager: VadManager, config: VadSegmentationConfig) {
        self.manager = manager
        self.config = config
    }

    func process(_ window: [Float]) async throws -> VoiceActivityEvent? {
        let result = try await manager.processStreamingChunk(
            window, state: state, config: config, returnSeconds: false)
        state = result.state
        guard let event = result.event else { return nil }
        switch event.kind {
        case .speechStart: return .speechStart(sample: event.sampleIndex)
        case .speechEnd: return .speechEnd(sample: event.sampleIndex)
        }
    }

    // The VAD model is loaded once per process and shared across classifiers
    // (e.g. the two source-attribution streams); each instance keeps its own
    // streaming state.
    private static let modelLock = NSLock()
    private static nonisolated(unsafe) var sharedManager: VadManager?

    /// Builds a classifier over the shared VAD model (loading it on first use,
    /// off the capture I/O thread at `LiveTranscriber` init). Throws if the
    /// model can't be loaded/downloaded so the factory can fall back to
    /// amplitude segmentation.
    /// Default speech-probability gate. Lower than FluidAudio's 0.85 so quieter
    /// speech still opens a segment (PRD §6.6); tune with `--vad-threshold`.
    static let defaultThreshold = 0.5

    static func makeLoading(
        pauseSeconds: Double, maxWindowSeconds: Double, threshold: Double
    ) throws -> FluidVadClassifier {
        let manager = try sharedVadManager(threshold: threshold)
        let config = VadSegmentationConfig(
            minSilenceDuration: pauseSeconds, maxSpeechDuration: maxWindowSeconds)
        return FluidVadClassifier(manager: manager, config: config)
    }

    private static func sharedVadManager(threshold: Double) throws -> VadManager {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let sharedManager { return sharedManager }
        if FluidAudioCache.isCached(FluidAudioCache.vadBundle) {
            Log.verbose("loading VAD model (threshold \(threshold))")
        } else {
            Log.notice("downloading VAD model (first use)…")
        }
        let config = VadConfig(defaultThreshold: Float(threshold))
        let manager: VadManager = try RunLoopBridge.runBlocking(timeout: 1800) {
            try await VadManager(config: config)
        }
        sharedManager = manager
        return manager
    }

    /// Pre-downloads the Silero VAD model (no streaming run), for
    /// `hark models download fluidaudio:vad` — lets privacy-conscious users
    /// avoid the first-live-run fetch.
    static func downloadModel() throws {
        guard Platform.isAppleSilicon else {
            throw HarkError.unavailable("the VAD model runs on Apple Silicon (CoreML/ANE).")
        }
        Log.notice("downloading VAD model …")
        _ = try RunLoopBridge.runBlocking(timeout: 1800) {
            UncheckedSendableBox(value: try await VadManager())
        }
    }
}

/// Builds the live `SpeechSegmenter`: VAD (Silero, FluidAudio) when usable,
/// otherwise the amplitude-threshold `StreamSegmenter` (current behavior).
/// VAD is used unless `HARK_VAD=0`, on Apple Silicon, and only if its model
/// loads; any failure falls back so transcription is never blocked (PRD §6.7).
enum SpeechSegmenterFactory {
    static func make(
        format: PCMFormat,
        silenceThresholdDBFS: Double,
        useVad: Bool,
        vadThreshold: Double?,
        pauseSeconds: Double,
        maxWindowSeconds: Double,
        minSegmentSeconds: Double
    ) -> SpeechSegmenter {
        if useVad, Platform.isAppleSilicon,
            let classifier = try? FluidVadClassifier.makeLoading(
                pauseSeconds: pauseSeconds, maxWindowSeconds: maxWindowSeconds,
                threshold: vadThreshold ?? FluidVadClassifier.defaultThreshold)
        {
            Log.verbose("live segmentation: VAD (Silero, FluidAudio)")
            let converter = AudioConverter()
            let resample: @Sendable ([Float], Double) throws -> [Float] = { samples, rate in
                rate == 16000 ? samples : try converter.resample(samples, from: rate)
            }
            return VadSegmenter(
                format: format, classifier: classifier, resample: resample,
                maxWindowSeconds: maxWindowSeconds, minSegmentSeconds: minSegmentSeconds)
        }
        Log.verbose("live segmentation: amplitude threshold (\(silenceThresholdDBFS) dBFS)")
        return StreamSegmenter(
            format: format, silenceThresholdDBFS: silenceThresholdDBFS,
            pauseSeconds: pauseSeconds, maxWindowSeconds: maxWindowSeconds,
            minSegmentSeconds: minSegmentSeconds)
    }
}
