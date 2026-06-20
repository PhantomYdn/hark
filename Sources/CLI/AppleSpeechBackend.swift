import Foundation
import Speech

/// On-device speech recognition via Apple's Speech.framework (PRD §6.6, engine
/// `apple`). Zero external dependencies and fully local (no network): it
/// recognizes in a single locale (no auto-detect) and cannot translate. It
/// produces plain text — the batch path rejects srt/json, while live output
/// still gets timestamps from hark's own segmenter.
final class AppleSpeechBackend: TranscriptionBackend {
    let capabilities = EngineCapabilities(autoDetect: false, translate: false, usesModelFile: false)

    private let recognizer: SFSpeechRecognizer
    private let localeIdentifier: String

    private init(recognizer: SFSpeechRecognizer, localeIdentifier: String) {
        self.recognizer = recognizer
        self.localeIdentifier = localeIdentifier
    }

    var label: String { "apple (Speech.framework, on-device, \(localeIdentifier))" }

    /// Builds a backend for `language` ("auto"/nil → current locale; a code like
    /// "de" → a matching supported locale). Requests/validates Speech
    /// authorization and requires on-device recognition, throwing actionable
    /// errors otherwise.
    static func make(language: String?) throws -> AppleSpeechBackend {
        try authorize()
        let locale = matchLocale(language, in: Array(SFSpeechRecognizer.supportedLocales()))
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw HarkError.unavailable(
                "the apple engine does not support locale '\(locale.identifier)'. "
                    + "Try a different --language, or --engine whisper.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw HarkError.unavailable(
                "on-device speech recognition is unavailable for '\(locale.identifier)'. "
                    + "Add the language under System Settings → Keyboard → Dictation, "
                    + "or use --engine whisper.")
        }
        recognizer.defaultTaskHint = .dictation
        return AppleSpeechBackend(recognizer: recognizer, localeIdentifier: locale.identifier)
    }

    func transcribe(
        wavFile: URL, language: String?, translate: Bool, format: TranscriptOutputFormat
    ) throws -> String {
        // Capability guard (also enforced up front by validation): apple cannot
        // translate and writes plain text only.
        if let error = Self.unsupportedRequest(translate: translate, format: format) {
            throw error
        }

        let request = SFSpeechURLRecognitionRequest(url: wavFile)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if #available(macOS 13.0, *) { request.addsPunctuation = true }

        let box = LockBox<Result<String, Error>>()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let error {
                box.set(.failure(HarkError.software(
                    "apple recognition failed: \(error.localizedDescription)")))
                return
            }
            guard let result, result.isFinal else { return }
            box.set(.success(result.bestTranscription.formattedString))
        }

        // Wait for completion, pumping the run loop so a main-queue callback
        // still runs (avoids deadlocking the CLI's main thread). Results arrive
        // off-main in practice; the pump handles either case.
        guard RunLoopBridge.waitPumping(timeout: 120, until: { box.get() != nil }) else {
            task.cancel()
            throw HarkError.software("apple recognition timed out.")
        }
        return try box.get()!.get()
    }

    func shutdown() {}

    /// Returns a usage error when the request exceeds apple's capabilities
    /// (translation, or a non-text format), else nil. Pure, for testing.
    static func unsupportedRequest(
        translate: Bool, format: TranscriptOutputFormat
    ) -> HarkError? {
        if translate {
            return HarkError.usage(
                "the apple engine cannot translate to English; use --engine whisper.")
        }
        if format != .txt {
            return HarkError.usage(
                "the apple engine writes plain text; transcribe to .txt "
                    + "(--transcript-format txt), or use --engine whisper for \(format.rawValue).")
        }
        return nil
    }

    // MARK: Authorization

    private static let deniedMessage = """
        speech recognition permission denied. Grant it under System Settings → \
        Privacy & Security → Speech Recognition (enable your terminal), then retry \
        — or use --engine whisper.
        """

    /// Ensures Speech authorization, prompting once if undetermined. Throws
    /// `HarkError.noPermission` when denied/restricted.
    private static func authorize() throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .denied, .restricted:
            throw HarkError.noPermission(deniedMessage)
        case .notDetermined:
            let box = LockBox<SFSpeechRecognizerAuthorizationStatus>()
            SFSpeechRecognizer.requestAuthorization { box.set($0) }
            _ = RunLoopBridge.waitPumping(timeout: 120, until: { box.get() != nil })
            guard box.get() == .authorized else {
                throw HarkError.noPermission(deniedMessage)
            }
        @unknown default:
            throw HarkError.noPermission(deniedMessage)
        }
    }

    // MARK: Locale resolution

    /// Maps a `--language` value to a recognizer locale: "auto"/nil → `current`;
    /// an exact identifier match; else a language-only match (e.g. "de" →
    /// "de-DE"); else a locale constructed from the value. Pure, for testing.
    static func matchLocale(
        _ language: String?, in supported: [Locale], current: Locale = .current
    ) -> Locale {
        guard let language, !language.isEmpty, language.lowercased() != "auto" else {
            return current
        }
        let want = language.replacingOccurrences(of: "_", with: "-").lowercased()
        if let exact = supported.first(where: { $0.identifier.lowercased() == want }) {
            return exact
        }
        let langOnly = String(want.prefix { $0 != "-" })
        if let byLang = supported.first(where: {
            ($0.language.languageCode?.identifier.lowercased() ?? "") == langOnly
        }) {
            return byLang
        }
        return Locale(identifier: language)
    }
}
