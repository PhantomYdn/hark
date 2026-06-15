import ArgumentParser
import Foundation

/// `aural models` — inspect and fetch local transcription models (PRD §6.1).
struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List and download local transcription models.",
        discussion: """
            Models live in ~/.aural/models as ggml-<name>.bin files and are \
            selected with --model. 'download' fetches whisper ggml models from \
            Hugging Face (ggerganov/whisper.cpp) — the only command here that \
            makes a network request. The 'apple' engine uses OS-managed assets \
            and is not listed.
            """,
        subcommands: [ModelsList.self, ModelsDownload.self],
        defaultSubcommand: ModelsList.self
    )
}

/// One downloadable catalog entry (also the `--available --json` shape).
struct AvailableModel: Codable {
    let name: String
    let multilingual: Bool
    let installed: Bool
    /// True if this is the active model (`$AURAL_WHISPER_MODEL` selects it).
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
        let models = ModelRegistry.localModels()
        if json {
            print(try OutputFormatting.json(models))
            return
        }
        guard !models.isEmpty else {
            print("no models in \(ModelRegistry.modelsDirectory.path)")
            print("see downloadable models with: aural models list --available")
            print("then fetch one with:          aural models download base.en")
            printCurrentOutsideNote(models: models)
            return
        }
        let rows = models.map {
            [$0.name, "whisper", ModelRegistry.formatBytes($0.sizeBytes),
             $0.current ? "*" : "", $0.path]
        }
        print(OutputFormatting.table(
            header: ["NAME", "ENGINE", "SIZE", "CURRENT", "PATH"], rows: rows))
        printCurrentOutsideNote(models: models)
    }

    private func listAvailable() throws {
        let local = ModelRegistry.localModels()
        let installed = Set(local.map(\.name))
        let currentName = ModelRegistry.currentModelPath().flatMap(ModelRegistry.shortName(forPath:))
        let entries = ModelRegistry.downloadable.map {
            AvailableModel(
                name: $0,
                multilingual: !ModelRegistry.isEnglishOnly(modelPath: "ggml-\($0).bin"),
                installed: installed.contains($0),
                current: $0 == currentName)
        }
        if json {
            print(try OutputFormatting.json(entries))
            return
        }
        let rows = entries.map {
            [$0.name, $0.multilingual ? "multilingual" : "english-only",
             $0.installed ? "yes" : "", $0.current ? "*" : ""]
        }
        print(OutputFormatting.table(
            header: ["NAME", "LANGUAGES", "INSTALLED", "CURRENT"], rows: rows))
        print("\ndownload with: aural models download <name>  (any ggml name from")
        print("ggerganov/whisper.cpp also works, e.g. small.en-q5_1)")
    }

    /// Notes the active model when it lives outside ~/.aural/models (so no listed
    /// row carries the `*`), so `*` never silently goes missing.
    private func printCurrentOutsideNote(models: [LocalModel]) {
        guard let current = ModelRegistry.currentModelPath(),
            !models.contains(where: { $0.current })
        else { return }
        print("\ncurrent model: \(current)")
        print(
            "(outside \(ModelRegistry.modelsDirectory.path); "
                + "set via $AURAL_WHISPER_MODEL or aural config)")
    }
}

struct ModelsDownload: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download a whisper ggml model into ~/.aural/models.")

    @Argument(help: ArgumentHelp(
        "Model short name, e.g. base.en, small, large-v3-turbo.", valueName: "name"))
    var name: String

    @Flag(name: .customLong("force"), help: "Re-download even if the model already exists.")
    var force = false

    @Flag(name: .customLong("default"), help: """
        Set this model as the default in ~/.aural/config.json. The first model \
        you download becomes the default automatically.
        """)
    var makeDefault = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        try runMapped(verbose: options.verbose) {
            try ModelDownloader.download(name: name, force: force)

            // Auto-adopt the first model as the default; --default always sets it.
            var config = Configuration.load()
            if ModelDownloader.shouldSetDefault(explicit: makeDefault, existing: config.model) {
                config.model = name
                try config.save()
                Log.notice("set '\(name)' as the default model (aural config)")
            }
        }
    }
}

/// Downloads a whisper ggml model to `~/.aural/models`. This is the only
/// network-touching code path in Aural and is always explicitly invoked.
enum ModelDownloader {
    /// Whether a freshly downloaded model should become the default: when the
    /// user asked (`--default`) or no default is configured yet (first model).
    static func shouldSetDefault(explicit: Bool, existing: String?) -> Bool {
        explicit || (existing?.isEmpty ?? true)
    }

    static func download(name: String, force: Bool) throws {
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
            throw AuralError.ioError("could not save model to \(destination.path): \(error)")
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
                box.set(.failure(AuralError.ioError("download failed: \(error.localizedDescription)")))
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                box.set(.failure(AuralError.ioError(
                    "download failed: HTTP \(http.statusCode) — is '\(modelName)' a valid "
                        + "model name? (see https://huggingface.co/ggerganov/whisper.cpp)")))
                return
            }
            guard let tempURL else {
                box.set(.failure(AuralError.ioError("download produced no file")))
                return
            }
            // URLSession deletes tempURL once this handler returns; move it to a
            // path we own before signaling.
            let owned = FileManager.default.temporaryDirectory
                .appendingPathComponent("aural-dl-\(UUID().uuidString).bin")
            do {
                try FileManager.default.moveItem(at: tempURL, to: owned)
                box.set(.success(owned))
            } catch {
                box.set(.failure(AuralError.ioError("could not stage download: \(error)")))
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
    private var value: Result<URL, Error> = .failure(AuralError.ioError("download did not run"))

    func set(_ result: Result<URL, Error>) {
        lock.lock(); defer { lock.unlock() }
        value = result
    }

    func get() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        return try value.get()
    }
}
