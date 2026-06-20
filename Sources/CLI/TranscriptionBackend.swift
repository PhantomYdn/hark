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
            isImplemented: true, plannedNote: nil),
        EngineSpec(
            name: "whisperkit",
            capabilities: EngineCapabilities(autoDetect: true, translate: true, usesModelFile: true),
            isImplemented: true, plannedNote: nil),
        EngineSpec(
            name: "parakeet",
            capabilities: EngineCapabilities(autoDetect: true, translate: false, usesModelFile: false),
            isImplemented: true, plannedNote: nil),
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

/// Serializes access to a shared backend so several pipelines (e.g. the two
/// source-attribution streams) can reuse one engine — one model load — without
/// concurrent calls. `shutdown()` is forwarded once by the owner.
final class SerializedBackend: TranscriptionBackend {
    private let backend: TranscriptionBackend
    private let lock = NSLock()

    init(_ backend: TranscriptionBackend) { self.backend = backend }

    var capabilities: EngineCapabilities { backend.capabilities }
    var label: String { "\(backend.label) (shared)" }

    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try backend.transcribe(
            wavFile: wavFile, language: language, translate: translate, format: format)
    }

    func shutdown() { backend.shutdown() }
}

/// Resolves a `TranscriptionBackend` for the selected engine, dispatching on
/// the engine name. `whisper` (CLI/server) and `apple` (Speech.framework) are
/// implemented; other named engines yield a clear "planned" error.
enum TranscriptionEngine {
    /// Validates an engine is usable before any capture/work (fail fast):
    /// whisper resolves its binary+model (and warns on a `.en`/language
    /// mismatch); apple checks Speech authorization and locale support so its
    /// permission prompt happens before recording starts.
    static func preflight(
        engineName: String, modelFlag: String?, language: String?, translate: Bool
    ) throws {
        switch try requireImplemented(engineName) {
        case "whisper":
            let whisper = try TranscribeEngine.resolveWhisper(
                engineName: engineName, modelFlag: modelFlag)
            ModelRegistry.warnIfModelLanguageMismatch(
                modelPath: whisper.modelPath, language: language, translate: translate)
        case "apple":
            _ = try AppleSpeechBackend.make(language: language)
        case "whisperkit":
            try Platform.requireAppleSilicon(engine: "whisperkit")
        case "parakeet":
            try Platform.requireAppleSilicon(engine: "parakeet")
        default:
            break
        }
    }

    /// Batch (whole-file) backend. whisper: a single CLI invocation (STDERR
    /// passes through). apple: an on-device recognizer for the locale.
    static func makeBatch(
        engineName: String, modelFlag: String?, language: String?, translate: Bool
    ) throws -> TranscriptionBackend {
        switch try requireImplemented(engineName) {
        case "whisper":
            let engine = try TranscribeEngine.resolveWhisper(
                engineName: engineName, modelFlag: modelFlag)
            ModelRegistry.warnIfModelLanguageMismatch(
                modelPath: engine.modelPath, language: language, translate: translate)
            return WhisperCLIBackend(engine: engine, quietStderr: false)
        case "apple":
            return try AppleSpeechBackend.make(language: language)
        case "whisperkit":
            return try WhisperKitBackend.make(model: rawModel(modelFlag))
        case "parakeet":
            return try ParakeetBackend.make(model: rawModel(modelFlag), language: language)
        default:
            throw HarkError.software("engine '\(engineName)' has no batch backend.")
        }
    }

    /// Live backend. whisper: prefers the model-resident `whisper-server`
    /// (loads the model once) when available and not disabled via
    /// `HARK_WHISPER_SERVER=0`, falling back to per-segment `whisper-cli` (so a
    /// server start failure never blocks transcription). apple: a resident
    /// on-device recognizer reused across segments.
    static func makeLive(
        engineName: String, modelFlag: String?, language: String?, quiet: Bool
    ) throws -> TranscriptionBackend {
        switch try requireImplemented(engineName) {
        case "whisper":
            let engine = try TranscribeEngine.resolveWhisper(
                engineName: engineName, modelFlag: modelFlag)
            let environment = ProcessInfo.processInfo.environment
            let disabled = environment["HARK_WHISPER_SERVER"] == "0"
            if !disabled, let serverBinary = WhisperEngine.discoverServer(environment: environment) {
                do {
                    let server = try WhisperServerEngine.start(
                        serverBinary: serverBinary, modelPath: engine.modelPath, quiet: quiet)
                    Log.verbose("live engine: \(server.label)")
                    return server
                } catch {
                    Log.verbose(
                        "whisper-server unavailable (\(error)); using per-segment whisper-cli")
                }
            }
            return WhisperCLIBackend(engine: engine, quietStderr: quiet)
        case "apple":
            return try AppleSpeechBackend.make(language: language)
        case "whisperkit":
            return try WhisperKitBackend.make(model: rawModel(modelFlag))
        case "parakeet":
            return try ParakeetBackend.make(model: rawModel(modelFlag), language: language)
        default:
            throw HarkError.software("engine '\(engineName)' has no live backend.")
        }
    }

    /// Resolves a non-whisper model name (no ggml file lookup): flag, then
    /// `$HARK_WHISPER_MODEL`, then the config default; nil lets the engine pick.
    static func rawModel(_ flag: String?) -> String? {
        if let flag, !flag.isEmpty { return flag }
        let env = ProcessInfo.processInfo.environment["HARK_WHISPER_MODEL"]
        if let env, !env.isEmpty { return env }
        return Configuration.load().model
    }

    /// Validates the engine is recognized and implemented, returning its name.
    private static func requireImplemented(_ name: String) throws -> String {
        guard let spec = EngineSpec.named(name) else {
            throw HarkError.usage("unknown engine '\(name)' (known: \(EngineSpec.knownNames)).")
        }
        guard spec.isImplemented else {
            throw HarkError.unavailable(
                (spec.plannedNote ?? "engine '\(name)' is not available") + "; use --engine whisper.")
        }
        return name
    }
}
