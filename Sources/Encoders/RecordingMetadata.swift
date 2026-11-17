import Foundation

/// What hark records about a capture inside the audio file itself (PRD
/// Feature 11): when it started, what it captured, and which hark wrote it.
/// Each container stores it its own way: a WAV `LIST/INFO` chunk
/// (`ICRD`/`INAM`/`ISFT`), an ID3v2 tag in mp3, iTunes-style atoms in m4a.
public struct RecordingMetadata: Sendable {
    /// Recording start time; stored as its local calendar date.
    public var creationDate: Date?
    /// Writing software, e.g. "hark 0.8.0".
    public var software: String?
    /// What was captured: the device or app name.
    public var title: String?

    public init(creationDate: Date? = nil, software: String? = nil, title: String? = nil) {
        self.creationDate = creationDate
        self.software = software
        self.title = title
    }

    var isEmpty: Bool { creationDate == nil && software == nil && title == nil }

    /// The recording date as `yyyy-MM-dd` in the local time zone.
    var dateString: String? {
        guard let creationDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: creationDate)
    }
}
