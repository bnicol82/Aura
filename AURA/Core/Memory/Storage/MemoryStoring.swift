import Foundation

/// A memory about to be written.
///
/// Separate from `MemorySnapshot` because a draft has no identity or history yet, and because
/// `supersedesMemoryID` only makes sense at creation time — that is the moment a correction replaces
/// what came before (§23).
struct MemoryDraft: Sendable, Equatable {
    var content: String
    var summary: String?
    var memoryType: MemoryType
    var category: MemoryCategory
    var importance: Double
    var confidence: Double
    var wasExplicitlyRequested: Bool

    var sourceConversationID: UUID?
    var sourceMessageIDs: [UUID]
    var relatedPersonIDs: [UUID]
    var relatedProjectIDs: [UUID]
    var relatedTaskIDs: [UUID]

    var tags: [String]
    var entities: [String]

    var isPinned: Bool
    var expiresAt: Date?
    /// The current memory this replaces. The old row is kept and marked superseded, never deleted.
    var supersedesMemoryID: UUID?

    init(
        content: String,
        summary: String? = nil,
        memoryType: MemoryType = .semantic,
        category: MemoryCategory = .other,
        importance: Double = AuraDefaults.ImportanceThreshold.episodic,
        confidence: Double = AuraDefaults.Confidence.explicit,
        wasExplicitlyRequested: Bool = false,
        sourceConversationID: UUID? = nil,
        sourceMessageIDs: [UUID] = [],
        relatedPersonIDs: [UUID] = [],
        relatedProjectIDs: [UUID] = [],
        relatedTaskIDs: [UUID] = [],
        tags: [String] = [],
        entities: [String] = [],
        isPinned: Bool = false,
        expiresAt: Date? = nil,
        supersedesMemoryID: UUID? = nil
    ) {
        self.content = content
        self.summary = summary
        self.memoryType = memoryType
        self.category = category
        self.importance = importance.clamped(to: 0...1)
        self.confidence = confidence.clamped(to: 0...1)
        self.wasExplicitlyRequested = wasExplicitlyRequested
        self.sourceConversationID = sourceConversationID
        self.sourceMessageIDs = sourceMessageIDs
        self.relatedPersonIDs = relatedPersonIDs
        self.relatedProjectIDs = relatedProjectIDs
        self.relatedTaskIDs = relatedTaskIDs
        self.tags = tags
        self.entities = entities
        self.isPinned = isPinned
        self.expiresAt = expiresAt
        self.supersedesMemoryID = supersedesMemoryID
    }
}

/// A partial edit to a stored memory. Double optionals mean "leave alone" vs "clear".
struct MemoryMutation: Sendable, Equatable {
    var content: String?
    var summary: String?
    var memoryType: MemoryType?
    var category: MemoryCategory?
    var importance: Double?
    var confidence: Double?
    var tags: [String]?
    var entities: [String]?
    var relatedPersonIDs: [UUID]?
    var relatedProjectIDs: [UUID]?
    var isPinned: Bool?
    var isArchived: Bool?
    var expiresAt: Date??

    init() {}

    var isEmpty: Bool { self == MemoryMutation() }
}

/// How memories are ordered when a query does not rank them.
enum MemorySortOrder: Sendable, Equatable {
    case newestFirst
    case oldestFirst
    case mostImportantFirst
    case recentlyUsedFirst
}

/// A memory search (§30).
///
/// Note what is *not* here: no way to ask for "everything". The narrowest query a caller can express
/// is still bounded by `limit`, because §28's privacy argument depends on retrieval being selective
/// rather than exhaustive.
struct MemoryQuery: Sendable, Equatable {
    /// The user's words, or a rewritten retrieval query.
    var text: String?
    /// Entities to match — names, places, products. Contributes its own term to the ranking.
    var entities: [String]
    var categories: Set<MemoryCategory>
    var memoryTypes: Set<MemoryType>
    var personIDs: Set<UUID>
    var projectIDs: Set<UUID>
    var conversationID: UUID?
    var minimumImportance: Double?
    var createdAfter: Date?
    var createdBefore: Date?
    var includePinnedRegardlessOfMatch: Bool
    /// Superseded and archived memories are excluded unless a caller is auditing history (§23).
    var includeSuperseded: Bool
    var includeArchived: Bool
    var sortOrder: MemorySortOrder
    var limit: Int

