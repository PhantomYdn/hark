import ArgumentParser
import Foundation

/// `hark models` — inspect and fetch local transcription models (PRD §6.1).
struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List and download local transcription models.",
        discussion: """
            'list' shows installed models across engines; 'list --available' \
            shows what you can download. 'download <name>' fetches a model: a \
            bare ggml name for whisper (base.en), or an engine-tagged name for \
            CoreML engines (whisperkit:tiny, parakeet:v3). Downloads are the only \
            commands here that make network requests. The 'apple' engine uses \
            OS-managed assets and is not listed.
            """,
        subcommands: [ModelsList.self, ModelsDownload.self],
        defaultSubcommand: ModelsList.self
    )
}

/// One downloadable catalog entry (also the `--available --json` shape).
struct AvailableModel: Codable {
    let name: String
    let engine: String
    let languages: String
    let installed: Bool
    /// True if this download is the active default (engine + model in config).
    let current: Bool
}

struct ModelsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show local models, or downloadable models with --available.")

    @Flag(name: .customLong("available"), help: """
        List models that can be downloaded (from ggerganov/whisper.cpp) instead \
        of the locally installed ones.
        """)
    var available = false

    @Flag(help: "Output as JSON for scripting.")
    var json = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            available ? try listAvailable() : try listLocal()
        }
    }

    private func listLocal() throws {
        let config = Configuration.load()
        let models = ModelRegistry.localModels()
            + ModelRegistry.coreMLModels(
                engine: "whisperkit", directory: WhisperKitBackend.downloadBase, config: config)
            // The FluidAudio cache mixes parakeet ASR with the fluidaudio
            // VAD/diarization helpers; classify each bundle by name.
            + ModelRegistry.coreMLModels(
                engine: "fluidaudio", directory: FluidAudioCache.modelsDirectory,
                classifyEngine: FluidAudioCache.engine(forBundle:), config: config)
        if json {
            print(try OutputFormatting.json(models))
            return
        }
        guard !models.isEmpty else {
            print("no models in \(ModelRegistry.modelsDirectory.path)")
            print("see downloadable models with: hark models list --available")
            print("then fetch one with:          hark models download base.en")
            printCurrentNote(models: models)
            return
        }
        let rows = models.map {
            [$0.name, $0.engine, ModelRegistry.formatBytes($0.sizeBytes),
             $0.current ? "*" : "", $0.path]
        }
        print(OutputFormatting.table(
            header: ["NAME", "ENGINE", "SIZE", "CURRENT", "PATH"], rows: rows))
        printCurrentNote(models: models)
    }

    private func listAvailable() throws {
        let whisperNames = Set(ModelRegistry.localModels().map(\.name))
        let wkCache = ModelRegistry.coreMLModels(
            engine: "whisperkit", directory: WhisperKitBackend.downloadBase)
        let pkCache = ModelRegistry.coreMLModels(
            engine: "parakeet", directory: ParakeetBackend.downloadBase)
        let currentWhisper = ModelRegistry.currentModelPath()
            .flatMap(ModelRegistry.shortName(forPath:))
        let config = Configuration.load()

        func installed(_ m: DownloadableModel) -> Bool {
            switch m.engine {
            case "whisperkit": return wkCache.contains { $0.name.contains(m.modelId) }
            case "parakeet": return pkCache.contains { $0.name.contains(m.modelId) }
            case "fluidaudio": return false  // FluidAudio owns its cache; not introspected
            default: return whisperNames.contains(m.modelId)
            }
        }
        func current(_ m: DownloadableModel) -> Bool {
            if m.engine == "whisper" { return currentWhisper == m.modelId }
            return config.engine == m.engine && config.model == m.modelId
        }

        func languages(_ m: DownloadableModel) -> String {
            if m.engine == "fluidaudio" { return "speaker pipeline" }
            return m.isEnglishOnly ? "english-only" : "multilingual"
        }
        let entries = ModelCatalog.available().map {
            AvailableModel(
                name: $0.name, engine: $0.engine, languages: languages($0),
                installed: installed($0), current: current($0))
        }
        if json {
            print(try OutputFormatting.json(entries))
            return
        }
        let rows = entries.map {
            [$0.name, $0.engine, $0.languages, $0.installed ? "yes" : "", $0.current ? "*" : ""]
        }
        print(OutputFormatting.table(
            header: ["NAME", "ENGINE", "LANGUAGES", "INSTALLED", "CURRENT"], rows: rows))
        print("\ndownload with: hark models download <name>")
        print("(whisper: any ggml name from ggerganov/whisper.cpp also works)")
    }

    /// Clarifies the active default when no listed row carries `*`: either a
    /// whisper model resolved outside ~/.hark/models, or no default configured.
    private func printCurrentNote(models: [LocalModel]) {
        guard !models.contains(where: { $0.current }) else { return }
        if let current = ModelRegistry.currentModelPath() {
            print("\ncurrent model: \(current)")
            print(
                "(outside \(ModelRegistry.modelsDirectory.path); "
                    + "set via $HARK_WHISPER_MODEL or hark config)")
            return
        }
        print("\nno default model set — pass --model, or configure one:")
        print("  hark config set engine <whisper|apple|whisperkit|parakeet>")
        print("  hark config set model <name>")
    }
}

