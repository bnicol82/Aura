import Foundation
import Testing

@testable import AURA

/// The three memory tools (§24, §30, §33).
///
/// Backed by a real in-memory `SwiftDataMemoryStore` rather than a stub, because what is being checked is
/// end-to-end: that "remember this" is actually retrievable afterwards, and that "forget that" leaves nothing
/// behind. A stub would let both pass while the store did neither.
@Suite("Memory tools", .timeLimit(.minutes(1)))
struct MemoryToolTests {

    private static func makeStore() throws -> SwiftDataMemoryStore {
        SwiftDataMemoryStore(modelContainer: try PersistenceController.inMemory().container)
    }

    private static func arguments(_ values: [String: JSONValue], for tool: any AssistantTool) -> ToolArguments {
        ToolArguments(toolName: tool.name, values: values)
    }

    // MARK: - remember_this

    @Test("Remembering something makes it findable afterwards")
    func rememberThenSearch() async throws {
        // The whole promise of §24 in one test: what the user asked to be kept can be got back.
        let store = try Self.makeStore()
        let remember = RememberTool(memoryStore: store)
        let search = SearchMemoryTool(memoryStore: store)

        let written = try await remember.execute(
            arguments: Self.arguments(
                ["content": .string("Prefers morning meetings"), "category": .string("personalPreference")],
                for: remember
            ),
            context: ToolExecutionContext()
        )
        #expect(written.didMutateData)

        let found = try await search.execute(
            arguments: Self.arguments(["query": .string("morning meetings")], for: search),
            context: ToolExecutionContext()
        )
        #expect(found.modelFacingText.contains("Prefers morning meetings"))
        #expect(found.didMutateData == false)
    }

    @Test("An explicitly requested memory is stored as explicitly requested")
    func rememberMarksExplicitRequest() async throws {
        // The flag the importance scorer treats as absolute. If this tool wrote memories that looked
        // inferred, retention could later decide to drop something the user asked for by name.
        let store = try Self.makeStore()
        let remember = RememberTool(memoryStore: store)

        _ = try await remember.execute(
            arguments: Self.arguments(["content": .string("Allergic to penicillin")], for: remember),
            context: ToolExecutionContext()
        )

        let stored = try await store.search(MemoryQuery(text: "penicillin"))
        let memory = try #require(stored.first)
        #expect(memory.wasExplicitlyRequested)
        #expect(memory.importance == AuraDefaults.ImportanceThreshold.explicitRequest)
        #expect(memory.confidence == AuraDefaults.Confidence.explicit)
    }

