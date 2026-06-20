import Encoders
import FluidAudio
import Foundation

/// Real-time streaming diarization via FluidAudio **LS-EEND** (long-form
/// streaming end-to-end neural diarization). Unlike the legacy per-segment
/// embedding-clustering path, this ingests the system/single capture stream
/// *continuously* and maintains a frame-level "who-spoke-when" timeline
/// (~100 ms updates) that is independent of the ASR VAD segmentation — so
/// speaker turns are detected by voice (including overlap), not silence. Each
/// completed ASR segment is then attributed to whichever speaker dominates its
/// time window (`label(start:end:)`).
///
/// Apple-Silicon-first (CoreML/ANE). The model loads once and is shared. The
/// underlying `LSEENDDiarizer` is not thread-safe, so every call (ingest,
/// query, finalize) is funneled through one serial queue. The diarizer is fed
/// from the capture I/O thread via `TimelineDiarizerSink` and queried from the
/// transcription worker; the serial queue keeps those ordered.
final class EENDStreamingDiarizer: LiveSpeakerResolver, @unchecked Sendable {
    private let diarizer: LSEENDDiarizer
    private let queue = DispatchQueue(label: "hark.live.eend")
    private var numbering = SpeakerNumbering()
    private var finalized = false

    private init(diarizer: LSEENDDiarizer) { self.diarizer = diarizer }

    /// FluidAudio LS-EEND variant + step. `callhome` is trained on 2-party
    /// single-channel telephone audio — the closest match to Hark's use case
    /// (a call/meeting mixed into one system stream). On real recordings it
    /// separated both a 2-party conversation and a multi-party meeting correctly,
    /// where `ami` (multi-headset meetings) collapsed the 2-party case to one
    /// speaker and `dihard3` under-split the meeting. `step100ms` gives the
    /// lowest-latency frame updates.
    private static let variant: LSEENDVariant = .callhome
    private static let stepSize: LSEENDStepSize = .step100ms

    static func make() throws -> EENDStreamingDiarizer {
        guard Platform.isAppleSilicon else {
            throw HarkError.unavailable("""
                streaming diarization requires Apple Silicon (CoreML/ANE). Deterministic \
                source attribution (--system/--app --mix --speakers --speaker-mode source) \
                works on Intel.
                """)
        }
        if FluidAudioCache.isCached(FluidAudioCache.streamingDiarizerBundle) {
            Log.verbose("loading streaming diarization model")
        } else {
            Log.notice("downloading streaming diarization model (first use)…")
        }
        let box = try RunLoopBridge.runBlocking(timeout: 1800) {
            let diarizer = LSEENDDiarizer()
            try await diarizer.initialize(variant: variant, stepSize: stepSize)
            return UncheckedSendableBox(value: diarizer)
        }
        return EENDStreamingDiarizer(diarizer: box.value)
    }

    /// Pre-downloads the LS-EEND CoreML model (no inference run), for
    /// `hark models download fluidaudio:streaming-diarizer`.
    static func download() throws {
        guard Platform.isAppleSilicon else {
            throw HarkError.unavailable("streaming diarization requires Apple Silicon (CoreML/ANE).")
        }
        Log.notice("downloading streaming diarization model …")
        _ = try RunLoopBridge.runBlocking(timeout: 3600) {
            let diarizer = LSEENDDiarizer()
            try await diarizer.initialize(variant: variant, stepSize: stepSize)
            return UncheckedSendableBox(value: diarizer)
        }
    }

    /// Feeds continuous mono `samples` (at `sampleRate`) to the diarizer,
    /// advancing the timeline. Non-blocking: inference runs on the serial queue.
    func ingest(_ samples: [Float], sampleRate: Double) {
        queue.async { [weak self] in
            guard let self, !self.finalized else { return }
            _ = try? self.diarizer.process(samples: samples, sourceSampleRate: sampleRate)
        }
    }

