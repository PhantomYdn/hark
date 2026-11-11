import Foundation
import Testing

@testable import CLI

/// Pins the protocol default: engines that don't opt in report nothing, so the
/// batch path never draws a line for them.
private final class ProgressStubBackend: TranscriptionBackend {
    let capabilities = EngineCapabilities(
        autoDetect: false, translate: false, usesModelFile: false)
    var label: String { "stub" }
    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String { "" }
    func shutdown() {}
}

@Suite("Transcribe progress (issue #13)")
struct TranscribeProgressTests {
    @Test func enginesWithoutSupportStaySilentByDefault() {
        #expect(!ProgressStubBackend().reportsProgress)
    }
    @Test func gatingFollowsStderrTTYOnly() {
        #expect(TranscribeProgress.shouldShow(isStderrTTY: true))
        #expect(!TranscribeProgress.shouldShow(isStderrTTY: false))
    }

    @Test func rendersPercentAndBar() {
        let line = TranscribeProgress.render(fraction: 0.42, elapsed: 300)
        #expect(line.contains("42%"))
        #expect(line.contains("[########............]"))
        #expect(line.hasPrefix("hark: transcribing "))
    }

    @Test func pinsExactShapeAtZero() {
        #expect(
            TranscribeProgress.render(fraction: 0, elapsed: 10)
                == "hark: transcribing 0% [....................]")
    }

    @Test func clampsFractionToUnitRange() {
        #expect(TranscribeProgress.render(fraction: 1.5, elapsed: 10).contains("100%"))
        #expect(TranscribeProgress.render(fraction: -0.2, elapsed: 10).contains("0%"))
        #expect(TranscribeProgress.render(fraction: .nan, elapsed: 10).contains("0%"))
    }

    @Test func etaHiddenEarlyShownOnceMoving() {
        #expect(!TranscribeProgress.render(fraction: 0.04, elapsed: 300).contains("eta"))
        let line = TranscribeProgress.render(fraction: 0.25, elapsed: 300)
        #expect(line.contains("eta 15:00"))
    }

    @Test func etaReachesZeroAtCompletion() {
        #expect(TranscribeProgress.render(fraction: 1, elapsed: 90).contains("eta 0:00"))
    }

    @Test func formatDurationCarriesMinutesAndHours() {
        #expect(TranscribeProgress.formatDuration(0) == "0:00")
        #expect(TranscribeProgress.formatDuration(59.4) == "0:59")
        #expect(TranscribeProgress.formatDuration(60) == "1:00")
        #expect(TranscribeProgress.formatDuration(3661) == "1:01:01")
        #expect(TranscribeProgress.formatDuration(-5) == "0:00")
    }
}
