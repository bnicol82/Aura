import FoundationModels
import Foundation
import Testing

@testable import AURA

/// What can be tested about the Apple provider without an eligible device.
///
/// Generation itself needs Apple Intelligence, so it is not tested here. Everything *around* generation
/// — availability translation, prompt rendering, option mapping, error translation — is pure, and those
/// are the parts most likely to be quietly wrong.
@Suite("Apple Foundation Model provider")
struct AppleProviderTests {

    // MARK: Availability

    @Test("Apple's availability states map onto AURA's")
    func mapsAvailability() {
        #expect(AppleFoundationModelProvider.mapAvailability(.available) == .available)
        #expect(
            AppleFoundationModelProvider.mapAvailability(.unavailable(.deviceNotEligible))
                == .deviceUnsupported
        )
        #expect(
            AppleFoundationModelProvider.mapAvailability(.unavailable(.appleIntelligenceNotEnabled))
                == .appleIntelligenceDisabled
        )
        #expect(
            AppleFoundationModelProvider.mapAvailability(.unavailable(.modelNotReady))
                == .modelNotReady
        )
    }

    @Test("Only `modelNotReady` among the unavailable reasons is worth retrying")
    func transienceOfMappedStates() {
        #expect(AppleFoundationModelProvider.mapAvailability(.unavailable(.modelNotReady)).isTransient)
        #expect(!AppleFoundationModelProvider.mapAvailability(.unavailable(.deviceNotEligible)).isTransient)
        #expect(
            !AppleFoundationModelProvider.mapAvailability(.unavailable(.appleIntelligenceNotEnabled)).isTransient
        )
    }

    @Test("The provider declares itself on-device and provider-managed for tools")
    func declaresItsNature() {
        let provider = AppleFoundationModelProvider()
        #expect(provider.isOnDevice)
        #expect(provider.id == .appleOnDevice)
        // Apple's framework calls `Tool.call` itself, so the orchestrator must not also run them.
        #expect(provider.toolExecutionStyle == .providerManaged)
    }

    // MARK: Prompt rendering

    @Test("A single user turn renders as the current message with no history block")
    func rendersSingleTurn() {
        let request = ModelRequest(
            instructions: "You are Nova.",
            messages: [.user("What's on today?")]
        )
        let prompt = AppleFoundationModelProvider.renderPrompt(for: request)

        #expect(prompt == "The user now says:\nWhat's on today?")
        #expect(!prompt.contains("Earlier in this conversation"))
    }

    @Test("History renders above the current message, with roles labelled")
    func rendersHistory() throws {
        let request = ModelRequest(
            instructions: "You are Nova.",
            messages: [
                .user("I'm remodelling the garage."),
                .assistant("Noted — the garage renovation."),
                .user("When did I say I'd start?")
            ]
        )
        let prompt = AppleFoundationModelProvider.renderPrompt(for: request)

        #expect(prompt.contains("Earlier in this conversation:"))
        #expect(prompt.contains("User: I'm remodelling the garage."))
        #expect(prompt.contains("You: Noted — the garage renovation."))
        #expect(prompt.contains("The user now says:\nWhen did I say I'd start?"))

        // Order matters: history first, then the live question.
        let historyIndex = try #require(prompt.range(of: "Earlier in this conversation:")).lowerBound
        let latestIndex = try #require(prompt.range(of: "The user now says:")).lowerBound
        #expect(historyIndex < latestIndex)
    }

    @Test("A tool result is labelled and framed as something to answer from")
    func rendersToolResult() {
        let request = ModelRequest(
            instructions: "",
            messages: [
                .user("What's on tomorrow?"),
                ModelMessage(role: .tool, text: "3 events", toolName: "read_calendar")
            ]
        )
        let prompt = AppleFoundationModelProvider.renderPrompt(for: request)

        #expect(prompt.contains("Result from read_calendar:"))
        #expect(prompt.contains("Answer the user using this result."))
    }

    @Test("An empty message list renders to nothing rather than to a stray label")
    func rendersEmptyRequest() {
        let request = ModelRequest(instructions: "You are Nova.", messages: [])
        #expect(AppleFoundationModelProvider.renderPrompt(for: request).isEmpty)
    }

    @Test("Instructions are never folded into the prompt")
    func instructionsStaySeparate() {
        // Personality and personal context belong in `Instructions`, not in the user-visible prompt, so
        // the model treats them as standing guidance rather than as something the user just said.
        let request = ModelRequest(
            instructions: "SECRET_MARKER_You are Nova.",
            messages: [.user("Hello.")]
        )
        let prompt = AppleFoundationModelProvider.renderPrompt(for: request)
        #expect(!prompt.contains("SECRET_MARKER"))
    }

    // MARK: Options

    @Test("Generation options carry temperature and token ceiling through")
    func mapsOptions() {
        let mapped = AppleFoundationModelProvider.generationOptions(
            for: ModelGenerationOptions(temperature: 0.42, maximumResponseTokens: 512)
        )
        #expect(mapped.temperature == 0.42)
        #expect(mapped.maximumResponseTokens == 512)
    }

    @Test("Unset options stay unset rather than becoming invented defaults")
    func leavesUnsetOptionsAlone() {
        let mapped = AppleFoundationModelProvider.generationOptions(
            for: ModelGenerationOptions()
        )
        #expect(mapped.temperature == nil)
        #expect(mapped.maximumResponseTokens == nil)
    }

    // MARK: Error mapping

    @Test("A non-Foundation-Models error keeps its own description")
    func mapsUnknownError() {
        struct Boom: LocalizedError {
            var errorDescription: String? { "upstream exploded" }
        }
        let mapped = AppleFoundationModelProvider.mapGenerationError(Boom())
        #expect(mapped == .modelFailed(reason: "upstream exploded"))
    }

    @Test("Every mapped model error produces something a person can read")
    func mappedErrorsAreReadable() {
        // Constructing `GenerationError` values needs a `Context`, which is not publicly constructible,
        // so the individual cases are covered by the switch's own exhaustiveness rather than here. What
        // is assertable is that the fallback path never yields an empty message.
        let mapped = AppleFoundationModelProvider.mapGenerationError(
            NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "something failed"])
        )
        #expect(mapped.errorDescription?.isEmpty == false)
    }
}
