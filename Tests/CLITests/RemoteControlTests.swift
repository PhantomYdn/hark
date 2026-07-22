import FlyingFox
import Foundation
import Testing

@testable import CLI

@Suite("Version single source of truth")
struct VersionTests {
    /// `--version`, the WAV-metadata tag, and the agent's `GET /status` must all
    /// report the same `harkVersion` — guards against re-hardcoding any of them.
    @Test func cliVersionMatchesHarkVersion() {
        #expect(Hark.configuration.version == harkVersion)
        // A release bump keeps the constant a plain semver triple.
        #expect(harkVersion.split(separator: ".").count == 3)
    }
}

@Suite("Remote-control address parsing")
struct RemoteAddressTests {
    @Test func parsesBarePortAsLoopback() throws {
        let addr = try RemoteAddress.parse("8473")
        #expect(addr.port == 8473)
        #expect(addr.isLoopback)
        #expect(addr.display == "127.0.0.1:8473")
    }

    @Test func parsesHostPort() throws {
        #expect(try RemoteAddress.parse(":8473").isLoopback)
        #expect(try RemoteAddress.parse("127.0.0.1:8473").isLoopback)
        #expect(try RemoteAddress.parse("localhost:8473").isLoopback)
        #expect(try !RemoteAddress.parse("0.0.0.0:8080").isLoopback)
        #expect(try !RemoteAddress.parse("192.168.1.5:8080").isLoopback)
    }

    @Test(arguments: ["", "abc", "70000", "0", "127.0.0.1:", "127.0.0.1:bad"])
    func rejectsBadAddresses(_ raw: String) {
        #expect(throws: (any Error).self) { _ = try RemoteAddress.parse(raw) }
    }
}

@Suite("Remote-control flag (optional value)")
struct RemoteControlFlagTests {
    @Test func normalizeInsertsSentinelForBareFlag() {
        // Last token → sentinel appended.
        #expect(Hark.normalizeRemoteControl(["--remote-control"]) == ["--remote-control", ""])
        // Followed by another option → sentinel inserted between.
        #expect(
            Hark.normalizeRemoteControl(["--remote-control", "--no-keep-awake"])
                == ["--remote-control", "", "--no-keep-awake"])
    }

    @Test func normalizeLeavesExplicitValueUntouched() {
        #expect(
            Hark.normalizeRemoteControl(["--remote-control", "8473"]) == ["--remote-control", "8473"])
        #expect(
            Hark.normalizeRemoteControl(["--remote-control", "0.0.0.0:8473", "--system"])
                == ["--remote-control", "0.0.0.0:8473", "--system"])
        // No flag present → unchanged.
        #expect(Hark.normalizeRemoteControl(["-a", "x.m4a"]) == ["-a", "x.m4a"])
    }

    @Test func bareFlagParsesToEmptySentinel() throws {
        let cmd = try Hark.parse(Hark.normalizeRemoteControl(["--remote-control"]))
        #expect(cmd.remoteControl == "")
    }

    @Test func explicitValueParsesThrough() throws {
        let cmd = try Hark.parse(Hark.normalizeRemoteControl(["--remote-control", "0.0.0.0:8080"]))
        #expect(cmd.remoteControl == "0.0.0.0:8080")
    }
}

@Suite("Capture microphone presence")
struct CapturesMicrophoneTests {
    @Test func trueForMicAndMix() throws {
        #expect(try Hark.parse([]).capturesMicrophone)                 // default mic-only
        #expect(try Hark.parse(["--system", "--mix"]).capturesMicrophone)
        #expect(try Hark.parse(["--app", "us.zoom.xos", "--mix"]).capturesMicrophone)
    }

    @Test func falseForSystemOrAppWithoutMix() throws {
        #expect(try !Hark.parse(["--system"]).capturesMicrophone)
        #expect(try !Hark.parse(["--app", "us.zoom.xos"]).capturesMicrophone)
        #expect(try !Hark.parse(["--exclude-app", "us.zoom.xos"]).capturesMicrophone)
    }
}

@Suite("Remote-control start request → command")
struct StartRequestTests {
    private func defaults(_ args: [String]) throws -> Hark {
        try Hark.parse(["--remote-control", "8473"] + args)
    }

    @Test func appliesOverridesAndClearsModalFlags() throws {
        var body = StartRequest()
        body.system = true
        body.transcript = "notes.txt"
        body.engine = "whisper"
        let cmd = try body.makeCommand(defaults: defaults([]))
        #expect(cmd.captureSystem)
        #expect(cmd.transcript == "notes.txt")
        #expect(cmd.engine == "whisper")
        #expect(cmd.remoteControl == nil)
        #expect(!cmd.interactive)
        #expect(cmd.input == nil)
    }

    @Test func inheritsLaunchDefaultsWhenNotOverridden() throws {
        var body = StartRequest()
        body.transcript = "n.txt"
        // Launch defaults capture system + whisperkit; the request only names output.
        let cmd = try body.makeCommand(defaults: defaults(["--system", "--engine", "whisperkit"]))
        #expect(cmd.captureSystem)
        #expect(cmd.engine == "whisperkit")
        #expect(cmd.transcript == "n.txt")
    }

