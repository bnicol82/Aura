import Foundation

/// Where a request came in from.
///
/// Not cosmetic. An unattended source cannot show a confirmation sheet, so `ToolRegistry` restricts
/// it to read-only tools rather than letting it decide alone whether to delete something (§34, §40).
enum AssistantRequestSource: String, Sendable, Equatable, CaseIterable {
    case textInput
    case voiceInput
    case appIntent
    case siri
    case shortcut
    case widget
    case actionButton
    case proactiveSuggestion

    /// `true` when a person is present and able to answer a prompt.
    var isInteractive: Bool {
        switch self {
        case .textInput, .voiceInput, .actionButton: return true
        case .appIntent, .siri, .shortcut, .widget, .proactiveSuggestion: return false
        }
    }

    /// `true` when the reply should be spoken by default.
    var prefersSpokenResponse: Bool {
        switch self {
        case .voiceInput, .siri, .actionButton: return true
        default: return false
        }
    }
}

/// One turn, as it enters the orchestrator (§35).
struct AssistantRequest: Sendable, Equatable {
    var id: UUID
    /// The user's words, already normalised.
    var text: String
    var source: AssistantRequestSource
    /// Conversation to continue. `nil` starts a new one.
    var conversationID: UUID?
    /// Ask for streaming. Ignored by providers that cannot.
    var prefersStreaming: Bool
    var now: Date

    init(
        id: UUID = UUID(),
        text: String,
        source: AssistantRequestSource = .textInput,
        conversationID: UUID? = nil,
        prefersStreaming: Bool = true,
        now: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.conversationID = conversationID
        self.prefersStreaming = prefersStreaming
        self.now = now
    }
}

/// The finished turn.
struct AssistantResponse: Sendable, Equatable {
    var requestID: UUID
    var conversationID: UUID
    var messageID: UUID
    var text: String
    /// Tool work carried out, for the transcript and the Activity screen.
    var toolActivity: [ToolActivityNote]
    /// Which model answered, and why it was chosen.
    var route: ModelRoute
    /// How much personal context this request carried, for the privacy dashboard.
    var personalContextItemCount: Int
    /// Memory the turn produced. Empty when nothing was worth keeping — the common case.
    var savedMemories: [MemorySnapshot]
    /// Candidates waiting on the user, when "Ask before saving" is on.
    var pendingMemoryCandidates: [MemoryCandidateSnapshot]
    /// `true` when this records a failure rather than an answer. Never spoken as though it worked.
    var isFailure: Bool
    var shouldSpeak: Bool

    init(
        requestID: UUID,
        conversationID: UUID,
        messageID: UUID,
        text: String,
        toolActivity: [ToolActivityNote] = [],
        route: ModelRoute,
        personalContextItemCount: Int = 0,
        savedMemories: [MemorySnapshot] = [],
        pendingMemoryCandidates: [MemoryCandidateSnapshot] = [],
        isFailure: Bool = false,
        shouldSpeak: Bool = false
    ) {
        self.requestID = requestID
        self.conversationID = conversationID
        self.messageID = messageID
        self.text = text
        self.toolActivity = toolActivity
        self.route = route
        self.personalContextItemCount = personalContextItemCount
        self.savedMemories = savedMemories
        self.pendingMemoryCandidates = pendingMemoryCandidates
        self.isFailure = isFailure
        self.shouldSpeak = shouldSpeak
    }
}

/// Progress the UI may show while a turn is in flight.
///
/// Every case is an observable *action* or output. There is no case for reasoning, and adding one
/// would violate §36 — "Never expose hidden chain-of-thought."
enum AssistantTurnEvent: Sendable {
    /// The turn's conversation and assistant message row exist, so the UI can anchor to them.
    case started(conversationID: UUID, messageID: UUID)
    /// Retrieval finished. The count is shown as "using N things I remember", never the contents.
    case contextAssembled(personalItemCount: Int, sensitivity: SensitivityMode)
    case routed(ModelRoute)
    /// Incremental reply text.
    case textDelta(String)
    /// A tool started: "Checking your calendar…".
    case toolStarted(ToolActivityNote)
    case toolFinished(ToolActivityNote)
    /// Waiting on the user to approve a consequential action.
    case awaitingConfirmation(toolName: String, prompt: String)
    /// A memory was written.
    case memorySaved(MemorySnapshot)
    /// A candidate needs review.
    case memoryCandidatePending(MemoryCandidateSnapshot)
    /// Terminal event.
    case finished(AssistantResponse)
    /// Terminal failure. Carries the user-facing error; the caller must not report success.
    case failed(AuraError)
}

/// The conductor (§35).
///
/// Owns one pipeline and nothing else: normalise, load the assistant profile, build context,
/// route, generate, run tools under the safety gate, persist the turn, extract memory, speak.
///
/// Two properties are worth stating because they are what the design is *for*:
///
/// * **It is the only writer of a turn.** Views never assemble prompts, call providers, or save
///   messages. That is what keeps §28's context discipline and §78's honesty rules in one auditable
///   path instead of scattered through the UI.
/// * **It is testable without a device.** Every dependency is a protocol, so a full turn — including
///   tool calls and memory extraction — runs against mocks with no model, no network, and no store.
protocol AssistantOrchestrating: Sendable {
    /// Runs a turn to completion.
    func send(_ request: AssistantRequest) async -> AssistantResponse

    /// Runs a turn, reporting progress. The stream always ends in `.finished` or `.failed`.
    func stream(_ request: AssistantRequest) -> AsyncStream<AssistantTurnEvent>

    /// Cancels the in-flight turn, if any.
    func cancelCurrentTurn() async
}
