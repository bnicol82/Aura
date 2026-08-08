import FoundationModels
import Foundation

/// `LanguageModelProvider` over Apple's on-device Foundation Model.
///
/// AURA's preferred provider: nothing sent to it leaves the device, it costs nothing to run, and it
/// works with no network. Every other provider is a fallback from this one.
///
/// ### Why a fresh session per request, still
/// `LanguageModelSession` accumulates its own transcript, so holding one across turns would keep the
/// earlier turns in the model's cache. This still builds a new session per request, because AURA's
/// history lives in SwiftData and survives app launches whereas a cached session does not — keeping a
/// long-lived session would mean two sources of truth for "what has been said", and they would disagree
/// after any relaunch, eviction, or context edit.
///
/// What changed in Phase 3 is *how* the prior turns are given to that session. They used to be rendered
/// into the prompt as a labelled text block ("Earlier in this conversation: User: …"). Now they are
/// replayed as a real `Transcript`, so the model sees proper role separation instead of prose describing
/// it, and the prompt contains only the turn actually being taken. The store stays the single source of
/// truth — the transcript is derived from it on every request rather than accumulated alongside it.
///
/// ### What this provider does not do yet
/// - **Tools.** Declares `.providerManaged` because Apple's framework is the thing that calls
///   `Tool.call`, but no tools are passed yet. Wiring them needs a `DynamicGenerationSchema` bridge
///   from `ToolParameterSchema`, which is Phase 10.
/// - **Token usage.** `LanguageModelSession.Usage` is iOS 27 only, so `ModelUsage` is `nil` here. No
///   loss: §67's cost controls exist for metered cloud providers, and on-device inference is free.
///
/// ### APIs verified against Apple's documentation before use
/// Every signature below was checked rather than recalled, because a plausible-looking wrong one is the
/// failure mode this codebase is most exposed to:
///
/// | API | Verified shape |
/// |---|---|
/// | `LanguageModelSession.init(model:tools:transcript:)` | iOS 26.0+, `transcript` required |
/// | `streamResponse(to:options:)` | returns `sending ResponseStream<String>`; not `async`, not throwing |
/// | `ResponseStream` | `AsyncSequence` with `Element == ResponseStream.Snapshot<Content>` |
/// | `Snapshot` | `content: Content.PartiallyGenerated`, `rawContent: GeneratedContent` |
/// | `Transcript.init(entries:)` | `some Sequence<Transcript.Entry>` |
/// | `Transcript.Instructions.init(id:segments:toolDefinitions:)` | all required |
/// | `Transcript.Prompt.init(id:segments:options:responseFormat:)` | all required |
/// | `Transcript.Response.init(id:assetIDs:segments:)` | all required |
/// | `Transcript.TextSegment.init(id:content:)` | all required |
///
/// One thing could not be verified from public documentation: `String.PartiallyGenerated`. `Generable`
/// declares `associatedtype PartiallyGenerated: ConvertibleFromGeneratedContent = Self`, and Apple does
/// not document `String`'s conformance, so `Snapshot.content` is annotated `String` explicitly below.
/// If that resolution is wrong the compiler says so and names the real type, which is a better outcome
/// than a silent `String(describing:)` that would ship mangled text.
struct AppleFoundationModelProvider: LanguageModelProvider {

    let id = LanguageModelProviderID.appleOnDevice
    let displayName = "Apple Intelligence"
    let isOnDevice = true
    let toolExecutionStyle = ToolExecutionStyle.providerManaged

    /// Injectable so a test or preview can point at a specific model instance.
    /// `SystemLanguageModel` is itself `Sendable`, so a value type holding one is too.
    private let model: SystemLanguageModel

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    var contextWindowTokens: Int? {
        model.contextSize
    }

    // MARK: - Availability

    func availability() async -> ModelAvailability {
        Self.mapAvailability(model.availability)
    }

