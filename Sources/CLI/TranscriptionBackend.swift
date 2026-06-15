import Foundation

/// What a transcription engine can do, used to validate a requested
/// language/translate combination before any work starts (PRD §6.6).
struct EngineCapabilities {
    /// Detects the spoken language itself (e.g. whisper `--language auto`).
    let autoDetect: Bool
    /// Can translate any spoken language to English (`--translate`).
    let translate: Bool
    /// Selects its model from a file/name, vs OS-managed assets.
    let usesModelFile: Bool
}

/// Static description of a selectable `--engine` value: its capabilities and
/// whether it is implemented yet. Engines named in the PRD but not yet built
/// are listed so the flag surface matches §6.1/§6.6 and the user gets a clear
/// "planned" message rather than "unknown engine".
struct EngineSpec {
    let name: String
    let capabilities: EngineCapabilities
    let isImplemented: Bool
    /// Shown when the engine is recognized but not implemented yet.
    let plannedNote: String?

    static let all: [EngineSpec] = [
        EngineSpec(
            name: "whisper",
            capabilities: EngineCapabilities(autoDetect: true, translate: true, usesModelFile: true),
            isImplemented: true, plannedNote: nil),
        EngineSpec(
            name: "apple",
            capabilities: EngineCapabilities(autoDetect: false, translate: false, usesModelFile: false),
            isImplemented: false,
            plannedNote: "the 'apple' engine (native Speech.framework) is planned — see PLAN Phase 6.2"),
        EngineSpec(
            name: "whisperkit",
            capabilities: EngineCapabilities(autoDetect: true, translate: true, usesModelFile: true),
            isImplemented: false,
            plannedNote: "the 'whisperkit' engine (CoreML) is planned — see PLAN Phase 6.3"),
        EngineSpec(
            name: "cloud",
            capabilities: EngineCapabilities(autoDetect: true, translate: true, usesModelFile: false),
            isImplemented: false,
            plannedNote: "cloud transcription backends are post-MVP — see PRD §4.2"),
    ]

    static func named(_ name: String) -> EngineSpec? {
        all.first { $0.name == name }
    }

    /// Comma-separated list of recognized engine names for error messages.
    static var knownNames: String {
        all.map(\.name).joined(separator: ", ")
    }
}

/// One transcription engine. Both the batch (`runFileInput`) and live
/// (`LiveTranscriber`) paths drive engines through this single primitive
/// (PRD §6.6): turn a normalized 16 kHz mono WAV into text in the requested
/// format, optionally detecting the language or translating to English.
protocol TranscriptionBackend: AnyObject {
    /// What the backend supports (validated up front).
    var capabilities: EngineCapabilities { get }
    /// Short description for verbose logging.
    var label: String { get }

    /// Transcribes one already-normalized WAV. `language` nil or "auto" means
    /// detect; a code (e.g. "de") forces it. `translate` emits English.
    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String

    /// Releases any held resources (e.g., terminates a server process).
    func shutdown()
}

/// Per-call whisper.cpp CLI backend: spawns `whisper-cli` once per request
/// (the model is reloaded each call). Used for batch transcription and as the
/// fallback for live per-segment work when no server is available.
final class WhisperCLIBackend: TranscriptionBackend {
    private let engine: WhisperEngine
    private let quietStderr: Bool

    init(engine: WhisperEngine, quietStderr: Bool) {
        self.engine = engine
        self.quietStderr = quietStderr
    }

    let capabilities = EngineCapabilities(autoDetect: true, translate: true, usesModelFile: true)

    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String {
        try engine.transcribe(
            wavFile: wavFile, language: language, translate: translate,
            format: format, quietStderr: quietStderr)
    }

    func shutdown() {}

    var label: String { "whisper-cli (per-call)" }
}

/// Resolves a `TranscriptionBackend` for the selected engine. Only `whisper`
/// is implemented today; other named engines yield a clear "planned" error via
/// `TranscribeEngine.resolveWhisper`.
enum TranscriptionEngine {
    /// Batch (whole-file) backend: a single CLI invocation. Engine STDERR
    /// passes through for progress/debugging.
    static func makeBatch(engineName: String, modelFlag: String?) throws -> TranscriptionBackend {
        let engine = try TranscribeEngine.resolveWhisper(
            engineName: engineName, modelFlag: modelFlag)
        return WhisperCLIBackend(engine: engine, quietStderr: false)
    }

    /// Live backend: prefers the model-resident `whisper-server` (loads the
    /// model once) when available and not disabled via `AURAL_WHISPER_SERVER=0`,
    /// falling back to per-segment `whisper-cli`. A server start failure also
    /// falls back, so transcription is never blocked by the optimization.
    static func makeLive(
        engineName: String, modelFlag: String?, quiet: Bool
    ) throws -> TranscriptionBackend {
        let engine = try TranscribeEngine.resolveWhisper(
            engineName: engineName, modelFlag: modelFlag)
        let environment = ProcessInfo.processInfo.environment
        let disabled = environment["AURAL_WHISPER_SERVER"] == "0"
        if !disabled, let serverBinary = WhisperEngine.discoverServer(environment: environment) {
            do {
                let server = try WhisperServerEngine.start(
                    serverBinary: serverBinary, modelPath: engine.modelPath, quiet: quiet)
                Log.verbose("live engine: \(server.label)")
                return server
            } catch {
                Log.verbose("whisper-server unavailable (\(error)); using per-segment whisper-cli")
            }
        }
        return WhisperCLIBackend(engine: engine, quietStderr: quiet)
    }
}
