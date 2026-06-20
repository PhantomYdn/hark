import FluidAudio
import Foundation

/// On-device CoreML transcription via FluidAudio's Parakeet TDT models (PRD
/// §6.6, engine `parakeet`). Apple-Silicon-first, ANE-accelerated. Multilingual
/// across 25 European languages (v3) or English-only (v2); it auto-handles the
/// language (no selection) and cannot translate. The models are loaded once
/// (resident) and CoreML bundles are downloaded from Hugging Face on first use
/// into `~/.hark/models/parakeet`.
final class ParakeetBackend: TranscriptionBackend {
    let capabilities = EngineCapabilities(autoDetect: true, translate: false, usesModelFile: false)

    private let manager: AsrManager  // actor (Sendable)
    private let versionLabel: String

    private init(manager: AsrManager, versionLabel: String) {
        self.manager = manager
        self.versionLabel = versionLabel
    }

    var label: String { "parakeet (CoreML, \(versionLabel))" }

    /// FluidAudio's managed CoreML cache (`~/Library/Application
    /// Support/FluidAudio/Models`). FluidAudio owns this location and does not
    /// honor a custom download directory when models already exist there, so —
    /// unlike whisperkit — parakeet models are not relocated under `~/.hark`;
    /// `hark models list` reads from here instead.
    static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// Loads (and, on first use, downloads) the model. `model` selects the
    /// version: `v2` = English-only, anything else = `v3` multilingual.
    /// `language` only triggers a notice — Parakeet auto-detects within its set.
    static func make(model: String?, language: String?) throws -> ParakeetBackend {
        try Platform.requireAppleSilicon(engine: "parakeet")
        if let warning = languageNotice(language) { Log.notice(warning) }

        let version = modelVersion(model)
        let label = version == .v2 ? "v2 (english)" : "v3 (multilingual)"
        Log.verbose("parakeet: loading \(label) models")
        let manager: AsrManager = try RunLoopBridge.runBlocking(timeout: 1800) {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager()
            try await manager.loadModels(models)
            return manager
        }
        return ParakeetBackend(manager: manager, versionLabel: label)
    }

    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String {
        // translate is already rejected by capability validation; guard anyway.
        if translate {
            throw HarkError.usage(
                "the parakeet engine cannot translate; use --engine whisper or whisperkit.")
        }
        let manager = self.manager
        let url = wavFile
        let result = try RunLoopBridge.runBlocking(timeout: 1800) {
            var state = try TdtDecoderState()
            return try await manager.transcribe(url, decoderState: &state)
        }
        let fullText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptFormatting.render(
            cues: Self.cues(from: result), fullText: fullText, format: format)
    }

    func shutdown() {}

    /// Versions offered by `hark models list --available` / `download`.
    static let downloadableVersions = ["v3", "v2"]

    /// Selects the model version: `v2`/`en` → English-only; default → v3.
    static func modelVersion(_ model: String?) -> AsrModelVersion {
        switch model?.lowercased() {
        case "v2", "parakeet-v2", "en", "english": return .v2
        default: return .v3
        }
    }

    /// Pre-downloads the model bundles (no load) into FluidAudio's cache.
    static func download(version model: String?) throws {
        try Platform.requireAppleSilicon(engine: "parakeet")
        let version = modelVersion(model)
        Log.notice("downloading parakeet \(version == .v2 ? "v2" : "v3") models …")
        try RunLoopBridge.runBlocking(timeout: 3600) {
            _ = try await AsrModels.download(version: version)
        }
    }

    /// A notice when a specific language is requested (Parakeet auto-detects and
    /// ignores it), or nil for `auto`/unset. Pure, for testing.
    static func languageNotice(_ language: String?) -> String? {
        guard let language, !language.isEmpty, language.lowercased() != "auto" else { return nil }
        return "note: the parakeet engine auto-detects language; --language \(language) is ignored."
    }

    /// Groups Parakeet token timings into transcript cues for srt/json. Breaks on
    /// sentence-ending punctuation or after `maxSeconds`. Pure, for testing.
    static func cues(from result: ASRResult, maxSeconds: Double = 8) -> [TranscriptCue] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            return [TranscriptCue(start: 0, end: result.duration, text: result.text)]
        }
        let boundary = ASRConstants.sentencePieceWordBoundary
        var cues: [TranscriptCue] = []
        var start = timings[0].startTime
        var buffer = ""

        func flush(end: Double) {
            let text = buffer.replacingOccurrences(of: boundary, with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { cues.append(TranscriptCue(start: start, end: end, text: text)) }
            buffer = ""
        }

        for timing in timings {
            buffer += timing.token
            let endsSentence = timing.token.last.map { ".!?。".contains($0) } ?? false
            if endsSentence || (timing.endTime - start) >= maxSeconds {
                flush(end: timing.endTime)
                start = timing.endTime
            }
        }
        flush(end: timings.last!.endTime)
        return cues
    }
}
