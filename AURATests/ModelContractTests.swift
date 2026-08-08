import Foundation
import Testing

@testable import AURA

@Suite("JSON value")
struct JSONValueTests {

    @Test("Round-trips through text with stable key ordering")
    func roundTrip() throws {
        let value = JSONValue.object([
            "title": .string("Order an air filter"),
            "count": .number(3),
            "done": .bool(false),
            "tags": .array([.string("household"), .string("errand")]),
            "notes": .null
        ])

        let text = try #require(value.jsonString())
        let decoded = try #require(JSONValue(jsonString: text))
        #expect(decoded == value)

        // Sorted keys mean equal values always serialise identically, so CloudKit never sees a
        // spurious change.
        #expect(try #require(decoded.jsonString()) == text)
    }

    @Test("Typed accessors coerce the way a model's loose output requires")
    func typedAccessors() {
        #expect(JSONValue.string("42").intValue == 42)
        #expect(JSONValue.number(42).stringValue == "42")
        #expect(JSONValue.number(1.5).stringValue == "1.5")
        #expect(JSONValue.string("true").boolValue == true)
        #expect(JSONValue.string("no").boolValue == false)
        #expect(JSONValue.bool(true).doubleValue == 1)
        #expect(JSONValue.null.stringValue == nil)
        #expect(JSONValue.array([.string("a"), .number(2)]).stringArrayValue == ["a", "2"])
    }

    @Test("Whole numbers render without a trailing decimal")
    func wholeNumbersRenderCleanly() {
        #expect(JSONValue.number(7).stringValue == "7")
        #expect(JSONValue.number(-7).stringValue == "-7")
        #expect(JSONValue.number(0).stringValue == "0")
    }

    @Test("Malformed text decodes to nothing rather than a wrong value")
    func rejectsMalformedText() {
        #expect(JSONValue(jsonString: "{not json") == nil)
    }
}

@Suite("Memory item")
struct MemoryItemTests {

    @Test("A summary is derived when none is supplied, and clipped on a word boundary")
    func derivesSummary() {
        let long = String(repeating: "renovation ", count: 20)
        let summary = MemoryItem.derivedSummary(from: long, limit: 40)

        #expect(summary.count <= 41)
        #expect(summary.hasSuffix("…"))
        #expect(!summary.contains("  "))
    }

    @Test("Currency excludes archived, superseded and expired memories")
    func currency() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let live = MemoryItem(content: "Live", createdAt: now)
        #expect(live.isCurrent(at: now))

        let archived = MemoryItem(content: "Archived", createdAt: now)
        archived.isArchived = true
        #expect(!archived.isCurrent(at: now))

        let superseded = MemoryItem(content: "Old major", createdAt: now)
        superseded.supersededByMemoryID = UUID()
        #expect(!superseded.isCurrent(at: now))

        let expired = MemoryItem(content: "Only for today", createdAt: now)
        expired.expiresAt = now.addingTimeInterval(-1)
        #expect(!expired.isCurrent(at: now))

