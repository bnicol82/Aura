import Foundation
import SwiftData

/// SwiftData-backed `ConversationStoring`.
///
/// The transcript is also the deepest layer of memory (§15) — the archive that low-importance turns
/// fall into rather than being discarded — so this store is what answers "what were we talking about
/// yesterday?" long before the memory system exists.
@ModelActor
actor SwiftDataConversationStore: ConversationStoring {

    // MARK: - Conversations

    @discardableResult
    func createConversation(title: String? = nil, at date: Date = Date()) async throws -> ConversationSnapshot {
        let conversation = Conversation(title: title?.normalizedWhitespace ?? "", createdAt: date)
        modelContext.insert(conversation)
        try persist()
        AuraLog.orchestrator.info("Started a new conversation.")
        return conversation.snapshot
    }

    func conversation(id: UUID) async throws -> ConversationSnapshot? {
        try fetchConversation(id: id)?.snapshot
    }

    func recentConversations(
        limit: Int = 25,
        includeArchived: Bool = false
    ) async throws -> [ConversationSnapshot] {
        var descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        if !includeArchived {
            descriptor.predicate = #Predicate { !$0.isArchived }
        }
        descriptor.fetchLimit = max(1, limit)
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    func mostRecentActiveConversation(
        staleAfter interval: TimeInterval,
        now: Date = Date()
    ) async throws -> ConversationSnapshot? {
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let candidate = try modelContext.fetch(descriptor).first else { return nil }

        // Picking up a thread from three days ago makes the assistant feel confused rather than
        // continuous, so a stale conversation is left alone and a fresh one is started instead.
        guard now.timeIntervalSince(candidate.updatedAt) <= interval else { return nil }
        // An empty conversation is always worth continuing — it is where the last one was going to start.
        return candidate.snapshot
    }

    func renameConversation(id: UUID, title: String) async throws {
        guard let conversation = try fetchConversation(id: id) else {
            throw AuraError.recordNotFound(entity: "conversation")
        }
        let normalized = title.normalizedWhitespace
        guard conversation.title != normalized else { return }
        conversation.title = normalized
        conversation.updatedAt = Date()
        try persist()
    }

    func setConversationArchived(_ archived: Bool, id: UUID) async throws {
        guard let conversation = try fetchConversation(id: id) else {
            throw AuraError.recordNotFound(entity: "conversation")
        }
        guard conversation.isArchived != archived else { return }
        conversation.isArchived = archived
        conversation.updatedAt = Date()
        try persist()
    }

    func setConversationPinned(_ pinned: Bool, id: UUID) async throws {
        guard let conversation = try fetchConversation(id: id) else {
            throw AuraError.recordNotFound(entity: "conversation")
        }
        guard conversation.isPinned != pinned else { return }
        conversation.isPinned = pinned
        conversation.updatedAt = Date()
        try persist()
    }

    func updateSummary(_ summary: String?, conversationID: UUID) async throws {
        guard let conversation = try fetchConversation(id: conversationID) else {
            throw AuraError.recordNotFound(entity: "conversation")
        }
        let resolved = summary?.isBlank == true ? nil : summary
        guard conversation.summary != resolved else { return }
        conversation.summary = resolved
        conversation.updatedAt = Date()
        try persist()
    }

    func deleteConversations(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let targets = Array(Set(ids))
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { targets.contains($0.id) }
        )
        // Messages cascade from the relationship's delete rule.
        for conversation in try modelContext.fetch(descriptor) {
            modelContext.delete(conversation)
        }
        try persist()
    }

    func deleteAllConversations() async throws {
        for conversation in try modelContext.fetch(FetchDescriptor<Conversation>()) {
            modelContext.delete(conversation)
        }
        // Orphaned messages should not exist, but a partial earlier failure could leave some behind and
        // an orphan would still surface in archive search.
        for message in try modelContext.fetch(FetchDescriptor<Message>()) {
            modelContext.delete(message)
        }
        try persist()
        AuraLog.orchestrator.notice("Deleted all conversation history at the user's request.")
    }

    // MARK: - Messages

    @discardableResult
    func appendMessage(
        _ draft: MessageDraft,
        toConversationID conversationID: UUID
    ) async throws -> MessageSnapshot {
        guard let conversation = try fetchConversation(id: conversationID) else {
            throw AuraError.recordNotFound(entity: "conversation")
        }

        let message = Message(
            role: draft.role,
            content: draft.content,
            sequence: nextSequence(in: conversation),
            createdAt: draft.createdAt
        )
        // The caller may already have handed this id out — as an in-flight assistant row, say — so it is
        // carried over rather than regenerated.
        message.id = draft.id
        message.toolActivity = draft.toolActivity
        message.providerIdentifier = draft.providerIdentifier
        message.isFailure = draft.isFailure
        message.promptTokens = draft.usage?.promptTokens
        message.responseTokens = draft.usage?.responseTokens
        message.conversation = conversation

        modelContext.insert(message)

        // First user message names the conversation, so history is browsable without an AI call.
        if conversation.title.isBlank, draft.role == .user {
            conversation.title = Conversation.derivedTitle(from: draft.content)
        }
        conversation.updatedAt = draft.createdAt

        try persist()
        return message.snapshot
    }

    func updateMessage(
        id: UUID,
        content: String? = nil,
        toolActivity: [ToolActivityNote]? = nil,
        isFailure: Bool? = nil,
        usage: ModelUsage? = nil
    ) async throws {
        guard let message = try fetchMessage(id: id) else {
            throw AuraError.recordNotFound(entity: "message")
        }

        var changed = false
        if let content, message.content != content {
            message.content = content
            changed = true
        }
        if let toolActivity, message.toolActivity != toolActivity {
            message.toolActivity = toolActivity
            changed = true
        }
        if let isFailure, message.isFailure != isFailure {
            message.isFailure = isFailure
            changed = true
        }
        if let usage {
            message.promptTokens = usage.promptTokens
            message.responseTokens = usage.responseTokens
            changed = true
        }

        guard changed else { return }
        message.conversation?.updatedAt = Date()
        try persist()
    }

    func messages(inConversationID conversationID: UUID) async throws -> [MessageSnapshot] {
        guard let conversation = try fetchConversation(id: conversationID) else {
            throw AuraError.recordNotFound(entity: "conversation")
        }
        return conversation.orderedMessages.map(\.snapshot)
    }

    func workingMemory(
        conversationID: UUID,
        limit: Int = AuraDefaults.workingMemoryTurnLimit
    ) async throws -> [MessageSnapshot] {
        guard let conversation = try fetchConversation(id: conversationID) else {
            throw AuraError.recordNotFound(entity: "conversation")
        }
        // Failed turns are excluded: an error message is a record for the user, not something the model
        // should treat as its own prior answer (§78).
        return conversation
            .workingMemory(limit: limit)
            .filter { !$0.isFailure }
            .map(\.snapshot)
    }

    func markMemoryCandidateStatus(_ status: MemoryCandidateStatus, messageID: UUID) async throws {
        guard let message = try fetchMessage(id: messageID) else {
            throw AuraError.recordNotFound(entity: "message")
        }
        guard message.memoryCandidateStatus != status else { return }
        message.memoryCandidateStatus = status
        try persist()
    }

    func deleteMessages(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let targets = Array(Set(ids))
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { targets.contains($0.id) }
        )
        for message in try modelContext.fetch(descriptor) {
            modelContext.delete(message)
        }
        try persist()
    }

    // MARK: - Archive search

    func searchMessages(matching text: String, limit: Int = 25) async throws -> [ConversationSearchHit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()

        // The coarse filter runs in the store; excerpting and trimming to `limit` run in memory. The
        // over-fetch is deliberate: some matches belong to messages with no conversation or to internal
        // roles, and those are dropped after fetching. If the archive ever outgrows this, the fix is a
        // lower-cased `searchText` column on `Message`, mirroring the one `MemoryItem` already has.
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.content.localizedStandardContains(trimmed) },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit) * 4

        let matches = try modelContext.fetch(descriptor)

        return matches
            .compactMap { message -> ConversationSearchHit? in
                guard let conversation = message.conversation else { return nil }
                guard message.role == .user || message.role == .assistant else { return nil }
                return ConversationSearchHit(
                    message: message.snapshot,
                    conversationID: conversation.id,
                    conversationTitle: conversation.resolvedTitle,
                    excerpt: Self.excerpt(from: message.content, around: needle)
                )
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    /// A window of text around the first match, so a result row shows why it matched.
    static func excerpt(from content: String, around needle: String, radius: Int = 60) -> String {
        let collapsed = content.normalizedWhitespace
        guard let range = collapsed.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(collapsed.prefix(radius * 2))
        }

        let start = collapsed.index(
            range.lowerBound,
            offsetBy: -radius,
            limitedBy: collapsed.startIndex
        ) ?? collapsed.startIndex
        let end = collapsed.index(
            range.upperBound,
            offsetBy: radius,
            limitedBy: collapsed.endIndex
        ) ?? collapsed.endIndex

        var excerpt = String(collapsed[start..<end])
        if start > collapsed.startIndex { excerpt = "…" + excerpt }
        if end < collapsed.endIndex { excerpt += "…" }
        return excerpt
    }

    // MARK: - Internals

    /// The next sequence number in a conversation.
    ///
    /// Timestamps alone are not enough: a reply written in the same millisecond as its request, or two
    /// devices' rows arriving out of order from CloudKit, would both render an ambiguous transcript.
    private func nextSequence(in conversation: Conversation) -> Int {
        ((conversation.messages ?? []).map(\.sequence).max() ?? -1) + 1
    }

    private func fetchConversation(id: UUID) throws -> Conversation? {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchMessage(id: UUID) throws -> Message? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func persist() throws {
        do {
            try modelContext.save()
        } catch {
            AuraLog.storage.error("Failed to save conversation data.")
            throw AuraError.saveFailed(reason: error.localizedDescription)
        }
    }
}
