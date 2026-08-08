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

    init(
        orchestrator: any AssistantOrchestrating,
        conversationStore: any ConversationStoring
    ) {
        self.orchestrator = orchestrator
        self.conversationStore = conversationStore
    }

    // MARK: - Derived

    var isBusy: Bool { state.isBusy }

    var canSend: Bool {
        !draft.isBlank && !isBusy && FeatureFlags.textConversation.isLive
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

            case .finished:
                // The store write is what the transcript renders, so the partial is dropped rather than
                // shown alongside the saved message.
                streamingText = nil
                state = .idle

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
