import Foundation

/// A voice the assistant can use.
struct AssistantVoice: Sendable, Equatable, Identifiable, Hashable {
    /// `AVSpeechSynthesisVoice.identifier`, or a provider-specific id for a future TTS backend.
    var id: String
    var displayName: String
    var localeIdentifier: String
    /// `true` for Apple's higher-quality downloadable voices, which the user may need to install.
    var isEnhanced: Bool
    /// `true` when the voice is not present on device and must be downloaded in iOS Settings.
    var requiresDownload: Bool

    init(
        id: String,
        displayName: String,
        localeIdentifier: String,
        isEnhanced: Bool = false,
        requiresDownload: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.localeIdentifier = localeIdentifier
        self.isEnhanced = isEnhanced
        self.requiresDownload = requiresDownload
    }
}

/// Speaks the assistant's replies (§39).
///
/// The V1 implementation uses `AVSpeechSynthesizer` with system voices. The protocol exists so a
/// higher-quality TTS backend can be added later without touching the orchestrator.
///
/// One constraint is permanent, not an implementation detail: **AURA never imitates a real person's
/// voice.** No cloning, no likeness of a named individual, whatever backend is in use.
protocol SpeechSynthesisService: Sendable {
    /// Voices available on this device, best first.
    func availableVoices() async -> [AssistantVoice]

    /// The voice used when the user has not chosen one, for their current language.
    func defaultVoice() async -> AssistantVoice?

    /// Speaks `text`, returning when the utterance finishes.
    ///
    /// Throws `AuraError.cancelled` if interrupted, so a caller can tell "finished" from "stopped"
    /// and does not mark a reply as delivered when the user cut it off.
    func speak(_ text: String, voiceIdentifier: String?, rate: Double) async throws

    /// Stops immediately, discarding anything queued.
    func stop() async

    var isSpeaking: Bool { get async }
}
