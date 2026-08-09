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
/// ### Two tool paths, one gate
/// Apple's model runs tools itself, inside `LanguageModelSession`, so its answers arrive already
/// grounded and `generateAnsweringToolCalls` returns after a single pass. Cloud providers hand a call
/// back and wait, so the same function loops: run the calls, append their results as `.tool` messages,
/// generate again, up to `AuraDefaults.maxToolIterations`. Both paths go through the same
/// `ToolExecuting`, which is what keeps §34's confirmation and permission gates from depending on which
/// provider happened to answer.
actor AssistantOrchestrator: AssistantOrchestrating {

    private let conversationStore: any ConversationStoring
    private let personalizationEngine: any PersonalizationEngineProtocol
    private let router: any ModelRouting
    private let assistantProfileStore: any AssistantProfileStoring
    private let networkMonitor: any NetworkStatusProviding

    /// Phase 7. Optional so a test or preview can run turns with no memory system at all, and so the
    /// pipeline degrades to Phase 2 behaviour rather than failing if either is absent.
    private let memoryExtractor: (any MemoryExtracting)?
    private let memoryConsolidator: (any MemoryConsolidating)?
    private let userProfileStore: (any UserProfileStoring)?

    /// Phase 10. Optional for the same reason: absent, no tools are offered and a turn is pure
    /// conversation, which is exactly the behaviour every phase before this one had.
    private let toolExecutor: (any ToolExecuting)?

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
        memoryExtractor: (any MemoryExtracting)? = nil,
        memoryConsolidator: (any MemoryConsolidating)? = nil,
        userProfileStore: (any UserProfileStoring)? = nil,
        toolExecutor: (any ToolExecuting)? = nil,
        conversationStaleInterval: TimeInterval = 60 * 60 * 6
    ) {
        self.conversationStore = conversationStore
        self.personalizationEngine = personalizationEngine
        self.router = router
        self.assistantProfileStore = assistantProfileStore
        self.networkMonitor = networkMonitor
        self.memoryExtractor = memoryExtractor
        self.memoryConsolidator = memoryConsolidator
        self.userProfileStore = userProfileStore
        self.toolExecutor = toolExecutor
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
            //
            // Which tools could run is asked *before* routing, because whether the turn needs tool
            // support is part of choosing a provider. Empty when there is no executor, which is the
            // pre-Phase-10 behaviour.
            let toolDefinitions = await toolExecutor?.availableToolDefinitions() ?? []

            let isOnline = await networkMonitor.isOnline
            let (provider, route) = try await router.route(
                purpose: .conversation,
                context: RoutingContext(
                    aiMode: assistantProfile.aiMode,
                    isOnline: isOnline,
                    requiresToolSupport: !toolDefinitions.isEmpty
                )
            )
            emit(.routed(route))

            // 5. Generation.
            let modelRequest = ModelRequest(
                // Split so a provider holding a warm session re-processes only what changed. The two
                // together are exactly what `modelInstructions` used to be — see `combinedInstructions`.
                instructions: context.stableInstructions,
                turnContext: context.turnContext(now: request.now),
                // What the thread said before it aged out of `history`. Without it, a long conversation
                // silently forgets its own beginning while appearing to remember everything.
                conversationSummary: try await conversationStore
                    .conversation(id: conversationID)?.summary,
                messages: Self.modelMessages(history: history, latestUserText: text),
                tools: toolDefinitions,
                options: .conversation,
                purpose: .conversation
            )

            try Task.checkCancellation()

            // Streamed rather than awaited whole, so the reply appears as it is generated. A provider
            // with no native streaming inherits a default that emits one delta, so this path is correct
            // for every provider — the orchestrator does not branch on whether streaming is real.
            let modelResponse = try await generateAnsweringToolCalls(
                modelRequest,
                using: provider,
                conversationID: conversationID,
                now: request.now,
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

            // After `.finished`, deliberately: the user has their answer and the UI is idle, so the only
            // cost of doing this here rather than in a detached task is that the event stream stays open a
            // moment longer. In exchange it is sequenced and testable, instead of a race.
            await refreshRollingSummary(conversationID: conversationID)

            await extractMemories(
                conversationID: conversationID,
                userText: text,
                assistantText: answer,
                assistantMessageID: assistantMessageID,
                request: request,
                emit: emit
            )
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
        var requestedCalls: [ModelToolCall] = []

        for try await event in provider.stream(modelRequest, toolInvoker: toolExecutor) {
            try Task.checkCancellation()

            switch event {
            case .textDelta(let delta):
                emit(.textDelta(delta))
            case .textReplaced(let whole):
                emit(.textReplaced(whole))
            case .toolActivity(let note):
                emit(.toolFinished(note))
            case .toolCallRequested(let call):
                // Collected rather than run here: a stream is not the place to await a confirmation
                // prompt, and the calls are answered together once the provider has finished asking.
                requestedCalls.append(call)
            case .finished(let response):
                finished = response
            }
        }

        guard var finished else {
            throw AuraError.emptyModelResponse
        }

        // Streamed `.toolCallRequested` events and `ModelResponse.toolCalls` are two renderings of the
        // same thing, and a provider may use either. Union rather than trusting one, deduplicated by id
        // so a provider that reports both does not get its tools run twice.
        if !requestedCalls.isEmpty {
            var byID: [String: ModelToolCall] = [:]
            for call in finished.toolCalls + requestedCalls { byID[call.id] = call }
            finished.toolCalls = byID.values.sorted { $0.id < $1.id }
        }
        return finished
    }

    /// Runs generation to a final answer, executing any tool calls the provider asks for in between.
    ///
    /// Only `orchestratorManaged` providers reach the loop body. Apple's model runs its own tools inside
    /// `LanguageModelSession`, so its answers arrive already grounded and this returns after one pass —
    /// the loop exists for cloud providers, which hand back a call and wait.
    ///
    /// ### Why the iteration cap is a hard error
    /// A model can ask for a tool, read the result, and ask again indefinitely. §36 caps it at
    /// `maxToolIterations`, and hitting the cap is reported as a failure rather than answered with
    /// whatever text the last round produced: a reply assembled halfway through an unfinished plan would
    /// describe actions that were still pending as though they were done.
    private func generateAnsweringToolCalls(
        _ modelRequest: ModelRequest,
        using provider: any LanguageModelProvider,
        conversationID: UUID,
        now: Date,
        emit: @Sendable (AssistantTurnEvent) -> Void
    ) async throws -> ModelResponse {
        var request = modelRequest
        // Accumulated across rounds, because each round's response only carries its own notes and the
        // transcript needs the whole turn's worth.
        var activity: [ToolActivityNote] = []

        for iteration in 0..<AuraDefaults.maxToolIterations {
            let response = try await generate(request, using: provider, emit: emit)
            activity += response.toolActivity

            guard response.hasPendingToolCalls else {
                var final = response
                final.toolActivity = activity
                return final
            }

            guard let toolExecutor else {
                // A provider asked for a tool that AURA has no way to run. Reported rather than ignored:
                // ignoring it would leave the model's request unanswered and its next reply free to claim
                // the action happened (§78).
                throw AuraError.toolFailed(
                    toolName: response.toolCalls.first?.toolName ?? "unknown",
                    reason: "tools aren't available in this build"
                )
            }

            for call in response.toolCalls {
                try Task.checkCancellation()
                emit(.toolStarted(.started(toolName: call.toolName)))

                let outcome: ToolInvocationOutcome
                do {
                    // `execute` rather than `invokeTool`, because the orchestrator knows things the
                    // provider-facing handle cannot pass on: which conversation this is, the clock the
                    // turn is using, and how many rounds deep the loop is. A tool reading `Date()` when
                    // the turn was given an explicit `now` would be untestable.
                    let record = try await toolExecutor.execute(
                        toolNamed: call.toolName,
                        arguments: call.arguments,
                        context: ToolExecutionContext(
                            conversationID: conversationID,
                            // The model reached for this, not the user. A reversible tool therefore still
                            // gets confirmed — see `ToolRiskLevel.requiresConfirmation`.
                            userExplicitlyRequested: false,
                            now: now,
                            iterationIndex: iteration
                        )
                    )
                    outcome = ToolInvocationOutcome(
                        modelFacingText: record.result.modelFacingText,
                        activity: record.activityNote
                    )
                } catch is CancellationError {
                    throw AuraError.cancelled
                } catch {
                    // Fed back as a tool result rather than thrown, so the model can tell the user what
                    // went wrong instead of the turn collapsing. Identical wording to the Apple path.
                    outcome = ToolInvocationOutcome.failure(toolName: call.toolName, error: error)
                }

                activity.append(outcome.activity)
                emit(.toolFinished(outcome.activity))

                request.messages.append(
                    ModelMessage(
                        role: .tool,
                        text: outcome.modelFacingText,
                        toolName: call.toolName,
                        toolCallID: call.id
                    )
                )
            }
        }

        AuraLog.orchestrator.error(
            "Tool loop hit \(AuraDefaults.maxToolIterations, privacy: .public) iterations in conversation \(conversationID.uuidString, privacy: .private)."
        )
        throw AuraError.toolIterationLimitReached
    }

    // MARK: - Memory extraction

    /// Mines the finished turn for anything worth remembering (§20, §21).
    ///
    /// Runs after `.finished` for the same reason the summary does: the user has their answer, so the only
    /// cost of doing it here rather than in a detached task is that the event stream stays open a moment
    /// longer — and in exchange it is sequenced and testable rather than a race.
    ///
    /// Every failure is swallowed. Extraction is an enhancement to a turn that already succeeded, and failing
    /// to learn something must never surface as an error about the answer the user just received.
    private func extractMemories(
        conversationID: UUID,
        userText: String,
        assistantText: String,
        assistantMessageID: UUID,
        request: AssistantRequest,
        emit: @Sendable (AssistantTurnEvent) -> Void
    ) async {
        guard FeatureFlags.memory.isLive,
              let memoryExtractor,
              let memoryConsolidator else { return }

        do {
            let profile = try await assistantProfileStore.currentProfile()
            // The user's switch, checked here rather than deeper down: with automatic memory off, nothing is
            // even examined, so there is no candidate sitting anywhere waiting to be swept up later (§48).
            guard profile.memory.automaticMemoryEnabled else { return }

            let people = try await userProfileStore?.currentProfile().people ?? []
            let history = try await conversationStore.workingMemory(
                conversationID: conversationID,
                limit: AuraDefaults.workingMemoryTurnLimit
            )

            let result = try await memoryExtractor.extract(
                from: ExtractionRequest(
                    userMessage: userText,
                    assistantMessage: assistantText,
                    conversationID: conversationID,
                    userMessageID: assistantMessageID,
                    recentTurns: history.suffix(4).map(\.content),
                    knownPeople: people,
                    now: request.now
                )
            )

            for candidate in result.retainableCandidates {
                // "Ask before saving" means exactly that: the candidate is surfaced for review and nothing is
                // written. Consolidating first and asking afterwards would make the setting cosmetic.
                if profile.memory.asksBeforeSaving {
                    emit(.memoryCandidatePending(candidate))
                    continue
                }
                let outcome = try await memoryConsolidator.consolidate(candidate)
                if let saved = outcome.savedMemory {
                    emit(.memorySaved(saved))
                }
            }
        } catch {
            AuraLog.memory.debug(
                "Extraction skipped for this turn: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Rolling summary

    /// Condenses the turns that have aged out of working memory, so a long thread stays coherent (§18).
    ///
    /// ### Why it is incremental
    /// The input is the previous summary plus the most recently aged-out turns, not the whole history. A
    /// thread hundreds of turns long would otherwise overflow the context window of the very model being
    /// asked to summarise it.
    ///
    /// ### The bound, stated honestly
    /// Coverage is not tracked in the store — there is no field for it, and adding one would mean a schema
    /// version for a single integer. Instead this relies on being called after **every** turn, which keeps
    /// the number of newly-aged-out turns at roughly two, well inside the window fed back in.
    ///
    /// The window is `workingMemoryTurnLimit`, so roughly six consecutive failed refreshes could pass before
    /// a turn ages out without ever reaching a summary. That is the real limitation: it is bounded, it
    /// self-heals on the next success within the window, and it is written down rather than presented as
    /// exact.
    ///
    /// Every failure is swallowed. A summary is an enhancement to a turn that has already succeeded, and
    /// failing to write one must never surface as an error about the answer the user just received.
    private func refreshRollingSummary(conversationID: UUID) async {
        do {
            // Failures are excluded for the same reason working memory excludes them: an error message is a
            // record for the user, not something to summarise as if the assistant had said it (§78).
            let visible = try await conversationStore
                .messages(inConversationID: conversationID)
                .filter { !$0.isFailure && ($0.role == .user || $0.role == .assistant) }

            let limit = AuraDefaults.workingMemoryTurnLimit
            let agedOutCount = max(0, visible.count - limit)
            guard agedOutCount > 0 else { return }

            let newlyAgedOut = Array(visible.prefix(agedOutCount).suffix(limit))
            guard !newlyAgedOut.isEmpty else { return }

            let existing = try await conversationStore.conversation(id: conversationID)?.summary
            let assistantProfile = try await assistantProfileStore.currentProfile()
            let isOnline = await networkMonitor.isOnline

            let (provider, _) = try await router.route(
                purpose: .summarization,
                context: RoutingContext(
                    aiMode: assistantProfile.aiMode,
                    isOnline: isOnline,
                    requiresToolSupport: false
                )
            )

            let summaryRequest = ModelRequest(
                instructions: Self.summaryInstructions,
                messages: [.user(Self.summaryPrompt(previous: existing, newlyAgedOut: newlyAgedOut))],
                options: .structured,
                purpose: .summarization
            )

            let response = try await provider.send(summaryRequest, toolInvoker: nil)
            let summary = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return }

            try await conversationStore.updateSummary(summary, conversationID: conversationID)
        } catch {
            AuraLog.orchestrator.debug(
                "Rolling summary not refreshed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Instructions for the summarisation pass.
    ///
    /// Written to constrain invention as hard as the prompt can: a summary that adds a detail nobody said
    /// becomes indistinguishable from something the user actually told AURA, and would then be recalled as
    /// fact for the rest of the conversation. That is the §78 failure with the longest reach.
    static let summaryInstructions = """
        You are condensing part of a conversation so it can be remembered after the full text is gone.

        Write a compact account of what was discussed, decided, and asked for. Keep names, numbers, dates \
        and commitments exactly as they appeared. Prefer plain sentences over bullet points.

        Include only what is actually present in the material you are given. Do not infer, do not \
        speculate, and do not add detail that is not there. If the material is thin, write a short summary \
        rather than padding it.

        Reply with the summary and nothing else — no preamble, no heading, no commentary.
        """

    /// Builds the summarisation prompt from the previous summary and the turns that have just aged out.
    ///
    /// `static` and pure so the exact text is assertable. A summary prompt that silently changes shape
    /// changes what the assistant remembers about every long conversation.
    static func summaryPrompt(previous: String?, newlyAgedOut: [MessageSnapshot]) -> String {
        var sections: [String] = []

        if let previous, !previous.isBlank {
            sections.append("""
                The summary so far, which already covers everything before the turns below:
                \(previous)
                """)
        }

        var lines = ["Turns to fold in:"]
        for message in newlyAgedOut {
            switch message.role {
            case .assistant:
                lines.append("Assistant: \(message.content)")
            default:
                lines.append("User: \(message.content)")
            }
        }
        sections.append(lines.joined(separator: "\n"))

        sections.append(
            previous?.isBlank == false
                ? "Rewrite the summary so it covers the earlier summary and these turns together."
                : "Summarise these turns."
        )

        return sections.joined(separator: "\n\n")
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
