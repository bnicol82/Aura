import Foundation
import SwiftData

/// One thing AURA remembers (§16).
///
/// A memory is deliberately more than text. `importance` decides whether it is durable at all
/// (§18), `confidence` decides whether AURA may state it as fact (§22), `supersededByMemoryID`
/// makes corrections non-destructive (§23), and `expiresAt` lets temporary context evaporate
/// instead of accumulating forever.
///
/// Cross-entity links are stored as ID arrays rather than SwiftData relationships. Memories point at
/// people, projects, conversations and messages; wiring all of those as relationships would create a
/// dense, cyclic graph that is slow to fault and awkward to mirror to CloudKit. IDs keep the graph
/// shallow, and the retrieval engine resolves them in one batched pass.
@Model
final class MemoryItem {
    var id: UUID = UUID()

    /// The memory as AURA would state it, in the third person: "The user is holding off on the
    /// garage renovation until October."
    var content: String = ""
    /// Short label for lists and cards.
    var summary: String = ""

    var memoryTypeRaw: String = MemoryType.semantic.rawValue
    var categoryRaw: String = MemoryCategory.other.rawValue

    /// 0...1 — how much this deserves durable storage (§18).
    var importance: Double = AuraDefaults.ImportanceThreshold.episodic
    /// 0...1 — how sure we are it is true (§22).
    var confidence: Double = AuraDefaults.Confidence.explicit

    // MARK: Provenance

    var sourceConversationID: UUID?
    var sourceMessageIDs: [UUID] = []
    /// `true` when the user said "remember this" outright, which outranks scoring (§19).
    var wasExplicitlyRequested: Bool = false

    // MARK: Links

    var relatedPersonIDs: [UUID] = []
    var relatedProjectIDs: [UUID] = []
    var relatedTaskIDs: [UUID] = []

    // MARK: Search

    var tags: [String] = []
    /// Named entities the extractor found — people, places, organisations, products. Used for the
    /// entity-match term of the ranking function (§30).
    var entities: [String] = []
    /// Flat lower-cased haystack: content, summary, tags and entities. The only column V1 keyword
    /// search predicates against, because `#Predicate` cannot look inside `[String]`.
    var searchText: String = ""

    /// Identifier of this memory's vector in the embedding index. Nothing reads it in V1 — it exists
    /// so V2's semantic search can backfill without a schema migration (§31).
    var embeddingReference: String?

    // MARK: Lifecycle

    var isPinned: Bool = false
    var isArchived: Bool = false
    /// Temporary context disappears on its own rather than being pruned by hand.
    var expiresAt: Date?
    /// Set when a correction replaced this memory. The old row stays for audit but is never
    /// retrieved as current (§23).
    var supersededByMemoryID: UUID?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastAccessedAt: Date?
    var accessCount: Int = 0

    init(
        content: String = "",
        summary: String = "",
        memoryType: MemoryType = .semantic,
        category: MemoryCategory = .other,
        importance: Double = AuraDefaults.ImportanceThreshold.episodic,
        confidence: Double = AuraDefaults.Confidence.explicit,
        createdAt: Date = Date()
    ) {
        let resolvedSummary = summary.isEmpty ? Self.derivedSummary(from: content) : summary
        self.content = content
        self.summary = resolvedSummary
        self.memoryTypeRaw = memoryType.rawValue
        self.categoryRaw = category.rawValue
        self.importance = importance.clamped(to: 0...1)
        self.confidence = confidence.clamped(to: 0...1)
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.searchText = Self.searchText(content: content, summary: resolvedSummary, tags: [], entities: [])
    }

    var memoryType: MemoryType {
        get { MemoryType(rawValue: memoryTypeRaw) ?? .semantic }
        set { memoryTypeRaw = newValue.rawValue }
    }