        let notYetExpired = MemoryItem(content: "Later today", createdAt: now)
        notYetExpired.expiresAt = now.addingTimeInterval(3600)
        #expect(notYetExpired.isCurrent(at: now))
    }

    @Test("Durability follows pinning, explicit requests, score, and layer")
    func durability() {
        let pinned = MemoryItem(content: "x", memoryType: .episodic, importance: 0.1)
        pinned.isPinned = true
        #expect(pinned.isDurable)

        let requested = MemoryItem(content: "x", memoryType: .episodic, importance: 0.1)
        requested.wasExplicitlyRequested = true
        #expect(requested.isDurable)

        let important = MemoryItem(content: "x", memoryType: .episodic, importance: 0.9)
        #expect(important.isDurable)

        let semantic = MemoryItem(content: "x", memoryType: .semantic, importance: 0.1)
        #expect(semantic.isDurable)

        let passing = MemoryItem(content: "x", memoryType: .episodic, importance: 0.2)
        #expect(!passing.isDurable)
    }

    @Test("Search text covers content, summary, tags and entities")
    func searchTextIsComprehensive() {
        let memory = MemoryItem(
            content: "Blake switched to mechanical engineering.",
            summary: "Blake's major",
            memoryType: .person,
            category: .education
        )
        memory.tags = ["college"]
        memory.entities = ["Blake", "University of Tennessee"]
        memory.refreshSearchText()

        #expect(memory.searchText.contains("mechanical"))
        #expect(memory.searchText.contains("college"))
        #expect(memory.searchText.contains("tennessee"))
        // Lower-cased, so `contains` matching needs no case handling at the call site.
        #expect(memory.searchText == memory.searchText.lowercased())
    }

    @Test("A low-confidence memory is hedged in the text handed to the model")
    func lowConfidenceIsHedgedInContext() {
        let hedged = MemorySnapshot(
            content: "Jennifer might like the Italian place.",
            confidence: AuraDefaults.Confidence.hedged
        )
        #expect(hedged.contextLine.contains("do not state it as certain"))

        let certain = MemorySnapshot(
            content: "Jennifer's birthday is May 6.",
            confidence: AuraDefaults.Confidence.explicit
        )
        #expect(certain.contextLine == "Jennifer's birthday is May 6.")
    }

    @Test("Recording access increments the counters retrieval ranks on")
    func recordsAccess() {
        let memory = MemoryItem(content: "x")
        #expect(memory.accessCount == 0)
        #expect(memory.lastAccessedAt == nil)

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        memory.noteAccess(at: when)
        memory.noteAccess(at: when)

        #expect(memory.accessCount == 2)
        #expect(memory.lastAccessedAt == when)
    }
}

@Suite("Conversation")
struct ConversationTests {

    @Test("Titles derive from the first message and clip on a word boundary")
    func derivesTitle() {
        #expect(Conversation.derivedTitle(from: "") == "New conversation")
        #expect(Conversation.derivedTitle(from: "   ") == "New conversation")
        #expect(Conversation.derivedTitle(from: "Short one") == "Short one")

        let long = Conversation.derivedTitle(
            from: "What time should I leave tomorrow for my nine o'clock appointment downtown",
            limit: 30
        )
        #expect(long.hasSuffix("…"))
        #expect(long.count <= 31)
        #expect(!long.contains("  "))
    }

    @Test("Whitespace in a title is collapsed")
    func collapsesWhitespace() {
        #expect(Conversation.derivedTitle(from: "  hello\n\n  world  ") == "hello world")
    }

    @Test("Tool activity survives its JSON round trip")
    func toolActivityRoundTrip() {
        let message = Message(role: .assistant, content: "Done.")
        #expect(message.toolActivity.isEmpty)

        let notes = [
            ToolActivityNote(toolName: "create_reminder", label: "Creating a reminder", succeeded: true, outcome: "Order an air filter"),
            ToolActivityNote(toolName: "read_calendar", label: "Checking your calendar", succeeded: false, outcome: nil)
        ]
        message.toolActivity = notes
        #expect(message.toolActivityJSON != nil)
        #expect(message.toolActivity == notes)

        message.toolActivity = []
        #expect(message.toolActivityJSON == nil)
    }
}

@Suite("Retrieval ranking")
struct MemoryRelevanceScoreTests {

    @Test("Every term contributes to the total")
    func termsContribute() {
        #expect(MemoryRelevanceScore().total == 0)

        let keywordOnly = MemoryRelevanceScore(keywordOverlap: 1)
        #expect(keywordOnly.total == MemoryRelevanceScore.Weight.keywordOverlap)

        let combined = MemoryRelevanceScore(keywordOverlap: 1, importance: 1)
        #expect(combined.total > keywordOnly.total)
    }