    init(
        text: String? = nil,
        entities: [String] = [],
        categories: Set<MemoryCategory> = [],
        memoryTypes: Set<MemoryType> = [],
        personIDs: Set<UUID> = [],
        projectIDs: Set<UUID> = [],
        conversationID: UUID? = nil,
        minimumImportance: Double? = nil,
        createdAfter: Date? = nil,
        createdBefore: Date? = nil,
        includePinnedRegardlessOfMatch: Bool = false,
        includeSuperseded: Bool = false,
        includeArchived: Bool = false,
        sortOrder: MemorySortOrder = .newestFirst,
        limit: Int = AuraDefaults.RetrievalBudget.memories
    ) {
        self.text = text
        self.entities = entities
        self.categories = categories
        self.memoryTypes = memoryTypes
        self.personIDs = personIDs
        self.projectIDs = projectIDs
        self.conversationID = conversationID
        self.minimumImportance = minimumImportance
        self.createdAfter = createdAfter
        self.createdBefore = createdBefore
        self.includePinnedRegardlessOfMatch = includePinnedRegardlessOfMatch
        self.includeSuperseded = includeSuperseded
        self.includeArchived = includeArchived
        self.sortOrder = sortOrder
        self.limit = max(1, limit)
    }

    /// `true` when nothing narrows this query but the limit — a plain browse, not a search.
    var isUnfiltered: Bool {
        (text?.isEmpty ?? true)
            && entities.isEmpty
            && categories.isEmpty
            && memoryTypes.isEmpty
            && personIDs.isEmpty
            && projectIDs.isEmpty
            && conversationID == nil
            && minimumImportance == nil
            && createdAfter == nil
            && createdBefore == nil
    }
}

/// Durable memory storage (§15, §16).
///
/// Implemented by a `@ModelActor` over SwiftData. Everything crossing the boundary is a `Sendable`
/// value type: SwiftData's `PersistentModel` is not `Sendable`, and passing model objects between
/// actors is the single most common way to corrupt a SwiftData app under Swift 6. Snapshots in,
/// snapshots out, no exceptions.
protocol MemoryStoring: Sendable {

    // MARK: Writing

    /// Writes a memory. When `draft.supersedesMemoryID` is set, the old row is marked superseded in
    /// the same transaction so there is never a moment with two current versions of one fact.
    func save(_ draft: MemoryDraft) async throws -> MemorySnapshot

    func update(id: UUID, with mutation: MemoryMutation) async throws -> MemorySnapshot

    /// Marks `id` superseded by a newly written memory. The correction path for §23.
    func supersede(id: UUID, with draft: MemoryDraft) async throws -> MemorySnapshot

    /// Hard delete — the "forget that" path (§24). Irreversible by design: a user who asks AURA to
    /// forget something must not find it still in the store.
    func delete(ids: [UUID]) async throws

    /// Soft-hides without deleting. Used when the user archives rather than forgets.
    func setArchived(_ archived: Bool, ids: [UUID]) async throws

    func setPinned(_ pinned: Bool, ids: [UUID]) async throws

    /// Removes memories whose `expiresAt` has passed. Called on launch, not on a timer.
    @discardableResult
    func pruneExpired(asOf date: Date) async throws -> Int

    // MARK: Reading

    func memory(id: UUID) async throws -> MemorySnapshot?

    func memories(ids: [UUID]) async throws -> [MemorySnapshot]

    /// Filtered fetch. Ranking is `MemoryRetrieving`'s job, not this one's.
    func search(_ query: MemoryQuery) async throws -> [MemorySnapshot]

    func count(matching query: MemoryQuery) async throws -> Int

    /// Records that these memories were used, feeding the recency and frequency ranking terms.
    func recordAccess(ids: [UUID], at date: Date) async

    // MARK: Wholesale

    /// Deletes every memory. Backs "Clear all memory" in Settings (§48) and must be confirmed by the
    /// caller before it is reached.
    func deleteAllMemories() async throws
}
