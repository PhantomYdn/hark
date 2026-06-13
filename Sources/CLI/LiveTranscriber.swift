import Encoders
import Foundation

/// Live transcription sink. Plugs into `CaptureEngine.run(into:)` alongside
/// the optional audio sink and tees the same PCM through a segmenter:
/// the stream is cut on natural pauses (silence) with a maximum-window cap,
/// and each completed segment is transcribed as soon as it closes and
/// appended to the transcript destination — keeping output as close to
/// runtime as possible without a streaming engine (PRD §6.6).
///
/// Whisper is invoked once per segment (per-segment model reload); a
/// persistent-process optimization is tracked as a follow-up. Timestamps are
/// sample-accurate, derived from the capture byte clock.
final class LiveTranscriber: AudioSink, @unchecked Sendable {
    private let whisper: WhisperEngine
    private let language: String?
    private let writer: LiveTranscriptWriter
    private let format: PCMFormat
    private let quietEngine: Bool
    private let segmenter: StreamSegmenter

    private var totalBytes: UInt64 = 0

    // Transcription runs on a serial queue so segments are transcribed and
    // emitted strictly in order.
    private let worker = DispatchQueue(label: "aural.live.transcribe")
    private let failure = FailureBox()

    let label: String

    init(
        destination: TranscriptDestination,
        transcriptFormat: TranscriptOutputFormat,
        engineName: String,
        modelFlag: String?,
        language: String?,
        captureFormat: PCMFormat,
        silenceThresholdDBFS: Double,
        pauseSeconds: Double = 0.7,
        maxWindowSeconds: Double = 12,
        minSegmentSeconds: Double = 0.4
    ) throws {
        self.whisper = try TranscribeEngine.resolveWhisper(
            engineName: engineName, modelFlag: modelFlag)
        self.language = language
        self.format = captureFormat
        self.quietEngine = !Log.isVerbose
        self.writer = try LiveTranscriptWriter(
            destination: destination, format: transcriptFormat)
        self.segmenter = StreamSegmenter(
            format: captureFormat, silenceThresholdDBFS: silenceThresholdDBFS,
            pauseSeconds: pauseSeconds, maxWindowSeconds: maxWindowSeconds,
            minSegmentSeconds: minSegmentSeconds)
        self.label = "live transcript -> \(destination.label)"

        // The segmenter calls back synchronously on the capture I/O queue;
        // hand each finished segment to the serial transcription worker.
        segmenter.onSegment = { [weak self] segment, start, end in
            self?.enqueue(segment, start: start, end: end)
        }
        Log.verbose("""
            live transcription: pause \(pauseSeconds)s, window \(maxWindowSeconds)s, \
            threshold \(silenceThresholdDBFS) dBFS
            """)
    }

    func write(_ data: Data) throws {
        guard failure.take() == nil else { return }  // stop after an engine error
        totalBytes += UInt64(data.count)
        segmenter.consume(data)
    }

    /// Queues a finished segment for in-order transcription and emission.
    private func enqueue(_ segment: Data, start: Double, end: Double) {
        let segFormat = format
        worker.async { [weak self] in
            guard let self, self.failure.take() == nil else { return }
            do {
                let text = try self.transcribeSegment(segment, format: segFormat)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !Self.isNonSpeech(trimmed) {
                    try self.writer.append(text: trimmed, start: start, end: end)
                }
            } catch {
                _ = self.failure.store(error)
            }
        }
    }

    /// Stages one segment as a temporary WAV, normalizes it to whisper's
    /// 16 kHz mono format, and returns the recognized text.
    private func transcribeSegment(_ pcm: Data, format: PCMFormat) throws -> String {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-seg-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: raw) }
        let writer = try WAVFileWriter(destination: .file(raw), format: format)
        try writer.write(pcm)
        try writer.finalize()

        let normalized = try AudioPipeline.normalizeFileForWhisper(raw.path)
        defer { try? FileManager.default.removeItem(at: normalized) }
        return try whisper.transcribe(
            wavFile: normalized, language: language, format: .txt, quietStderr: quietEngine)
    }

    func finalize() throws {
        // Emit the trailing segment, then wait for the queue to drain.
        segmenter.finish()
        worker.sync {}
        try? writer.close()
    }

    /// Surfaces a stored transcription error after capture finishes. Broken
    /// pipes (closed downstream) are treated as graceful completion.
    func rethrowErrors() throws {
        guard let error = failure.take() else { return }
        if isBrokenPipe(error) {
            Log.verbose("transcript pipe closed, stopping")
            return
        }
        throw error
    }

    var bytesWritten: UInt64 { totalBytes }

    /// whisper.cpp emits placeholder tokens for silence/non-speech segments;
    /// drop them so the transcript holds only recognized speech.
    private static func isNonSpeech(_ text: String) -> Bool {
        let markers = ["[BLANK_AUDIO]", "[silence]", "(silence)", "[ Silence ]", "[MUSIC]", "(buzzer)"]
        return markers.contains { text.caseInsensitiveCompare($0) == .orderedSame }
    }
}

