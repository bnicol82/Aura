import Foundation
import Observation

/// The UI's view onto a live conversation.
///
/// A thin adapter, on purpose. It holds what the screen needs to draw — the in-flight state, the draft,
/// the current conversation — and forwards everything else to `AssistantOrchestrator`. No prompt
/// assembly, no provider calls, no message writing happens here; the transcript itself comes from
/// SwiftData through `@Query`, so the store stays the single source of truth for what was said.
///
/// Lives on `AppEnvironment` rather than in a `@State` on the view, so an in-flight turn survives the
/// user switching tabs mid-answer.
@MainActor
@Observable
final class ConversationController {

    private let orchestrator: any AssistantOrchestrating
    private let conversationStore: any ConversationStoring

    /// The conversation being shown. `nil` until the first turn creates one.
    private(set) var conversationID: UUID?

    /// Drives the orb, the composer's enabled state, and the status line.
    private(set) var state: VoiceState = .idle

    /// What the model has produced so far this turn.
    ///
    /// Non-nil only while a turn is in flight. Phase 2's provider answers in one piece, so this holds
    /// the whole reply for the moment between arrival and the store write landing in `@Query`; Phase 3's
    /// streaming fills it token by token through the same path.
    private(set) var streamingText: String?

    /// Set when a turn failed for a reason the user has not yet acknowledged.
    var errorMessage: String?

    /// Bound to the composer.
    var draft: String = ""

    /// How much remembered context the last turn used. Shown as a count, never as contents (§43).
    private(set) var lastContextItemCount: Int = 0

    /// Which model answered last, so the transcript can be honest about on-device versus cloud.
    private(set) var lastRoute: ModelRoute?

    private let recognition: (any SpeechRecognitionService)?
    private let synthesis: (any SpeechSynthesisService)?
    private let permissions: (any PermissionManaging)?
    private let assistantProfileStore: (any AssistantProfileStoring)?

    /// The live listening session, so stopping is possible from the UI.
    private var listeningTask: Task<Void, Never>?

    /// Why listening is unavailable, when it is. Shown instead of silently doing nothing on a tap.
    ///
    /// Settable so the alert that presents it can dismiss it.
    var voiceUnavailableMessage: String?

    init(
        orchestrator: any AssistantOrchestrating,
        conversationStore: any ConversationStoring,
        recognition: (any SpeechRecognitionService)? = nil,
        synthesis: (any SpeechSynthesisService)? = nil,
        permissions: (any PermissionManaging)? = nil,
        assistantProfileStore: (any AssistantProfileStoring)? = nil
    ) {
        self.orchestrator = orchestrator
        self.conversationStore = conversationStore
        self.recognition = recognition
        self.synthesis = synthesis
        self.permissions = permissions
        self.assistantProfileStore = assistantProfileStore
    }

    // MARK: - Derived

    var isBusy: Bool { state.isBusy }

    var canSend: Bool {
        !draft.isBlank && !isBusy && FeatureFlags.textConversation.isLive
    }

    /// Whether the microphone button does anything.
    ///
    /// Requires the flag *and* an injected service: a build wired without one must disable the button
    /// rather than present a control that silently fails.
    var canListen: Bool {
        FeatureFlags.voiceInput.isLive && recognition != nil && !isBusy
    }

    var isListening: Bool { state.isListening }

    // MARK: - Voice

    /// Starts or stops listening, matching what the one microphone button means in each state.
    func toggleListening() async {
        if state.isListening {
            await stopListening()
        } else {
            await startListening()
        }
    }

