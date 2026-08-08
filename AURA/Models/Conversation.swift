import Foundation
import SwiftData

/// A conversation thread (§32).
@Model
final class Conversation {
    var id: UUID = UUID()

    /// Auto-titled from the first user message until the user renames it.
    var title: String = ""
    /// Rolling summary of turns that have aged out of working memory, so long threads stay usable
    /// without replaying the whole transcript into the model.
    var summary: String?

    var isArchived: Bool = false
    var isPinned: Bool = false

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message]?

    init(title: String = "", createdAt: Date = Date()) {
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Messages in send order. SwiftData does not guarantee relationship ordering, so never rely on
    /// the stored array's order — sort by `createdAt` and break ties by `sequence`.
    var orderedMessages: [Message] {
        (messages ?? []).sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.sequence < rhs.sequence : lhs.createdAt < rhs.createdAt
        }
    }

    /// Messages that belong in the transcript UI — system and tool rows are internal.
    var visibleMessages: [Message] {
        orderedMessages.filter { $0.role == .user || $0.role == .assistant }
    }

    var lastMessage: Message? { orderedMessages.last }

    /// A display title, derived if the user never set one.
    var resolvedTitle: String {
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        if let first = visibleMessages.first(where: { $0.role == .user }) {
            return Self.derivedTitle(from: first.content)
        }
        return "New conversation"
    }

    /// First clause of the opening message, capped so it fits a list row.
    static func derivedTitle(from content: String, limit: Int = 48) -> String {
        let collapsed = content
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "New conversation" }
        if collapsed.count <= limit { return collapsed }
        let clipped = collapsed.prefix(limit)
        if let lastSpace = clipped.lastIndex(of: " ") {
            return String(clipped[clipped.startIndex..<lastSpace]) + "…"
        }
        return String(clipped) + "…"
    }

    /// The most recent turns, which is what "working memory" means in §15.
    func workingMemory(limit: Int = AuraDefaults.workingMemoryTurnLimit) -> [Message] {
        let visible = visibleMessages
        return Array(visible.suffix(limit))
    }

    var snapshot: ConversationSnapshot {
        ConversationSnapshot(
            id: id,
            title: resolvedTitle,
            summary: summary,
            isArchived: isArchived,
            isPinned: isPinned,
            messageCount: messages?.count ?? 0,
            lastMessagePreview: lastMessage?.content,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

/// One turn in a conversation (§32).
@Model
final class Message {
    var id: UUID = UUID()

    var roleRaw: String = MessageRole.user.rawValue
    var content: String = ""

    /// Monotonic tie-breaker within a conversation. Two messages can share a `Date` when a reply is
    /// written immediately after the request, and CloudKit can reorder arrivals; this keeps the
    /// transcript stable.
    var sequence: Int = 0

    var createdAt: Date = Date()

    /// JSON describing tool activity attached to this turn, rendered as progress rows in the
    /// transcript ("Checking your calendar…"). Never contains reasoning (§36).
    var toolActivityJSON: String?

    /// Where this reply came from, so the transcript can be honest about on-device vs cloud.
    var providerIdentifier: String?

    /// Whether the extractor has looked at this message yet.
    var memoryCandidateStatusRaw: String = MemoryCandidateStatus.notEvaluated.rawValue

    /// Set when this row records a failure rather than a reply, so the UI can style it and the
    /// orchestrator never counts it as a successful answer (§78).
    var isFailure: Bool = false

    /// Token accounting for the cost controls in §67. `nil` when the provider does not report it.
    var promptTokens: Int?
    var responseTokens: Int?

    var conversation: Conversation?

    init(
        role: MessageRole = .user,
        content: String = "",
        sequence: Int = 0,
        createdAt: Date = Date()
    ) {
        self.roleRaw = role.rawValue
        self.content = content
        self.sequence = sequence
        self.createdAt = createdAt
    }

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    var memoryCandidateStatus: MemoryCandidateStatus {
        get { MemoryCandidateStatus(rawValue: memoryCandidateStatusRaw) ?? .notEvaluated }
        set { memoryCandidateStatusRaw = newValue.rawValue }
    }

    var toolActivity: [ToolActivityNote] {
        get {
            guard let toolActivityJSON,
                  let data = toolActivityJSON.data(using: .utf8),
                  let notes = try? JSONDecoder().decode([ToolActivityNote].self, from: data)
            else { return [] }
            return notes
        }
        set {
            guard !newValue.isEmpty else {
                toolActivityJSON = nil
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(newValue) else {
                toolActivityJSON = nil
                return
            }
            toolActivityJSON = String(decoding: data, as: UTF8.self)
        }
    }

    var snapshot: MessageSnapshot {
        MessageSnapshot(
            id: id,
            conversationID: conversation?.id,
            role: role,
            content: content,
            sequence: sequence,
            createdAt: createdAt,
            toolActivity: toolActivity,
            providerIdentifier: providerIdentifier,
            memoryCandidateStatus: memoryCandidateStatus,
            isFailure: isFailure
        )
    }
}

/// A user-visible note about something AURA did during a turn.
///
/// This is the *only* channel between the agent loop and the transcript. It carries actions, never
/// chain-of-thought (§36, §43).
struct ToolActivityNote: Sendable, Equatable, Codable, Hashable, Identifiable {
    var id: UUID
    var toolName: String
    /// Present-tense progress line, e.g. "Checking your calendar".
    var label: String
    var succeeded: Bool
    /// Short outcome, e.g. "Created reminder “Order air filter”". Never raw tool payloads.
    var outcome: String?

    init(
        id: UUID = UUID(),
        toolName: String,
        label: String,
        succeeded: Bool = true,
        outcome: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.label = label
        self.succeeded = succeeded
        self.outcome = outcome
    }
}

// MARK: - Snapshots

struct MessageSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: UUID
    var conversationID: UUID?
    var role: MessageRole
    var content: String
    var sequence: Int
    var createdAt: Date
    var toolActivity: [ToolActivityNote]
    var providerIdentifier: String?
    var memoryCandidateStatus: MemoryCandidateStatus
    var isFailure: Bool

    init(
        id: UUID = UUID(),
        conversationID: UUID? = nil,
        role: MessageRole = .user,
        content: String = "",
        sequence: Int = 0,
        createdAt: Date = Date(),
        toolActivity: [ToolActivityNote] = [],
        providerIdentifier: String? = nil,
        memoryCandidateStatus: MemoryCandidateStatus = .notEvaluated,
        isFailure: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.sequence = sequence
        self.createdAt = createdAt
        self.toolActivity = toolActivity
        self.providerIdentifier = providerIdentifier
        self.memoryCandidateStatus = memoryCandidateStatus
        self.isFailure = isFailure
    }
}

struct ConversationSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var summary: String?
    var isArchived: Bool
    var isPinned: Bool
    var messageCount: Int
    var lastMessagePreview: String?
    var createdAt: Date
    var updatedAt: Date
}
