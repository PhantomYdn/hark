import ArgumentParser

@main
struct Aural: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aural",
        abstract: "Capture microphone and system audio on macOS.",
        version: "0.1.0"
    )
}
