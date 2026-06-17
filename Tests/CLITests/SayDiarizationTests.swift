import FluidAudio
import Foundation
import Testing

@testable import CLI

/// Speaker-detection validation using macOS `say`-synthesized audio with exact
/// ground truth. Exercises the **zero-config default** live diarization path
/// (`EENDStreamingDiarizer` → LS-EEND `callhome`): a single speaker must not be
/// over-split, and two acoustically distinct speakers must separate with a
/// stable 1:1 voice→label mapping.
///
/// Gated: it runs `say` and downloads/loads the LS-EEND CoreML model, so it is
/// off in the normal suite. Enable with `AURAL_TEST_DIARIZE=1` on Apple Silicon.
/// SKIPs cleanly if a requested `say` voice is unavailable.
@Suite("Speaker detection (say, integration)")
struct SayDiarizationTests {
    private struct Turn { let voice: String; let text: String }

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["AURAL_TEST_DIARIZE"] == "1" && Platform.isAppleSilicon
    }

    /// Synthesizes one line to 16 kHz mono Float via `say`. Returns [] if the
    /// voice/synthesis is unavailable (→ test SKIPs).
    private func synth(voice: String, text: String) -> [Float] {
        let aiff = FileManager.default.temporaryDirectory
            .appendingPathComponent("aural-say-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", aiff.path, text]
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return (try? AudioConverter().resampleAudioFile(aiff)) ?? []
    }

    /// Splices turns into one stream (with short gaps), tracking each turn's
    /// `(voice, start, end)` seconds. Returns nil if any voice is unavailable.
    private func conversation(_ turns: [Turn], gap: Double = 0.3)
        -> (samples: [Float], windows: [(voice: String, start: Double, end: Double)])?
    {
        let sampleRate = 16000.0
        var samples: [Float] = []
        var windows: [(String, Double, Double)] = []
        let gapSamples = [Float](repeating: 0, count: Int(gap * sampleRate))
        for turn in turns {
            let speech = synth(voice: turn.voice, text: turn.text)
            guard !speech.isEmpty else { return nil }
            let start = Double(samples.count) / sampleRate
            samples.append(contentsOf: speech)
            windows.append((turn.voice, start, Double(samples.count) / sampleRate))
            samples.append(contentsOf: gapSamples)
        }
        return (samples, windows)
    }

    /// Streams `samples` through the production default diarizer (0.5 s chunks).
    private func diarize(_ samples: [Float]) throws -> EENDStreamingDiarizer {
        let diarizer = try EENDStreamingDiarizer.make()
        var i = 0
        while i < samples.count {
            let end = min(i + 8000, samples.count)
            diarizer.ingest(Array(samples[i..<end]), sampleRate: 16000)
            i = end
        }
        diarizer.finalize()
        return diarizer
    }

    @Test func singleSpeakerIsNotOverSplit() throws {
        guard enabled else { return }
        guard let convo = conversation([
            Turn(
                voice: "Daniel",
                text: "This is a single speaker talking continuously for a while, with no one "
                    + "else in the room, so the diarizer should report exactly one speaker "
                    + "across the entire clip and never split this voice into several.")
        ]) else { return }

        let diarizer = try diarize(convo.samples)
        let end = Double(convo.samples.count) / 16000
        var labels: Set<String> = []
        var t = 0.0
        while t < end {
            if let label = diarizer.label(start: t, end: min(t + 2, end)) { labels.insert(label) }
            t += 2
        }
        #expect(labels == ["Speaker 1"])
    }

    @Test func twoDistinctSpeakersSeparateWithStableMapping() throws {
        guard enabled else { return }
        let turns = [
            Turn(voice: "Daniel", text: "Good morning, I wanted to discuss the quarterly numbers with you today."),
            Turn(voice: "Samantha", text: "Of course, I have the report right here, revenue grew by twelve percent."),
            Turn(voice: "Daniel", text: "That is excellent news, what about the operating margins this time around?"),
            Turn(voice: "Samantha", text: "Margins improved slightly thanks to the new supply agreement we signed."),
            Turn(voice: "Daniel", text: "Perfect, let us schedule a follow up meeting with the rest of the board."),
            Turn(voice: "Samantha", text: "I will send the calendar invitation this afternoon, does Friday work for you?"),
        ]
        guard let convo = conversation(turns) else { return }

        let diarizer = try diarize(convo.samples)
        var perTurn: [String] = []
        var voiceToLabels: [String: Set<String>] = [:]
        for window in convo.windows {
            let label = diarizer.label(start: window.start, end: window.end) ?? "-"
            perTurn.append(label)
            voiceToLabels[window.voice, default: []].insert(label)
        }

        // Exactly two speakers, each voice mapped to a single, distinct label.
        #expect(Set(perTurn).count == 2)
        #expect(voiceToLabels["Daniel"]?.count == 1)
        #expect(voiceToLabels["Samantha"]?.count == 1)
        #expect(voiceToLabels["Daniel"] != voiceToLabels["Samantha"])
    }
}
