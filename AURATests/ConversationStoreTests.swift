import Foundation
import SwiftData
import Testing

@testable import AURA

@Suite("Conversation store")
struct ConversationStoreTests {

    private func makeStore() throws -> SwiftDataConversationStore {
        let controller = try PersistenceController.inMemory()
        return SwiftDataConversationStore(modelContainer: controller.container)
    }

    // MARK: Conversations

    @Test("A conversation is created and can be read back")
    func createsConversation() async throws {
        let store = try makeStore()
        let created = try await store.createConversation(title: "Garage", at: .now)

        #expect(created.title == "Garage")
        #expect(try await store.conversation(id: created.id)?.id == created.id)
    }

    @Test("An untitled conversation takes its name from the first user message")
    func derivesTitleFromFirstMessage() async throws {
        let store = try makeStore()
        let conversation = try await store.createConversation(title: nil, at: .now)

        _ = try await store.appendMessage(
            .user("What did I decide about the garage renovation?"),
            toConversationID: conversation.id
        )

        let reread = try await store.conversation(id: conversation.id)
        #expect(reread?.title.hasPrefix("What did I decide") == true)
    }

    @Test("A title the user set is never overwritten by a message")
    func keepsExplicitTitle() async throws {
        let store = try makeStore()
        let conversation = try await store.createConversation(title: "House projects", at: .now)

        _ = try await store.appendMessage(.user("Anything else?"), toConversationID: conversation.id)

        #expect(try await store.conversation(id: conversation.id)?.title == "House projects")
    }

    @Test("Recent conversations come back newest first and exclude archived by default")
    func listsRecentConversations() async throws {
        let store = try makeStore()
        let older = try await store.createConversation(title: "Older", at: Date(timeIntervalSince1970: 1000))
        let newer = try await store.createConversation(title: "Newer", at: Date(timeIntervalSince1970: 5000))

        let listed = try await store.recentConversations(limit: 10, includeArchived: false)
        #expect(listed.map(\.title) == ["Newer", "Older"])

        try await store.setConversationArchived(true, id: newer.id)
        #expect(try await store.recentConversations(limit: 10, includeArchived: false).map(\.title) == ["Older"])
        #expect(try await store.recentConversations(limit: 10, includeArchived: true).count == 2)
        #expect(older.id != newer.id)
    }

    @Test("A recent conversation is resumable; a stale one is not")
    func resumeWindow() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.createConversation(title: "Fresh", at: now.addingTimeInterval(-600))

