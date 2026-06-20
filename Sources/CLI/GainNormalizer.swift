import Encoders
import Foundation

/// Per-segment peak normalization for the transcription path (PRD §6.6). Quiet
/// captures (low mic/system gain) leave speech well below the levels engines and
/// the VAD expect, so segments are boosted toward a target peak before they are
/// sent to the engine — improving recognition on low-level audio. This only
/// affects the audio fed to the recognizer; the `-a` recording is untouched.
///
/// The gain is capped so near-silence isn't blown up, and it never attenuates
/// (a segment already at/above the target passes through unchanged).
enum GainNormalizer {
    /// Boosts `data` (packed little-endian PCM) so its peak approaches
    /// `targetDBFS`, up to `maxGainDB`. Returns the input unchanged when it is
    /// already loud enough, silent, or the bit depth is unsupported.
    static func normalize(
        _ data: Data, format: PCMFormat, targetDBFS: Double = -3, maxGainDB: Double = 20
    ) -> Data {
        let peak = peakAmplitude(of: data, format: format)
        guard peak > 0 else { return data }  // pure silence: nothing to boost
        let target = pow(10.0, targetDBFS / 20.0)
        guard peak < target else { return data }  // already loud enough
        let maxGain = pow(10.0, maxGainDB / 20.0)
        let gain = min(maxGain, target / peak)
        guard gain > 1.0 else { return data }
        return scale(data, by: gain, format: format)
    }

    /// Multiplies every sample by `gain` with hard clamping, preserving the
    /// packed little-endian layout for the format's bit depth.
    static func scale(_ data: Data, by gain: Double, format: PCMFormat) -> Data {
        switch format.bitsPerSample {
        case 16:
            var out = Data(count: data.count)
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                let input = src.bindMemory(to: Int16.self)
                out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    let output = dst.bindMemory(to: Int16.self)
                    for i in 0..<input.count {
                        let v = (Double(input[i]) * gain).rounded()
                        output[i] = Int16(max(-32768.0, min(32767.0, v)))
                    }
                }
            }
            return out
        case 32:
            var out = Data(count: data.count)
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                let input = src.bindMemory(to: Int32.self)
                out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    let output = dst.bindMemory(to: Int32.self)
                    for i in 0..<input.count {
                        let v = (Double(input[i]) * gain).rounded()
                        output[i] = Int32(max(-2147483648.0, min(2147483647.0, v)))
                    }
                }
            }
            return out
        case 24:
            var out = Data(capacity: data.count)
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                let bytes = src.bindMemory(to: UInt8.self)
                var i = 0
                while i + 2 < bytes.count {
                    let raw = UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]) << 16
                        | UInt32(bytes[i + 2]) << 24
                    let sample = Int32(bitPattern: raw) >> 8  // sign-extended 24-bit
                    let scaled = Int32(max(-8388608.0, min(8388607.0, (Double(sample) * gain).rounded())))
                    let u = UInt32(bitPattern: scaled)
                    out.append(UInt8(u & 0xFF))
                    out.append(UInt8((u >> 8) & 0xFF))
                    out.append(UInt8((u >> 16) & 0xFF))
                    i += 3
                }
            }
            return out
        default:
            return data
        }
    }

    /// Whether normalization is enabled (default on; `HARK_GAIN=off` disables).
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Bool
    {
        environment["HARK_GAIN"]?.lowercased() != "off"
    }
}
