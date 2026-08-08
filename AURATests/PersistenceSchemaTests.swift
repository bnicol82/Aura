import Foundation
import SwiftData
import Testing

@testable import AURA

/// Schema validation.
///
/// This is the most valuable suite in Phase 1. SwiftData validates a schema at container-creation
/// time, so an invalid relationship, a missing inverse or an unsupported attribute shows up as a
/// thrown error here rather than as a crash on a user's device. Every test that builds a container is
/// also, implicitly, a schema test.
@Suite("Persistence and schema")
struct PersistenceSchemaTests {

    @Test("The V1 schema builds a container")
    func schemaIsValid() throws {
        let controller = try PersistenceController.inMemory()
        #expect(controller.isEphemeral)
        #expect(!controller.sync.isCloudEnabled)
    }

    @Test("An in-memory controller never enables CloudKit mirroring, even if asked")
    func inMemoryForcesLocalOnly() throws {
        let controller = try PersistenceController(
            storage: .inMemory,
            sync: .cloudKit(containerIdentifier: "iCloud.test.container")
        )
        #expect(!controller.sync.isCloudEnabled)
    }

    @Test("Every model in the schema is registered exactly once")
    func schemaHasNoDuplicates() {
        let names = AuraSchemaV1.models.map { String(describing: $0) }
        #expect(Set(names).count == names.count)
        #expect(names.count == 15)
    }

    @Test("The migration plan lists the current schema")
    func migrationPlanIsWired() {
        #expect(AuraMigrationPlan.schemas.count == 1)
        #expect(AuraMigrationPlan.stages.isEmpty)
        #expect(AuraSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    // MARK: Insert-and-read round trips
    //
    // Each of these proves the model can actually be written and fetched, which catches problems the
    // schema check alone does not — a `#Predicate` that cannot compile against a column, or a
    // relationship whose inverse does not hold.

    @Test("A conversation and its messages round-trip, ordered by time then sequence")
    @MainActor
    func conversationRoundTrip() throws {
        let controller = try PersistenceController.inMemory()
        let context = ModelContext(controller.container)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let conversation = Conversation(title: "", createdAt: start)
        context.insert(conversation)

        let user = Message(role: .user, content: "Remember that I'm saving the garage until October.", sequence: 0, createdAt: start)
        let reply = Message(role: .assistant, content: "Got it.", sequence: 1, createdAt: start)
        user.conversation = conversation
        reply.conversation = conversation
        context.insert(user)
        context.insert(reply)
        try context.save()

        let fetched = try #require(
            try context.fetch(FetchDescriptor<Conversation>()).first
        )
        #expect(fetched.orderedMessages.map(\.sequence) == [0, 1])
        #expect(fetched.visibleMessages.count == 2)
        // Titles derive from the first user message when the user never set one.
        #expect(fetched.resolvedTitle.hasPrefix("Remember that I'm saving"))
    }

    @Test("Deleting a conversation cascades to its messages")
    @MainActor
    func conversationCascades() throws {
        let controller = try PersistenceController.inMemory()
        let context = ModelContext(controller.container)

        let conversation = Conversation(title: "Garage")
        context.insert(conversation)
        for index in 0..<3 {
            let message = Message(role: .user, content: "turn \(index)", sequence: index)
            message.conversation = conversation
            context.insert(message)
        }
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == 3)

        context.delete(conversation)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == 0)
    }

    @Test("Deleting a person cascades to their important dates")
    @MainActor
    func personCascades() throws {
        let controller = try PersistenceController.inMemory()
        let context = ModelContext(controller.container)

        let person = PersonProfile(name: "Blake", relationship: "son")
        context.insert(person)
        let birthday = ImportantDate(title: "Birthday", date: .now, isRecurringAnnually: true)
        birthday.person = person
        context.insert(birthday)
        try context.save()

        context.delete(person)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ImportantDate>()) == 0)
    }

    @Test("Every model type can be inserted and saved")
    @MainActor
    func allModelsInsertable() throws {
        let controller = try PersistenceController.inMemory()
        let context = ModelContext(controller.container)

        context.insert(AssistantProfile())
        context.insert(UserProfile())
        context.insert(ProfileFact(key: "Favourite driver", value: "Christopher Bell", category: .sports))
        context.insert(PersonProfile(name: "Jennifer", relationship: "wife"))
        context.insert(ImportantDate(title: "Anniversary", date: .now, isRecurringAnnually: true))
        context.insert(Conversation(title: "First"))
        context.insert(Message(role: .user, content: "Hello"))
        context.insert(MemoryItem(content: "The user prefers aisle seats.", memoryType: .semantic, category: .travel))
        context.insert(MemoryCandidate(content: "Blake studies aerospace engineering.", category: .education))
        context.insert(Project(name: "Garage Renovation"))
        context.insert(AssistantTask(title: "Order an air filter"))
        context.insert(ToolExecution(toolID: "memory.search", toolName: "search_memory"))
        context.insert(ActivityRecord(kind: .memorySaved, title: "Saved a memory"))
        context.insert(KnowledgeDocument(title: "Warranty", filename: "warranty.pdf"))
        context.insert(UserPreference(key: "tip.dismissed", value: .bool(true)))

        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<MemoryItem>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<UserPreference>()) == 1)
    }

    @Test("Predicates work against the columns retrieval depends on")
    @MainActor
    func predicatesCompileAndMatch() throws {
        let controller = try PersistenceController.inMemory()
        let context = ModelContext(controller.container)

        let travel = MemoryItem(
            content: "The user always prefers aisle seats on flights.",
            memoryType: .semantic,
            category: .travel,
            importance: 0.9
        )
        travel.refreshSearchText()
        context.insert(travel)

        let sports = MemoryItem(
            content: "The user's favourite NASCAR driver is Christopher Bell.",
            memoryType: .semantic,
            category: .sports,
            importance: 0.88
        )
        sports.refreshSearchText()
        context.insert(sports)
        try context.save()

        // Raw-string enum storage is what makes this possible; a `Codable` enum column could not be
        // used in a predicate.
        let travelRaw = MemoryCategory.travel.rawValue
        let byCategory = try context.fetch(
            FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.categoryRaw == travelRaw })
        )
        #expect(byCategory.count == 1)

        let needle = "nascar"
        let byText = try context.fetch(
            FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.searchText.contains(needle) })
        )
        #expect(byText.count == 1)

        let byImportance = try context.fetch(
            FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.importance >= 0.89 })
        )
        #expect(byImportance.count == 1)
    }

    @Test("An id-set predicate over a captured array matches the right rows")
    @MainActor
    func idArrayPredicate() throws {
        let controller = try PersistenceController.inMemory()
        let context = ModelContext(controller.container)

        let first = ProfileFact(key: "Seat", value: "Aisle", category: .travel)
        let second = ProfileFact(key: "Coffee", value: "Black", category: .food)
        context.insert(first)
        context.insert(second)
        try context.save()

        let targets = [first.id]
        let matches = try context.fetch(
            FetchDescriptor<ProfileFact>(predicate: #Predicate { targets.contains($0.id) })
        )
        #expect(matches.count == 1)
        #expect(matches.first?.key == "Seat")
    }
}
