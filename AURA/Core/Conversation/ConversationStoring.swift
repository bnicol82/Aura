import Foundation

/// Persists conversations and their turns (§32).
///
/// Conversations are also the deepest layer of memory — the archive that low-importance turns fall
/// into rather than being discarded (§15). A question about "what were we talking about yesterday"
/// is answered from here, not from `MemoryStoring`.
protocol ConversationStoring: Sendable {

    // MARK: Conversations

    /// Creates a conversation. `title` is derived from the first message when omitted.
    @discardableResult
    func createConversation(title: String?, at date: Date) async throws -> ConversationSnapshot

    func conversation(id: UUID) async throws -> ConversationSnapshot?

    /// Most recent first, excluding archived unless asked.
    func recentConversations(limit: Int, includeArchived: Bool) async throws -> [ConversationSnapshot]

    /// The conversation to continue on launch, or `nil` if the last one is stale or absent.
    ///
    /// "Stale" is a product decision, not a technical one: picking up a thread from three days ago
    /// makes the assistant feel confused rather than continuous, so `staleAfter` bounds it.
    func mostRecentActiveConversation(staleAfter interval: TimeInterval, now: Date) async throws -> ConversationSnapshot?

    func renameConversation(id: UUID, title: String) async throws
    func setConversationArchived(_ archived: Bool, id: UUID) async throws
    func setConversationPinned(_ pinned: Bool, id: UUID) async throws
    func updateSummary(_ summary: String?, conversationID: UUID) async throws
    func deleteConversations(ids: [UUID]) async throws

    /// Backs "Clear conversation history" (§48). Leaves memories intact — the user asked to forget
    /// the transcript, not what AURA learned from it.
    func deleteAllConversations() async throws

    // MARK: Messages

    @discardableResult
    func appendMessage(
        _ draft: MessageDraft,
        toConversationID conversationID: UUID
    ) async throws -> MessageSnapshot

    /// Replaces a message's text. Used while streaming, to grow the in-flight assistant turn.
    func updateMessage(
        id: UUID,
        content: String?,
        toolActivity: [ToolActivityNote]?,
        isFailure: Bool?,
        usage: ModelUsage?
    ) async throws

    func messages(inConversationID conversationID: UUID) async throws -> [MessageSnapshot]

    /// The last `limit` visible turns — the working-memory window (§15).
    func workingMemory(conversationID: UUID, limit: Int) async throws -> [MessageSnapshot]

    func markMemoryCandidateStatus(_ status: MemoryCandidateStatus, messageID: UUID) async throws

    func deleteMessages(ids: [UUID]) async throws

    // MARK: Archive search

    /// Keyword search over the whole transcript archive (§30).
    func searchMessages(matching text: String, limit: Int) async throws -> [ConversationSearchHit]
}

/// A message about to be written.
struct MessageDraft: Sendable, Equatable {
    var role: MessageRole
    var content: String
    var toolActivity: [ToolActivityNote]
    var providerIdentifier: String?
    var isFailure: Bool
    var usage: ModelUsage?
    var createdAt: Date
    /// Supplied so a caller that already generated an id can reference the row before it is written.
    var id: UUID

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        toolActivity: [ToolActivityNote] = [],
        providerIdentifier: String? = nil,
        isFailure: Bool = false,
        usage: ModelUsage? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolActivity = toolActivity
        self.providerIdentifier = providerIdentifier
        self.isFailure = isFailure
        self.usage = usage
        self.createdAt = createdAt
    }

    static func user(_ content: String, at date: Date = Date()) -> MessageDraft {
        MessageDraft(role: .user, content: content, createdAt: date)
    }

    static func assistant(
        _ content: String,
        providerIdentifier: String? = nil,
        at date: Date = Date()
    ) -> MessageDraft {
        MessageDraft(
            role: .assistant,
            content: content,
            providerIdentifier: providerIdentifier,
            createdAt: date
        )
    }

    /// A turn that records a failure. Never presented as an answer (§69, §78).
    static func failure(_ message: String, at date: Date = Date()) -> MessageDraft {
        MessageDraft(role: .assistant, content: message, isFailure: true, createdAt: date)
    }
}

/// A hit from searching the conversation archive.
struct ConversationSearchHit: Sendable, Equatable, Identifiable, Hashable {
    var message: MessageSnapshot
    var conversationID: UUID
    var conversationTitle: String
    /// The matching text with a little surrounding context, for the result row.
    var excerpt: String

    var id: UUID { message.id }
}
