import Foundation

/// Output container/codec formats Aural knows about.
public enum AudioFileFormat: String, CaseIterable, Sendable {
    case wav
    case m4a
    case flac
    case mp3
    case opus

    /// Formats that can currently be written. Ogg/Opus (Ogg muxer) is planned —
    /// see PLAN.md Phase 3.
    public var isWritable: Bool {
        switch self {
        case .wav, .m4a, .flac, .mp3: return true
        case .opus: return false
        }
    }

    /// Detects the format from a file path's extension.
    public static func detect(fromPath path: String) -> AudioFileFormat? {
        AudioFileFormat(rawValue: (path as NSString).pathExtension.lowercased())
    }
}