    /// Flushes the streaming tail at end of capture so the trailing segment's
    /// frames are finalized before the last label query.
    func finalize() {
        queue.sync {
            guard !finalized else { return }
            _ = try? diarizer.finalizeSession()
            finalized = true
        }
    }

    // MARK: LiveSpeakerResolver

    /// Dominant speaker over `[start, end]` (seconds), as a stable `Speaker N`,
    /// or nil when no speaker is active in that window (caller falls back to the
    /// transcriber's fixed label).
    func label(start: Double, end: Double) -> String? {
        queue.sync {
            guard let slot = dominantSlot(start: start, end: end) else { return nil }
            return numbering.label(for: String(slot))
        }
    }

    /// The diarizer output slot with the most speech overlapping `[start, end]`.
    /// Must run on `queue`.
    private func dominantSlot(start: Double, end: Double) -> Int? {
        var overlapBySlot: [Int: Double] = [:]
        for (_, speaker) in diarizer.timeline.speakers {
            for segment in speaker.finalizedSegments + speaker.tentativeSegments {
                let overlap = min(end, Double(segment.endTime)) - max(start, Double(segment.startTime))
                if overlap > 0 {
                    overlapBySlot[segment.speakerIndex, default: 0] += overlap
                }
            }
        }
        return overlapBySlot.max(by: { $0.value < $1.value })?.key
    }
}

/// `AudioSink` that tees a capture stream to the streaming diarizer. Converts
/// interleaved PCM to mono Float and hands it to the (serial, non-blocking)
/// diarizer so CoreML inference never blocks the capture I/O thread.
final class TimelineDiarizerSink: AudioSink, @unchecked Sendable {
    private let diarizer: EENDStreamingDiarizer
    private let format: PCMFormat
    private let lock = NSLock()
    private var count: UInt64 = 0
    let label = "live diarizer (LS-EEND)"

    init(diarizer: EENDStreamingDiarizer, format: PCMFormat) {
        self.diarizer = diarizer
        self.format = format
    }

    func write(_ data: Data) throws {
        lock.lock()
        count += UInt64(data.count)
        lock.unlock()
        let mono = PCMFloat.monoSamples(from: data, format: format)
        if !mono.isEmpty {
            diarizer.ingest(mono, sampleRate: Double(format.sampleRate))
        }
    }

    func finalize() throws { diarizer.finalize() }

    var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Decodes interleaved little-endian PCM (`Data`) to mono `Float` in [-1, 1],
/// averaging channels. Supports 16/24/32-bit signed integer samples.
enum PCMFloat {
    static func monoSamples(from data: Data, format: PCMFormat) -> [Float] {
        let channels = max(1, format.channels)
        switch format.bitsPerSample {
        case 16:
            return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
                let src = raw.bindMemory(to: Int16.self)
                let frames = src.count / channels
                var out = [Float](repeating: 0, count: frames)
                let scale: Float = 1.0 / 32768.0
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += Float(src[f * channels + c]) }
                    out[f] = (sum / Float(channels)) * scale
                }
                return out
            }
        case 32:
            return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
                let src = raw.bindMemory(to: Int32.self)
                let frames = src.count / channels
                var out = [Float](repeating: 0, count: frames)
                let scale: Float = 1.0 / 2147483648.0
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += Float(src[f * channels + c]) }
                    out[f] = (sum / Float(channels)) * scale
                }
                return out
            }
        case 24:
            return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
                let bytes = raw.bindMemory(to: UInt8.self)
                let bytesPerFrame = 3 * channels
                let frames = bytes.count / bytesPerFrame
                var out = [Float](repeating: 0, count: frames)
                let scale: Float = 1.0 / 8388608.0
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels {
                        let i = f * bytesPerFrame + c * 3
                        let rawValue =
                            UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]) << 16
                            | UInt32(bytes[i + 2]) << 24
                        let sample = Int32(bitPattern: rawValue) >> 8  // sign-extended 24-bit
                        sum += Float(sample)
                    }
                    out[f] = (sum / Float(channels)) * scale
                }
                return out
            }
        default:
            return []
        }
    }
}
