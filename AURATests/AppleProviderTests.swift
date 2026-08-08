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

    // MARK: Turn prompt

    @Test("The prompt is the live turn only — history is not in it")
    func rendersSingleTurn() {
        let request = ModelRequest(
            instructions: "You are Nova.",
            messages: [
                .user("I'm remodelling the garage."),
                .assistant("Noted — the garage renovation."),
                .user("When did I say I'd start?")
            ]
        )
        let prompt = AppleFoundationModelProvider.renderTurnPrompt(for: request)

        #expect(prompt == "When did I say I'd start?")
        #expect(!prompt.contains("remodelling"))
        #expect(!prompt.contains("Earlier in this conversation"))
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
        let prompt = AppleFoundationModelProvider.renderTurnPrompt(for: request)

        #expect(prompt.contains("Result from read_calendar:"))
        #expect(prompt.contains("Answer the user using this result."))
    }

    @Test("An empty message list renders to nothing rather than to a stray label")
    func rendersEmptyRequest() {
        let request = ModelRequest(instructions: "You are Nova.", messages: [])
        #expect(AppleFoundationModelProvider.renderTurnPrompt(for: request).isEmpty)
    }

    @Test("Instructions are never folded into the prompt")
    func instructionsStaySeparate() {
        // Personality and personal context belong in the transcript's instructions entry, not in the
        // user-visible prompt, so the model treats them as standing guidance rather than as something the
        // user just said.
        let request = ModelRequest(
            instructions: "SECRET_MARKER_You are Nova.",
            messages: [.user("Hello.")]
        )
        let prompt = AppleFoundationModelProvider.renderTurnPrompt(for: request)
        #expect(!prompt.contains("SECRET_MARKER"))
    }

    // MARK: Transcript

    @Test("History replays as instructions, then alternating prompt and response entries")
    func buildsTranscript() throws {
        let request = ModelRequest(
            instructions: "You are Nova.",
            messages: [
                .user("I'm remodelling the garage."),
                .assistant("Noted — the garage renovation."),
                .user("When did I say I'd start?")
            ]
        )
        let transcript = AppleFoundationModelProvider.makeTranscript(for: request)
        let entries = Array(transcript)

        // Instructions, one prompt, one response. The live turn is the prompt, not a transcript entry.
        #expect(entries.count == 3)
        #expect(Self.kinds(of: entries) == ["instructions", "prompt", "response"])
        #expect(Self.text(of: entries[0]) == "You are Nova.")
        #expect(Self.text(of: entries[1]) == "I'm remodelling the garage.")
        #expect(Self.text(of: entries[2]) == "Noted — the garage renovation.")
    }

    @Test("The live turn is never replayed as history")
    func transcriptExcludesLiveTurn() {
        let request = ModelRequest(
            instructions: "You are Nova.",
            messages: [.user("When did I say I'd start?")]
        )
        let entries = Array(AppleFoundationModelProvider.makeTranscript(for: request))

        // Instructions only. Including the live turn would present the user's question as already asked
        // and answered.
        #expect(Self.kinds(of: entries) == ["instructions"])
    }

    @Test("Empty instructions produce no instructions entry rather than a blank one")
    func transcriptOmitsEmptyInstructions() {
        let request = ModelRequest(
            instructions: "   \n  ",
            messages: [.user("Hi."), .assistant("Hello."), .user("Again.")]
        )
        let entries = Array(AppleFoundationModelProvider.makeTranscript(for: request))

        #expect(Self.kinds(of: entries) == ["prompt", "response"])
    }

    @Test("Per-turn context rides with the prompt, not with the stable instructions")
    func turnContextRidesWithThePrompt() throws {
        // What makes the split worth having: the instructions entry stays byte-identical between turns so it
        // can be prewarmed, while the material that changes every turn travels with the prompt that changes
        // anyway. If per-turn context leaked into the instructions entry, the cached prefix would be
        // invalidated on every single turn and the split would buy nothing.
        let request = ModelRequest(
            instructions: "You are Nova.",
            turnContext: "TURN_MARKER: what you know about the user.",
            messages: [.user("What did I decide?")]
        )

        let prompt = AppleFoundationModelProvider.renderTurnPrompt(for: request)
        #expect(prompt.contains("TURN_MARKER"))
        #expect(prompt.contains("What did I decide?"))

        let entries = Array(AppleFoundationModelProvider.makeTranscript(for: request))
        let instructions = try #require(entries.first)
        #expect(Self.kinds(of: [instructions]) == ["instructions"])
        #expect(Self.text(of: instructions) == "You are Nova.")
        #expect(!Self.text(of: instructions).contains("TURN_MARKER"))
    }

    @Test("An empty turn stays empty rather than becoming a request to answer silence")
    func emptyTurnIsNotRescuedByContext() {
        // `prepare` treats an empty prompt as nothing to send. Prefixing context onto nothing would turn
        // that no-op into a request with context and no question.
        let request = ModelRequest(
            instructions: "You are Nova.",
            turnContext: "Plenty of context.",
            messages: []
        )
        #expect(AppleFoundationModelProvider.renderTurnPrompt(for: request).isEmpty)
    }

    // MARK: Snapshot diffing

    @Test("Cumulative snapshots become append-only deltas")
    func diffsCumulativeSnapshots() {
        // Apple yields the whole answer so far each time; `ModelStreamEvent` promises only what is new.
        #expect(
            AppleFoundationModelProvider.resolveDelta(emitted: "", cumulative: "Hel")
                == .append("Hel")
        )
        #expect(
            AppleFoundationModelProvider.resolveDelta(emitted: "Hel", cumulative: "Hello")
                == .append("lo")
        )
        #expect(
            AppleFoundationModelProvider.resolveDelta(emitted: "Hello", cumulative: "Hello")
                == .none
        )
    }

    @Test("A revised snapshot replaces rather than appends")
    func diffsRevisedSnapshot() {
        // Not an extension of what was already sent. Deltas cannot be retracted, so the consumer is told
        // to start over instead of being handed text that would concatenate into nonsense.
        #expect(
            AppleFoundationModelProvider.resolveDelta(emitted: "Hello th", cumulative: "Good morning")
                == .replace("Good morning")
        )
    }

    @Test("Reassembling every delta reproduces the final answer exactly")
    func deltasReassemble() {
        // The property that matters on screen: the user must end up reading precisely what the model said,
        // with nothing duplicated and nothing dropped.
        let answer = "You decided to hold off on the garage renovation until October."
        var emitted = ""
        var assembled = ""

        // Every prefix, in order, is the worst case for a diffing bug: one snapshot per character.
        for end in 1...answer.count {
            let cumulative = String(answer.prefix(end))
            switch AppleFoundationModelProvider.resolveDelta(emitted: emitted, cumulative: cumulative) {
            case .none:
                break
            case .append(let addition):
                assembled += addition
            case .replace(let whole):
                assembled = whole
            }
            emitted = cumulative
        }

        #expect(assembled == answer)
    }

    // MARK: Transcript helpers

    /// Entry kinds as strings, so an assertion reads as the shape it is checking.
    ///
    /// Only the three kinds this provider builds are matched by name. `Transcript.Entry` also carries
    /// `reasoning`, `toolCalls` and `toolOutput`, and enumerating those would tie this test to their
    /// availability for no benefit — anything unexpected showing up as "other" fails the assertion just as
    /// loudly.
    private static func kinds(of entries: [Transcript.Entry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .instructions: return "instructions"
            case .prompt: return "prompt"
            case .response: return "response"
            default: return "other"
            }
        }
    }

    /// The concatenated text of an entry's segments.
    private static func text(of entry: Transcript.Entry) -> String {
        let segments: [Transcript.Segment]
        switch entry {
        case .instructions(let instructions): segments = instructions.segments
        case .prompt(let prompt): segments = prompt.segments
        case .response(let response): segments = response.segments
        default: segments = []
        }

        return segments.compactMap { segment in
            if case .text(let textSegment) = segment { return textSegment.content }
            return nil
        }.joined()
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