/// Cuts a live PCM stream into transcription-sized segments. A segment is
/// closed when a speech segment is followed by a pause (`pauseSeconds` of
/// audio below the silence threshold), or when it reaches the maximum window
/// (`maxWindowSeconds`) so long monologues still emit. Windows of pure
/// silence are dropped — the clock advances but no segment is produced.
///
/// `consume`/`finish` and `onSegment` are driven serially from the capture
/// I/O queue; the class holds no locks.
final class StreamSegmenter {
    private let format: PCMFormat
    private let silenceBoundaryBytes: Int
    private let maxWindowBytes: Int
    private let minSegmentBytes: Int
    private let linearThreshold: Double

    private var buffer = Data()
    private var hadSpeech = false
    private var silenceRunBytes = 0
    private var emittedBytes: UInt64 = 0

    /// Called with each finished segment: (PCM, startSeconds, endSeconds).
    var onSegment: ((Data, Double, Double) -> Void)?

    init(
        format: PCMFormat,
        silenceThresholdDBFS: Double,
        pauseSeconds: Double,
        maxWindowSeconds: Double,
        minSegmentSeconds: Double
    ) {
        self.format = format
        let byteRate = Double(format.byteRate)
        let frame = max(1, format.bytesPerFrame)
        func align(_ seconds: Double) -> Int {
            let n = Int(seconds * byteRate)
            return max(frame, n - (n % frame))
        }
        self.silenceBoundaryBytes = align(pauseSeconds)
        self.maxWindowBytes = align(maxWindowSeconds)
        self.minSegmentBytes = align(minSegmentSeconds)
        self.linearThreshold = pow(10, silenceThresholdDBFS / 20)
    }

    func consume(_ data: Data) {
        buffer.append(data)
        if peakAmplitude(of: data, format: format) < linearThreshold {
            silenceRunBytes += data.count
        } else {
            hadSpeech = true
            silenceRunBytes = 0
        }

        if hadSpeech && buffer.count >= minSegmentBytes
            && silenceRunBytes >= silenceBoundaryBytes
        {
            flush()
        } else if buffer.count >= maxWindowBytes {
            if hadSpeech {
                flush()  // long monologue: cut at the window cap
            } else {
                // A window of pure silence: advance the clock, drop the audio.
                emittedBytes += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                silenceRunBytes = 0
            }
        }
    }

    /// Emits any trailing speech as a final segment.
    func finish() {
        if hadSpeech && !buffer.isEmpty { flush() }
        buffer.removeAll()
    }

    private func flush() {
        let segment = buffer
        buffer = Data()
        let start = Double(emittedBytes) / Double(format.byteRate)
        emittedBytes += UInt64(segment.count)
        let end = Double(emittedBytes) / Double(format.byteRate)
        hadSpeech = false
        silenceRunBytes = 0
        onSegment?(segment, start, end)
    }
}

/// Appends transcript segments to a destination (file or stdout) as they are
/// produced, formatting each according to the requested transcript format.
/// File writes are unbuffered so `tail -f` reflects progress live.
final class LiveTranscriptWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let closeHandle: Bool
    private let format: TranscriptOutputFormat
    private let lock = NSLock()
    private var cueIndex = 0

    init(destination: TranscriptDestination, format: TranscriptOutputFormat) throws {
        self.format = format
        switch destination {
        case .stdout:
            self.handle = .standardOutput
            self.closeHandle = false
        case .file(let path):
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: path) else {
                throw AuralError.ioError("cannot open transcript file '\(path)' for writing")
            }
            self.handle = handle
            self.closeHandle = true
        }
    }

    func append(text: String, start: Double, end: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        let chunk: String
        switch format {
        case .txt:
            chunk = text + "\n"
        case .srt:
            cueIndex += 1
            chunk = "\(cueIndex)\n\(Self.srtTimestamp(start)) --> \(Self.srtTimestamp(end))\n\(text)\n\n"
        case .json:
            chunk = Self.jsonLine(start: start, end: end, text: text) + "\n"
        }
        do {
            try handle.write(contentsOf: Data(chunk.utf8))
        } catch {
            throw AuralError.ioError("transcript write failed: \(error)")
        }
    }

    func close() throws {
        if closeHandle { try? handle.close() }
    }

    /// SRT timestamp: `HH:MM:SS,mmm`.
    static func srtTimestamp(_ seconds: Double) -> String {
        let total = Int((seconds * 1000).rounded())
        let hours = total / 3_600_000
        let minutes = (total % 3_600_000) / 60_000
        let secs = (total % 60_000) / 1000
        let millis = total % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    /// One-line JSON object for JSON-lines output.
    static func jsonLine(start: Double, end: Double, text: String) -> String {
        struct Segment: Encodable {
            let start: Double
            let end: Double
            let text: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(Segment(start: start, end: end, text: text)) else {
            return "{\"start\":\(start),\"end\":\(end),\"text\":\"\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
