import FoundationModels
import Foundation

/// `LanguageModelProvider` over Apple's on-device Foundation Model.
///
/// AURA's preferred provider: nothing sent to it leaves the device, it costs nothing to run, and it
/// works with no network. Every other provider is a fallback from this one.
///
/// ### Why a fresh session per request
/// `LanguageModelSession` accumulates its own transcript, so reusing one across turns would be faster
/// — the earlier turns stay in the model's cache. It is not what this does, for a reason worth
/// recording: AURA's conversation history lives in SwiftData and survives app launches, whereas a
/// cached session does not. Reusing sessions would mean two sources of truth for "what has been said",
/// and they would disagree after any relaunch, memory-pressure eviction, or context edit. A fresh
/// session per request, with history rendered into the prompt, is always consistent with the store.
///
/// The cost is re-processing a bounded prompt each turn — bounded because working memory is capped at
/// `AuraDefaults.workingMemoryTurnLimit`. Phase 3 revisits this with `Transcript`-based history and
/// `prewarm()`, which needs `Transcript.Prompt` / `Transcript.Response` initialisers verified against a
/// real SDK rather than guessed at.
///
/// ### What this provider does not do yet
/// - **Tools.** Declares `.providerManaged` because Apple's framework is the thing that calls
///   `Tool.call`, but Phase 2 passes no tools. Wiring them needs a `DynamicGenerationSchema` bridge
///   from `ToolParameterSchema`, which is Phase 10.
/// - **Streaming.** Inherits the protocol's default `stream`, which emits the finished answer as one
///   delta. Real token streaming is Phase 3; `ResponseStream`'s element type changed shape between the
///   iOS 26.0 release and the current SDK, and that is not something to guess about.
/// - **Token usage.** `LanguageModelSession.Usage` is iOS 27 only, so `ModelUsage` is `nil` here. No
///   loss: §67's cost controls exist for metered cloud providers, and on-device inference is free.
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

        let instructions = request.instructions
        let promptText = Self.renderPrompt(for: request)

        guard !promptText.isEmpty else {
            throw AuraError.emptyModelResponse
        }

        do {
            let session = LanguageModelSession(model: model, tools: []) {
                instructions
            }

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

    // MARK: - Prompt rendering

    /// Renders a request's messages into a single prompt.
    ///
    /// `static` and pure so the exact text handed to the model is assertable in a test — the prompt is
    /// the contract with the model, and a silent change to it changes the product's behaviour.
    static func renderPrompt(for request: ModelRequest) -> String {
        let history = request.messages.dropLast()
        let latest = request.messages.last

        var sections: [String] = []

        if !history.isEmpty {
            var lines = ["Earlier in this conversation:"]
            for message in history {
                switch message.role {
                case .user:
                    lines.append("User: \(message.text)")
                case .assistant:
                    lines.append("You: \(message.text)")
                case .tool:
                    let name = message.toolName ?? "tool"
                    lines.append("Result from \(name): \(message.text)")
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if let latest {
            switch latest.role {
            case .user:
                sections.append("The user now says:\n\(latest.text)")
            case .assistant:
                // An assistant-final request is a continuation, not a question.
                sections.append("You were saying:\n\(latest.text)\n\nContinue.")
            case .tool:
                let name = latest.toolName ?? "tool"
                sections.append("Result from \(name):\n\(latest.text)\n\nAnswer the user using this result.")
            }
        }

        return sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
