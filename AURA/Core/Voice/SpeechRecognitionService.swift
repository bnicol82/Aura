import Foundation

/// A transcription result while listening.
struct SpeechTranscriptionUpdate: Sendable, Equatable {
    /// Best transcription so far — cumulative, not a delta.
    var text: String
    /// `false` while the recognizer may still revise this text.
    var isFinal: Bool
    /// Recognizer confidence, when reported.
    var confidence: Double?

    init(text: String, isFinal: Bool = false, confidence: Double? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

/// Turns speech into text (§38).
///
/// ### Implementation note for Phase 5
/// iOS 26's `SpeechAnalyzer` + `SpeechTranscriber` supersede `SFSpeechRecognizer`, and the concrete
/// service will prefer them. Two facts about that API shape this protocol:
///
/// * `SpeechTranscriber.isAvailable` and `installedLocales` mean transcription can be unsupported for
///   the user's language even on eligible hardware, so `availability()` is async and returns a
///   reason rather than a bool.
/// * Model assets may need downloading before first use, which is a visible wait — hence
///   `prepare()` as a separate step from `startListening()`.
///
/// ### On stored audio
/// `startListening()` returns text, never audio. Raw microphone samples are not persisted by
/// default, per §38 — the buffer is consumed by the recognizer and released.
protocol SpeechRecognitionService: Sendable {
    /// Whether transcription can run right now, and why not if it cannot.
    func availability() async -> SpeechRecognitionAvailability

    /// Downloads assets and warms the recognizer. Safe to call repeatedly.
    func prepare(locale: Locale) async throws

    /// Starts listening.
    ///
    /// The stream finishes after a final update, or throws. Cancelling the consuming task stops the
    /// microphone — there is no way to leave it open by dropping the stream.
    func startListening(locale: Locale) throws -> AsyncThrowingStream<SpeechTranscriptionUpdate, any Error>

    /// Stops listening and finalises the transcript. The corresponding stream ends with `isFinal`.
    func stopListening() async

    /// Stops immediately and discards the partial transcript.
    func cancel() async
}

/// Why transcription is or is not available.
enum SpeechRecognitionAvailability: Sendable, Equatable {
    case available
    case microphonePermissionRequired
    case speechPermissionRequired
    case microphoneDenied
    case speechDenied
    /// Hardware or OS cannot transcribe at all.
    case unsupportedDevice
    /// No transcription assets for this language.
    case unsupportedLocale(Locale)
    /// Assets are downloading.
    case assetsDownloading
    case temporarilyUnavailable(reason: String)

    var isAvailable: Bool { self == .available }

    var userFacingDescription: String {
        switch self {
        case .available:
            return "Ready to listen."
        case .microphonePermissionRequired:
            return "I need microphone access first."
        case .speechPermissionRequired:
            return "I need speech recognition access first."
        case .microphoneDenied:
            return "Microphone access is off, so I can't hear you."
        case .speechDenied:
            return "Speech recognition is off, so I can't turn what you say into text."
        case .unsupportedDevice:
            return "This device can't transcribe speech."
        case .unsupportedLocale(let locale):
            let language = locale.language.languageCode?.identifier ?? locale.identifier
            return "I can't transcribe \(language) yet."
        case .assetsDownloading:
            return "Getting speech recognition ready — this only happens once."
        case .temporarilyUnavailable(let reason):
            return "I can't listen right now. (\(reason))"
        }
    }

    /// The error to surface when listening is attempted anyway.
    var asError: AuraError? {
        switch self {
        case .available:
            return nil
        case .microphonePermissionRequired, .microphoneDenied:
            return .microphonePermissionDenied
        case .speechPermissionRequired, .speechDenied:
            return .speechRecognitionPermissionDenied
        case .unsupportedDevice:
            return .speechRecognitionUnavailable(reason: "not supported on this device")
        case .unsupportedLocale(let locale):
            return .speechRecognitionUnavailable(reason: "no support for \(locale.identifier)")
        case .assetsDownloading:
            return .speechRecognitionUnavailable(reason: "still downloading")
        case .temporarilyUnavailable(let reason):
            return .speechRecognitionUnavailable(reason: reason)
        }
    }
}
