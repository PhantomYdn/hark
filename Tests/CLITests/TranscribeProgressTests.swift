import Foundation
import Testing

@testable import CLI

/// Pins the protocol default: an engine that does not implement the progress
/// overload reports nothing, so the line shows elapsed time for it.
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
    @Test func enginesWithoutSupportReportNothingByDefault() throws {
        let reported = LockBox<Double>()
        let text = try ProgressStubBackend().transcribe(
            wavFile: URL(fileURLWithPath: "/dev/null"), language: nil, translate: false,
            format: .txt, progress: { reported.set($0) })
        #expect(text == "")
        #expect(reported.get() == nil)
    }

    @Test func noLineWithoutATerminal() {
        #expect(TranscribeProgressLine.begin(isStderrTTY: false) == nil)
        #expect(TranscribeProgressLine.active == nil)
    }

    @Test func showsElapsedTimeUntilTheEngineReportsAPosition() {
        #expect(
            TranscribeProgress.render(fraction: nil, elapsed: 42)
                == "hark: transcribing… 0:42 elapsed")
        #expect(
            TranscribeProgress.render(fraction: nil, elapsed: 42, audioSeconds: 452)
                == "hark: transcribing… 0:42 elapsed (7:32 of audio)")
    }

    @Test func showsThePositionInTheAudioWhenItsLengthIsKnown() {
        let line = TranscribeProgress.render(fraction: 0.5, elapsed: 60, audioSeconds: 600)
        #expect(line == "hark: transcribing 50% [##########..........] 5:00 / 10:00 eta 1:00")
    }

    @Test func etaCountsDownBetweenEngineSteps() {
        // 25% reported at 300 s gives 15:00; 60 s later with no new step it is 14:00.
        let line = TranscribeProgress.render(fraction: 0.25, elapsed: 360, sinceUpdate: 60)
        #expect(line.contains("eta 14:00"))
        // A step that is overdue bottoms out at zero rather than going negative.
        #expect(
            TranscribeProgress.render(fraction: 0.9, elapsed: 1000, sinceUpdate: 900)
                .contains("eta 0:00"))
    }

    @Test func etaMeasuresSpeedFromTheFirstReportedPosition() {
        // 20 s of model load before the first position (1%); the next 49%
        // took 49 s, so the remaining 50% is about 50 s, not 69 s.
        let line = TranscribeProgress.render(
            fraction: 0.5, elapsed: 69, baseline: (fraction: 0.01, elapsed: 20))
        #expect(line.contains("eta 0:50"))
        // Too little covered since the first position: no estimate yet.
        #expect(
            !TranscribeProgress.render(
                fraction: 0.12, elapsed: 30, baseline: (fraction: 0.08, elapsed: 20)
            ).contains("eta"))
    }

    @Test func overallFractionSpansEveryPass() {
        #expect(TranscribeProgress.overall(completedPasses: 0, passes: 1, passFraction: nil) == nil)
        #expect(TranscribeProgress.overall(completedPasses: 0, passes: 1, passFraction: 0.4) == 0.4)
        #expect(TranscribeProgress.overall(completedPasses: 0, passes: 2, passFraction: 0.5) == 0.25)
        #expect(TranscribeProgress.overall(completedPasses: 1, passes: 2, passFraction: nil) == 0.5)
        #expect(TranscribeProgress.overall(completedPasses: 1, passes: 2, passFraction: 0.5) == 0.75)
        #expect(TranscribeProgress.overall(completedPasses: 2, passes: 2, passFraction: 0.5) == 1)
    }

    @Test func transcribeTimeoutGrowsWithTheAudio() {
        #expect(RunLoopBridge.transcribeTimeout(audioSeconds: nil) == 1800)
        #expect(RunLoopBridge.transcribeTimeout(audioSeconds: 60) == 1800)
        // A three-hour lecture gets nine hours, not the old flat 30 minutes.
        #expect(RunLoopBridge.transcribeTimeout(audioSeconds: 10800) == 32400)
        #expect(RunLoopBridge.transcribeTimeout(audioSeconds: 30, floor: 120) == 120)
        #expect(RunLoopBridge.transcribeTimeout(audioSeconds: 600, floor: 120) == 1800)
        #expect(RunLoopBridge.transcribeTimeout(audioSeconds: .nan) == 1800)
    }

    @Test func readsWhisperCppProgressLines() {
        #expect(
            WhisperEngine.progressFraction(
                fromStderrLine: "whisper_print_progress_callback: progress =  35%") == 0.35)
        #expect(
            WhisperEngine.progressFraction(
                fromStderrLine: "whisper_print_progress_callback: progress = 100%") == 1)
        #expect(
            WhisperEngine.progressFraction(
                fromStderrLine: "read_audio_data: trying to decode with miniaudio") == nil)
        #expect(WhisperEngine.progressFraction(fromStderrLine: "progress = soon") == nil)
    }

    @Test func whisperProgressFlagIsOptIn() {
        let plain = WhisperEngine.buildArguments(
            model: "m.bin", wav: "a.wav", language: nil, translate: false, format: .txt,
            outputBase: "out")
        #expect(!plain.contains("-pp"))
        let reporting = WhisperEngine.buildArguments(
            model: "m.bin", wav: "a.wav", language: nil, translate: false, format: .txt,
            outputBase: "out", printProgress: true)
        #expect(reporting.contains("-pp"))
        #expect(reporting.dropLast() == plain[...])
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