    @Test func requiresAFileOutput() throws {
        // No output named, launch had none → 400-worthy usage error.
        #expect(throws: HarkError.self) {
            _ = try StartRequest().makeCommand(defaults: defaults([]))
        }
    }

    @Test func rejectsStdoutOutput() throws {
        var body = StartRequest()
        body.transcript = "-"
        #expect(throws: HarkError.self) {
            _ = try body.makeCommand(defaults: defaults([]))
        }
    }

    @Test func rejectsInvalidEnum() throws {
        var body = StartRequest()
        body.transcript = "n.txt"
        body.speakerMode = "bogus"
        #expect(throws: HarkError.self) {
            _ = try body.makeCommand(defaults: defaults([]))
        }
    }

    @Test func runsCLIValidation() throws {
        // --mix without a tap source is rejected by Hark.validate().
        var body = StartRequest()
        body.transcript = "n.txt"
        body.mix = true
        #expect(throws: HarkError.self) {
            _ = try body.makeCommand(defaults: defaults([]))
        }
    }
}

@Suite("Remote-control session manager")
struct RemoteSessionManagerTests {
    @Test func lifecycleRecordingPauseResumeStop() throws {
        let manager = RemoteSessionManager()
        let snap = try manager.begin(
            id: "a", control: CaptureControl(), hasMic: true, muted: false,
            audio: nil, transcript: "n.txt")
        #expect(snap.state == .recording)
        #expect(snap.muted == false)
        #expect(try manager.pause().state == .paused)
        #expect(try manager.resume().state == .recording)
        #expect(try manager.stop().state == .stopped)
    }

    @Test func rejectsSecondConcurrentStart() throws {
        let manager = RemoteSessionManager()
        _ = try manager.begin(
            id: "a", control: CaptureControl(), hasMic: true, muted: false,
            audio: nil, transcript: "n.txt")
        #expect(throws: AgentError.self) {
            _ = try manager.begin(
                id: "b", control: CaptureControl(), hasMic: true, muted: false,
                audio: nil, transcript: "x.txt")
        }
    }

    @Test func controlVerbsRequireActiveSession() {
        let manager = RemoteSessionManager()
        #expect(throws: AgentError.self) { _ = try manager.pause() }
        #expect(throws: AgentError.self) { _ = try manager.stop() }
        #expect(throws: AgentError.self) { _ = try manager.mute() }
        #expect(throws: AgentError.self) { _ = try manager.unmute() }
    }

    @Test func muteUnmuteLifecycleAndIdempotency() throws {
        let manager = RemoteSessionManager()
        let control = CaptureControl()
        _ = try manager.begin(
            id: "a", control: control, hasMic: true, muted: false,
            audio: "rec.m4a", transcript: nil)
        // Mute is orthogonal to state: stays `recording`, flips `muted`.
        let muted = try manager.mute()
        #expect(muted.state == .recording)
        #expect(muted.muted == true)
        #expect(control.isMuted == true)
        // Idempotent.
        #expect(try manager.mute().muted == true)
        // Unmute.
        #expect(try manager.unmute().muted == false)
        #expect(control.isMuted == false)
        #expect(manager.current()?.muted == false)
    }

    @Test func muteRejectedWithoutMicrophone() throws {
        let manager = RemoteSessionManager()
        _ = try manager.begin(
            id: "a", control: CaptureControl(), hasMic: false, muted: false,
            audio: "sys.m4a", transcript: nil)
        #expect(throws: AgentError.self) { _ = try manager.mute() }
        #expect(throws: AgentError.self) { _ = try manager.unmute() }
    }

    @Test func beginMutedRequiresMicrophone() throws {
        let manager = RemoteSessionManager()
        // muted:true with no mic → rejected (→422).
        #expect(throws: AgentError.self) {
            _ = try manager.begin(
                id: "a", control: CaptureControl(), hasMic: false, muted: true,
                audio: "sys.m4a", transcript: nil)
        }
        // muted:true with a mic → starts muted.
        let control = CaptureControl()
        let snap = try manager.begin(
            id: "b", control: control, hasMic: true, muted: true,
            audio: "rec.m4a", transcript: nil)
        #expect(snap.muted == true)
        #expect(control.isMuted == true)
    }

    @Test func finishAllowsANewSession() throws {
        let manager = RemoteSessionManager()
        _ = try manager.begin(
            id: "a", control: CaptureControl(), hasMic: true, muted: false,
            audio: nil, transcript: "n.txt")
        manager.finish(id: "a", error: nil)
        #expect(manager.current()?.state == .stopped)
        // A new session is now allowed.
        let snap = try manager.begin(
            id: "b", control: CaptureControl(), hasMic: true, muted: false,
            audio: nil, transcript: "x.txt")
        #expect(snap.state == .recording)
    }

    @Test func finishWithErrorMarksFailed() throws {
        let manager = RemoteSessionManager()
        _ = try manager.begin(
            id: "a", control: CaptureControl(), hasMic: true, muted: false,
            audio: nil, transcript: "n.txt")
        manager.finish(id: "a", error: "boom")
        #expect(manager.current()?.state == .failed)
        #expect(manager.current()?.error == "boom")
    }
}

@Suite("Remote-control error mapping")
struct RemoteErrorMappingTests {
    @Test func mapsExitCodesToHTTPStatus() {
        #expect(RemoteControlAgent.httpStatus(for: .usage).code == 400)
        #expect(RemoteControlAgent.httpStatus(for: .noInput).code == 404)
        #expect(RemoteControlAgent.httpStatus(for: .noPermission).code == 403)
        #expect(RemoteControlAgent.httpStatus(for: .unavailable).code == 422)
        #expect(RemoteControlAgent.httpStatus(for: .software).code == 500)
    }
}