    var category: MemoryCategory {
        get { MemoryCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    /// A memory is *current* when nothing has replaced it, it is not archived, and it has not
    /// expired. Only current memories may be retrieved into model context.
    func isCurrent(at reference: Date = Date()) -> Bool {
        guard supersededByMemoryID == nil, !isArchived else { return false }
        if let expiresAt, expiresAt <= reference { return false }
        return true
    }

    /// Whether this memory should survive automatic pruning.
    var isDurable: Bool {
        isPinned
            || wasExplicitlyRequested
            || importance >= AuraDefaults.ImportanceThreshold.durable
            || memoryType.isDurableByDefault
    }

    func refreshSearchText() {
        searchText = Self.searchText(content: content, summary: summary, tags: tags, entities: entities)
    }

    /// Records a retrieval. Access counts feed the ranking function, so frequently useful memories
    /// surface faster over time.
    func noteAccess(at date: Date = Date()) {
        lastAccessedAt = date
        accessCount += 1
    }

    static func derivedSummary(from content: String, limit: Int = 72) -> String {
        let collapsed = content
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let clipped = collapsed.prefix(limit)
        if let lastSpace = clipped.lastIndex(of: " ") {
            return String(clipped[clipped.startIndex..<lastSpace]) + "…"
        }
        return String(clipped) + "…"
    }

    private static func searchText(
        content: String,
        summary: String,
        tags: [String],
        entities: [String]
    ) -> String {
        ([content, summary] + tags + entities)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    var snapshot: MemorySnapshot {
        MemorySnapshot(
            id: id,
            content: content,
            summary: summary,
            memoryType: memoryType,
            category: category,
            importance: importance,
            confidence: confidence,
            sourceConversationID: sourceConversationID,
            sourceMessageIDs: sourceMessageIDs,
            wasExplicitlyRequested: wasExplicitlyRequested,
            relatedPersonIDs: relatedPersonIDs,
            relatedProjectIDs: relatedProjectIDs,
            relatedTaskIDs: relatedTaskIDs,
            tags: tags,
            entities: entities,
            embeddingReference: embeddingReference,
            isPinned: isPinned,
            isArchived: isArchived,
            expiresAt: expiresAt,
            supersededByMemoryID: supersededByMemoryID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastAccessedAt: lastAccessedAt,
            accessCount: accessCount
        )
    }
}

/// An immutable read of a memory. Everything outside the store actor works with this.
struct MemorySnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: UUID
    var content: String
    var summary: String
    var memoryType: MemoryType
    var category: MemoryCategory
    var importance: Double
    var confidence: Double
    var sourceConversationID: UUID?
    var sourceMessageIDs: [UUID]
    var wasExplicitlyRequested: Bool
    var relatedPersonIDs: [UUID]
    var relatedProjectIDs: [UUID]
    var relatedTaskIDs: [UUID]
    var tags: [String]
    var entities: [String]
    var embeddingReference: String?
    var isPinned: Bool
    var isArchived: Bool
    var expiresAt: Date?
    var supersededByMemoryID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date?
    var accessCount: Int

    init(
        id: UUID = UUID(),
        content: String = "",
        summary: String = "",
        memoryType: MemoryType = .semantic,
        category: MemoryCategory = .other,
        importance: Double = AuraDefaults.ImportanceThreshold.episodic,
        confidence: Double = AuraDefaults.Confidence.explicit,
        sourceConversationID: UUID? = nil,
        sourceMessageIDs: [UUID] = [],
        wasExplicitlyRequested: Bool = false,
        relatedPersonIDs: [UUID] = [],
        relatedProjectIDs: [UUID] = [],
        relatedTaskIDs: [UUID] = [],
        tags: [String] = [],
        entities: [String] = [],
        embeddingReference: String? = nil,
        isPinned: Bool = false,
        isArchived: Bool = false,
        expiresAt: Date? = nil,
        supersededByMemoryID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastAccessedAt: Date? = nil,
        accessCount: Int = 0
    ) {
        self.id = id
        self.content = content
        self.summary = summary.isEmpty ? MemoryItem.derivedSummary(from: content) : summary
        self.memoryType = memoryType
        self.category = category
        self.importance = importance
        self.confidence = confidence
        self.sourceConversationID = sourceConversationID
        self.sourceMessageIDs = sourceMessageIDs
        self.wasExplicitlyRequested = wasExplicitlyRequested
        self.relatedPersonIDs = relatedPersonIDs
        self.relatedProjectIDs = relatedProjectIDs
        self.relatedTaskIDs = relatedTaskIDs
        self.tags = tags
        self.entities = entities
        self.embeddingReference = embeddingReference
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.expiresAt = expiresAt
        self.supersededByMemoryID = supersededByMemoryID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessedAt = lastAccessedAt
        self.accessCount = accessCount
    }

    func isCurrent(at reference: Date = Date()) -> Bool {
        guard supersededByMemoryID == nil, !isArchived else { return false }
        if let expiresAt, expiresAt <= reference { return false }
        return true
    }

    /// How this memory reads inside a model prompt. Low-confidence memories are hedged so the model
    /// cannot restate a guess as a fact (§22, §78).
    var contextLine: String {
        if confidence < AuraDefaults.Confidence.inferred {
            return "\(content) (the user was tentative about this — do not state it as certain)"
        }
        return content
    }
}