        #expect(try await store.mostRecentActiveConversation(staleAfter: 3600, now: now) != nil)
        // Picking up a thread from days ago reads as confusion, not continuity.
        #expect(try await store.mostRecentActiveConversation(staleAfter: 60, now: now) == nil)
    }

    @Test("An archived conversation is never offered for resumption")
    func archivedIsNotResumable() async throws {
        let store = try makeStore()
        let now = Date()
        let conversation = try await store.createConversation(title: "Done", at: now)
        try await store.setConversationArchived(true, id: conversation.id)

        #expect(try await store.mostRecentActiveConversation(staleAfter: 3600, now: now) == nil)
    }

    @Test("Renaming, pinning and summarising all persist")
    func metadataUpdates() async throws {
        let store = try makeStore()
        let conversation = try await store.createConversation(title: "Untitled", at: .now)

        try await store.renameConversation(id: conversation.id, title: "  Garage   plans ")
        try await store.setConversationPinned(true, id: conversation.id)
        try await store.updateSummary("Holding off until October.", conversationID: conversation.id)

        let reread = try #require(try await store.conversation(id: conversation.id))
        #expect(reread.title == "Garage plans")
        #expect(reread.isPinned)
        #expect(reread.summary == "Holding off until October.")

        // A blank summary clears rather than storing whitespace.
        try await store.updateSummary("   ", conversationID: conversation.id)
        #expect(try await store.conversation(id: conversation.id)?.summary == nil)
    }

    @Test("Operating on a missing conversation reports not-found rather than failing silently")
    func missingConversation() async throws {
        let store = try makeStore()
        await #expect(throws: AuraError.recordNotFound(entity: "conversation")) {
            try await store.renameConversation(id: UUID(), title: "Nope")
        }
        await #expect(throws: AuraError.recordNotFound(entity: "conversation")) {
            _ = try await store.appendMessage(.user("hi"), toConversationID: UUID())
        }
    }

    @Test("Deleting a conversation takes its messages with it")
    func deleteCascades() async throws {
        let store = try makeStore()
        let conversation = try await store.createConversation(title: "Temp", at: .now)
        _ = try await store.appendMessage(.user("one"), toConversationID: conversation.id)
        _ = try await store.appendMessage(.assistant("two"), toConversationID: conversation.id)

        try await store.deleteConversations(ids: [conversation.id])

        #expect(try await store.conversation(id: conversation.id) == nil)
        #expect(try await store.searchMessages(matching: "one", limit: 10).isEmpty)
    }

    @Test("Clearing all history leaves nothing behind")
    func deleteAll() async throws {
        let store = try makeStore()
        for index in 0..<3 {
            let conversation = try await store.createConversation(title: "C\(index)", at: .now)
            _ = try await store.appendMessage(.user("message \(index)"), toConversationID: conversation.id)
        }

        try await store.deleteAllConversations()

        #expect(try await store.recentConversations(limit: 10, includeArchived: true).isEmpty)
        #expect(try await store.searchMessages(matching: "message", limit: 10).isEmpty)
    }

    // MARK: Messages

    @Test("Messages get increasing sequence numbers within a conversation")
    func sequencesIncrease() async throws {
        let store = try makeStore()
        let conversation = try await store.createConversation(title: nil, at: .now)

        // Same timestamp for all three: sequence is the only thing that can order them.
        let sameMoment = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<3 {
            _ = try await store.appendMessage(
                MessageDraft(role: index % 2 == 0 ? .user : .assistant, content: "m\(index)", createdAt: sameMoment),
                toConversationID: conversation.id
            )
        }

        let messages = try await store.messages(inConversationID: conversation.id)
        #expect(messages.map(\.sequence) == [0, 1, 2])
        #expect(messages.map(\.content) == ["m0", "m1", "m2"])
    }

    @Test("Sequence numbers are per-conversation, not global")
    func sequencesArePerConversation() async throws {
        let store = try makeStore()
        let first = try await store.createConversation(title: "A", at: .now)
        let second = try await store.createConversation(title: "B", at: .now)

        _ = try await store.appendMessage(.user("a1"), toConversationID: first.id)
        _ = try await store.appendMessage(.user("a2"), toConversationID: first.id)
        let firstInSecond = try await store.appendMessage(.user("b1"), toConversationID: second.id)

        #expect(firstInSecond.sequence == 0)
    }

    @Test("A caller-supplied message id is preserved")
    func preservesSuppliedID() async throws {
        let store = try makeStore()
        let conversation = try await store.createConversation(title: nil, at: .now)

        let id = UUID()
        let saved = try await store.appendMessage(
            MessageDraft(id: id, role: .assistant, content: "Answer."),
            toConversationID: conversation.id
        )
        #expect(saved.id == id)
    }

    @Test("A message can be updated in place")
    func updatesMessage() async throws {
        let store = try makeStore()
        let conversation = try await store.createConversation(title: nil, at: .now)
        let message = try await store.appendMessage(
            .assistant("partial"),
            toConversationID: conversation.id
        )

        try await store.updateMessage(
            id: message.id,
            content: "complete",
            toolActivity: [ToolActivityNote(toolName: "search_memory", label: "Searching memory")],
            isFailure: false,
            usage: ModelUsage(promptTokens: 120, responseTokens: 30)
        )

        let messages = try await store.messages(inConversationID: conversation.id)
        #expect(messages.first?.content == "complete")
        #expect(messages.first?.toolActivity.count == 1)
    }

    @Test("Working memory is the last N visible turns and excludes failures")
    func workingMemoryWindow() async throws {
        let store = try makeStore()
        let conversation = try await store.createConversation(title: nil, at: .now)

        for index in 0..<10 {
            _ = try await store.appendMessage(.user("u\(index)"), toConversationID: conversation.id)
            _ = try await store.appendMessage(.assistant("a\(index)"), toConversationID: conversation.id)
        }
        _ = try await store.appendMessage(
            .failure("I need an internet connection for that."),
            toConversationID: conversation.id
        )

        let window = try await store.workingMemory(conversationID: conversation.id, limit: 6)
        #expect(window.count <= 6)
        // An error is a record for the user, not a prior answer the model should build on (§78).
        #expect(!window.contains { $0.isFailure })
        #expect(window.last?.content == "a9")
    }

    @Test("Memory candidate status can be marked on a message")
    func marksCandidateStatus() async throws {
        let store = try makeStore()
        let conversation = try await store.createConversation(title: nil, at: .now)
        let message = try await store.appendMessage(.user("Remember this."), toConversationID: conversation.id)

        #expect(message.memoryCandidateStatus == .notEvaluated)
        try await store.markMemoryCandidateStatus(.accepted, messageID: message.id)

        let messages = try await store.messages(inConversationID: conversation.id)
        #expect(messages.first?.memoryCandidateStatus == .accepted)
    }

    // MARK: Archive search

    @Test("Archive search finds a turn and names its conversation")
    func searchesArchive() async throws {
        let store = try makeStore()
        let conversation = try await store.createConversation(title: "House", at: .now)
        _ = try await store.appendMessage(
            .user("I'm holding off on the garage renovation until October."),
            toConversationID: conversation.id
        )
        _ = try await store.appendMessage(.assistant("Got it."), toConversationID: conversation.id)

        let hits = try await store.searchMessages(matching: "garage", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.conversationTitle == "House")
        #expect(hits.first?.excerpt.contains("garage") == true)
    }

    @Test("Archive search is case-insensitive and ignores blank queries")
    func searchNormalisesQuery() async throws {
        let store = try makeStore()
        let conversation = try await store.createConversation(title: nil, at: .now)
        _ = try await store.appendMessage(.user("Tuition payment due Friday."), toConversationID: conversation.id)

        #expect(try await store.searchMessages(matching: "TUITION", limit: 10).count == 1)
        #expect(try await store.searchMessages(matching: "   ", limit: 10).isEmpty)
        #expect(try await store.searchMessages(matching: "nonexistent", limit: 10).isEmpty)
    }

    @Test("An excerpt shows the match with surrounding context and ellipses")
    func excerptWindow() {
        let long = String(repeating: "padding ", count: 40) + "garage renovation " + String(repeating: "tail ", count: 40)
        let excerpt = SwiftDataConversationStore.excerpt(from: long, around: "garage", radius: 20)

        #expect(excerpt.contains("garage"))
        #expect(excerpt.hasPrefix("…"))
        #expect(excerpt.hasSuffix("…"))
        #expect(excerpt.count < long.count)
    }

    @Test("An excerpt with no match falls back to the opening text")
    func excerptFallback() {
        let excerpt = SwiftDataConversationStore.excerpt(from: "Nothing relevant here", around: "zzz", radius: 5)
        #expect(!excerpt.isEmpty)
        #expect(excerpt.hasPrefix("Nothing"))
    }
}
