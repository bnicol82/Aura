import Foundation
import SwiftData

/// Something the extractor thinks might be worth remembering, before it becomes a `MemoryItem` (§17).
///
/// Candidates are persisted rather than kept in memory for one reason: when "Ask before saving" is
/// on, the user might not answer for hours or days, and the pending queue has to survive the app
/// being killed. When the setting is off, an accepted candidate is written and resolved in the same
/// turn — the row still gets stored, which gives the Activity screen an honest audit trail of what
/// AURA proposed versus what it kept.
@Model
final class MemoryCandidate {
    var id: UUID = UUID()

    var content: String = ""
    var categoryRaw: String = MemoryCategory.other.rawValue
    var memoryTypeRaw: String = MemoryType.semantic.rawValue

    var importance: Double = 0
    var confidence: Double = AuraDefaults.Confidence.inferred

    var retentionRecommendationRaw: String = RetentionRecommendation.archiveOnly.rawValue
    var statusRaw: String = MemoryCandidateStatus.awaitingReview.rawValue

    /// Plain-language justification shown in the review sheet: "You said to remember this",
    /// "This looks like a lasting preference". Not model reasoning — a category label (§36).
    var reasonForRetention: String = ""

    /// Was this produced by an explicit "remember that…" instruction? (§19)
    var wasExplicitlyRequested: Bool = false

    // MARK: Where it came from and where it would go

    var sourceConversationID: UUID?
    var sourceMessageID: UUID?
    /// Which structured field this would update, when the extractor can tell.
    var suggestedProfileFactKey: String?
    var suggestedPersonID: UUID?
    var suggestedPersonName: String?
    var suggestedProjectID: UUID?
    var suggestedProjectName: String?
    /// The current memory this would correct or replace (§23).
    var supersedesMemoryID: UUID?

    var entities: [String] = []
    var tags: [String] = []

    /// Set once accepted, linking the candidate to what it became.
    var resultingMemoryID: UUID?

    var createdAt: Date = Date()
    var resolvedAt: Date?

    init(
        content: String = "",
        category: MemoryCategory = .other,
        memoryType: MemoryType = .semantic,
        importance: Double = 0,
        confidence: Double = AuraDefaults.Confidence.inferred,
        retentionRecommendation: RetentionRecommendation = .archiveOnly,
        reasonForRetention: String = "",
        wasExplicitlyRequested: Bool = false,
        createdAt: Date = Date()
    ) {
        self.content = content
        self.categoryRaw = category.rawValue
        self.memoryTypeRaw = memoryType.rawValue
        self.importance = importance.clamped(to: 0...1)
        self.confidence = confidence.clamped(to: 0...1)
        self.retentionRecommendationRaw = retentionRecommendation.rawValue
        self.reasonForRetention = reasonForRetention
        self.wasExplicitlyRequested = wasExplicitlyRequested
        self.createdAt = createdAt
    }

    var category: MemoryCategory {
        get { MemoryCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var memoryType: MemoryType {
        get { MemoryType(rawValue: memoryTypeRaw) ?? .semantic }
        set { memoryTypeRaw = newValue.rawValue }
    }

    var retentionRecommendation: RetentionRecommendation {
        get { RetentionRecommendation(rawValue: retentionRecommendationRaw) ?? .archiveOnly }
        set { retentionRecommendationRaw = newValue.rawValue }
    }

    var status: MemoryCandidateStatus {
        get { MemoryCandidateStatus(rawValue: statusRaw) ?? .awaitingReview }
        set { statusRaw = newValue.rawValue }
    }

    var snapshot: MemoryCandidateSnapshot {
        MemoryCandidateSnapshot(
            id: id,
            content: content,
            category: category,
            memoryType: memoryType,
            importance: importance,
            confidence: confidence,
            retentionRecommendation: retentionRecommendation,
            status: status,
            reasonForRetention: reasonForRetention,
            wasExplicitlyRequested: wasExplicitlyRequested,
            sourceConversationID: sourceConversationID,
            sourceMessageID: sourceMessageID,
            suggestedProfileFactKey: suggestedProfileFactKey,
            suggestedPersonID: suggestedPersonID,
            suggestedPersonName: suggestedPersonName,
            suggestedProjectID: suggestedProjectID,
            suggestedProjectName: suggestedProjectName,
            supersedesMemoryID: supersedesMemoryID,
            entities: entities,
            tags: tags,
            resultingMemoryID: resultingMemoryID,
            createdAt: createdAt,
            resolvedAt: resolvedAt
        )
    }
}

struct MemoryCandidateSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: UUID
    var content: String
    var category: MemoryCategory
    var memoryType: MemoryType
    var importance: Double
    var confidence: Double
    var retentionRecommendation: RetentionRecommendation
    var status: MemoryCandidateStatus
    var reasonForRetention: String
    var wasExplicitlyRequested: Bool
    var sourceConversationID: UUID?
    var sourceMessageID: UUID?
    var suggestedProfileFactKey: String?
    var suggestedPersonID: UUID?
    var suggestedPersonName: String?
    var suggestedProjectID: UUID?
    var suggestedProjectName: String?
    var supersedesMemoryID: UUID?
    var entities: [String]
    var tags: [String]
    var resultingMemoryID: UUID?
    var createdAt: Date
    var resolvedAt: Date?

    init(
        id: UUID = UUID(),
        content: String = "",
        category: MemoryCategory = .other,
        memoryType: MemoryType = .semantic,
        importance: Double = 0,
        confidence: Double = AuraDefaults.Confidence.inferred,
        retentionRecommendation: RetentionRecommendation = .archiveOnly,
        status: MemoryCandidateStatus = .awaitingReview,
        reasonForRetention: String = "",
        wasExplicitlyRequested: Bool = false,
        sourceConversationID: UUID? = nil,
        sourceMessageID: UUID? = nil,
        suggestedProfileFactKey: String? = nil,
        suggestedPersonID: UUID? = nil,
        suggestedPersonName: String? = nil,
        suggestedProjectID: UUID? = nil,
        suggestedProjectName: String? = nil,
        supersedesMemoryID: UUID? = nil,
        entities: [String] = [],
        tags: [String] = [],
        resultingMemoryID: UUID? = nil,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.content = content
        self.category = category
        self.memoryType = memoryType
        self.importance = importance
        self.confidence = confidence
        self.retentionRecommendation = retentionRecommendation
        self.status = status
        self.reasonForRetention = reasonForRetention
        self.wasExplicitlyRequested = wasExplicitlyRequested
        self.sourceConversationID = sourceConversationID
        self.sourceMessageID = sourceMessageID
        self.suggestedProfileFactKey = suggestedProfileFactKey
        self.suggestedPersonID = suggestedPersonID
        self.suggestedPersonName = suggestedPersonName
        self.suggestedProjectID = suggestedProjectID
        self.suggestedProjectName = suggestedProjectName
        self.supersedesMemoryID = supersedesMemoryID
        self.entities = entities
        self.tags = tags
        self.resultingMemoryID = resultingMemoryID
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}
