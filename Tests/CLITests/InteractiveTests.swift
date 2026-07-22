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

    @Test func toggleMuteFlipsStateIndependentlyOfPause() {
        let control = CaptureControl()
        #expect(!control.isMuted)
        #expect(control.toggleMute())   // -> muted
        #expect(control.isMuted)
        // Pause is independent of mute.
        #expect(control.togglePause())  // -> paused
        #expect(control.isPaused)
        #expect(control.isMuted)        // still muted
        #expect(!control.toggleMute())  // -> unmuted
        #expect(!control.isMuted)
        #expect(control.isPaused)       // pause unaffected
    }

    @Test func stopClearsMute() {
        let control = CaptureControl()
        _ = control.toggleMute()
        control.stop()
        #expect(!control.isMuted)            // stop clears mute
        #expect(!control.toggleMute())       // no-op after stop
    }

    @Test func explicitMuteUnmuteAreIdempotent() {
        let control = CaptureControl()
        #expect(control.mute())     // changed -> muted
        #expect(control.isMuted)
        #expect(!control.mute())    // already muted -> no change
        #expect(control.unmute())   // changed -> unmuted
        #expect(!control.isMuted)
        #expect(!control.unmute())  // already unmuted -> no change
        // No-op after stop.
        control.stop()
        #expect(!control.mute())
    }
}

/// Records the last text written, for testing the yank key without touching the
/// real system clipboard.
final class FakeClipboard: ClipboardWriter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var copied: [String] = []
    var succeed = true

    @discardableResult
    func copy(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard succeed else { return false }
        copied.append(text)
        return true
    }
}

@Suite("Transcript log (interactive yank)")
struct TranscriptLogTests {
    @Test func accumulatesLinesInOrder() {
        let log = TranscriptLog()
        #expect(log.isEmpty)
        log.append("You: hello")
        log.append("Others: hi there")
        #expect(!log.isEmpty)
        #expect(log.count == 2)
        #expect(log.text == "You: hello\nOthers: hi there")
    }
}

@Suite("Interactive key handling (PRD §6.9)")
struct InteractiveKeyTests {
    private func session(
        control: CaptureControl, hasMic: Bool, log: TranscriptLog?, clipboard: ClipboardWriter
    ) -> InteractiveSession {
        InteractiveSession(control: control, hasMic: hasMic, transcriptLog: log, clipboard: clipboard)
    }

    @Test func spaceTogglesPause() {
        let control = CaptureControl()
        let ui = session(control: control, hasMic: true, log: nil, clipboard: FakeClipboard())
        #expect(!ui.handleKey(0x20))
        #expect(control.isPaused)
        #expect(!ui.handleKey(0x20))
        #expect(!control.isPaused)
    }

    @Test func enterStopsAndSignalsFinish() {
        let control = CaptureControl()
        let ui = session(control: control, hasMic: true, log: nil, clipboard: FakeClipboard())
        #expect(ui.handleKey(0x0A))  // returns true -> reader loop ends
        #expect(control.isStopped)
    }

    @Test func mTogglesMuteWhenMicPresent() {
        let control = CaptureControl()
        let ui = session(control: control, hasMic: true, log: nil, clipboard: FakeClipboard())
        #expect(!ui.handleKey(0x6D))  // m
        #expect(control.isMuted)
        #expect(!ui.handleKey(0x4D))  // M
        #expect(!control.isMuted)
    }

    @Test func mIsNoOpWithoutMic() {
        let control = CaptureControl()
        let ui = session(control: control, hasMic: false, log: nil, clipboard: FakeClipboard())
        #expect(!ui.handleKey(0x6D))
        #expect(!control.isMuted)  // no mic -> unchanged
    }

    @Test func yCopiesTranscriptWhenPresent() {
        let control = CaptureControl()
        let log = TranscriptLog()
        log.append("You: hello")
        log.append("Others: world")
        let clip = FakeClipboard()
        let ui = session(control: control, hasMic: true, log: log, clipboard: clip)
        #expect(!ui.handleKey(0x79))  // y
        #expect(clip.copied == ["You: hello\nOthers: world"])
    }

    @Test func yWithEmptyLogDoesNotCopy() {
        let control = CaptureControl()
        let clip = FakeClipboard()
        let ui = session(control: control, hasMic: true, log: TranscriptLog(), clipboard: clip)
        #expect(!ui.handleKey(0x59))  // Y
        #expect(clip.copied.isEmpty)
    }
}

@Suite("Interactive controls hint")
struct InteractiveHintTests {
    @Test func showsMuteHintOnlyWithMic() {
        let withMic = InteractiveSession.controlsHint(hasMic: true)
        #expect(withMic.contains("[m] mute mic"))
        #expect(withMic.contains("[y] yank transcript"))
        #expect(withMic.contains("[space] pause/resume"))

        let noMic = InteractiveSession.controlsHint(hasMic: false)
        #expect(!noMic.contains("[m]"))
        #expect(noMic.contains("[y] yank transcript"))  // yank always available
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