    /// Translates Apple's availability onto AURA's (§68).
    ///
    /// `Availability` is `@frozen`, so its switch is exhaustive without an `@unknown default`.
    /// `UnavailableReason` is not, so that one needs the catch-all — a future OS adding a reason must
    /// degrade to "unknown" rather than failing to compile or, worse, being mis-reported as available.
    static func mapAvailability(_ availability: SystemLanguageModel.Availability) -> ModelAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceUnsupported
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceDisabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .unknown
            }
        }
    }

    // MARK: - Generation

    func send(
        _ request: ModelRequest,
        toolInvoker: (any ToolInvoking)?
    ) async throws -> ModelResponse {
        let (session, promptText) = try prepare(request)

        do {
            try Task.checkCancellation()

            let response = try await session.respond(
                to: Prompt { promptText },
                options: Self.generationOptions(for: request.options)
            )

            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw AuraError.emptyModelResponse
            }

            return ModelResponse(
                text: text,
                providerID: id,
                usage: nil,
                finishReason: .complete
            )
        } catch is CancellationError {
            throw AuraError.cancelled
        } catch let error as AuraError {
            throw error
        } catch {
            throw Self.mapGenerationError(error)
        }
    }

    /// Real token streaming, replacing the protocol's one-delta default.
    ///
    /// Apple yields *cumulative* snapshots — each one is the whole answer so far, not the newest
    /// fragment. `ModelStreamEvent` promises deltas, so the snapshots are diffed here. That diffing is in
    /// `resolveDelta`, which is pure and unit-tested, because getting it wrong duplicates or drops text on
    /// screen and no compiler catches that.
    func stream(
        _ request: ModelRequest,
        toolInvoker: (any ToolInvoking)?
    ) -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (session, promptText) = try prepare(request)

                    try Task.checkCancellation()

                    let responseStream = session.streamResponse(
                        to: Prompt { promptText },
                        options: Self.generationOptions(for: request.options)
                    )

                    var emitted = ""

                    for try await snapshot in responseStream {
                        try Task.checkCancellation()

                        // Annotated deliberately: `Snapshot.content` is `Content.PartiallyGenerated`, and
                        // `String.PartiallyGenerated` is not documented. If it is not `String`, this line
                        // fails to compile and names the actual type.
                        let cumulative: String = snapshot.content

                        switch Self.resolveDelta(emitted: emitted, cumulative: cumulative) {
                        case .none:
                            break
                        case .append(let addition):
                            continuation.yield(.textDelta(addition))
                        case .replace(let whole):
                            continuation.yield(.textReplaced(whole))
                        }
                        emitted = cumulative
                    }

                    let text = emitted.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        throw AuraError.emptyModelResponse
                    }

                    continuation.yield(.finished(
                        ModelResponse(text: text, providerID: id, usage: nil, finishReason: .complete)
                    ))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AuraError.cancelled)
                } catch let error as AuraError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: Self.mapGenerationError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Shared front half of both generation paths: availability gate, session, prompt.
    ///
    /// One function so `send` and `stream` cannot drift apart in what they check or what they send — a
    /// streaming reply that saw different context from a non-streaming one would be a bug nobody would
    /// think to look for.
    private func prepare(_ request: ModelRequest) throws -> (LanguageModelSession, String) {
        let availability = Self.mapAvailability(model.availability)
        guard availability.isAvailable else {
            throw AuraError.onDeviceModelUnavailable(availability)
        }

        if !request.effectiveTools.isEmpty {
            // Better to say so than to silently drop the tools and let the model promise an action it
            // was never given the means to take (§78).
            AuraLog.model.notice(
                "Apple provider was offered \(request.effectiveTools.count, privacy: .public) tool(s); tool support lands in Phase 10."
            )
        }

        let promptText = Self.renderTurnPrompt(for: request)
        guard !promptText.isEmpty else {
            throw AuraError.emptyModelResponse
        }

        let session = LanguageModelSession(
            model: model,
            tools: [],
            transcript: Self.makeTranscript(for: request)
        )
        return (session, promptText)
    }

    // MARK: - Guided generation

    /// Generates a `@Generable` value rather than prose.
    ///
    /// Outside `LanguageModelProvider` on purpose: guided generation is Apple-specific, and putting it on the
    /// protocol would oblige every provider — including cloud ones and the mock — to fake a schema they cannot
    /// honour. A caller that needs structure asks for this provider explicitly and does nothing if it is not
    /// the one routed, which is what `ModelMemoryExtractor` does.
    ///
    /// Verified: `respond(to:generating:includeSchemaInPrompt:options:)` is
    /// `async throws -> Response<Content> where Content: Generable`, and `Response.content` is the value.
    ///
    /// `includeSchemaInPrompt` stays `true`. The default costs prompt tokens but makes the model far likelier
    /// to fill every field, and a half-populated extraction is worse than a slower one.
    func generate<Content: Generable>(
        _ type: Content.Type,
        instructions: String,
        prompt: String,
        options: ModelGenerationOptions = .structured
    ) async throws -> Content {
        let availability = Self.mapAvailability(model.availability)
        guard availability.isAvailable else {
            throw AuraError.onDeviceModelUnavailable(availability)
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw AuraError.emptyModelResponse
        }

        let session = LanguageModelSession(
            model: model,
            tools: [],
            transcript: Transcript(entries: [
                .instructions(Transcript.Instructions(
                    id: UUID().uuidString,
                    segments: [Self.textSegment(instructions)],
                    toolDefinitions: []
                ))
            ])
        )

        do {
            try Task.checkCancellation()
            let response = try await session.respond(
                to: Prompt { trimmedPrompt },
                generating: type,
                includeSchemaInPrompt: true,
                options: Self.generationOptions(for: options)
            )
            return response.content
        } catch is CancellationError {
            throw AuraError.cancelled
        } catch let error as AuraError {
            throw error
        } catch {
            throw Self.mapGenerationError(error)
        }
    }

    // MARK: - Snapshot diffing

    /// What a new cumulative snapshot adds to what has already been sent downstream.
    enum SnapshotDelta: Sendable, Equatable {
        case none
        case append(String)
        /// The snapshot is not an extension of what was already emitted, so the consumer has to start
        /// over. Deltas cannot be retracted, which is the only reason this case exists.
        case replace(String)
    }

    /// Diffs a cumulative snapshot against what has already been emitted.
    ///
    /// For plain-text generation the snapshots grow by appending, so `append` is the path taken in
    /// practice. `replace` is here because monotonic growth is not a documented guarantee, and the
    /// alternative to handling revision is text silently duplicating on screen.
    static func resolveDelta(emitted: String, cumulative: String) -> SnapshotDelta {
        if cumulative == emitted { return .none }
        if cumulative.hasPrefix(emitted) {
            return .append(String(cumulative.dropFirst(emitted.count)))
        }
        return .replace(cumulative)
    }

    // MARK: - Options

    static func generationOptions(for options: ModelGenerationOptions) -> GenerationOptions {
        // `init(samplingMode:temperature:maximumResponseTokens:)` is back-deployed to iOS 26 and every
        // parameter has a default; the four-parameter variant is iOS 27 and requires an explicit
        // `toolCallingMode:`, so there is no ambiguity between them.
        GenerationOptions(
            temperature: options.temperature,
            maximumResponseTokens: options.maximumResponseTokens
        )
    }

    // MARK: - Transcript and prompt

    /// Replays the request's instructions and prior turns as a `Transcript`.
    ///
    /// The final message is deliberately excluded — that one is the prompt for this turn, and including
    /// it here would present the user's live question as something already said and answered.
    ///
    /// `static` and pure so what the model actually receives is assertable in a test. The transcript is
    /// the contract with the model just as much as the prompt is.
    static func makeTranscript(for request: ModelRequest) -> Transcript {
        var entries: [Transcript.Entry] = []

        // Instructions ride in the transcript because `init(model:tools:transcript:)` takes no
        // `instructions` parameter — the transcript is the only way in.
        let instructions = request.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                id: UUID().uuidString,
                segments: [textSegment(instructions)],
                toolDefinitions: []
            )))
        }

        // Before the surviving turns, because that is where it happened. A summary appended after them
        // would read as the most recent thing said.
        //
        // It goes in as a labelled prompt entry. `Transcript` has no "note about the conversation" entry
        // other than `instructions`, and instructions is where the cacheable prefix lives — putting a
        // summary that grows with the thread in there would invalidate that prefix every turn. Labelling it
        // explicitly is honest about what it is, rather than passing it off as either party's words. Same
        // reasoning as the tool-result case below.
        if let summary = request.conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            entries.append(.prompt(Transcript.Prompt(
                id: UUID().uuidString,
                segments: [textSegment("Summary of earlier turns in this conversation: \(summary)")],
                options: GenerationOptions(),
                responseFormat: nil
            )))
        }

        for message in request.messages.dropLast() {
            switch message.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(
                    id: UUID().uuidString,
                    segments: [textSegment(message.text)],
                    options: GenerationOptions(),
                    responseFormat: nil
                )))
            case .assistant:
                entries.append(.response(Transcript.Response(
                    id: UUID().uuidString,
                    assetIDs: [],
                    segments: [textSegment(message.text)]
                )))
            case .tool:
                // `Transcript.ToolOutput` exists, but constructing one honestly needs the tool-call entry
                // it answers, and tools are Phase 10. Until then a tool result is replayed as a labelled
                // prompt: less faithful, but it does not fabricate a call that was never recorded.
                let name = message.toolName ?? "tool"
                entries.append(.prompt(Transcript.Prompt(
                    id: UUID().uuidString,
                    segments: [textSegment("Result from \(name): \(message.text)")],
                    options: GenerationOptions(),
                    responseFormat: nil
                )))
            }
        }

        return Transcript(entries: entries)
    }

    private static func textSegment(_ content: String) -> Transcript.Segment {
        .text(Transcript.TextSegment(id: UUID().uuidString, content: content))
    }

    /// Renders the turn being taken, preceded by this turn's context.
    ///
    /// The per-turn context goes here rather than into the transcript's instructions entry, which is what
    /// makes the split worth having: the instructions entry stays byte-identical between turns and can be
    /// prewarmed, while the material that changes every turn rides with the prompt that changes anyway.
    ///
    /// History lives in the transcript.
    static func renderTurnPrompt(for request: ModelRequest) -> String {
        guard let latest = request.messages.last else { return "" }

        let turn: String
        switch latest.role {
        case .user:
            turn = latest.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .assistant:
            // An assistant-final request is a continuation, not a question.
            let text = latest.text.trimmingCharacters(in: .whitespacesAndNewlines)
            turn = text.isEmpty ? "" : "Continue from where you left off:\n\(text)"
        case .tool:
            let name = latest.toolName ?? "tool"
            let text = latest.text.trimmingCharacters(in: .whitespacesAndNewlines)
            turn = text.isEmpty
                ? ""
                : "Result from \(name):\n\(text)\n\nAnswer the user using this result."
        }

        // An empty turn stays empty: `prepare` treats that as nothing to send, and prefixing context onto
        // nothing would turn a no-op into a request that asks the model to answer silence.
        guard !turn.isEmpty else { return "" }

        guard let context = request.turnContext, !context.isBlank else { return turn }
        return context + "\n\n" + turn
    }

    // MARK: - Prewarming

    /// Loads model assets ahead of a likely request, using the stable instructions as the prefix.
    ///
    /// Called when the conversation screen opens, so the first reply of a session does not pay for asset
    /// loading while the user watches. Deliberately silent on unavailability: prewarming a model that is not
    /// there is a no-op, not an error worth telling anyone about.
    func prewarm(instructions: String) async {
        guard Self.mapAvailability(model.availability).isAvailable else { return }

        let session = LanguageModelSession(
            model: model,
            tools: [],
            transcript: Transcript(entries: [
                .instructions(Transcript.Instructions(
                    id: UUID().uuidString,
                    segments: [Self.textSegment(instructions)],
                    toolDefinitions: []
                ))
            ])
        )
        session.prewarm()
    }

    // MARK: - Error mapping

    /// Maps a Foundation Models failure onto an `AuraError` with a sentence a person can act on (§69).
    ///
    /// `LanguageModelSession.GenerationError` is the iOS 26 error type and is deprecated in the iOS 27
    /// SDK, where `LanguageModelSession.Error` covers part of the same ground. The mapping is isolated
    /// here so that migration is one function, and so the deprecation warnings have exactly one home.
    static func mapGenerationError(_ error: any Error) -> AuraError {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return .modelFailed(reason: error.localizedDescription)
        }

        switch generationError {
        case .exceededContextWindowSize:
            return .contextWindowExceeded
        case .guardrailViolation, .refusal:
            return .modelRefusedRequest
        case .assetsUnavailable:
            return .onDeviceModelUnavailable(.modelNotReady)
        case .rateLimited:
            return .modelFailed(reason: "The model is busy. Try again in a moment.")
        case .concurrentRequests:
            return .modelFailed(reason: "I was already working on something. Try that again.")
        case .unsupportedLanguageOrLocale:
            return .modelFailed(reason: "I can't work in that language yet.")
        case .decodingFailure, .unsupportedGuide:
            return .modelFailed(reason: "I couldn't make sense of my own answer that time.")
        @unknown default:
            return .modelFailed(reason: generationError.localizedDescription)
        }
    }
}