    @Test("Meaning outweighs wording, which outweighs recency")
    func weightOrdering() {
        #expect(MemoryRelevanceScore.Weight.semanticSimilarity > MemoryRelevanceScore.Weight.keywordOverlap)
        #expect(MemoryRelevanceScore.Weight.keywordOverlap > MemoryRelevanceScore.Weight.entityMatch)
        #expect(MemoryRelevanceScore.Weight.entityMatch > MemoryRelevanceScore.Weight.recency)
        #expect(MemoryRelevanceScore.Weight.usage < MemoryRelevanceScore.Weight.recency)
    }

    @Test("The dominant term explains why something was recalled")
    func dominantTerm() {
        #expect(MemoryRelevanceScore(keywordOverlap: 1).dominantTerm == "wording")
        #expect(MemoryRelevanceScore(entityMatch: 1).dominantTerm == "who or what it mentions")
        #expect(MemoryRelevanceScore(pinned: 1).dominantTerm == "you pinned it")
        #expect(MemoryRelevanceScore(contextualLink: 1).dominantTerm == "what you're working on")
    }
}

@Suite("Context assembly")
struct PersonalizationContextTests {

    private func context(
        facts: [ProfileFactSnapshot] = [],
        people: [PersonProfileSnapshot] = [],
        memories: [RankedMemory] = [],
        userName: String? = "Blake"
    ) -> PersonalizationContext {
        PersonalizationContext(
            identity: AssistantIdentity(name: "Nova", userPreferredName: userName),
            personalityInstructions: "You are Nova.",
            relevantFacts: facts,
            relevantPeople: people,
            relevantMemories: memories
        )
    }

    @Test("With nothing stored, the model is told so explicitly")
    func statesAbsenceOfContext() {
        let instructions = context(userName: nil).modelInstructions()
        #expect(instructions.contains("You have no stored information relevant to this request"))
        #expect(instructions.contains("Do not guess"))
    }

    // MARK: Stable / per-turn split

    @Test("The stable half holds identity and carries nothing that changes between turns")
    func stableInstructionsExcludePerTurnMaterial() {
        let fact = ProfileFactSnapshot(
            id: UUID(),
            key: "Favourite driver",
            value: "Christopher Bell",
            category: .sports,
            confidence: AuraDefaults.Confidence.explicit,
            isPinned: false,
            isArchived: false,
            sourceMemoryID: nil,
            supersededByFactID: nil,
            createdAt: .now,
            updatedAt: .now
        )
        let assembled = context(facts: [fact], userName: "Alex")

        // Identity belongs to the stable half: it is the same on every turn.
        #expect(assembled.stableInstructions.contains("Alex"))

        // Retrieval results and the clock do not — they are what makes a turn different from the last one.
        #expect(!assembled.stableInstructions.contains("Christopher Bell"))
        #expect(!assembled.stableInstructions.contains("The current date and time is"))
    }

    @Test("The per-turn half holds what retrieval found, and the clock")
    func turnContextHoldsRetrievedMaterial() {
        let fact = ProfileFactSnapshot(
            id: UUID(),
            key: "Favourite driver",
            value: "Christopher Bell",
            category: .sports,
            confidence: AuraDefaults.Confidence.explicit,
            isPinned: false,
            isArchived: false,
            sourceMemoryID: nil,
            supersededByFactID: nil,
            createdAt: .now,
            updatedAt: .now
        )
        let turn = context(facts: [fact], userName: "Alex").turnContext()

        #expect(turn.contains("Christopher Bell"))
        #expect(turn.contains("The current date and time is"))
        #expect(!turn.hasPrefix("\n"))
    }

