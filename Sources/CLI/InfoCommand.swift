import ArgumentParser
import AudioToolbox
import Foundation

/// Inspection result for `hark info` (also the `--json` shape).
struct AudioFileDetails: Codable {
    let path: String
    let format: String
    let sampleRate: Double
    let channels: Int
    /// Bits per channel; 0 for lossy/compressed codecs.
    let bitsPerChannel: Int
    let durationSeconds: Double
    /// Bits per second; 0 when the file does not report one.
    let bitRate: Int
    let metadata: [String: String]
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print duration, format, and metadata of an audio file.",
        discussion: "Reads WAV, AIFF, CAF, M4A, FLAC, and MP3 files."
    )

    @Argument(help: ArgumentHelp(
        "Audio file to inspect.", valueName: "path"))
    var input: String

    @Flag(help: "Output as JSON for scripting.")
    var json = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            let details = try Self.inspect(path: input)
            if json {
                print(try OutputFormatting.json(details))
                return
            }
            var rows: [[String]] = [
                ["format", details.format],
                ["duration", String(format: "%.3f s", details.durationSeconds)],
                ["sample rate", "\(Int(details.sampleRate)) Hz"],
                ["channels", String(details.channels)],
            ]
            if details.bitsPerChannel > 0 {
                rows.append(["bit depth", "\(details.bitsPerChannel)-bit"])
            }
            if details.bitRate > 0 {
                rows.append(["bit rate", "\(details.bitRate / 1000) kbps"])
            }
            for key in details.metadata.keys.sorted() {
                rows.append([key, details.metadata[key] ?? ""])
            }
            print(OutputFormatting.table(header: ["FIELD", "VALUE"], rows: rows))
        }
    }

    /// Reads format and metadata via the AudioFile API.
    static func inspect(path: String) throws -> AudioFileDetails {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw HarkError.noInput("no such file: \(path)")
        }
        var fileID: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
        guard openStatus == noErr, let file = fileID else {
            throw HarkError.noInput(
                "cannot read '\(path)' as audio (CoreAudio error \(openStatus))")
        }
        defer { AudioFileClose(file) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd) == noErr
        else {
            throw HarkError.software("failed to read data format of '\(path)'")
        }

        var duration: Double = 0
        size = UInt32(MemoryLayout<Double>.size)
        _ = AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)

        var bitRate: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitRate)

        var metadata: [String: String] = [:]
        var dictionary: Unmanaged<CFDictionary>?
        size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        if AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &dictionary)
            == noErr, let dictionary
        {
            let raw = dictionary.takeRetainedValue() as? [String: Any] ?? [:]
            for (key, value) in raw {
                // The info dictionary duplicates duration; keep real tags only.
                if key == "approximate duration in seconds" { continue }
                metadata[key] = String(describing: value)
            }
        }

        return AudioFileDetails(
            path: path,
            format: Self.codecName(asbd.mFormatID),
            sampleRate: asbd.mSampleRate,
            channels: Int(asbd.mChannelsPerFrame),
            bitsPerChannel: Int(asbd.mBitsPerChannel),
            durationSeconds: duration,
            bitRate: Int(bitRate),
            metadata: metadata
        )
    }

    static func codecName(_ formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatLinearPCM: return "Linear PCM"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatAppleLossless: return "Apple Lossless"
        default:
            let bytes = withUnsafeBytes(of: formatID.bigEndian) { Array($0) }
            let fourCC = String(decoding: bytes, as: UTF8.self)
            return "'\(fourCC)'"
        }
    }
}
