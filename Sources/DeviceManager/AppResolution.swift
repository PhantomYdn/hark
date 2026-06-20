import CoreAudio
import Foundation

/// Errors raised while resolving `--app` / `--exclude-app` specifiers.
public enum AppResolutionError: Error, CustomStringConvertible {
    case notFound(String)

    public var description: String {
        switch self {
        case .notFound(let specifier):
            return """
                no capturable process matches '\(specifier)'. The application \
                must be running and registered with the audio system; see \
                'hark apps' for valid bundle IDs and PIDs.
                """
        }
    }
}

extension DeviceManager {
    /// Resolves user-facing app specifiers (numeric PID or bundle ID) to
    /// HAL process objects.
    ///
    /// A bundle ID may match several processes (e.g., app + helpers); all
    /// matches are included. Results are de-duplicated across specifiers.
    public static func resolveApps(specifiers: [String]) throws -> [CapturableApp] {
        let apps = try listCapturableApps()
        var resolved: [CapturableApp] = []
        var seen = Set<UInt32>()

        for specifier in specifiers {
            let matches: [CapturableApp]
            if let pid = pid_t(specifier) {
                matches = apps.filter { $0.pid == pid }
            } else {
                matches = apps.filter {
                    $0.bundleID.caseInsensitiveCompare(specifier) == .orderedSame
                }
            }
            guard !matches.isEmpty else {
                throw AppResolutionError.notFound(specifier)
            }
            for match in matches where seen.insert(match.objectID).inserted {
                resolved.append(match)
            }
        }
        return resolved
    }
}
