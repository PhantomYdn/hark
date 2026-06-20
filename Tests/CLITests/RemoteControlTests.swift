import FlyingFox
import Foundation
import Testing

@testable import CLI

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
        let snap = try manager.begin(id: "a", control: CaptureControl(), audio: nil, transcript: "n.txt")
        #expect(snap.state == .recording)
        #expect(try manager.pause().state == .paused)
        #expect(try manager.resume().state == .recording)
        #expect(try manager.stop().state == .stopped)
    }

    @Test func rejectsSecondConcurrentStart() throws {
        let manager = RemoteSessionManager()
        _ = try manager.begin(id: "a", control: CaptureControl(), audio: nil, transcript: "n.txt")
        #expect(throws: AgentError.self) {
            _ = try manager.begin(id: "b", control: CaptureControl(), audio: nil, transcript: "x.txt")
        }
    }

    @Test func controlVerbsRequireActiveSession() {
        let manager = RemoteSessionManager()
        #expect(throws: AgentError.self) { _ = try manager.pause() }
        #expect(throws: AgentError.self) { _ = try manager.stop() }
    }

    @Test func finishAllowsANewSession() throws {
        let manager = RemoteSessionManager()
        _ = try manager.begin(id: "a", control: CaptureControl(), audio: nil, transcript: "n.txt")
        manager.finish(id: "a", error: nil)
        #expect(manager.current()?.state == .stopped)
        // A new session is now allowed.
        let snap = try manager.begin(id: "b", control: CaptureControl(), audio: nil, transcript: "x.txt")
        #expect(snap.state == .recording)
    }

    @Test func finishWithErrorMarksFailed() throws {
        let manager = RemoteSessionManager()
        _ = try manager.begin(id: "a", control: CaptureControl(), audio: nil, transcript: "n.txt")
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
