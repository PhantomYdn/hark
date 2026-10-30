import Foundation

/// A model that can be downloaded, tagged by engine. `name` is the user-facing
/// download identifier (`base.en`, `whisperkit:tiny`, `parakeet:ultra`);
/// `modelId` is the engine-specific id passed to that engine (ggml short name,
/// WhisperKit variant, or Parakeet variant).
struct DownloadableModel: Codable, Equatable {
    let engine: String
    let name: String
    let modelId: String

    /// English-only vs multilingual, for display.
    var isEnglishOnly: Bool { languages == "english-only" }

    /// Language coverage label for `models list --available`.
    var languages: String {
        switch engine {
        case "fluidaudio": return "speaker pipeline"
        case "parakeet": return ParakeetBackend.resolve(modelId)?.languages ?? "multilingual"
        default: return modelId.lowercased().contains(".en") ? "english-only" : "multilingual"
        }
    }
}

/// Maps download names to engines and lists what each engine can fetch.
/// Engine-tagged names (`whisperkit:`/`parakeet:` prefixes) disambiguate the
/// CoreML engines; a bare name is a whisper ggml model (backward compatible).
enum ModelCatalog {
    /// Parses a download name into engine + engine-specific id.
    /// `parakeet:v3` / `parakeet-v3` → parakeet/v3 (aliases canonicalized,
    /// bare `parakeet` → the default variant); `whisperkit:tiny` →
    /// whisperkit/tiny; otherwise → whisper/<name>.
    static func parse(_ name: String) -> DownloadableModel {
        if let id = tagged(name, engine: "fluidaudio") {
            // fluidaudio:diarizer / fluidaudio:vad (CoreML helper models).
            let component = id.isEmpty ? "diarizer" : id
            return DownloadableModel(engine: "fluidaudio", name: name, modelId: component)
        }
        if let id = tagged(name, engine: "parakeet") {
            // Canonicalize known variants (`parakeet:bark-clean` → bark3-clean);
            // bare `parakeet` → the default. Unknown ids pass through.
            let variant = id.isEmpty
                ? ParakeetBackend.defaultModel.name
                : (ParakeetBackend.resolve(id)?.name ?? id)
            return DownloadableModel(engine: "parakeet", name: name, modelId: variant)
        }
        if let id = tagged(name, engine: "whisperkit") {
            return DownloadableModel(engine: "whisperkit", name: name, modelId: id)
        }
        return DownloadableModel(engine: "whisper", name: name, modelId: name)
    }

    /// Returns the id after an `<engine>:` or `<engine>-` prefix, or nil.
    private static func tagged(_ name: String, engine: String) -> String? {
        for separator in [":", "-"] {
            let prefix = engine + separator
            if name.lowercased().hasPrefix(prefix) {
                return String(name.dropFirst(prefix.count))
            }
        }
        return name.lowercased() == engine ? "" : nil
    }

    /// The full downloadable catalog across engines, for `models list --available`.
    static func available() -> [DownloadableModel] {
        let whisper = ModelRegistry.downloadable.map {
            DownloadableModel(engine: "whisper", name: $0, modelId: $0)
        }
        let whisperkit = WhisperKitBackend.downloadableVariants.map {
            DownloadableModel(engine: "whisperkit", name: "whisperkit:\($0)", modelId: $0)
        }
        let parakeet = ParakeetBackend.models.map {
            DownloadableModel(engine: "parakeet", name: "parakeet:\($0.name)", modelId: $0.name)
        }
        // CoreML speaker pipeline helpers (PRD §6.7): pre-fetch to avoid a
        // first-use download on the default live path. `diarizer` is the
        // offline/batch Pyannote pipeline; `streaming-diarizer` is the live
        // LS-EEND model; `vad` is Silero.
        let fluidaudio = ["diarizer", "streaming-diarizer", "vad"].map {
            DownloadableModel(engine: "fluidaudio", name: "fluidaudio:\($0)", modelId: $0)
        }
        return whisper + whisperkit + parakeet + fluidaudio
    }
}