    @Test("Splitting loses nothing: the two halves together are what a provider used to receive")
    func splitIsLossless() {
        // The point of the split is caching, not censorship. Anything that fell out of both halves would be
        // context silently dropped, which no test of either half alone would catch.
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let assembled = context(userName: "Alex")

        #expect(
            assembled.modelInstructions(now: now)
                == assembled.stableInstructions + "\n\n" + assembled.turnContext(now: now)
        )
    }

    @Test("A request's combined instructions are the two halves, and tolerate either being absent")
    func combinedInstructionsJoinBothHalves() {
        let both = ModelRequest(
            instructions: "You are Nova.",
            turnContext: "The current date and time is Tuesday.",
            messages: [.user("Hi")]
        )
        #expect(both.combinedInstructions == "You are Nova.\n\nThe current date and time is Tuesday.")

        // No stray separator when one side is missing — a provider receiving a leading blank line would be
        // getting a subtly different prompt than intended.
        let stableOnly = ModelRequest(instructions: "You are Nova.", messages: [.user("Hi")])
        #expect(stableOnly.combinedInstructions == "You are Nova.")

        let turnOnly = ModelRequest(
            instructions: "  ",
            turnContext: "Just context.",
            messages: [.user("Hi")]
        )
        #expect(turnOnly.combinedInstructions == "Just context.")
    }

    @Test("Relevant knowledge appears under headings the model can use")
    func includesRelevantKnowledge() {
        let fact = ProfileFactSnapshot(
            id: UUID(),
            key: "Favourite driver",
            value: "Christopher Bell",
            category: .sports,
            confidence: AuraDefaults.Confidence.explicit,
            isPinned: false,
            isArchived: false,
            sourceMemoryID: nil,
            supersededByFactID: nil,
            createdAt: .now,
            updatedAt: .now
        )
        let person = PersonProfileSnapshot(
            name: "Blake",
            relationship: "son",
            education: "Mechanical Engineering"
        )
        let memory = RankedMemory(
            memory: MemorySnapshot(content: "The user is holding off on the garage renovation until October."),
            score: MemoryRelevanceScore(keywordOverlap: 1)
        )

        let instructions = context(facts: [fact], people: [person], memories: [memory]).modelInstructions()

        #expect(instructions.contains("The user's name is Blake."))
        #expect(instructions.contains("Favourite driver: Christopher Bell"))
        #expect(instructions.contains("Blake — son"))
        #expect(instructions.contains("garage renovation until October"))
        #expect(!instructions.contains("no stored information"))
    }

    @Test("The item count reflects exactly what was included")
    func countsPersonalItems() {
        let empty = context(userName: nil)
        #expect(empty.carriesNoPersonalContext)
        #expect(empty.personalItemCount == 0)

        let populated = context(
            people: [PersonProfileSnapshot(name: "Blake")],
            memories: [RankedMemory(memory: MemorySnapshot(content: "x"), score: MemoryRelevanceScore())]
        )
        #expect(!populated.carriesNoPersonalContext)
        #expect(populated.personalItemCount == 2)
    }

    @Test("The current date is always supplied, since the model has no clock")
    func includesCurrentDate() {
        let instructions = context().modelInstructions(now: Date(timeIntervalSince1970: 1_770_000_000))
        #expect(instructions.contains("The current date and time is"))
    }
}

@Suite("Mock provider")
struct MockLanguageModelProviderTests {

    @Test("Fixed responses come back and requests are recorded")
    func respondsAndRecords() async throws {
        let provider = MockLanguageModelProvider(behavior: .respond("Got it."))
        let request = ModelRequest(instructions: "You are Nova.", messages: [.user("Hello")])

        let response = try await provider.send(request, toolInvoker: nil)

        #expect(response.text == "Got it.")
        #expect(response.providerID == .mock)
        #expect(provider.requestCount == 1)
        #expect(provider.lastRequest?.instructions == "You are Nova.")
    }

    @Test("Echo mode reveals what was actually sent")
    func echoesInput() async throws {
        let provider = MockLanguageModelProvider(behavior: .echo(prefix: "You said: "))
        let response = try await provider.send(
            ModelRequest(instructions: "", messages: [.user("what's on my schedule")]),
            toolInvoker: nil
        )
        #expect(response.text == "You said: what's on my schedule")
    }

    @Test("Sequenced responses advance and then cycle")
    func sequencedResponses() async throws {
        let provider = MockLanguageModelProvider(behavior: .respondInSequence(["one", "two"]))
        let request = ModelRequest(instructions: "", messages: [.user("go")])

        #expect(try await provider.send(request, toolInvoker: nil).text == "one")
        #expect(try await provider.send(request, toolInvoker: nil).text == "two")
        #expect(try await provider.send(request, toolInvoker: nil).text == "one")
    }

