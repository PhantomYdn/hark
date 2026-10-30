import FluidAudio
import Foundation

/// A Parakeet TDT variant Hark exposes, mapped to FluidAudio's model version.
/// `name` is the user-facing id (`--model ultra`, `parakeet:bark3-clean`).
struct ParakeetModel: Equatable, Sendable {
    let name: String
    /// Extra accepted spellings (FluidAudio CLI names, short forms).
    let aliases: [String]
    let version: AsrModelVersion
    /// Display label for `models list --available` (multilingual = 25 European).
    let languages: String

    /// FluidAudio's cache directory for this variant.
    var cacheDirectory: URL { AsrModels.defaultCacheDirectory(for: version) }

    /// The cached bundle's directory name (what `hark models list` shows).
    var bundleName: String { cacheDirectory.lastPathComponent }
}

/// On-device CoreML transcription via FluidAudio's Parakeet TDT models (PRD
/// §6.6, engine `parakeet`). Apple-Silicon-first, ANE-accelerated. Variants
/// (`ParakeetBackend.models`) cover 25 European languages (ultra — the
/// default — v3, redux), English (v2, phonon2, bark3, bark3-clean,
/// tdt-ctc-110m) or Japanese (ja); the engine auto-handles the language (no
/// selection) and cannot translate. The models are loaded once (resident) and
/// CoreML bundles are downloaded from Hugging Face on first use into
/// FluidAudio's cache.
final class ParakeetBackend: TranscriptionBackend {
    let capabilities = EngineCapabilities(autoDetect: true, translate: false, usesModelFile: false)

    private let manager: AsrManager  // actor (Sendable)
    private let versionLabel: String
    /// Decoder LSTM depth of the loaded variant (1 for tdt-ctc-110m, else 2).
    private let decoderLayers: Int

    private init(manager: AsrManager, versionLabel: String, decoderLayers: Int) {
        self.manager = manager
        self.versionLabel = versionLabel
        self.decoderLayers = decoderLayers
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
    /// variant (see `models`); nil or an unknown name uses `defaultModel`.
    /// `language` only triggers a notice — Parakeet auto-detects within its set.
    static func make(model: String?, language: String?) throws -> ParakeetBackend {
        try Platform.requireAppleSilicon(engine: "parakeet")
        if let warning = languageNotice(language) { Log.notice(warning) }

        let selected = resolveOrDefault(model)
        let version = selected.version
        let label = "\(selected.name) (\(selected.languages))"
        if !AsrModels.modelsExist(at: selected.cacheDirectory, version: version) {
            Log.notice("downloading parakeet \(selected.name) models (first use)…")
        }
        Log.verbose("parakeet: loading \(label) models")
        let manager: AsrManager = try RunLoopBridge.runBlocking(timeout: 1800) {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager()
            try await manager.loadModels(models)
            return manager
        }
        return ParakeetBackend(
            manager: manager, versionLabel: label, decoderLayers: version.decoderLayers)
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
        let layers = decoderLayers
        let result = try RunLoopBridge.runBlocking(timeout: 1800) {
            var state = try TdtDecoderState(decoderLayers: layers)
            return try await manager.transcribe(url, decoderState: &state)
        }
        let fullText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptFormatting.render(
            cues: Self.cues(from: result), fullText: fullText, format: format)
    }

    func shutdown() {}

    /// Every variant, in `models list --available` order. redux, phonon2,
    /// bark3 and bark3-clean need macOS 15+ (FluidAudio rejects them earlier
    /// with a clear error).
    static let models: [ParakeetModel] = [
        ParakeetModel(name: "ultra", aliases: [], version: .ultra, languages: "multilingual"),
        ParakeetModel(name: "v3", aliases: ["3"], version: .v3, languages: "multilingual"),
        ParakeetModel(name: "redux", aliases: [], version: .redux, languages: "multilingual"),
        ParakeetModel(
            name: "v2", aliases: ["2", "en", "english"], version: .v2, languages: "english-only"),
        ParakeetModel(
            name: "phonon2", aliases: ["phonon-2"], version: .phonon2, languages: "english-only"),
        ParakeetModel(
            name: "bark3", aliases: ["bark-3", "bark"], version: .bark3, languages: "english-only"),
        ParakeetModel(
            name: "bark3-clean", aliases: ["bark-3-clean", "bark-clean"], version: .bark3Clean,
            languages: "english-only"),
        ParakeetModel(
            name: "tdt-ctc-110m", aliases: ["110m"], version: .tdtCtc110m,
            languages: "english-only"),
        ParakeetModel(
            name: "ja", aliases: ["tdt-ja", "japanese"], version: .tdtJa, languages: "japanese"),
    ]

    /// The variant used when none (or an unknown one) is selected.
    static let defaultModel = models[0]

    /// Looks a variant up by name, alias, `parakeet-`/`parakeet:` prefixed
    /// name, or cached bundle name (`parakeet-tdt-0.6b-v3`, also with the HF
    /// repo's `-coreml` suffix); nil if unknown. Pure, for testing.
    static func resolve(_ name: String?) -> ParakeetModel? {
        guard var key = name?.lowercased(), !key.isEmpty else { return nil }
        if key.hasSuffix("-coreml") { key = String(key.dropLast("-coreml".count)) }
        for prefix in ["parakeet:", "parakeet-"] where key.hasPrefix(prefix) {
            let stripped = String(key.dropFirst(prefix.count))
            if models.contains(where: { $0.name == stripped || $0.aliases.contains(stripped) }) {
                key = stripped
            }
        }
        return models.first { model in
            let bundle = model.bundleName.lowercased()
            return model.name == key || model.aliases.contains(key) || bundle == key
        }
    }

    /// `resolve`, falling back to `defaultModel` with a notice for a name that
    /// isn't a parakeet variant (e.g. a whisper model left in config).
    static func resolveOrDefault(_ name: String?) -> ParakeetModel {
        if let model = resolve(name) { return model }
        if let name, !name.isEmpty {
            Log.notice(
                "note: '\(name)' is not a parakeet model; using \(defaultModel.name) "
                    + "(see 'hark models list --available').")
        }
        return defaultModel
    }

    /// True if the variant's bundles are fully present in FluidAudio's cache.
    static func isCached(_ model: ParakeetModel) -> Bool {
        AsrModels.modelsExist(at: model.cacheDirectory, version: model.version)
    }

    /// Pre-downloads the model bundles (no load) into FluidAudio's cache.
    static func download(model name: String?) throws {
        try Platform.requireAppleSilicon(engine: "parakeet")
        let selected = resolveOrDefault(name)
        let version = selected.version
        Log.notice("downloading parakeet \(selected.name) models …")
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
