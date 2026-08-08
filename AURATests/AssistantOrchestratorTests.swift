import Foundation
import SwiftData
import Testing

@testable import AURA

/// End-to-end turns.
///
/// Real stores, real personalization engine, real router — only the model is a double. That is the point
/// of the architecture: a complete turn, including persistence and context assembly, is verifiable with
/// no device, no Apple Intelligence, and no network.
@Suite("Assistant orchestrator")
struct AssistantOrchestratorTests {

    /// Everything a turn needs, wired the way the app wires it.
    private struct Harness {
        let controller: PersistenceController
        let assistantProfileStore: AssistantProfileStore
        let userProfileStore: UserProfileStore
        let conversationStore: SwiftDataConversationStore
        let provider: MockLanguageModelProvider
        let orchestrator: AssistantOrchestrator

        init(
            behavior: MockLanguageModelProvider.Behavior = .respond("Got it."),
            availability: ModelAvailability = .available,
            isOnline: Bool = true
        ) throws {
            controller = try PersistenceController.inMemory()
            assistantProfileStore = AssistantProfileStore(modelContainer: controller.container)
            userProfileStore = UserProfileStore(modelContainer: controller.container)
            conversationStore = SwiftDataConversationStore(modelContainer: controller.container)

            provider = MockLanguageModelProvider(availability: availability, behavior: behavior)

            let monitor = StubNetworkMonitor(isOnline: isOnline)
            let personalization = DefaultPersonalizationEngine(
                assistantProfileStore: assistantProfileStore,
                userProfileStore: userProfileStore
            )
            let router = DefaultModelRouter(
                providers: [provider],
                networkMonitor: monitor,
                availabilityCacheLifetime: 0
            )
            orchestrator = AssistantOrchestrator(
                conversationStore: conversationStore,
                personalizationEngine: personalization,
                router: router,
                assistantProfileStore: assistantProfileStore,
                networkMonitor: monitor
            )
        }
    }

    // MARK: A successful turn