    @Test("Failures propagate as the error they were configured with")
    func propagatesFailure() async {
        let provider = MockLanguageModelProvider(behavior: .fail(.noInternetConnection))
        await #expect(throws: AuraError.noInternetConnection) {
            _ = try await provider.send(
                ModelRequest(instructions: "", messages: [.user("hi")]),
                toolInvoker: nil
            )
        }
    }

    @Test("Orchestrator-managed tool flow asks first, then answers once a result is present")
    func orchestratorManagedToolFlow() async throws {
        let provider = MockLanguageModelProvider(
            toolExecutionStyle: .orchestratorManaged,
            behavior: .requestTool(
                name: "read_calendar",
                arguments: ["date": .string("2026-05-06")],
                thenRespond: "You've got three things tomorrow."
            )
        )

        let first = try await provider.send(
            ModelRequest(instructions: "", messages: [.user("what's on tomorrow?")]),
            toolInvoker: nil
        )
        #expect(first.finishReason == .toolCallsRequested)
        #expect(first.toolCalls.first?.toolName == "read_calendar")
        #expect(first.text.isEmpty)

        // Once the tool result is in the transcript the loop must terminate, not ask again.
        let second = try await provider.send(
            ModelRequest(
                instructions: "",
                messages: [
                    .user("what's on tomorrow?"),
                    ModelMessage(role: .tool, text: "3 events", toolName: "read_calendar")
                ]
            ),
            toolInvoker: nil
        )
        #expect(second.finishReason == .complete)
        #expect(second.text == "You've got three things tomorrow.")
    }

    @Test("Provider-managed tool flow runs the tool through the invoker")
    func providerManagedToolFlow() async throws {
        let provider = MockLanguageModelProvider(
            toolExecutionStyle: .providerManaged,
            behavior: .requestTool(
                name: "search_memory",
                arguments: ["query": .string("garage")],
                thenRespond: "You're holding off until October."
            )
        )
        let invoker = RecordingToolInvoker()

        let response = try await provider.send(
            ModelRequest(instructions: "", messages: [.user("what did I decide about the garage?")]),
            toolInvoker: invoker
        )

        #expect(response.text == "You're holding off until October.")
        #expect(response.toolCalls.isEmpty)
        #expect(response.toolActivity.count == 1)
        #expect(await invoker.invocations == ["search_memory"])
    }

    @Test("Streaming emits deltas and finishes with the assembled response")
    func streams() async throws {
        let provider = MockLanguageModelProvider(behavior: .respond("one two three"))
        var deltas: [String] = []
        var finished: ModelResponse?

        for try await event in provider.stream(
            ModelRequest(instructions: "", messages: [.user("go")]),
            toolInvoker: nil
        ) {
            switch event {
            case .textDelta(let delta): deltas.append(delta)
            case .finished(let response): finished = response
            default: break
            }
        }

        #expect(deltas.count == 3)
        #expect(deltas.joined().trimmingCharacters(in: .whitespaces) == "one two three")
        #expect(finished?.text == "one two three")
    }

    @Test("Reported availability is what the router will see")
    func reportsAvailability() async {
        let provider = MockLanguageModelProvider(availability: .available)
        #expect(await provider.availability() == .available)

        provider.setAvailability(.appleIntelligenceDisabled)
        #expect(await provider.availability() == .appleIntelligenceDisabled)
    }
}

/// Records which tools a provider asked for.
private actor RecordingToolInvoker: ToolInvoking {
    private(set) var invocations: [String] = []

    func invokeTool(named name: String, arguments: [String: JSONValue]) async throws -> ToolInvocationOutcome {
        invocations.append(name)
        return ToolInvocationOutcome(
            modelFacingText: "result for \(name)",
            activity: ToolActivityNote(toolName: name, label: "Ran \(name)")
        )
    }
}
