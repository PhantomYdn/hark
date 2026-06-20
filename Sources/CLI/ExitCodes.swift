import ArgumentParser

/// Hark exit codes, following BSD `sysexits(3)` where applicable
/// (PRD §6.3: explicit error codes documented; §7: POSIX conventions).
///
/// | Code | Name           | Meaning                                          |
/// |------|----------------|--------------------------------------------------|
/// | 0    | OK             | Success                                          |
/// | 1    | failure        | Generic/unspecified failure                      |
/// | 64   | usage          | Invalid arguments (also used by argument-parser) |
/// | 66   | noInput        | Input file or device not found                   |
/// | 69   | unavailable    | Feature/service not available or not implemented |
/// | 70   | software       | Internal software error                          |
/// | 74   | ioError        | I/O error (file write, audio stream)             |
/// | 77   | noPermission   | Permission denied (e.g., TCC microphone/system)  |
enum HarkExitCode: Int32 {
    case ok = 0
    case failure = 1
    case usage = 64
    case noInput = 66
    case unavailable = 69
    case software = 70
    case ioError = 74
    case noPermission = 77

    var exitCode: ExitCode { ExitCode(rawValue) }
}

/// An error carrying a message for stderr and a specific exit code.
struct HarkError: Error, CustomStringConvertible {
    let code: HarkExitCode
    let message: String

    var description: String { message }

    static func noInput(_ message: String) -> HarkError { .init(code: .noInput, message: message) }
    static func unavailable(_ message: String) -> HarkError { .init(code: .unavailable, message: message) }
    static func software(_ message: String) -> HarkError { .init(code: .software, message: message) }
    static func ioError(_ message: String) -> HarkError { .init(code: .ioError, message: message) }
    static func noPermission(_ message: String) -> HarkError { .init(code: .noPermission, message: message) }
    static func usage(_ message: String) -> HarkError { .init(code: .usage, message: message) }
}
