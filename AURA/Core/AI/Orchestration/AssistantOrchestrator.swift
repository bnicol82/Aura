import Foundation

/// The conductor (§35).
///
/// Owns one pipeline and nothing else: normalise, resolve the conversation, build context, route,
/// generate, persist, report. Views never assemble prompts, call providers, or save messages — that
/// single rule is what keeps §28's context discipline and §78's honesty rules in one auditable path.
///
/// ### Failures are turns too
/// A turn that fails still writes a message, flagged `isFailure`. Three reasons: the user sees what
/// happened instead of a request that vanished; `workingMemory` filters failures out so the model never
/// treats an error as its own prior answer; and nothing anywhere can mistake a failure for a reply.
///
/// ### What Phase 2 does not do
/// No tools, no memory extraction, no real token streaming. Those are Phases 10, 7 and 3, and the
/// events for them already exist in `AssistantTurnEvent` — the pipeline gains steps rather than
/// changing shape.
actor AssistantOrchestrator: AssistantOrchestrating {

    private let conversationStore: any ConversationStoring
    private let personalizationEngine: any PersonalizationEngineProtocol
    private let router: any ModelRouting
    private let assistantProfileStore: any AssistantProfileStoring
    private let networkMonitor: any NetworkStatusProviding

    /// How long a conversation stays resumable before a new request starts a fresh one.
    private let conversationStaleInterval: TimeInterval

    /// The in-flight turn, so `cancelCurrentTurn()` has something to cancel.
    private var activeTurn: Task<Void, Never>?

    init(
        conversationStore: any ConversationStoring,
        personalizationEngine: any PersonalizationEngineProtocol,
        router: any ModelRouting,
        assistantProfileStore: any AssistantProfileStoring,
        networkMonitor: any NetworkStatusProviding,
        conversationStaleInterval: TimeInterval = 60 * 60 * 6
    ) {
        self.conversationStore = conversationStore
        self.personalizationEngine = personalizationEngine
        self.router = router
        self.assistantProfileStore = assistantProfileStore
        self.networkMonitor = networkMonitor
        self.conversationStaleInterval = conversationStaleInterval
    }

    // MARK: - Public entry points

    func send(_ request: AssistantRequest) async -> AssistantResponse {
        var finished: AssistantResponse?
        var failure: AuraError?
        var startedIdentifiers: (conversationID: UUID, messageID: UUID)?

        for await event in stream(request) {
            switch event {
            case .started(let conversationID, let messageID):
                startedIdentifiers = (conversationID, messageID)
            case .finished(let response):
                finished = response
            case .failed(let error):
                failure = error
            default:
                break
            }
        }

        if let finished { return finished }

        // The stream always terminates in `.finished` or `.failed`, so this only synthesises the
        // response envelope around a failure that was already persisted.
        return Self.failureResponse(
            for: request,
            error: failure ?? .modelFailed(reason: "The turn ended without an answer."),
            conversationID: startedIdentifiers?.conversationID ?? UUID(),
            messageID: startedIdentifiers?.messageID ?? UUID()
        )
    }

    /// `nonisolated` because the protocol requirement is synchronous, and an actor-isolated method
    /// cannot satisfy one. Nothing here touches actor state directly — it starts a task and hands the
    /// work back to the actor.
    nonisolated func stream(_ request: AssistantRequest) -> AsyncStream<AssistantTurnEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.perform(request) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
            Task { await self.setActiveTurn(task) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelCurrentTurn() async {
        activeTurn?.cancel()
        activeTurn = nil
    }

    /// Warms the provider the next turn would most likely use.
    ///
    /// Deliberately cheap: it routes and asks the provider to prewarm with the *stable* instructions only.
    /// No retrieval runs, because retrieval needs a message that has not been typed yet — and doing it here
    /// would both waste work and assemble personal context for a request that may never happen.
    ///
    /// Every failure is swallowed. Prewarming is an optimisation, and a warm-up that reported errors to the
    /// user would be worse than no warm-up at all.
    func prewarm() async {
        do {
            let assistantProfile = try await assistantProfileStore.currentProfile()
            let isOnline = await networkMonitor.isOnline
            let (provider, _) = try await router.route(
                purpose: .conversation,
                context: RoutingContext(
                    aiMode: assistantProfile.aiMode,
                    isOnline: isOnline,
                    requiresToolSupport: false
                )
            )

            let context = try await personalizationEngine.buildContext(
                for: PersonalizationRequest(
                    userMessage: "",
                    conversationID: nil,
                    recentTurns: [],
                    now: Date(),
                    // Nothing retrieved: the stable half is all that is needed, and it is all that is
                    // byte-identical to what the next real turn will send.
                    budget: .none
                )
            )

            await provider.prewarm(instructions: context.stableInstructions)
        } catch {
            AuraLog.orchestrator.debug("Prewarm skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - The pipeline

    private func perform(
        _ request: AssistantRequest,
        emit: @Sendable (AssistantTurnEvent) -> Void
    ) async {
        let text = request.text.normalizedWhitespace
        guard !text.isEmpty else {
            emit(.failed(.cancelled))
            return
        }

        // 1. Resolve the conversation before anything can fail, so a failure still has somewhere to be
        //    recorded.
        let conversationID: UUID
        do {
            conversationID = try await resolveConversation(for: request)
        } catch {
            emit(.failed(error.asAuraError))
            return
        }

        // 2. Persist the user's message immediately. If generation fails, what they said is still saved.
        do {
            _ = try await conversationStore.appendMessage(
                MessageDraft.user(text, at: request.now),
                toConversationID: conversationID
            )
        } catch {
            emit(.failed(error.asAuraError))
            return
        }

        let assistantMessageID = UUID()
        emit(.started(conversationID: conversationID, messageID: assistantMessageID))

        do {
            try Task.checkCancellation()

            // 3. Context. The only thing that decides what the model learns about the user.
            let assistantProfile = try await assistantProfileStore.currentProfile()
            let history = try await conversationStore.workingMemory(
                conversationID: conversationID,
                limit: AuraDefaults.workingMemoryTurnLimit
            )

            let context = try await personalizationEngine.buildContext(
                for: PersonalizationRequest(
                    userMessage: text,
                    conversationID: conversationID,
                    recentTurns: history.suffix(4).map(\.content),
                    now: request.now,
                    budget: assistantProfile.memory.usesMemoryInResponses ? .default : .none
                )
            )

            emit(.contextAssembled(
                personalItemCount: context.personalItemCount,
                sensitivity: context.sensitivityMode
            ))

            try Task.checkCancellation()

            // 4. Routing.
            let isOnline = await networkMonitor.isOnline
            let (provider, route) = try await router.route(
                purpose: .conversation,
                context: RoutingContext(
                    aiMode: assistantProfile.aiMode,
                    isOnline: isOnline,
                    requiresToolSupport: false
                )
            )
            emit(.routed(route))

            // 5. Generation.
            let modelRequest = ModelRequest(
                // Split so a provider holding a warm session re-processes only what changed. The two
                // together are exactly what `modelInstructions` used to be — see `combinedInstructions`.
                instructions: context.stableInstructions,
                turnContext: context.turnContext(now: request.now),
                messages: Self.modelMessages(history: history, latestUserText: text),
                tools: [],
                options: .conversation,
                purpose: .conversation
            )

            try Task.checkCancellation()

            // Streamed rather than awaited whole, so the reply appears as it is generated. A provider
            // with no native streaming inherits a default that emits one delta, so this path is correct
            // for every provider — the orchestrator does not branch on whether streaming is real.
            let modelResponse = try await generate(
                modelRequest,
                using: provider,
                emit: emit
            )

            let answer = modelResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                throw AuraError.emptyModelResponse
            }

            try Task.checkCancellation()

            // 6. Persist the answer.
            let saved = try await conversationStore.appendMessage(
                MessageDraft(
                    id: assistantMessageID,
                    role: .assistant,
                    content: answer,
                    toolActivity: modelResponse.toolActivity,
                    providerIdentifier: route.providerID.rawValue,
                    isFailure: false,
                    usage: modelResponse.usage,
                    createdAt: Date()
                ),
                toConversationID: conversationID
            )

            let response = AssistantResponse(
                requestID: request.id,
                conversationID: conversationID,
                messageID: saved.id,
                text: answer,
                toolActivity: modelResponse.toolActivity,
                route: route,
                personalContextItemCount: context.personalItemCount,
                savedMemories: [],
                pendingMemoryCandidates: [],
                isFailure: false,
                shouldSpeak: request.source.prefersSpokenResponse
                    && assistantProfile.voice.speaksResponsesAutomatically
            )

            emit(.finished(response))
        } catch {
            let auraError = error.asAuraError
            await recordFailure(
                auraError,
                conversationID: conversationID,
                assistantMessageID: assistantMessageID
            )
            emit(.failed(auraError))
        }
    }

    // MARK: - Steps

    /// Runs one generation, forwarding incremental text to the caller and returning the finished response.
    ///
    /// The provider's terminal `.finished` event is the authority on the final text, not the accumulated
    /// deltas. Those two agreeing is the normal case, but if they ever disagree the persisted message must
    /// match what the provider actually concluded rather than what the UI happened to assemble. A stream
    /// that ends without `.finished` is a provider bug, and it is reported rather than papered over with
    /// whatever text arrived.
    private func generate(
        _ modelRequest: ModelRequest,
        using provider: any LanguageModelProvider,
        emit: @Sendable (AssistantTurnEvent) -> Void
    ) async throws -> ModelResponse {
        var finished: ModelResponse?

        for try await event in provider.stream(modelRequest, toolInvoker: nil) {
            try Task.checkCancellation()

            switch event {
            case .textDelta(let delta):
                emit(.textDelta(delta))
            case .textReplaced(let whole):
                emit(.textReplaced(whole))
            case .toolActivity(let note):
                emit(.toolFinished(note))
            case .toolCallRequested:
                // Only `orchestratorManaged` providers request calls, and no tools are offered yet, so
                // reaching here means a provider changed behaviour. Phase 10 gives this a real branch.
                AuraLog.orchestrator.notice("A provider requested a tool call before tool support exists; ignoring it.")
            case .finished(let response):
                finished = response
            }
        }

        guard let finished else {
            throw AuraError.emptyModelResponse
        }
        return finished
    }

    private func resolveConversation(for request: AssistantRequest) async throws -> UUID {
        if let existing = request.conversationID,
           try await conversationStore.conversation(id: existing) != nil {
            return existing
        }

        if let resumable = try await conversationStore.mostRecentActiveConversation(
            staleAfter: conversationStaleInterval,
            now: request.now
        ) {
            return resumable.id
        }

        return try await conversationStore.createConversation(title: nil, at: request.now).id
    }

    /// Writes the failure into the transcript.
    ///
    /// A user-cancelled turn leaves no row: they know they cancelled, and a "cancelled" bubble in the
    /// transcript is clutter rather than information.
    private func recordFailure(
        _ error: AuraError,
        conversationID: UUID,
        assistantMessageID: UUID
    ) async {
        guard !error.isSilent else { return }

        var message = error.errorDescription ?? "Something went wrong."
        if let recovery = error.recoverySuggestion {
            message += " \(recovery)"
        }

        do {
            _ = try await conversationStore.appendMessage(
                MessageDraft(
                    id: assistantMessageID,
                    role: .assistant,
                    content: message,
                    isFailure: true,
                    createdAt: Date()
                ),
                toConversationID: conversationID
            )
        } catch {
            // The store is what just failed, so there is nowhere left to write this. Log the shape of it
            // and let the emitted `.failed` event carry the news to the UI.
            AuraLog.orchestrator.error("Could not record a turn failure in the transcript.")
        }
    }

    private func setActiveTurn(_ task: Task<Void, Never>) {
        activeTurn?.cancel()
        activeTurn = task
    }

    // MARK: - Helpers

    /// Turns stored history plus the new message into provider-shaped messages.
    ///
    /// The latest user turn is already in `history` — it was persisted in step 2 — so it is dropped and
    /// re-appended, which guarantees it is last regardless of how the store ordered equal timestamps.
    static func modelMessages(
        history: [MessageSnapshot],
        latestUserText: String
    ) -> [ModelMessage] {
        var messages: [ModelMessage] = []

        for snapshot in history.dropLast(history.last?.role == .user ? 1 : 0) {
            switch snapshot.role {
            case .user:
                messages.append(.user(snapshot.content))
            case .assistant:
                messages.append(.assistant(snapshot.content))
            case .tool, .system:
                continue
            }
        }

        messages.append(.user(latestUserText))
        return messages
    }

    static func failureResponse(
        for request: AssistantRequest,
        error: AuraError,
        conversationID: UUID,
        messageID: UUID
    ) -> AssistantResponse {
        AssistantResponse(
            requestID: request.id,
            conversationID: conversationID,
            messageID: messageID,
            text: error.errorDescription ?? "Something went wrong.",
            route: ModelRoute(
                providerID: LanguageModelProviderID("none"),
                providerDisplayName: "None",
                isOnDevice: true,
                reason: .lastResort
            ),
            isFailure: true,
            shouldSpeak: false
        )
    }
}

extension Error {
    /// Normalises any thrown error into AURA's own vocabulary.
    ///
    /// Cancellation is mapped explicitly, because `CancellationError` reaching the UI as
    /// "The operation couldn't be completed" would present the user's own tap as a fault.
    var asAuraError: AuraError {
        if let auraError = self as? AuraError { return auraError }
        if self is CancellationError { return .cancelled }
        return .modelFailed(reason: localizedDescription)
    }
}