    @Test("Missing content is an argument error, not an empty memory")
    func rememberRejectsMissingContent() async throws {
        let store = try Self.makeStore()
        let remember = RememberTool(memoryStore: store)

        await #expect(throws: AuraError.self) {
            try await remember.execute(
                arguments: Self.arguments([:], for: remember),
                context: ToolExecutionContext()
            )
        }
        #expect(try await store.count(matching: MemoryQuery(text: nil)) == 0)
    }

    @Test("An unrecognised category still saves the memory")
    func rememberSurvivesABadCategory() async throws {
        // Losing the user's fact over a taxonomy typo would be a much worse failure than filing it
        // under "other".
        #expect(RememberTool.category(from: "not_a_category") == .other)
        #expect(RememberTool.category(from: nil) == .other)
        #expect(RememberTool.category(from: "  PersonalPreference ") == .personalPreference)
    }

    @Test("Categories map onto the memory layer they belong in")
    func categoryDecidesMemoryType() {
        #expect(RememberTool.memoryType(for: .person) == .person)
        #expect(RememberTool.memoryType(for: .relationship) == .person)
        #expect(RememberTool.memoryType(for: .project) == .project)
        #expect(RememberTool.memoryType(for: .goal) == .project)
        #expect(RememberTool.memoryType(for: .temporaryContext) == .episodic)
        // Anything the user asked to keep is durable unless it is explicitly time-bound.
        #expect(RememberTool.memoryType(for: .personalPreference) == .semantic)
        #expect(RememberTool.memoryType(for: .other) == .semantic)
    }

    @Test("The confirmation prompt quotes the fact, not the tool's name")
    func rememberPromptQuotesTheContent() throws {
        let remember = RememberTool(memoryStore: try Self.makeStore())
        let prompt = remember.confirmationPrompt(
            for: Self.arguments(["content": .string("Sister is called Priya")], for: remember)
        )
        #expect(prompt.contains("Sister is called Priya"))
        #expect(!prompt.contains("remember_this"))
    }

    // MARK: - search_memory

    @Test("A search that finds nothing says so, without hedging")
    func searchReportsNothingFound() async throws {
        // The failure this guards against is the model treating a soft "I couldn't find much" as licence
        // to answer from the question itself (§78).
        let store = try Self.makeStore()
        let search = SearchMemoryTool(memoryStore: store)

        let result = try await search.execute(
            arguments: Self.arguments(["query": .string("scuba diving")], for: search),
            context: ToolExecutionContext()
        )
        #expect(result.modelFacingText.contains("No stored memories match"))
        #expect(result.modelFacingText.contains("You do not know this"))
        #expect(result.didMutateData == false)
    }

    @Test("An unrecognised category filter widens the search instead of narrowing it to nothing")
    func unknownCategoryFilterDoesNotHide() async throws {
        // `.other` would be a plausible fallback and a bad one: it would report "you do not know this"
        // about a memory that is sitting in the store.
        #expect(SearchMemoryTool.explicitCategory(from: "nonsense") == nil)
        #expect(SearchMemoryTool.explicitCategory(from: "health") == .health)

        let store = try Self.makeStore()
        _ = try await store.save(MemoryDraft(content: "Runs on Tuesdays", category: .routine))
        let search = SearchMemoryTool(memoryStore: store)

        let result = try await search.execute(
            arguments: Self.arguments(
                ["query": .string("Tuesdays"), "category": .string("nonsense")],
                for: search
            ),
            context: ToolExecutionContext()
        )
        #expect(result.modelFacingText.contains("Runs on Tuesdays"))
    }

    @Test("Rendered results carry their age and flag uncertainty")
    func renderKeepsAgeAndConfidence() throws {
        let now = Date()
        let hedged = MemorySnapshot(
            content: "Might be moving to Leeds",
            confidence: AuraDefaults.Confidence.hedged,
            createdAt: now
        )
        let certain = MemorySnapshot(
            content: "Works at a hospital",
            confidence: AuraDefaults.Confidence.explicit,
            // Calendar arithmetic rather than 30 × 86400, so a DST boundary cannot turn 30 days into 29.
            createdAt: try #require(Calendar.current.date(byAdding: .day, value: -30, to: now))
        )

        let rendered = SearchMemoryTool.render([hedged, certain], matching: "leeds", now: now)
        #expect(rendered.contains("Might be moving to Leeds (recorded today, uncertain)"))
        // §22's confidence is only worth recording if it survives into the prompt.
        #expect(rendered.contains("Works at a hospital (recorded 4 weeks ago)"))
        #expect(!rendered.contains("hospital (recorded 4 weeks ago, uncertain)"))
    }

    @Test("Ages are described the way a person would describe them")
    func relativeAgeReadsNaturally() {
        let now = Date()
        func age(daysAgo: Int) -> String {
            SearchMemoryTool.relativeAge(
                of: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!,
                now: now
            )
        }
        #expect(age(daysAgo: 0) == "today")
        #expect(age(daysAgo: 1) == "yesterday")
        #expect(age(daysAgo: 5) == "5 days ago")
        #expect(age(daysAgo: 21) == "3 weeks ago")
        #expect(age(daysAgo: 90) == "3 months ago")
        // Vague at the long end on purpose: a precise date would invite the model to quote it back as
        // though the user had said it then.
        #expect(age(daysAgo: 500) == "over a year ago")
    }

    @Test("Search is read-only and needs no permission, so it works offline")
    func searchIsReadOnly() throws {
        let search = SearchMemoryTool(memoryStore: try Self.makeStore())
        #expect(search.riskLevel == .readOnly)
        #expect(search.requiredPermissions.isEmpty)
        #expect(search.worksOffline)
        #expect(!search.requiresConfirmation(context: ToolExecutionContext(userExplicitlyRequested: false)))
    }

    // MARK: - forget_this

    @Test("Forgetting actually deletes, and the memory is not findable afterwards")
    func forgetDeletesForReal() async throws {
        // §24 requires a hard delete. A user who is told AURA forgot something and finds it still there
        // has been lied to, so this checks the store rather than the tool's own report.
        let store = try Self.makeStore()
        _ = try await store.save(MemoryDraft(content: "Old landlord is called Derek"))
        let forget = ForgetTool(memoryStore: store)

        let result = try await forget.execute(
            arguments: Self.arguments(["query": .string("old landlord")], for: forget),
            context: ToolExecutionContext(userExplicitlyRequested: true)
        )

        #expect(result.didMutateData)
        #expect(result.modelFacingText.contains("Derek"))
        #expect(try await store.count(matching: MemoryQuery(text: "landlord", includeArchived: true)) == 0)
    }

    @Test("Forgetting something that was never stored reports exactly that")
    func forgetReportsNoMatch() async throws {
        let store = try Self.makeStore()
        let forget = ForgetTool(memoryStore: store)

        let result = try await forget.execute(
            arguments: Self.arguments(["query": .string("my old car")], for: forget),
            context: ToolExecutionContext(userExplicitlyRequested: true)
        )
        #expect(result.didMutateData == false)
        #expect(result.modelFacingText.contains("Nothing stored matches"))
        #expect(result.activityLabel == "Nothing to forget")
    }

    @Test("Archived memories are forgotten too")
    func forgetIncludesArchived() async throws {
        // From the user's point of view an archived memory is still something AURA knows. Leaving it
        // behind would make "forget that" a half-truth.
        let store = try Self.makeStore()
        let archived = try await store.save(MemoryDraft(content: "Used to smoke"))
        try await store.setArchived(true, ids: [archived.id])
        let forget = ForgetTool(memoryStore: store)

        let result = try await forget.execute(
            arguments: Self.arguments(["query": .string("used to smoke")], for: forget),
            context: ToolExecutionContext(userExplicitlyRequested: true)
        )
        #expect(result.didMutateData)
        #expect(try await store.count(matching: MemoryQuery(text: "smoke", includeArchived: true)) == 0)
    }

    @Test("A query matching too much is refused rather than partly obeyed")
    func forgetRefusesTooBroadAQuery() async throws {
        // Deleting the first ten of a wider match would be irreversible, arbitrary, and reported as
        // though it were what was asked for. Refusing is the only recoverable option.
        let store = try Self.makeStore()
        for index in 0...ForgetTool.deletionCeiling {
            _ = try await store.save(MemoryDraft(content: "Work note number \(index)"))
        }
        let forget = ForgetTool(memoryStore: store)

        await #expect(throws: AuraError.self) {
            try await forget.execute(
                arguments: Self.arguments(["query": .string("work note")], for: forget),
                context: ToolExecutionContext(userExplicitlyRequested: true)
            )
        }
        // Nothing may have been deleted on the way to refusing.
        #expect(
            try await store.count(matching: MemoryQuery(text: "work note"))
                == ForgetTool.deletionCeiling + 1
        )
    }

    @Test("Forgetting is consequential, so it is confirmed even when asked for outright")
    func forgetAlwaysConfirms() throws {
        // The asymmetry with `remember_this` is deliberate: a wrong memory can be deleted, a deleted one
        // cannot be brought back.
        let store = try Self.makeStore()
        let forget = ForgetTool(memoryStore: store)
        let remember = RememberTool(memoryStore: store)

        #expect(forget.riskLevel == .consequential)
        #expect(forget.requiresConfirmation(context: ToolExecutionContext(userExplicitlyRequested: true)))
        #expect(remember.riskLevel == .reversible)
        #expect(!remember.requiresConfirmation(context: ToolExecutionContext(userExplicitlyRequested: true)))
        // But a memory the model decided to write on its own still gets confirmed.
        #expect(remember.requiresConfirmation(context: ToolExecutionContext(userExplicitlyRequested: false)))
    }

    @Test("The confirmation prompt says the deletion is permanent")
    func forgetPromptStatesPermanence() throws {
        let forget = ForgetTool(memoryStore: try Self.makeStore())
        let prompt = forget.confirmationPrompt(
            for: Self.arguments(["query": .string("old landlord")], for: forget)
        )
        #expect(prompt.contains("old landlord"))
        #expect(prompt.lowercased().contains("permanently"))
        #expect(prompt.lowercased().contains("can't be undone"))
    }

    @Test("A multi-memory deletion names what went")
    func forgetRendersEveryDeletion() {
        let one = MemorySnapshot(content: "Drives a blue estate", summary: "Drives a blue estate")
        let two = MemorySnapshot(content: "Parks on the street", summary: "Parks on the street")

        let single = ForgetTool.render(deleted: [one])
        #expect(single.contains("Drives a blue estate"))
        #expect(single.contains("You no longer know this"))

        let both = ForgetTool.render(deleted: [one, two])
        #expect(both.contains("Deleted 2 memories permanently"))
        #expect(both.contains("Drives a blue estate"))
        #expect(both.contains("Parks on the street"))
        #expect(ForgetTool.outcomeSummary(deleted: [one, two]) == "2 memories")
    }

    // MARK: - Shared display rules

    @Test("Long text is shortened on a word boundary")
    func displayTrimmingBreaksOnWords() {
        let long = "The user has decided to renovate the garage before winter and wants it finished by October"
        // A prompt that stops mid-word reads like a bug at the exact moment the user is deciding whether
        // to trust what they are approving, so the cut lands on the last whole word inside the limit.
        #expect(RememberTool.trimmedForDisplay(long, limit: 40) == "The user has decided to renovate the…")

        #expect(RememberTool.trimmedForDisplay("Short enough") == "Short enough")
        #expect(RememberTool.trimmedForDisplay("  spaced   out  words ") == "spaced out words")
    }
}
