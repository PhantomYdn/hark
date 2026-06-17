import Foundation

/// FluidAudio's shared CoreML model cache
/// (`~/Library/Application Support/FluidAudio/Models`), home to the parakeet
/// ASR model plus the speaker-pipeline helpers (silero-vad, speaker-diarization).
enum FluidAudioCache {
    /// Bundle directory names of the speaker-pipeline helpers.
    static let vadBundle = "silero-vad"
    static let diarizerBundle = "speaker-diarization"
    /// LS-EEND streaming-diarization model (FluidAudio caches it under the repo
    /// folder `ls-eend/<variant>`; `ch` (callhome) is Aural's default variant).
    static let streamingDiarizerBundle = "ls-eend/ch"

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// True if a model bundle is already present, so callers avoid a misleading
    /// "downloading" notice when loading from cache.
    static func isCached(_ bundle: String, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: modelsDirectory.appendingPathComponent(bundle).path)
    }

    /// Maps a cached bundle directory name to its Aural engine label. Parakeet
    /// ASR bundles are `parakeet`; the VAD/diarization helpers are `fluidaudio`.
    static func engine(forBundle name: String) -> String {
        name.lowercased().contains("parakeet") ? "parakeet" : "fluidaudio"
    }
}
