import Encoders
import Foundation

/// Destination for captured PCM data.
protocol AudioSink: Sendable {
    func write(_ data: Data) throws
    func finalize() throws
    var bytesWritten: UInt64 { get }
    /// Human-readable destination for verbose stats.
    var label: String { get }
}

/// A per-source sink that holds the user's recording — today only the `-a`
/// file written from the separated sources by `--tracks stereo`.
///
/// `CaptureEngine` writes per-source chunks best-effort, because the usual
/// per-source sink is a transcriber feed or a temporary diarization WAV whose
/// loss costs a transcript, not the recording. A `RecordingSink` is the
/// artifact itself, so the engine treats a failed write on one exactly as it
/// treats a failed write on the mixed stream: stop and report, rather than
/// leave a silently truncated file behind a success exit.
protocol RecordingSink: AudioSink {}

/// WAV container output (file or stdout stream).
final class WAVSink: AudioSink, @unchecked Sendable {
    private let writer: WAVFileWriter
    let label: String

    init(writer: WAVFileWriter, label: String) {
        self.writer = writer
        self.label = label
    }

    func write(_ data: Data) throws { try writer.write(data) }
    func finalize() throws { try writer.finalize() }
    var bytesWritten: UInt64 { writer.bytesWritten }
}

/// Encoded file output (M4A/AAC, FLAC) via native CoreAudio encoders.
final class EncodedSink: AudioSink, @unchecked Sendable {
    private let writer: EncodedFileWriter
    let label: String

    init(writer: EncodedFileWriter, label: String) {
        self.writer = writer
        self.label = label
    }

    func write(_ data: Data) throws { try writer.write(data) }
    func finalize() throws { try writer.finalize() }
    var bytesWritten: UInt64 { writer.bytesWritten }
}

/// Encodes the capture stream to MP3 via vendored libmp3lame.
final class MP3Sink: AudioSink, @unchecked Sendable {
    private let writer: MP3FileWriter
    let label: String

    init(writer: MP3FileWriter, label: String) {
        self.writer = writer
        self.label = label
    }

    func write(_ data: Data) throws { try writer.write(data) }
    func finalize() throws { try writer.finalize() }
    var bytesWritten: UInt64 { writer.bytesWritten }
}

/// Encodes the capture stream to Ogg/Opus via the native encoder + Ogg muxer.
final class OpusSink: AudioSink, @unchecked Sendable {
    private let writer: OpusFileWriter
    let label: String

    init(writer: OpusFileWriter, label: String) {
        self.writer = writer
        self.label = label
    }

    func write(_ data: Data) throws { try writer.write(data) }
    func finalize() throws { try writer.finalize() }
    var bytesWritten: UInt64 { writer.bytesWritten }
}

/// Headerless PCM to a file handle (default for piped stdout).
final class RawStreamSink: AudioSink, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var count: UInt64 = 0
    let label: String

    init(handle: FileHandle, label: String) {
        self.handle = handle
        self.label = label
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
        count += UInt64(data.count)
    }

    func finalize() throws {}

    var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Counts and discards audio (--no-output dry run).
final class DiscardSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0
    let label = "discarded (--no-output)"

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        count += UInt64(data.count)
    }

    func finalize() throws {}

    var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Returns true if the error chain bottoms out in EPIPE (downstream pipe
/// closed) — treated as graceful completion, matching Unix conventions.
func isBrokenPipe(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    while let nsError = current {
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EPIPE) {
            return true
        }
        current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
}
