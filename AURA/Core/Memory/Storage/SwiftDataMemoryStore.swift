import Foundation
import SwiftData

/// SwiftData-backed `MemoryStoring` (§15, §16).
///
/// ### Snapshots in, snapshots out
/// A `@ModelActor` over SwiftData, and nothing but `Sendable` value types crosses its boundary.
/// `PersistentModel` is not `Sendable`, and handing model objects between actors is the most common way to
/// corrupt a SwiftData app under Swift 6. There is no exception to that here, including for reads.
///
/// ### Why filtering happens in Swift rather than in `#Predicate`
/// Most of `MemoryQuery` is expressed against arrays — `entities`, `relatedPersonIDs`, `tags` — and
/// SwiftData cannot compile a predicate that tests membership of a captured collection against a stored
/// array. The fetch narrows on what the store *can* push down (archived, superseded, expiry, dates,
/// importance), then Swift finishes the job. Attempting it all in a predicate is how you get a crash at
/// runtime instead of a compile error, which is strictly worse.
///
/// Bounded on purpose: every query carries a `limit`, and §28's privacy argument depends on retrieval being
/// selective rather than exhaustive. The narrowing is applied *before* the limit so the limit truncates the
/// best matches rather than an arbitrary page.
@ModelActor
actor SwiftDataMemoryStore: MemoryStoring {

    // MARK: - Writing

    @discardableResult
    func save(_ draft: MemoryDraft) async throws -> MemorySnapshot {
        let item = MemoryItem(
            content: draft.content.normalizedWhitespace,
            summary: draft.summary?.normalizedWhitespace ?? "",
            memoryType: draft.memoryType,
            category: draft.category,
            importance: draft.importance,
            confidence: draft.confidence
        )

        apply(draft, to: item)
        modelContext.insert(item)

        // A correction supersedes rather than overwrites (§23): the old value stays, marked, so "what did I
        // used to think" is answerable and a wrong correction is recoverable.
        if let supersededID = draft.supersedesMemoryID,
           let superseded = try fetch(id: supersededID) {
            superseded.supersededByMemoryID = item.id
            superseded.updatedAt = Date()
        }

        try persist()
        return item.snapshot
    }

    func update(id: UUID, with mutation: MemoryMutation) async throws -> MemorySnapshot {
        guard let item = try fetch(id: id) else {
            throw AuraError.recordNotFound(entity: "memory")
        }
        guard !mutation.isEmpty else { return item.snapshot }

        if let content = mutation.content { item.content = content.normalizedWhitespace }
        if let summary = mutation.summary { item.summary = summary.normalizedWhitespace }
        if let memoryType = mutation.memoryType { item.memoryType = memoryType }
        if let category = mutation.category { item.category = category }
        if let importance = mutation.importance { item.importance = importance.clamped(to: 0...1) }
        if let confidence = mutation.confidence { item.confidence = confidence.clamped(to: 0...1) }
        if let tags = mutation.tags { item.tags = tags }
        if let entities = mutation.entities { item.entities = entities }
        if let personIDs = mutation.relatedPersonIDs { item.relatedPersonIDs = personIDs }
        if let projectIDs = mutation.relatedProjectIDs { item.relatedProjectIDs = projectIDs }
        if let isPinned = mutation.isPinned { item.isPinned = isPinned }
        if let isArchived = mutation.isArchived { item.isArchived = isArchived }
        // Doubly optional: the outer layer means "was expiry mentioned", the inner means "should it have
        // one". Flattening them would make clearing an expiry indistinguishable from not touching it.
        if let expiresAt = mutation.expiresAt { item.expiresAt = expiresAt }

        item.refreshSearchText()
        item.updatedAt = Date()
        try persist()
        return item.snapshot
    }

    @discardableResult
    func supersede(id: UUID, with draft: MemoryDraft) async throws -> MemorySnapshot {
        var superseding = draft
        superseding.supersedesMemoryID = id
        return try await save(superseding)
    }

    func delete(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        for item in try fetch(ids: ids) {
            modelContext.delete(item)
        }
        try persist()
        // Count only, never content: §51 forbids personal material at default log privacy.
        AuraLog.memory.info("Deleted \(ids.count, privacy: .public) memory item(s).")
    }

    func setArchived(_ archived: Bool, ids: [UUID]) async throws {
        try setFlag(ids: ids) { $0.isArchived = archived }
    }

    func setPinned(_ pinned: Bool, ids: [UUID]) async throws {
        try setFlag(ids: ids) { $0.isPinned = pinned }
    }

    @discardableResult
    func pruneExpired(asOf date: Date) async throws -> Int {
        // Expiry is the mechanism that stops "for the rest of today" becoming permanent, so it deletes
        // rather than archives — an expired temporary note has no historical value.
        //
        // Filtered in Swift rather than in a `#Predicate`, for the same reason as `fetchCandidates`: a
        // predicate body must be a single expression, so unwrapping an optional `Date` inside one means
        // either a force-unwrap the macro has to translate or a contortion nobody can read. Pruning is
        // maintenance that runs rarely, so fetching and filtering costs nothing that matters.
        let expired = try modelContext.fetch(FetchDescriptor<MemoryItem>()).filter { item in
            guard let expiresAt = item.expiresAt else { return false }
            return expiresAt <= date
        }
        guard !expired.isEmpty else { return 0 }

        for item in expired {
            modelContext.delete(item)
        }
        try persist()
        AuraLog.memory.info("Pruned \(expired.count, privacy: .public) expired memory item(s).")
        return expired.count
    }

    func deleteAllMemories() async throws {
        try modelContext.delete(model: MemoryItem.self)
        try persist()
        AuraLog.memory.notice("Deleted every memory item at the user's request.")
    }

    // MARK: - Reading

    func memory(id: UUID) async throws -> MemorySnapshot? {
        try fetch(id: id)?.snapshot
    }

    func memories(ids: [UUID]) async throws -> [MemorySnapshot] {
        guard !ids.isEmpty else { return [] }
        // Returned in the caller's order: a ranked list of ids must not come back reshuffled by whatever
        // order the store happened to fetch.
        let byID = Dictionary(
            try fetch(ids: ids).map { ($0.id, $0.snapshot) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { byID[$0] }
    }

    func search(_ query: MemoryQuery) async throws -> [MemorySnapshot] {
        let candidates = try fetchCandidates(for: query)
        let matched = Self.narrow(candidates.map(\.snapshot), with: query)
        return Array(Self.sort(matched, by: query.sortOrder).prefix(query.limit))
    }

    func count(matching query: MemoryQuery) async throws -> Int {
        // Deliberately not `prefix(limit)`: a count is "how many exist", and capping it at the page size
        // would make "19 things I know about you" wrong the moment there were twenty.
        let candidates = try fetchCandidates(for: query)
        return Self.narrow(candidates.map(\.snapshot), with: query).count
    }

    func recordAccess(ids: [UUID], at date: Date) async {
        guard !ids.isEmpty else { return }
        do {
            for item in try fetch(ids: ids) {
                item.noteAccess(at: date)
            }
            try persist()
        } catch {
            // Access counts feed ranking, not correctness. Failing to record one must never fail the turn
            // that used the memory.
            AuraLog.memory.debug("Could not record memory access: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Narrowing

    /// Applies the parts of a query SwiftData cannot express, in Swift.
    ///
    /// `static` and pure so every filtering rule is testable without a store. This is where the privacy
    /// promise in §28 is actually kept or broken, so it is the last place that should need a database to
    /// verify.
    static func narrow(_ memories: [MemorySnapshot], with query: MemoryQuery) -> [MemorySnapshot] {
        memories.filter { memory in
            // Pinned material bypasses matching when the caller asked for that, because a pinned memory is
            // the user saying "always consider this".
            if query.includePinnedRegardlessOfMatch && memory.isPinned { return true }

            if !query.categories.isEmpty && !query.categories.contains(memory.category) { return false }
            if !query.memoryTypes.isEmpty && !query.memoryTypes.contains(memory.memoryType) { return false }

            if !query.personIDs.isEmpty {
                guard memory.relatedPersonIDs.contains(where: { query.personIDs.contains($0) }) else {
                    return false
                }
            }
            if !query.projectIDs.isEmpty {
                guard memory.relatedProjectIDs.contains(where: { query.projectIDs.contains($0) }) else {
                    return false
                }
            }
            if let conversationID = query.conversationID, memory.sourceConversationID != conversationID {
                return false
            }

            if !query.entities.isEmpty {
                let haystack = Self.haystack(for: memory)
                guard query.entities.contains(where: { haystack.contains($0.lowercased()) }) else {
                    return false
                }
            }

            if let text = query.text, !text.isBlank {
                // Every word has to appear somewhere, so "garage October" does not match a memory about the
                // garage that says nothing about October. Substring rather than whole-word, because
                // "renovation" should match "renovations".
                let haystack = Self.haystack(for: memory)
                let words = text.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 1 }
                guard !words.isEmpty else { return true }
                guard words.allSatisfy({ haystack.contains($0) }) else { return false }
            }

            return true
        }
    }

    /// Everything about a memory that a text or entity query may match.
    ///
    /// Built from the snapshot rather than read from `MemoryItem.searchText`, because `narrow` works on
    /// snapshots so it stays testable without a store — and a snapshot does not carry the stored index.
    /// Kept in one place so text search and entity search can never drift apart on what they look at.
    static func haystack(for memory: MemorySnapshot) -> String {
        ([memory.content, memory.summary] + memory.tags + memory.entities)
            .joined(separator: " ")
            .lowercased()
    }

    /// Orders results. `static` and pure for the same reason as `narrow`.
    static func sort(_ memories: [MemorySnapshot], by order: MemorySortOrder) -> [MemorySnapshot] {
        switch order {
        case .newestFirst:
            return memories.sorted { $0.createdAt > $1.createdAt }
        case .oldestFirst:
            return memories.sorted { $0.createdAt < $1.createdAt }
        case .mostImportantFirst:
            // Importance first, then recency, so equally important memories still come back in a stable
            // and sensible order rather than whatever the fetch produced.
            return memories.sorted {
                $0.importance == $1.importance
                    ? $0.createdAt > $1.createdAt
                    : $0.importance > $1.importance
            }
        case .recentlyUsedFirst:
            // Never-used memories sort last rather than first, which `nil` would otherwise do.
            return memories.sorted {
                ($0.lastAccessedAt ?? .distantPast) > ($1.lastAccessedAt ?? .distantPast)
            }
        }
    }

    // MARK: - Fetching

    /// Fetches the rows a query could possibly match, narrowing on what SwiftData can push down.
    private func fetchCandidates(for query: MemoryQuery) throws -> [MemoryItem] {
        let includeArchived = query.includeArchived
        let includeSuperseded = query.includeSuperseded
        let now = Date()

        // Optional bounds are collapsed into sentinels *before* the predicate rather than tested inside it.
        // A `#Predicate` body must be a single expression, so an absent bound would otherwise need
        // `after == nil || item.createdAt >= after!` — a force-unwrap for the macro to translate, on a value
        // that is not even a model property. An open range says the same thing with nothing to translate.
        let after = query.createdAfter ?? .distantPast
        let before = query.createdBefore ?? .distantFuture
        let minimumImportance = query.minimumImportance ?? 0

        let descriptor = FetchDescriptor<MemoryItem>(
            predicate: #Predicate { item in
                (includeArchived || !item.isArchived)
                    && (includeSuperseded || item.supersededByMemoryID == nil)
                    && item.createdAt >= after
                    && item.createdAt <= before
                    && item.importance >= minimumImportance
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        // Expiry is filtered here rather than in the predicate: an expired memory is invisible immediately,
        // without waiting for `pruneExpired` to run. Leaving that to the pruner would mean a temporary note
        // could still surface between expiring and being cleaned up.
        return try modelContext.fetch(descriptor).filter { item in
            guard let expiresAt = item.expiresAt else { return true }
            return expiresAt > now
        }
    }

    private func fetch(id: UUID) throws -> MemoryItem? {
        var descriptor = FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetch(ids: [UUID]) throws -> [MemoryItem] {
        let wanted = Set(ids)
        let descriptor = FetchDescriptor<MemoryItem>(
            predicate: #Predicate { wanted.contains($0.id) }
        )
        return try modelContext.fetch(descriptor)
    }

    private func setFlag(ids: [UUID], _ change: (MemoryItem) -> Void) throws {
        guard !ids.isEmpty else { return }
        for item in try fetch(ids: ids) {
            change(item)
            item.updatedAt = Date()
        }
        try persist()
    }

    /// Copies a draft's non-initialiser fields onto a fresh item.
    private func apply(_ draft: MemoryDraft, to item: MemoryItem) {
        item.wasExplicitlyRequested = draft.wasExplicitlyRequested
        item.sourceConversationID = draft.sourceConversationID
        item.sourceMessageIDs = draft.sourceMessageIDs
        item.relatedPersonIDs = draft.relatedPersonIDs
        item.relatedProjectIDs = draft.relatedProjectIDs
        item.relatedTaskIDs = draft.relatedTaskIDs
        item.tags = draft.tags
        item.entities = draft.entities
        item.isPinned = draft.isPinned
        item.expiresAt = draft.expiresAt
        item.refreshSearchText()
    }

    private func persist() throws {
        do {
            try modelContext.save()
        } catch {
            AuraLog.storage.error("Failed to save memory data.")
            throw AuraError.saveFailed(reason: error.localizedDescription)
        }
    }
}
