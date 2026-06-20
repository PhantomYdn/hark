import Foundation

/// Output container/codec formats Hark knows about.
public enum AudioFileFormat: String, CaseIterable, Sendable {
    case wav
    case m4a
    case flac
    case mp3
    case opus

    /// All known formats are writable: WAV/M4A/FLAC via CoreAudio, MP3 via
    /// vendored LAME, Opus via the native encoder + Ogg muxer.
    public var isWritable: Bool { true }

    /// Detects the format from a file path's extension.
    public static func detect(fromPath path: String) -> AudioFileFormat? {
        AudioFileFormat(rawValue: (path as NSString).pathExtension.lowercased())
    }
}