    /// Opens the microphone and streams the transcript into `state`.
    ///
    /// Permission is requested here rather than at launch (§53): the microphone prompt makes sense the
    /// moment someone taps a microphone, and makes none on first run before they know what AURA is.
    func startListening() async {
        guard let recognition, canListen else { return }

        voiceUnavailableMessage = nil

        if let permissions {
            for permission in [AuraPermission.microphone, .speechRecognition] {
                let status = await permissions.request(permission)
                guard status.isUsable else {
                    // Naming which one is missing is the difference between a fixable problem and a dead
                    // button. A denied permission cannot be re-prompted, so the message points at Settings.
                    voiceUnavailableMessage = status == .notDetermined
                        ? "\(permission.displayName) access is needed before I can listen."
                        : "\(permission.displayName) access is off. You can turn it back on in Settings."
                    return
                }
            }
        }

        let availability = await recognition.availability()
        guard availability.isAvailable || availability == .assetsDownloading else {
            voiceUnavailableMessage = availability.userFacingDescription
            return
        }

        state = .listening(transcript: "")

        listeningTask = Task { [weak self] in
            guard let self else { return }
            do {
                let locale = Locale.current
                // Assets may need downloading on first use, which is a visible wait rather than a failure.
                try await recognition.prepare(locale: locale)

                var finalTranscript = ""
                for try await update in try recognition.startListening(locale: locale) {
                    // A cumulative transcript, not a delta — assigning is correct, appending would stutter.
                    finalTranscript = update.text
                    if self.state.isListening {
                        self.state = .listening(transcript: update.text)
                    }
                }
                await self.finishListening(with: finalTranscript)
            } catch {
                await self.failListening(with: error.asAuraError)
            }
        }
    }

    /// Stops the microphone and lets the recogniser finalise, so the last words still count.
    func stopListening() async {
        guard let recognition, state.isListening else { return }
        await recognition.stopListening()
        // Deliberately not cancelling `listeningTask`: the stream is still going to deliver a final update,
        // and cancelling here would throw away the sentence the user just finished saying.
    }

    /// Abandons listening and keeps nothing.
    func cancelListening() async {
        listeningTask?.cancel()
        listeningTask = nil
        await recognition?.cancel()
        if state.isListening { state = .idle }
    }

    private func finishListening(with transcript: String) async {
        listeningTask = nil
        let spoken = transcript.normalizedWhitespace

        guard !spoken.isEmpty else {
            // Nothing heard. Returning to idle silently is right — a "I didn't catch that" error for an
            // accidental tap would be noise.
            if state.isListening { state = .idle }
            return
        }

        state = .idle
        await run(
            AssistantRequest(text: spoken, source: .voiceInput, conversationID: conversationID)
        )
    }

