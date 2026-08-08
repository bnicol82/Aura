import AVFoundation
import Foundation

/// `SpeechSynthesisService` over `AVSpeechSynthesizer` (§39).
///
/// ### Why `@MainActor` rather than an actor
/// `AVSpeechSynthesizer` and its delegate are not `Sendable`, and the delegate callbacks arrive on the main
/// queue. Pinning the whole service to the main actor is what makes that safe under strict concurrency
/// without wrapping a non-Sendable object in unchecked promises. A `@MainActor` class is implicitly
/// `Sendable`, so it still satisfies the protocol.
///
/// ### The one permanent constraint
/// AURA never imitates a real person's voice — no cloning, no likeness of a named individual. That is a
/// product rule, not a limitation of this backend, and it survives any future TTS engine.
@MainActor
final class SystemSpeechSynthesisService: NSObject, SpeechSynthesisService {

    private let synthesizer = AVSpeechSynthesizer()

    /// Resumed when the current utterance finishes or is stopped.
    ///
    /// Exactly one continuation can be outstanding, because `speak` does not return until the utterance
    /// ends. Storing it here rather than capturing it lets the delegate resume it.
    private var activeContinuation: CheckedContinuation<Void, any Error>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Voices

    func availableVoices() async -> [AssistantVoice] {
        let preferredLanguage = Locale.current.identifier
        return AVSpeechSynthesisVoice.speechVoices()
            .map(Self.voice(from:))
            // Voices for the user's own language first: a list led by Afrikaans is technically complete and
            // practically useless.
            .sorted { lhs, rhs in
                let lhsMatches = Self.languagesMatch(lhs.localeIdentifier, preferredLanguage)
                let rhsMatches = Self.languagesMatch(rhs.localeIdentifier, preferredLanguage)
                if lhsMatches != rhsMatches { return lhsMatches }
                if lhs.isEnhanced != rhs.isEnhanced { return lhs.isEnhanced }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func defaultVoice() async -> AssistantVoice? {
        // `AVSpeechSynthesisVoice(language:)` is what the synthesizer itself falls back to, so asking it
        // keeps "the default" identical to what happens when no voice is set.
        if let match = AVSpeechSynthesisVoice(language: Locale.current.identifier) {
            return Self.voice(from: match)
        }
        return await availableVoices().first
    }

    /// Maps a system voice onto AURA's own type.
    ///
    /// `static` and pure so the mapping is testable without a speech engine.
    static func voice(from voice: AVSpeechSynthesisVoice) -> AssistantVoice {
        AssistantVoice(
            id: voice.identifier,
            displayName: voice.name,
            localeIdentifier: voice.language,
            isEnhanced: voice.quality == .enhanced || voice.quality == .premium,
            // Nothing to download: `speechVoices()` only reports voices already present. A higher-quality
            // voice the user has not installed simply does not appear, which is why this is always false
            // and not a guess about the user's Settings.
            requiresDownload: false
        )
    }

    /// Whether two locale identifiers share a language, ignoring region and separator style.
    ///
    /// `en_US` and `en-GB` match; `en_US` and `fr_FR` do not. Apple mixes `_` and `-` between APIs, which is
    /// exactly the sort of thing that silently sorts every voice into the wrong bucket.
    static func languagesMatch(_ lhs: String, _ rhs: String) -> Bool {
        func language(_ identifier: String) -> String {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            return String(normalized.split(separator: "-").first ?? "").lowercased()
        }
        let left = language(lhs)
        return !left.isEmpty && left == language(rhs)
    }

    // MARK: - Speaking

    func speak(_ text: String, voiceIdentifier: String?, rate: Double) async throws {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }

        // A second `speak` while one is in flight would leave the first caller's continuation orphaned and
        // its task suspended forever. Stopping first makes the previous call throw `.cancelled`, which is
        // the truth: it was cut off.
        if synthesizer.isSpeaking || activeContinuation != nil {
            await stop()
        }

        let utterance = AVSpeechUtterance(string: spoken)
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        }
        utterance.rate = Self.utteranceRate(from: rate)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                activeContinuation = continuation
                synthesizer.speak(utterance)
            }
        } onCancel: {
            // Cancelling the awaiting task has to actually silence the device. Without this the caller
            // returns while AURA keeps talking, which reads as the app ignoring the user.
            Task { @MainActor in await self.stop() }
        }
    }

    func stop() async {
        synthesizer.stopSpeaking(at: .immediate)
        // `didCancel` is not guaranteed to arrive when nothing was speaking, so the continuation is resumed
        // here rather than left to a callback that may never come.
        resumeActive(throwing: AuraError.cancelled)
    }

    var isSpeaking: Bool {
        get async { synthesizer.isSpeaking }
    }

    /// Maps AURA's 0...1 rate onto `AVSpeechUtterance`'s range.
    ///
    /// `static` and pure because the mapping is the sort of arithmetic that is wrong by a factor of two for
    /// months before anyone notices. 0.5 means "the system default", not "half speed".
    static func utteranceRate(from rate: Double) -> Float {
        let clamped = min(max(rate, 0), 1)
        let minimum = Double(AVSpeechUtteranceMinimumSpeechRate)
        let maximum = Double(AVSpeechUtteranceMaximumSpeechRate)
        let normal = Double(AVSpeechUtteranceDefaultSpeechRate)

        // Piecewise so that 0.5 lands exactly on the system default rather than the midpoint between the
        // extremes, which is noticeably faster than what iOS considers normal.
        if clamped <= 0.5 {
            return Float(minimum + (normal - minimum) * (clamped / 0.5))
        }
        return Float(normal + (maximum - normal) * ((clamped - 0.5) / 0.5))
    }

    private func resumeActive(throwing error: (any Error)?) {
        guard let continuation = activeContinuation else { return }
        activeContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SystemSpeechSynthesisService: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in resumeActive(throwing: nil) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        // Throwing rather than returning normally is what lets a caller tell "finished speaking" from "the
        // user cut it off", so a reply is never marked as delivered when it was not.
        Task { @MainActor in resumeActive(throwing: AuraError.cancelled) }
    }
}
