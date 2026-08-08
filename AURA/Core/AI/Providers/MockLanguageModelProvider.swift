import Foundation

/// A scripted `LanguageModelProvider` for tests and SwiftUI previews.
///
/// Every orchestration behaviour AURA needs to guarantee — tool routing, confirmation gating,
/// memory extraction, failure handling, streaming — has to be verifiable without an eligible device,
/// without Apple Intelligence enabled, and without a network. This is the double that makes that
/// possible, so it is production code in `Core`, not test scaffolding.
final class MockLanguageModelProvider: LanguageModelProvider, @unchecked Sendable {

    /// What the mock does when asked to respond.
    enum Behavior: Sendable {
        /// Reply with fixed text.
        case respond(String)
        /// Reply with each element in turn, cycling once exhausted.
        case respondInSequence([String])
        /// Ask for a tool, then reply with the text once the result comes back.
        case requestTool(name: String, arguments: [String: JSONValue], thenRespond: String)
        /// Fail.
        case fail(AuraError)
        /// Echo the last user message, prefixed. Useful for asserting what context was assembled.
        case echo(prefix: String)
        /// Stream exactly these deltas, then finish with different text.
        ///
        /// Exists to make one invariant testable: the persisted answer comes from the provider's
        /// `.finished` response, not from concatenating the deltas. Every other behaviour derives its
        /// deltas *from* the final text by splitting it, so the two always agree and a test built on them
        /// proves nothing. Here they disagree by construction.
        case streamDivergently(deltas: [String], thenFinish: String)
    }

    let id: LanguageModelProviderID
    let displayName: String
    let isOnDevice: Bool
    let toolExecutionStyle: ToolExecutionStyle
    let contextWindowTokens: Int?

    private let lock = NSLock()
    private var behavior: Behavior
    private var sequenceIndex = 0
    private var reportedAvailability: ModelAvailability
    /// Artificial latency, for exercising cancellation and progress UI.
    private var responseDelay: Duration

    /// Every request the mock received, in order. Assert against this instead of guessing what the
    /// orchestrator sent.
    private var recordedRequests: [ModelRequest] = []

    init(
        id: LanguageModelProviderID = .mock,
        displayName: String = "Mock Model",
        isOnDevice: Bool = true,
        toolExecutionStyle: ToolExecutionStyle = .orchestratorManaged,
        contextWindowTokens: Int? = 8_192,
        availability: ModelAvailability = .available,
        behavior: Behavior = .respond("Understood."),
        responseDelay: Duration = .zero
    ) {
        self.id = id
        self.displayName = displayName
        self.isOnDevice = isOnDevice
        self.toolExecutionStyle = toolExecutionStyle
        self.contextWindowTokens = contextWindowTokens
        self.reportedAvailability = availability
        self.behavior = behavior
        self.responseDelay = responseDelay
    }

    // MARK: Test control

    func setBehavior(_ behavior: Behavior) {
        lock.withLock {
            self.behavior = behavior
            self.sequenceIndex = 0
        }
    }

    func setAvailability(_ availability: ModelAvailability) {
        lock.withLock { reportedAvailability = availability }
    }

    func setResponseDelay(_ delay: Duration) {
        lock.withLock { responseDelay = delay }
    }

    var requests: [ModelRequest] {
        lock.withLock { recordedRequests }
    }

    var lastRequest: ModelRequest? {
        lock.withLock { recordedRequests.last }
    }

    var requestCount: Int {
        lock.withLock { recordedRequests.count }
    }

    func reset() {
        lock.withLock {
            recordedRequests.removeAll()
            sequenceIndex = 0
        }
    }

    // MARK: LanguageModelProvider

    func availability() async -> ModelAvailability {
        lock.withLock { reportedAvailability }
    }

    func send(
        _ request: ModelRequest,
        toolInvoker: (any ToolInvoking)?
    ) async throws -> ModelResponse {
        let (currentBehavior, delay) = lock.withLock { () -> (Behavior, Duration) in
            recordedRequests.append(request)
            return (behavior, responseDelay)
        }

        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        try Task.checkCancellation()

        switch currentBehavior {
        case .respond(let text):
            return makeResponse(text: text)

        case .respondInSequence(let texts):
            guard !texts.isEmpty else { return makeResponse(text: "") }
            let text = lock.withLock { () -> String in
                let value = texts[sequenceIndex % texts.count]
                sequenceIndex += 1
                return value
            }
            return makeResponse(text: text)

        case .fail(let error):
            throw error

        case .echo(let prefix):
            let lastUserText = request.messages.last { $0.role == .user }?.text ?? ""
            return makeResponse(text: prefix + lastUserText)

        case .streamDivergently(_, let thenFinish):
            // Non-streaming callers see only the final text, which is the whole point of it being final.
            return makeResponse(text: thenFinish)

        case .requestTool(let name, let arguments, let thenRespond):
            switch toolExecutionStyle {
            case .providerManaged:
                // Mirror Apple's behaviour: run the tool through the invoker, then answer.
                guard let toolInvoker else {
                    throw AuraError.toolNotFound(name: name)
                }
                let outcome = try await toolInvoker.invokeTool(named: name, arguments: arguments)
                return ModelResponse(
                    text: thenRespond,
                    providerID: id,
                    usage: ModelUsage(promptTokens: 100, responseTokens: 20),
                    finishReason: .complete,
                    toolActivity: [outcome.activity]
                )

            case .orchestratorManaged:
                // On the first call ask for the tool; once a tool result is in the transcript,
                // answer — otherwise the agent loop would never terminate.
                let alreadyRan = request.messages.contains { $0.role == .tool }
                if alreadyRan {
                    return makeResponse(text: thenRespond)
                }
                return ModelResponse(
                    text: "",
                    toolCalls: [ModelToolCall(toolName: name, arguments: arguments)],
                    providerID: id,
                    finishReason: .toolCallsRequested
                )
            }
        }
    }

    func stream(
        _ request: ModelRequest,
        toolInvoker: (any ToolInvoking)?
    ) -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await send(request, toolInvoker: toolInvoker)

                    if case .streamDivergently(let deltas, _) = lock.withLock({ behavior }) {
                        for delta in deltas {
                            try Task.checkCancellation()
                            continuation.yield(.textDelta(delta))
                        }
                        continuation.yield(.finished(response))
                        continuation.finish()
                        return
                    }

                    // Emit word by word so streaming UI and cancellation are genuinely exercised
                    // rather than trivially satisfied by one large chunk.
                    for word in response.text.split(separator: " ", omittingEmptySubsequences: false) {
                        try Task.checkCancellation()
                        continuation.yield(.textDelta(String(word) + " "))
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

    private func makeResponse(text: String) -> ModelResponse {
        ModelResponse(
            text: text,
            providerID: id,
            usage: ModelUsage(
                promptTokens: 100,
                responseTokens: max(1, text.split(separator: " ").count)
            ),
            finishReason: .complete
        )
    }
}
