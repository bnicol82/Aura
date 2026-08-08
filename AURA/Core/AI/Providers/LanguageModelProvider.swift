import Foundation

/// Stable identifier for a model provider. Persisted on `Message.providerIdentifier` so the
/// transcript can be honest about where each answer came from.
struct LanguageModelProviderID: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    /// Apple's on-device Foundation Model.
    static let appleOnDevice = LanguageModelProviderID("apple.foundation")
    static let claude = LanguageModelProviderID("anthropic.claude")
    static let openAI = LanguageModelProviderID("openai")
    /// A locally hosted model that is not Apple's.
    static let localCustom = LanguageModelProviderID("local.custom")
    static let mock = LanguageModelProviderID("mock")
}

/// Who runs the tools when a model asks for one.
///
/// This distinction is forced by the platform, not invented. Apple's `FoundationModels.Tool`
/// protocol is invoked *by the framework* inside `LanguageModelSession` — the session calls
/// `Tool.call(arguments:)` itself and feeds the result back into generation without ever returning
/// control to us. Cloud providers do the opposite: they return a tool-call request and wait for the
/// caller to run it and send the output back.
///
/// The orchestrator has to handle both, so it asks the provider which one it is dealing with rather
/// than assuming.
enum ToolExecutionStyle: Sendable, Equatable {
    /// The provider executes tools itself, through the `ToolInvoking` handle it was given.
    /// `ModelResponse.toolCalls` will be empty; completed work arrives as `ToolActivityNote`s.
    case providerManaged
    /// The provider returns tool calls; the orchestrator executes them and sends results back.
    case orchestratorManaged
}

/// What a request is *for*. `ModelRouter` reads this to choose a provider (§7): a classification
/// pass belongs on-device even in cloud-enhanced mode, and a long reasoning task may be worth
/// escalating even in automatic mode.
enum ModelRequestPurpose: String, Sendable, Equatable, CaseIterable {
    /// A turn of conversation with the user.
    case conversation
    /// Deciding what in a turn is worth remembering.
    case memoryExtraction
    /// Turning a vague question into retrieval terms.
    case memoryQuery
    /// Condensing a conversation or project.
    case summarization
    /// Short structured judgement — sensitivity, intent, category.
    case classification
    /// Multi-step reasoning that the on-device model may not handle well.
    case complexReasoning

    /// Purposes that must never leave the device regardless of AI mode.
    ///
    /// Extraction and classification see raw user speech before any relevance filtering has
    /// happened, so shipping them to a third party would leak exactly the material §50 protects.
    var isOnDeviceOnly: Bool {
        switch self {
        case .memoryExtraction, .classification: return true
        default: return false
        }
    }
}

/// One turn handed to a provider.
struct ModelMessage: Sendable, Equatable, Hashable {
    enum Role: String, Sendable, Equatable, Hashable {
        case user
        case assistant
        /// A tool result being fed back in `orchestratorManaged` flows.
        case tool
    }

    var role: Role
    var text: String
    /// Set for `.tool` messages: which tool produced this, and which call it answers.
    var toolName: String?
    var toolCallID: String?

    init(role: Role, text: String, toolName: String? = nil, toolCallID: String? = nil) {
        self.role = role
        self.text = text
        self.toolName = toolName
        self.toolCallID = toolCallID
    }

    static func user(_ text: String) -> ModelMessage { ModelMessage(role: .user, text: text) }
    static func assistant(_ text: String) -> ModelMessage { ModelMessage(role: .assistant, text: text) }
}

/// Knobs that every provider can honour, or ignore without breaking.
struct ModelGenerationOptions: Sendable, Equatable {
    /// `nil` leaves the provider's default alone.
    var temperature: Double?
    var maximumResponseTokens: Int?
    /// When `false`, tools are withheld from the request entirely.
    var allowsToolUse: Bool

    init(temperature: Double? = nil, maximumResponseTokens: Int? = nil, allowsToolUse: Bool = true) {
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.allowsToolUse = allowsToolUse
    }

    /// Conversation defaults: a little warmth, tools on.
    static let conversation = ModelGenerationOptions(temperature: 0.7)
    /// Structured work: as close to deterministic as the provider allows, no tools.
    static let structured = ModelGenerationOptions(temperature: 0.1, allowsToolUse: false)
}

