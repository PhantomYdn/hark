import Encoders
import Foundation
import Testing

@testable import CLI

@Suite("Startup status (PRD §6.8)")
struct StartupStatusTests {
    private let format = PCMFormat(sampleRate: 44100, bitsPerSample: 16, channels: 2)

    @Test func rendersCoreRows() {
        let text = StartupStatus.render(
            engine: "whisper", model: "base.en", language: "auto", translate: false,
            source: "MacBook Pro Microphone", captureBackend: nil, format: format,
            audio: "rec.m4a", transcript: "stdout (txt)", speakers: nil, vad: true,
            duration: nil, split: nil)
        #expect(text.contains("hark — listening"))
        #expect(text.contains("whisper (base.en)"))
        #expect(text.contains("44100 Hz"))
        #expect(text.contains("16-bit"))
        #expect(text.contains("MacBook Pro Microphone"))
        #expect(text.contains("rec.m4a"))
        #expect(text.contains("stdout (txt)"))
        #expect(text.contains("on"))  // vad
    }

    @Test func includesOptionalRowsWhenSet() {
        let text = StartupStatus.render(
            engine: "whisper", model: nil, language: "de", translate: true,
            source: "system audio (tap) + mic", captureBackend: "coreaudio", format: format,
            audio: nil, transcript: "mtg.srt (srt)", speakers: "auto (You/Others)", vad: false,
            duration: 30, split: "duration=10")
        #expect(text.contains("de → English"))
        #expect(text.contains("[coreaudio]"))
        #expect(text.contains("speakers"))
        #expect(text.contains("You/Others"))
        #expect(text.contains("30 s"))
        #expect(text.contains("duration=10"))
        #expect(text.contains("(none)"))  // audio omitted
    }

    @Test func gatingShowsOnTTYorVerbose() {
        #expect(StartupStatus.shouldShow(isStderrTTY: true, verbose: false))
        #expect(StartupStatus.shouldShow(isStderrTTY: false, verbose: true))
        #expect(StartupStatus.shouldShow(isStderrTTY: true, verbose: true))
        #expect(!StartupStatus.shouldShow(isStderrTTY: false, verbose: false))
    }
}

@Suite("Capture control (pause/resume/stop)")
struct CaptureControlTests {
    @Test func togglePauseFlipsState() {
        let control = CaptureControl()
        #expect(!control.isPaused)
        #expect(control.togglePause())   // -> paused
        #expect(control.isPaused)
        #expect(!control.togglePause())  // -> running
        #expect(!control.isPaused)
    }

    @Test func pauseAndResumeReportChanges() {
        let control = CaptureControl()
        #expect(control.pause())
        #expect(!control.pause())   // already paused
        #expect(control.resume())
        #expect(!control.resume())  // already running
    }

    @Test func stopFiresHandlerAndFreezesState() {
        let control = CaptureControl()
        var fired = 0
        control.setStopHandler { fired += 1 }
        _ = control.togglePause()
        control.stop()
        #expect(control.isStopped)
        #expect(!control.isPaused)            // stop clears pause
        #expect(!control.togglePause())       // no-op after stop
        control.stop()                        // idempotent
        #expect(fired == 1)
    }

    @Test func stopBeforeHandlerStillFires() {
        let control = CaptureControl()
        control.stop()
        var fired = false
        control.setStopHandler { fired = true }  // installed late
        #expect(fired)
    }
}

@Suite("Interactive output resolution")
struct InteractiveOutputTests {
    @Test func recordOnlyInteractiveShowsTranscriptOnStdout() throws {
        let hark = try Hark.parse(["--interactive", "-a", "rec.m4a"])
        let outputs = try hark.resolveOutputs()
        guard case .file("rec.m4a")? = outputs.audio else {
            Issue.record("expected audio to rec.m4a"); return
        }
        guard case .stdout? = outputs.transcript else {
            Issue.record("expected interactive transcript on stdout"); return
        }
    }

    @Test func recordOnlyWithoutInteractiveHasNoTranscript() throws {
        let hark = try Hark.parse(["-a", "rec.m4a"])
        let outputs = try hark.resolveOutputs()
        #expect(outputs.transcript == nil)
    }
}
