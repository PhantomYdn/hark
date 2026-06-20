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
    private let transcriber: TranscriptionBackend
    private let language: String?
    private let translate: Bool
    private let writer: LiveTranscriptWriter
    private let format: PCMFormat
    private let segmenter: SpeechSegmenter
    private let speaker: String?
    private let resolver: LiveSpeakerResolver?
    private let useGain: Bool
    private let ownsBackend: Bool
    private let ownsWriter: Bool

    // Interactive captions: when the transcript is persisted to a file the
    // interactive UI gets nothing on stdout, so the live paths ask the
    // transcriber to also echo each finalised segment (plain text, with the
    // speaker label when set) to `screen` so captions still appear on-screen
    // (PRD §6.9). Off by default; `screen` is injectable for tests.
    private let screenEcho: Bool
    private let screen: FileHandle

    private var totalBytes: UInt64 = 0

    // Transcription runs on a serial queue so segments are transcribed and
    // emitted strictly in order.
    private let worker = DispatchQueue(label: "hark.live.transcribe")
    private let failure = FailureBox()

    let label: String

    /// Designated init. `ownsBackend`/`ownsWriter` control teardown so several
    /// transcribers can share one engine + transcript (source attribution).
    /// `speaker`, when set, labels every emitted segment (PRD §6.7).
    init(
        backend: TranscriptionBackend,
        writer: LiveTranscriptWriter,
        ownsBackend: Bool,
        ownsWriter: Bool,
        speaker: String?,
        language: String?,
        translate: Bool,
        captureFormat: PCMFormat,
        silenceThresholdDBFS: Double,
        labelName: String,
        resolver: LiveSpeakerResolver? = nil,
        useVad: Bool = true,
        vadThreshold: Double? = nil,
        useGain: Bool = true,
        screenEcho: Bool = false,
        screen: FileHandle = .standardOutput,
        pauseSeconds: Double = 0.7,
        maxWindowSeconds: Double = 12,
        minSegmentSeconds: Double = 0.4
    ) {
        self.transcriber = backend
        self.writer = writer
        self.ownsBackend = ownsBackend
        self.ownsWriter = ownsWriter
        self.speaker = speaker
        self.resolver = resolver
        self.useGain = useGain
        self.screenEcho = screenEcho
        self.screen = screen
        self.language = language
        self.translate = translate
        self.format = captureFormat
        self.segmenter = SpeechSegmenterFactory.make(
            format: captureFormat, silenceThresholdDBFS: silenceThresholdDBFS,
            useVad: useVad, vadThreshold: vadThreshold, pauseSeconds: pauseSeconds,
            maxWindowSeconds: maxWindowSeconds, minSegmentSeconds: minSegmentSeconds)
        self.label = labelName

        // The segmenter calls back synchronously on the capture I/O queue;
        // hand each finished segment to the serial transcription worker.
        segmenter.onSegment = { [weak self] segment, start, end in
            self?.enqueue(segment, start: start, end: end)
        }
        Log.verbose("""
            live transcription: \(transcriber.label)\(speaker.map { " [\($0)]" } ?? ""); \
            pause \(pauseSeconds)s, window \(maxWindowSeconds)s, threshold \(silenceThresholdDBFS) dBFS
            """)
    }

    /// Single-stream convenience: builds its own engine + transcript writer.
    convenience init(
        destination: TranscriptDestination,
        transcriptFormat: TranscriptOutputFormat,
        engineName: String,
        modelFlag: String?,
        language: String?,
        translate: Bool,
        captureFormat: PCMFormat,
        silenceThresholdDBFS: Double,
        useVad: Bool = true,
        vadThreshold: Double? = nil,
        useGain: Bool = true,
        screenEcho: Bool = false,
        pauseSeconds: Double = 0.7,
        maxWindowSeconds: Double = 12,
        minSegmentSeconds: Double = 0.4
    ) throws {
        let backend = try TranscriptionEngine.makeLive(
            engineName: engineName, modelFlag: modelFlag, language: language, quiet: !Log.isVerbose)
        let writer = try LiveTranscriptWriter(destination: destination, format: transcriptFormat)
        self.init(
            backend: backend, writer: writer, ownsBackend: true, ownsWriter: true, speaker: nil,
            language: language, translate: translate, captureFormat: captureFormat,
            silenceThresholdDBFS: silenceThresholdDBFS, labelName: "live transcript -> \(destination.label)",
            useVad: useVad, vadThreshold: vadThreshold, useGain: useGain, screenEcho: screenEcho,
            pauseSeconds: pauseSeconds,
            maxWindowSeconds: maxWindowSeconds, minSegmentSeconds: minSegmentSeconds)
    }

    /// Source-attribution convenience: shares an engine + transcript writer with
    /// the other source pipeline. `speaker` is the fallback label; a `resolver`
    /// (acoustic diarization) overrides it per segment when set.
    convenience init(
        sharedWriter: LiveTranscriptWriter,
        sharedBackend: TranscriptionBackend,
        speaker: String,
        resolver: LiveSpeakerResolver? = nil,
        language: String?,
        translate: Bool,
        captureFormat: PCMFormat,
        silenceThresholdDBFS: Double,
        useVad: Bool = true,
        vadThreshold: Double? = nil,
        useGain: Bool = true,
        screenEcho: Bool = false,
        pauseSeconds: Double = 0.7,
        maxWindowSeconds: Double = 12,
        minSegmentSeconds: Double = 0.4
    ) {
        self.init(
            backend: sharedBackend, writer: sharedWriter, ownsBackend: false, ownsWriter: false,
            speaker: speaker, language: language, translate: translate, captureFormat: captureFormat,
            silenceThresholdDBFS: silenceThresholdDBFS, labelName: "live transcript [\(speaker)]",
            resolver: resolver, useVad: useVad, vadThreshold: vadThreshold, useGain: useGain,
            screenEcho: screenEcho, pauseSeconds: pauseSeconds, maxWindowSeconds: maxWindowSeconds,
            minSegmentSeconds: minSegmentSeconds)
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
                let (text, speaker) = try self.transcribeSegment(
                    segment, format: segFormat, start: start, end: end)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !Self.isNonSpeech(trimmed) {
                    try self.writer.append(text: trimmed, start: start, end: end, speaker: speaker)
                    // Interactive captions: when the transcript is persisted to a
                    // file the writer never reaches the UI, so mirror the plain
                    // text (with the speaker label when set) to the screen so the
                    // live transcript still appears on-screen (PRD §6.9).
                    if self.screenEcho {
                        let line = (speaker.map { "\($0): " } ?? "") + trimmed + "\n"
                        try? self.screen.write(contentsOf: Data(line.utf8))
                    }
                }
            } catch {
                _ = self.failure.store(error)
            }
        }
    }

    /// Stages one segment as a temporary WAV, normalizes it to whisper's
    /// 16 kHz mono format, and returns the recognized text plus its speaker
    /// label (from the optional acoustic resolver over `[start, end]`, else the
    /// fixed label).
    private func transcribeSegment(
        _ pcm: Data, format: PCMFormat, start: Double, end: Double
    ) throws -> (text: String, speaker: String?) {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-seg-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: raw) }
        // Boost quiet segments toward a target peak so the engine recognizes
        // low-level captures (the `-a` recording is unaffected — this only
        // touches the temp WAV fed to the engine). Disable with HARK_GAIN=off.
        let boosted = useGain ? GainNormalizer.normalize(pcm, format: format) : pcm
        let writer = try WAVFileWriter(destination: .file(raw), format: format)
        try writer.write(boosted)
        try writer.finalize()

        let normalized = try AudioPipeline.normalizeFileForWhisper(raw.path)
        defer { try? FileManager.default.removeItem(at: normalized) }
        let text = try transcriber.transcribe(
            wavFile: normalized, language: language, translate: translate, format: .txt)
        let speaker = resolver?.label(start: start, end: end) ?? self.speaker
        return (text, speaker)
    }

    func finalize() throws {
        // Emit the trailing segment, drain the queue, then release owned
        // resources (a shared engine/writer is released by its owner).
        segmenter.finish()
        worker.sync {}
        if ownsBackend { transcriber.shutdown() }
        if ownsWriter { try? writer.close() }
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
final class StreamSegmenter: SpeechSegmenter {
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
                throw HarkError.ioError("cannot open transcript file '\(path)' for writing")
            }
            self.handle = handle
            self.closeHandle = true
        }
    }

    func append(text: String, start: Double, end: Double, speaker: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        let chunk: String
        switch format {
        case .txt:
            chunk = (speaker.map { "\($0): " } ?? "") + text + "\n"
        case .srt:
            cueIndex += 1
            let body = (speaker.map { "[\($0)] " } ?? "") + text
            chunk = "\(cueIndex)\n\(Self.srtTimestamp(start)) --> \(Self.srtTimestamp(end))\n\(body)\n\n"
        case .json:
            chunk = Self.jsonLine(start: start, end: end, text: text, speaker: speaker) + "\n"
        }
        do {
            try handle.write(contentsOf: Data(chunk.utf8))
        } catch {
            // A closed downstream pipe (transcript to stdout, reader gone / Ctrl+C)
            // surfaces here as EPIPE wrapped in NSCocoaError 512. Propagate it raw
            // so the graceful broken-pipe handlers (rethrowErrors / CaptureEngine)
            // recognize it instead of masking it as a generic write failure.
            if isBrokenPipe(error) { throw error }
            throw HarkError.ioError("transcript write failed: \(error)")
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

    /// One-line JSON object for JSON-lines output. `speaker` is optional and
    /// omitted when nil (synthesized encodeIfPresent), so default output is
    /// byte-identical to the no-speaker case.
    static func jsonLine(start: Double, end: Double, text: String, speaker: String? = nil) -> String {
        struct Segment: Encodable {
            let start: Double
            let end: Double
            let text: String
            let speaker: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let segment = Segment(start: start, end: end, text: text, speaker: speaker)
        guard let data = try? encoder.encode(segment) else {
            return "{\"start\":\(start),\"end\":\(end),\"text\":\"\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