/// A complete, provider-agnostic request.
///
/// `instructions` is already fully assembled by `PersonalizationEngine` — personality, retrieved
/// memory, relevant people and projects. Providers must not add to it, and in particular must never
/// reach for the profile or memory stores themselves. That single rule is what keeps §28's
/// "only what this request needs" promise auditable in one place.
struct ModelRequest: Sendable {
    /// The standing part: personality, the user's standing instructions, their name. Identical across
    /// turns of a conversation, so a provider holding a warm session can cache it.
    var instructions: String
    /// Assembled fresh for this turn — what retrieval found, and the clock. `nil` when there is none.
    ///
    /// Separate from `instructions` because the two have different lifetimes, and a provider that
    /// re-processes stable text every turn pays for it. Providers that cannot exploit the split use
    /// `combinedInstructions` and see no difference.
    var turnContext: String?
    var messages: [ModelMessage]
    var tools: [ToolDefinition]
    var options: ModelGenerationOptions
    var purpose: ModelRequestPurpose

    init(
        instructions: String,
        turnContext: String? = nil,
        messages: [ModelMessage],
        tools: [ToolDefinition] = [],
        options: ModelGenerationOptions = .conversation,
        purpose: ModelRequestPurpose = .conversation
    ) {
        self.instructions = instructions
        self.turnContext = turnContext
        self.messages = messages
        self.tools = tools
        self.options = options
        self.purpose = purpose
    }

    /// Everything the model is told. The audit answer to "what was sent" (§28).
    var combinedInstructions: String {
        guard let turnContext, !turnContext.isBlank else { return instructions }
        guard !instructions.isBlank else { return turnContext }
        return instructions + "\n\n" + turnContext
    }

    /// Tools actually offered, honouring `options.allowsToolUse`.
    var effectiveTools: [ToolDefinition] {
        options.allowsToolUse ? tools : []
    }
}

/// A model's request to run a tool, in `orchestratorManaged` flows.
struct ModelToolCall: Sendable, Equatable, Identifiable, Hashable {
    /// Provider-assigned call identifier, echoed back with the result.
    var id: String
    var toolName: String
    var arguments: [String: JSONValue]

    init(id: String = UUID().uuidString, toolName: String, arguments: [String: JSONValue] = [:]) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
    }
}

/// Token accounting, where the provider reports it (§67).
struct ModelUsage: Sendable, Equatable, Hashable {
    var promptTokens: Int?
    var responseTokens: Int?

    init(promptTokens: Int? = nil, responseTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.responseTokens = responseTokens
    }

    var totalTokens: Int? {
        guard promptTokens != nil || responseTokens != nil else { return nil }
        return (promptTokens ?? 0) + (responseTokens ?? 0)
    }
}

/// Why generation stopped.
enum ModelFinishReason: String, Sendable, Equatable {
    case complete
    /// The model wants tools run before it can finish.
    case toolCallsRequested
    case maxTokensReached
    case refused
    case cancelled
}

/// A provider's answer.
struct ModelResponse: Sendable, Equatable {
    var text: String
    var toolCalls: [ModelToolCall]
    var providerID: LanguageModelProviderID
    var usage: ModelUsage?
    var finishReason: ModelFinishReason
    /// Tool work the provider carried out itself, for the transcript's progress rows.
    var toolActivity: [ToolActivityNote]

    init(
        text: String,
        toolCalls: [ModelToolCall] = [],
        providerID: LanguageModelProviderID,
        usage: ModelUsage? = nil,
        finishReason: ModelFinishReason = .complete,
        toolActivity: [ToolActivityNote] = []
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.providerID = providerID
        self.usage = usage
        self.finishReason = finishReason
        self.toolActivity = toolActivity
    }

    var hasPendingToolCalls: Bool { !toolCalls.isEmpty }
}