struct ModelsDownload: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download a whisper ggml model into ~/.hark/models.")

    @Argument(help: ArgumentHelp(
        "Model name. whisper: a ggml short name (base.en). CoreML: engine-tagged "
            + "(whisperkit:tiny, parakeet:v3). See 'hark models list --available'.",
        valueName: "name"))
    var name: String

    @Flag(name: .customLong("force"), help: "Re-download even if the model already exists.")
    var force = false

    @Flag(name: .customLong("default"), help: """
        Make this the default (~/.hark/config.json). For whisper the first \
        download is auto-adopted; for whisperkit/parakeet --default also sets \
        the engine.
        """)
    var makeDefault = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            let spec = ModelCatalog.parse(name)
            try ModelDownloader.download(spec: spec, force: force)

            var config = Configuration.load()
            // fluidaudio diarizer/vad are speaker-pipeline helpers, not a
            // transcription engine, so they are never adopted as the default.
            let adopt =
                spec.engine == "fluidaudio"
                ? false
                : spec.engine == "whisper"
                    ? ModelDownloader.shouldSetDefault(explicit: makeDefault, existing: config.model)
                    : makeDefault
            if adopt {
                config.model = spec.modelId
                if spec.engine != "whisper" { config.engine = spec.engine }
                try config.save()
                Log.notice("set '\(spec.name)' as the default (hark config)")
            }
        }
    }
}

/// Downloads transcription models. The whisper ggml path is the only direct
/// network code in Hark; whisperkit/parakeet downloads are delegated to their
/// SDKs. Always explicitly invoked.
enum ModelDownloader {
    /// Whether a freshly downloaded whisper model should become the default:
    /// when the user asked (`--default`) or no default is configured yet.
    static func shouldSetDefault(explicit: Bool, existing: String?) -> Bool {
        explicit || (existing?.isEmpty ?? true)
    }

    /// Dispatches a download to the right engine.
    static func download(spec: DownloadableModel, force: Bool) throws {
        switch spec.engine {
        case "whisperkit": try WhisperKitBackend.download(variant: spec.modelId)
        case "parakeet": try ParakeetBackend.download(version: spec.modelId)
        case "fluidaudio":
            switch spec.modelId {
            case "vad": try FluidVadClassifier.downloadModel()
            case "streaming-diarizer": try EENDStreamingDiarizer.download()
            default: try SpeakerDiarizer.download()
            }
        default: try downloadGGML(name: spec.modelId, force: force)
        }
    }

    static func downloadGGML(name: String, force: Bool) throws {
        let directory = ModelRegistry.modelsDirectory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(ModelRegistry.fileName(for: name))

        if FileManager.default.fileExists(atPath: destination.path) && !force {
            Log.notice(
                "\(destination.lastPathComponent) already present at \(destination.path) "
                    + "(use --force to re-download)")
            return
        }

        let url = ModelRegistry.downloadURL(for: name)
        Log.notice("downloading \(url.absoluteString) …")
        let staged = try fetch(url, modelName: name)
        defer { try? FileManager.default.removeItem(at: staged) }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: staged, to: destination)
        } catch {
            throw HarkError.ioError("could not save model to \(destination.path): \(error)")
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        Log.notice("saved \(destination.path) (\(ModelRegistry.formatBytes(size)))")
    }

    /// Synchronously downloads `url` to a temporary file owned by the caller.
    private static func fetch(_ url: URL, modelName: String) throws -> URL {
        let box = DownloadBox()
        let semaphore = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: url) { tempURL, response, error in
            defer { semaphore.signal() }
            if let error {
                box.set(.failure(HarkError.ioError("download failed: \(error.localizedDescription)")))
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                box.set(.failure(HarkError.ioError(
                    "download failed: HTTP \(http.statusCode) — is '\(modelName)' a valid "
                        + "model name? (see https://huggingface.co/ggerganov/whisper.cpp)")))
                return
            }
            guard let tempURL else {
                box.set(.failure(HarkError.ioError("download produced no file")))
                return
            }
            // URLSession deletes tempURL once this handler returns; move it to a
            // path we own before signaling.
            let owned = FileManager.default.temporaryDirectory
                .appendingPathComponent("hark-dl-\(UUID().uuidString).bin")
            do {
                try FileManager.default.moveItem(at: tempURL, to: owned)
                box.set(.success(owned))
            } catch {
                box.set(.failure(HarkError.ioError("could not stage download: \(error)")))
            }
        }
        task.resume()
        semaphore.wait()
        return try box.get()
    }
}

/// Thread-safe holder for the async download result.
private final class DownloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<URL, Error> = .failure(HarkError.ioError("download did not run"))

    func set(_ result: Result<URL, Error>) {
        lock.lock(); defer { lock.unlock() }
        value = result
    }

    func get() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        return try value.get()
    }
}
