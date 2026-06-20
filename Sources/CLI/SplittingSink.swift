import Encoders
import Foundation

/// `--split` specification: `duration=SEC` or `silence=SEC`.
enum SplitSpec: Equatable {
    case duration(Double)
    case silence(Double)

    static func parse(_ raw: String) throws -> SplitSpec {
        let parts = raw.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, let value = Double(parts[1]), value > 0 else {
            throw HarkError.usage(
                "invalid --split '\(raw)'; expected duration=SEC or silence=SEC with a positive number.")
        }
        switch parts[0] {
        case "duration": return .duration(value)
        case "silence": return .silence(value)
        default:
            throw HarkError.usage(
                "unknown --split mode '\(parts[0])'; expected 'duration' or 'silence'.")
        }
    }
}

/// Inserts a sequence number before the extension:
/// `rec.m4a` + 1 -> `rec_001.m4a`.
func chunkPath(base: String, index: Int) -> String {
    let ns = base as NSString
    let ext = ns.pathExtension
    let stem = ext.isEmpty ? base : ns.deletingPathExtension
    let suffix = String(format: "_%03d", index)
    return ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)"
}

/// Splits a PCM stream across sequentially numbered files, each chunk an
/// independently finalized, playable file (PRD §6.5, US04).
///
/// Splitting happens on the PCM side, so any output format works. Chunk
/// boundaries are frame-aligned (the byte threshold is rounded down to a
/// whole frame and incoming writes are frame-multiples).
final class SplittingSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private let byteThreshold: UInt64
    private let makeChunkSink: (Int) throws -> AudioSink
    private var current: AudioSink?
    private var chunkIndex = 0
    private var currentBytes: UInt64 = 0
    private var totalBytes: UInt64 = 0
    let label: String

    /// - Parameters:
    ///   - chunkSeconds: target duration of each chunk.
    ///   - format: PCM stream format (drives the byte threshold).
    ///   - label: human-readable description for stats.
    ///   - makeChunkSink: factory invoked with 1-based chunk numbers.
    init(
        chunkSeconds: Double,
        format: PCMFormat,
        label: String,
        makeChunkSink: @escaping (Int) throws -> AudioSink
    ) {
        let rawBytes = UInt64(chunkSeconds * Double(format.byteRate))
        let frame = UInt64(max(1, format.bytesPerFrame))
        self.byteThreshold = max(frame, rawBytes - (rawBytes % frame))
        self.makeChunkSink = makeChunkSink
        self.label = label
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        var remaining = data
        while !remaining.isEmpty {
            if current == nil {
                chunkIndex += 1
                current = try makeChunkSink(chunkIndex)
                currentBytes = 0
            }
            let capacity = byteThreshold - currentBytes
            let take = min(UInt64(remaining.count), capacity)
            let piece = remaining.prefix(Int(take))
            try current?.write(Data(piece))
            currentBytes += take
            totalBytes += take
            remaining = remaining.dropFirst(Int(take))

            if currentBytes >= byteThreshold {
                try current?.finalize()
                current = nil
            }
        }
    }

    func finalize() throws {
        lock.lock()
        defer { lock.unlock() }
        try current?.finalize()
        current = nil
    }

    var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    /// Number of chunks started so far.
    var chunksCreated: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunkIndex
    }
}
