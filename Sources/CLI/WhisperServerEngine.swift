import Darwin
import Foundation

/// Thread-safe holder for the async URLSession result; reads happen only
/// after the completion handler signals its semaphore.
private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<String, Error> =
        .failure(WhisperServerError.requestFailed("no response"))

    func set(_ result: Result<String, Error>) {
        lock.lock(); defer { lock.unlock() }
        value = result
    }

    func get() throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try value.get()
    }
}

enum WhisperServerError: Error, CustomStringConvertible {
    case noFreePort
    case launchFailed(String)
    case notReady
    case exited(Int32)
    case requestFailed(String)

    var description: String {
        switch self {
        case .noFreePort: return "could not allocate a local port for whisper-server"
        case .launchFailed(let why): return "could not launch whisper-server: \(why)"
        case .notReady: return "whisper-server did not become ready in time"
        case .exited(let code): return "whisper-server exited early (code \(code))"
        case .requestFailed(let why): return "whisper-server request failed: \(why)"
        }
    }
}

/// Model-resident backend: launches `whisper-server` once (loading the model
/// a single time) and transcribes each segment over an HTTP POST to its
/// `/inference` endpoint on loopback (127.0.0.1). This is local IPC with our
/// own child process — no external network — and avoids the per-segment model
/// reload of the CLI backend.
final class WhisperServerEngine: TranscriptionBackend {
    private let process: Process
    private let inferenceURL: URL
    private let session: URLSession
    let port: UInt16

    let capabilities = EngineCapabilities(autoDetect: true, translate: true, usesModelFile: true)

    private init(process: Process, port: UInt16) {
        self.process = process
        self.port = port
        self.inferenceURL = URL(string: "http://127.0.0.1:\(port)/inference")!
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]  // never route loopback via a proxy
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
    }

    /// Launches the server, loads `modelPath`, and waits until it accepts
    /// connections (which, for whisper.cpp, means the model is loaded).
    static func start(
        serverBinary: URL, modelPath: String, quiet: Bool,
        readyTimeout: TimeInterval = 60
    ) throws -> WhisperServerEngine {
        guard let port = freePort() else { throw WhisperServerError.noFreePort }

        let process = Process()
        process.executableURL = serverBinary
        process.arguments = [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
        ]
        if quiet {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
        } catch {
            throw WhisperServerError.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            if !process.isRunning {
                throw WhisperServerError.exited(process.terminationStatus)
            }
            if tcpConnectable(port: port) {
                return WhisperServerEngine(process: process, port: port)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.terminate()
        throw WhisperServerError.notReady
    }

    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String {
        let wav = try Data(contentsOf: wavFile)
        let boundary = "aural-\(UUID().uuidString)"
        var request = URLRequest(url: inferenceURL)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary, wav: wav, responseFormat: Self.responseFormat(for: format),
            translate: translate, language: language)

        let semaphore = DispatchSemaphore(value: 0)
        let outcome = ResponseBox()
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome.set(.failure(WhisperServerError.requestFailed(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome.set(.failure(WhisperServerError.requestFailed("no HTTP response")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                outcome.set(.failure(WhisperServerError.requestFailed("HTTP \(http.statusCode)")))
                return
            }
            outcome.set(.success(String(decoding: data ?? Data(), as: UTF8.self)))
        }
        task.resume()
        semaphore.wait()

        do {
            return try outcome.get()
        } catch {
            throw AuralError.software((error as? WhisperServerError)?.description ?? "\(error)")
        }
    }

    func shutdown() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    var label: String { "whisper-server (model-resident, port \(port))" }

    /// Maps an aural transcript format to a whisper.cpp server `response_format`.
    static func responseFormat(for format: TranscriptOutputFormat) -> String {
        switch format {
        case .txt: return "text"
        case .srt: return "srt"
        case .json: return "json"
        }
    }

    /// Builds a `multipart/form-data` body carrying the WAV file plus the
    /// requested response format, translation flag, and optional language. The
    /// whisper.cpp server reads these as form fields (`translate` is parsed as a
    /// boolean string; `language` accepts "auto").
    static func multipartBody(
        boundary: String, wav: Data, responseFormat: String, translate: Bool, language: String?
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"segment.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n")

        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        field("response_format", responseFormat)
        field("temperature", "0.0")
        if translate { field("translate", "true") }
        if let language { field("language", language) }

        append("--\(boundary)--\r\n")
        return body
    }
}

/// Returns an unused TCP port on the loopback interface (the OS assigns one
/// via bind-to-0). There is a tiny window before the server binds it, which
/// is acceptable for a short-lived local handoff.
func freePort() -> UInt16? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let bindResult = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { return nil }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    guard nameResult == 0 else { return nil }
    return UInt16(bigEndian: bound.sin_port)
}

/// True if a TCP connection to `127.0.0.1:port` succeeds (server listening).
func tcpConnectable(port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = port.bigEndian
    let result = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}