    @Test("A turn is answered and both messages are persisted")
    func completesATurn() async throws {
        let harness = try Harness(behavior: .respond("You've got three things today."))

        let response = await harness.orchestrator.send(
            AssistantRequest(text: "What's on today?")
        )

        #expect(!response.isFailure)
        #expect(response.text == "You've got three things today.")
        #expect(response.route.isOnDevice)

        let messages = try await harness.conversationStore.messages(
            inConversationID: response.conversationID
        )
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[0].content == "What's on today?")
        #expect(messages[1].role == .assistant)
        #expect(messages[1].content == "You've got three things today.")
        #expect(messages[1].providerIdentifier == LanguageModelProviderID.mock.rawValue)
        #expect(messages[1].isFailure == false)
        // Sequence numbers are what keep the transcript stable when timestamps collide.
        #expect(messages.map(\.sequence) == [0, 1])
    }

    @Test("The first turn creates a conversation and titles it from what was said")
    func createsAndTitlesConversation() async throws {
        let harness = try Harness()

        let response = await harness.orchestrator.send(
            AssistantRequest(text: "Remember that I'm saving the garage renovation until October.")
        )

        let conversation = try await harness.conversationStore.conversation(id: response.conversationID)
        #expect(conversation != nil)
        #expect(conversation?.title.hasPrefix("Remember that I'm saving") == true)
    }

    @Test("A second turn continues the same conversation and carries history to the model")
    func continuesConversation() async throws {
        let harness = try Harness(behavior: .respondInSequence(["First answer.", "Second answer."]))

        let first = await harness.orchestrator.send(AssistantRequest(text: "Hello there."))
        let second = await harness.orchestrator.send(
            AssistantRequest(text: "And what about tomorrow?", conversationID: first.conversationID)
        )

        #expect(second.conversationID == first.conversationID)

        let messages = try await harness.conversationStore.messages(inConversationID: first.conversationID)
        #expect(messages.count == 4)

        // The second request must have carried the first exchange.
        let secondRequest = try #require(harness.provider.lastRequest)
        #expect(secondRequest.messages.count == 3)
        #expect(secondRequest.messages.first?.text == "Hello there.")
        #expect(secondRequest.messages.last?.text == "And what about tomorrow?")
        #expect(secondRequest.messages.last?.role == .user)
    }

    @Test("Whitespace is normalised before anything is stored or sent")
    func normalisesInput() async throws {
        let harness = try Harness()
        let response = await harness.orchestrator.send(
            AssistantRequest(text: "  what's   on\n\n today?  ")
        )

        let messages = try await harness.conversationStore.messages(inConversationID: response.conversationID)
        #expect(messages.first?.content == "what's on today?")
    }

    @Test("An empty message is refused without creating anything")
    func refusesEmptyInput() async throws {
        let harness = try Harness()
        let response = await harness.orchestrator.send(AssistantRequest(text: "   \n "))

        #expect(response.isFailure)
        #expect(harness.provider.requestCount == 0)
        #expect(try await harness.conversationStore.recentConversations(limit: 10, includeArchived: true).isEmpty)
    }

    // MARK: Context

    @Test("The model receives the assistant's name and the honesty rules")
    func instructionsCarryIdentityAndHonesty() async throws {
        let harness = try Harness()

        var rename = AssistantProfileMutation()
        rename.assistantName = "Nova"
        _ = try await harness.assistantProfileStore.update(rename)

        _ = await harness.orchestrator.send(AssistantRequest(text: "Hello."))

        let instructions = try #require(harness.provider.lastRequest?.instructions)
        #expect(instructions.contains("You are Nova"))
        #expect(instructions.contains("Never claim to remember something that isn't in your context"))
        #expect(instructions.contains("The current date and time is"))
    }

    @Test("With nothing stored, the model is told so rather than left to invent")
    func statesAbsenceOfContext() async throws {
        let harness = try Harness()
        _ = await harness.orchestrator.send(AssistantRequest(text: "What's my wife's favourite colour?"))

        let instructions = try #require(harness.provider.lastRequest?.instructions)
        #expect(instructions.contains("You have no stored information relevant to this request"))
    }

    @Test("Context is selective: a question about one person does not ship the other")
    func contextIsSelective() async throws {
        let harness = try Harness()

        let blake = try await harness.userProfileStore.createPerson(
            name: "Blake", relationship: "son", sourceMemoryID: nil
        )
        var blakeEducation = PersonProfileMutation()
        blakeEducation.education = .some("Mechanical Engineering at Tennessee")
        _ = try await harness.userProfileStore.updatePerson(id: blake.id, with: blakeEducation)

        _ = try await harness.userProfileStore.createPerson(
            name: "Jennifer", relationship: "wife", sourceMemoryID: nil
        )

        _ = await harness.orchestrator.send(AssistantRequest(text: "What is Blake studying again?"))

        let instructions = try #require(harness.provider.lastRequest?.instructions)
        #expect(instructions.contains("Blake"))
        #expect(instructions.contains("Mechanical Engineering"))
        // Jennifer has nothing to do with this question. §28 is the whole point.
        #expect(!instructions.contains("Jennifer"))
    }

    @Test("Relevant profile facts reach the model; irrelevant ones do not")
    func factsAreFiltered() async throws {
        let harness = try Harness()

        _ = try await harness.userProfileStore.upsertFact(
            key: "Favourite NASCAR driver", value: "Christopher Bell",
            category: .sports, confidence: 1, sourceMemoryID: nil
        )
        _ = try await harness.userProfileStore.upsertFact(
            key: "Preferred seat", value: "Aisle",
            category: .travel, confidence: 1, sourceMemoryID: nil
        )

        _ = await harness.orchestrator.send(AssistantRequest(text: "Who's my favourite NASCAR driver?"))

        let instructions = try #require(harness.provider.lastRequest?.instructions)
        #expect(instructions.contains("Christopher Bell"))
        #expect(!instructions.contains("Aisle"))
    }

    @Test("Turning memory off withholds retrieved context entirely")
    func memoryOffSuppressesContext() async throws {
        let harness = try Harness()

        _ = try await harness.userProfileStore.upsertFact(
            key: "Favourite driver", value: "Christopher Bell",
            category: .sports, confidence: 1, sourceMemoryID: nil
        )

        var disable = AssistantProfileMutation()
        disable.usesMemoryInResponses = false
        _ = try await harness.assistantProfileStore.update(disable)

        _ = await harness.orchestrator.send(AssistantRequest(text: "Who's my favourite driver?"))

        let instructions = try #require(harness.provider.lastRequest?.instructions)
        #expect(!instructions.contains("Christopher Bell"))
        #expect(instructions.contains("You have no stored information relevant to this request"))
    }

    @Test("Standing instructions are included even when nothing else matches")
    func standingInstructionsAlwaysApply() async throws {
        let harness = try Harness()

        var mutation = UserProfileMutation()
        mutation.assistantInstructions = ["Always show me the numbers"]
        _ = try await harness.userProfileStore.update(mutation)

        _ = await harness.orchestrator.send(AssistantRequest(text: "How's the weather?"))

        let instructions = try #require(harness.provider.lastRequest?.instructions)
        #expect(instructions.contains("Always show me the numbers"))
        #expect(instructions.contains("take priority over your default style"))
    }

    @Test("A sensitive topic suppresses humour, whatever the personality says")
    func sensitiveTopicChangesInstructions() async throws {
        let harness = try Harness()
        _ = try await harness.assistantProfileStore.update(.applying(preset: .casual))

        _ = await harness.orchestrator.send(
            AssistantRequest(text: "What did the doctor say about my blood pressure?")
        )

        let instructions = try #require(harness.provider.lastRequest?.instructions)
        #expect(instructions.contains("This topic is sensitive"))
        #expect(!instructions.contains("Light humour"))
    }

    // MARK: Failures

    @Test("A model failure is recorded as a failed turn, never as an answer")
    func recordsModelFailure() async throws {
        let harness = try Harness(behavior: .fail(.modelRefusedRequest))

        let response = await harness.orchestrator.send(AssistantRequest(text: "Do something odd."))

        #expect(response.isFailure)

        let messages = try await harness.conversationStore.messages(inConversationID: response.conversationID)
        #expect(messages.count == 2)
        // What the user said is kept even though the answer failed.
        #expect(messages[0].role == .user)
        #expect(messages[1].isFailure)
        #expect(messages[1].content.contains("not able to help"))
    }

    @Test("An unavailable model fails with a reason and a recovery step")
    func unavailableModelFailsWell() async throws {
        let harness = try Harness(availability: .appleIntelligenceDisabled)

        let response = await harness.orchestrator.send(AssistantRequest(text: "Hello."))

        #expect(response.isFailure)
        let messages = try await harness.conversationStore.messages(inConversationID: response.conversationID)
        let failureText = try #require(messages.last?.content)
        #expect(failureText.contains("Apple Intelligence is turned off"))
        #expect(failureText.contains("Settings"))
    }

    @Test("An empty model response is a failure, not an empty answer")
    func emptyResponseIsAFailure() async throws {
        let harness = try Harness(behavior: .respond("   "))

        let response = await harness.orchestrator.send(AssistantRequest(text: "Hello."))

        #expect(response.isFailure)
        let messages = try await harness.conversationStore.messages(inConversationID: response.conversationID)
        #expect(messages.last?.isFailure == true)
    }

    @Test("A failed turn is not replayed to the model as its own prior answer")
    func failuresAreExcludedFromHistory() async throws {
        let harness = try Harness(behavior: .fail(.noInternetConnection))
        let first = await harness.orchestrator.send(AssistantRequest(text: "First question."))

        harness.provider.setBehavior(.respond("Now it works."))
        _ = await harness.orchestrator.send(
            AssistantRequest(text: "Second question.", conversationID: first.conversationID)
        )

        let request = try #require(harness.provider.lastRequest)
        #expect(!request.messages.contains { $0.text.contains("internet connection") })
        #expect(request.messages.contains { $0.text == "First question." })
    }

    // MARK: Events

    @Test("The event stream reports the turn in order and ends in finished")
    func emitsOrderedEvents() async throws {
        let harness = try Harness(behavior: .respond("Done."))

        var labels: [String] = []
        for await event in harness.orchestrator.stream(AssistantRequest(text: "Hello.")) {
            switch event {
            case .started: labels.append("started")
            case .contextAssembled: labels.append("context")
            case .routed: labels.append("routed")
            case .textDelta: labels.append("delta")
            case .toolStarted, .toolFinished, .awaitingConfirmation: labels.append("tool")
            case .memorySaved, .memoryCandidatePending: labels.append("memory")
            case .finished: labels.append("finished")
            case .failed: labels.append("failed")
            }
        }

        #expect(labels.first == "started")
        #expect(labels.last == "finished")
        #expect(labels.contains("context"))
        #expect(labels.contains("routed"))
        #expect(!labels.contains("failed"))
    }

    @Test("A failing turn's stream ends in failed")
    func failedStreamTerminatesCorrectly() async throws {
        let harness = try Harness(behavior: .fail(.noInternetConnection))

        var sawFailure = false
        var sawFinished = false
        for await event in harness.orchestrator.stream(AssistantRequest(text: "Hello.")) {
            if case .failed = event { sawFailure = true }
            if case .finished = event { sawFinished = true }
        }

        #expect(sawFailure)
        #expect(!sawFinished)
    }

    @Test("The context event reports how many personal items the turn used")
    func reportsContextItemCount() async throws {
        let harness = try Harness()
        _ = try await harness.userProfileStore.createPerson(
            name: "Blake", relationship: "son", sourceMemoryID: nil
        )

        var reported: Int?
        for await event in harness.orchestrator.stream(AssistantRequest(text: "How is Blake doing?")) {
            if case .contextAssembled(let count, _) = event { reported = count }
        }

        #expect(reported == 1)
    }

    // MARK: Cancellation

    @Test("Cancelling a turn leaves no failure message in the transcript")
    func cancellationIsSilent() async throws {
        let harness = try Harness(behavior: .respond("Too late."))
        harness.provider.setResponseDelay(.seconds(10))

        let stream = harness.orchestrator.stream(AssistantRequest(text: "Take your time."))

        // Consume until the turn has started, then abandon the stream — which is what dismissing the
        // screen does, and it must cancel rather than leak a running turn.
        var conversationID: UUID?
        for await event in stream {
            if case .started(let id, _) = event {
                conversationID = id
                break
            }
        }
        await harness.orchestrator.cancelCurrentTurn()

        let id = try #require(conversationID)
        let messages = try await harness.conversationStore.messages(inConversationID: id)
        // The user's message is kept; no "cancelled" bubble is added.
        #expect(messages.contains { $0.role == .user })
        #expect(!messages.contains { $0.isFailure })
    }

    // MARK: Working memory bound

    @Test("History handed to the model is capped at the working-memory limit")
    func historyIsBounded() async throws {
        let harness = try Harness(behavior: .respond("Noted."))

        var conversationID: UUID?
        for index in 0..<(AuraDefaults.workingMemoryTurnLimit + 6) {
            let response = await harness.orchestrator.send(
                AssistantRequest(text: "Message \(index).", conversationID: conversationID)
            )
            conversationID = response.conversationID
        }

        let request = try #require(harness.provider.lastRequest)
        // The window plus the new message, never the whole transcript.
        #expect(request.messages.count <= AuraDefaults.workingMemoryTurnLimit + 1)

        let id = try #require(conversationID)
        let stored = try await harness.conversationStore.messages(inConversationID: id)
        #expect(stored.count == (AuraDefaults.workingMemoryTurnLimit + 6) * 2)
    }

    // MARK: Message assembly

    @Test("Model messages put the new turn last and drop internal roles")
    func modelMessageAssembly() {
        let history: [MessageSnapshot] = [
            MessageSnapshot(role: .user, content: "first", sequence: 0),
            MessageSnapshot(role: .assistant, content: "reply", sequence: 1),
            MessageSnapshot(role: .system, content: "internal", sequence: 2),
            MessageSnapshot(role: .user, content: "latest", sequence: 3)
        ]

        let messages = AssistantOrchestrator.modelMessages(history: history, latestUserText: "latest")

        #expect(messages.map(\.text) == ["first", "reply", "latest"])
        #expect(messages.last?.role == .user)
        // The trailing user turn is not duplicated, even though it is already in the stored history.
        #expect(messages.filter { $0.text == "latest" }.count == 1)
    }
}
