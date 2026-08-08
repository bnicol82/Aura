import Foundation

/// The voice interface's state machine (§37).
///
/// One enum drives the orb, the microphone button, the accessibility announcements and whether input
/// is accepted. Keeping it in a single type rather than several booleans is what prevents the
/// impossible combinations — listening while speaking, thinking with nothing pending — that make a
/// voice UI feel broken.
enum VoiceState: Sendable, Equatable {
    /// Nothing happening. The microphone is closed.
    case idle
    /// Capturing audio. `transcript` is the live partial result.
    case listening(transcript: String)
    /// The turn is with the model.
    case processing
    /// A tool is running. `label` is the progress line ("Checking your calendar").
    case toolExecution(label: String)
    /// Reading the reply aloud.
    case speaking
    /// Something failed. Terminal until dismissed.
    case error(AuraError)

    /// `true` when the microphone is open.
    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    /// `true` when a turn is in flight and a second one must not start.
    var isBusy: Bool {
        switch self {
        case .processing, .toolExecution: return true
        case .idle, .listening, .speaking, .error: return false
        }
    }

    var isSpeaking: Bool { self == .speaking }

    /// Partial transcript while listening.
    var liveTranscript: String? {
        if case .listening(let transcript) = self { return transcript }
        return nil
    }

    /// Status line under the orb.
    var statusText: String {
        switch self {
        case .idle: return ""
        case .listening(let transcript): return transcript.isEmpty ? "Listening…" : transcript
        case .processing: return "Thinking…"
        case .toolExecution(let label): return "\(label)…"
        case .speaking: return "Speaking…"
        case .error(let error): return error.errorDescription ?? "Something went wrong."
        }
    }

    /// What VoiceOver announces. Separate from `statusText` because reading a growing partial
    /// transcript aloud on every update is unusable — the state is announced instead.
    var accessibilityAnnouncement: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .toolExecution(let label): return label
        case .speaking: return "Speaking"
        case .error(let error): return error.errorDescription ?? "Error"
        }
    }

    /// Whether tapping the microphone should stop what is happening rather than start listening.
    var tapWouldInterrupt: Bool {
        switch self {
        case .listening, .speaking, .processing, .toolExecution: return true
        case .idle, .error: return false
        }
    }
}