    private func failListening(with error: AuraError) async {
        listeningTask = nil
        if state.isListening { state = .idle }
        guard !error.isSilent else { return }
        voiceUnavailableMessage = [error.errorDescription, error.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// Reads a reply aloud, if the user asked for that.
    ///
    /// `shouldSpeak` on the response already accounts for the preference and the request source, so this
    /// does not second-guess it. Cancellation is expected rather than exceptional: the user interrupting is
    /// the normal way speech ends.
    private func speak(_ response: AssistantResponse) async {
        guard FeatureFlags.voiceOutput.isLive,
              let synthesis,
              response.shouldSpeak,
              !response.isFailure else { return }

        let preferences = await voicePreferences()
        state = .speaking
        do {
            try await synthesis.speak(
                response.text,
                voiceIdentifier: preferences?.voiceIdentifier,
                rate: preferences?.speechRate ?? 0.5
            )
        } catch {
            // Interrupted, or the engine failed. Either way the reply is already on screen, so there is
            // nothing worth telling the user about.
        }
        if state.isSpeaking { state = .idle }
    }

    /// Stops speech immediately. Bound to a tap on the orb while it is talking.
    func stopSpeaking() async {
        await synthesis?.stop()
        if state.isSpeaking { state = .idle }
    }

    private func voicePreferences() async -> VoicePreferences? {
        guard let assistantProfileStore else { return nil }
        return try? await assistantProfileStore.currentProfile().voice
    }

    /// Status line under the composer, or `nil` when there is nothing to say.
    var statusText: String? {
        switch state {
        case .idle, .error:
            return nil
        default:
            return state.statusText
        }
    }

    // MARK: - Lifecycle

    /// Attaches to the conversation worth resuming, if there is one.
    ///
    /// Deliberately does *not* create one: an empty conversation created just because a screen appeared
    /// would litter the history with blank threads. The first turn creates it.
    func prepare() async {
        guard conversationID == nil else { return }
        do {
            let resumable = try await conversationStore.mostRecentActiveConversation(
                staleAfter: Self.resumeWindow,
                now: Date()
            )
            conversationID = resumable?.id
        } catch {
            AuraLog.app.error("Could not look up a conversation to resume.")
        }

        // Detached from `prepare` so the screen never waits on it. Loading the on-device model's assets
        // takes long enough to be visible on a first reply, and the user opening this screen is the best
        // available signal that a reply is coming.
        Task { await orchestrator.prewarm() }
    }

    /// Switches the screen to an existing conversation, from history.
    ///
    /// Refuses while a turn is in flight: repointing mid-answer would file the reply under a conversation the
    /// user was no longer looking at.
    func open(conversationID id: UUID) {
        guard !isBusy else { return }
        conversationID = id
        streamingText = nil
        errorMessage = nil
        voiceUnavailableMessage = nil
        state = .idle
    }

    /// Starts a fresh conversation on the next turn.
    func startNewConversation() {
        guard !isBusy else { return }
        conversationID = nil
        streamingText = nil
        lastContextItemCount = 0
        lastRoute = nil
        state = .idle
    }

    // MARK: - Sending

    func send() async {
        guard canSend else { return }

        let text = draft
        draft = ""
        await run(AssistantRequest(
            text: text,
            source: .textInput,
            conversationID: conversationID
        ))
    }

    /// Sends text that did not come from the composer — a suggestion tap, or a voice transcript in
    /// Phase 5.
    func send(text: String, source: AssistantRequestSource = .textInput) async {
        guard !text.isBlank, !isBusy else { return }
        await run(AssistantRequest(text: text, source: source, conversationID: conversationID))
    }

    func cancel() async {
        await orchestrator.cancelCurrentTurn()
        streamingText = nil
        state = .idle
    }

    private func run(_ request: AssistantRequest) async {
        state = .processing
        streamingText = nil
        errorMessage = nil

        var accumulated = ""

        for await event in orchestrator.stream(request) {
            switch event {
            case .started(let conversationID, _):
                self.conversationID = conversationID

            case .contextAssembled(let count, _):
                lastContextItemCount = count

            case .routed(let route):
                lastRoute = route

            case .textDelta(let delta):
                accumulated += delta
                streamingText = accumulated

            case .textReplaced(let whole):
                // The provider revised rather than continued, so what is on screen is wrong and gets
                // replaced outright instead of appended to.
                accumulated = whole
                streamingText = accumulated

            case .toolStarted(let note):
                state = .toolExecution(label: note.label)

            case .toolFinished:
                state = .processing

            case .awaitingConfirmation(_, let prompt):
                state = .toolExecution(label: prompt)

            case .memorySaved, .memoryCandidatePending:
                // Surfaced in Phase 7, when there is something to surface.
                break

            case .finished(let response):
                // The store write is what the transcript renders, so the partial is dropped rather than
                // shown alongside the saved message.
                streamingText = nil
                state = .idle
                // Speaking happens after the reply is on screen, never instead of it. A spoken answer that
                // the user cannot also read would be lost the moment they missed a word.
                await speak(response)

            case .failed(let error):
                streamingText = nil
                state = .idle
                // Silent errors are the user's own cancellations; the transcript already reflects them.
                if !error.isSilent {
                    errorMessage = [error.errorDescription, error.recoverySuggestion]
                        .compactMap { $0 }
                        .joined(separator: " ")
                }
            }
        }

        // A stream that ends without a terminal event would otherwise leave the composer disabled
        // forever. Nothing should reach this, which is exactly why it is worth handling.
        if state.isBusy {
            state = .idle
            streamingText = nil
        }
    }

    /// How long a conversation stays resumable. Matches the orchestrator's own window.
    private static let resumeWindow: TimeInterval = 60 * 60 * 6
}