/// Incremental output during streaming (§66).
///
/// `textDelta` carries only what is *new*. Apple's `ResponseStream` yields cumulative snapshots, so
/// `AppleFoundationModelProvider` diffs them before emitting — every provider presents deltas, and
/// the UI never has to know which kind it is talking to.
enum ModelStreamEvent: Sendable {
    case textDelta(String)
    /// The reply so far, replacing everything streamed before it.
    ///
    /// Emitted when a provider's cumulative output stops being an extension of what it already sent — a
    /// revision rather than a continuation. A delta cannot be taken back, so a provider that revises has
    /// to be able to say "discard that, here is the whole thing".
    case textReplaced(String)
    /// A tool call the orchestrator must run.
    case toolCallRequested(ModelToolCall)
    /// Progress on tool work the provider is doing itself. Actions only, never reasoning (§36).
    case toolActivity(ToolActivityNote)
    /// Terminal event, carrying the assembled response.
    case finished(ModelResponse)
}

/// A handle a `providerManaged` provider uses to run tools mid-generation.
///
/// `ToolExecutor` conforms to this. Permission checks, confirmation gating and audit logging all
/// happen behind it, so a provider cannot bypass the safety tiers in §34 even though it is the one
/// initiating the call.
protocol ToolInvoking: Sendable {
    func invokeTool(named name: String, arguments: [String: JSONValue]) async throws -> ToolInvocationOutcome
}

/// The result of a tool invocation, in the two shapes its two audiences need.
struct ToolInvocationOutcome: Sendable, Equatable {
    /// What the model is told. Factual and compact; this is what grounds the final answer.
    var modelFacingText: String
    /// What the user is shown in the transcript and Activity screen.
    var activity: ToolActivityNote

    init(modelFacingText: String, activity: ToolActivityNote) {
        self.modelFacingText = modelFacingText
        self.activity = activity
    }
}

/// The abstraction every language model sits behind (§7).
///
/// Nothing above this line knows whether it is talking to Apple's on-device model, a cloud API, or a
/// test double.
protocol LanguageModelProvider: Sendable {
    var id: LanguageModelProviderID { get }
    /// Shown in Settings → AI Model, and next to replies in the transcript.
    var displayName: String { get }
    /// `true` when no request data leaves the device. Drives the privacy indicators in §49.
    var isOnDevice: Bool { get }
    var toolExecutionStyle: ToolExecutionStyle { get }
    /// Rough context budget, when known, so context assembly can trim before overflowing.
    var contextWindowTokens: Int? { get }

    /// Cheap and safe to call repeatedly; implementations cache what is expensive.
    func availability() async -> ModelAvailability

    /// One-shot generation.
    /// - Parameter toolInvoker: required by `providerManaged` providers whenever the request offers
    ///   tools; ignored by `orchestratorManaged` ones.
    func send(
        _ request: ModelRequest,
        toolInvoker: (any ToolInvoking)?
    ) async throws -> ModelResponse

    /// Streaming generation. Providers that cannot stream inherit the default below.
    func stream(
        _ request: ModelRequest,
        toolInvoker: (any ToolInvoking)?
    ) -> AsyncThrowingStream<ModelStreamEvent, any Error>

    /// Optional hint that a request is likely soon, so the provider can load assets ahead of time.
    ///
    /// Best-effort by contract: it must never throw, never block anything the user is waiting on, and
    /// never be required for correctness. A provider that cannot prewarm inherits a no-op.
    func prewarm(instructions: String) async
}

extension LanguageModelProvider {
    /// Default streaming: run the one-shot path and emit the whole answer as a single delta.
    ///
    /// Correct but not incremental, which is exactly the right trade for a provider with no native
    /// streaming — the UI code path stays identical either way.
    func stream(
        _ request: ModelRequest,
        toolInvoker: (any ToolInvoking)?
    ) -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await send(request, toolInvoker: toolInvoker)
                    if !response.text.isEmpty {
                        continuation.yield(.textDelta(response.text))
                    }
                    for note in response.toolActivity {
                        continuation.yield(.toolActivity(note))
                    }
                    for call in response.toolCalls {
                        continuation.yield(.toolCallRequested(call))
                    }
                    continuation.yield(.finished(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var contextWindowTokens: Int? { nil }

    /// Nothing to warm up. Correct for every provider whose latency is network round-trip rather than
    /// local asset loading.
    func prewarm(instructions: String) async {}

    func send(_ request: ModelRequest) async throws -> ModelResponse {
        try await send(request, toolInvoker: nil)
    }
}
