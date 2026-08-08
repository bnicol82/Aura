import Foundation
import SwiftData

/// Reads and writes what AURA knows about the user, including the people in their life (§13, §14).
///
/// People live here rather than in a store of their own because "What AURA Knows About You" is one
/// screen and one privacy surface. A person is not an independent entity in this app — they exist
/// because the user mentioned them, and "delete everything about John" has to be able to reach the
/// person, their dates, and the facts that referenced them in one operation.
protocol UserProfileStoring: Sendable {

    // MARK: Profile

    func currentProfile() async throws -> UserProfileSnapshot
    @discardableResult
    func update(_ mutation: UserProfileMutation) async throws -> UserProfileSnapshot

    // MARK: Facts

    /// Adds or replaces a fact keyed by `key`.
    ///
    /// Replacement is a supersede, not an overwrite: the previous fact is archived and points at its
    /// successor, so a correction leaves a trail (§23).
    @discardableResult
    func upsertFact(
        key: String,
        value: String,
        category: MemoryCategory,
        confidence: Double,
        sourceMemoryID: UUID?
    ) async throws -> ProfileFactSnapshot

    func facts(in categories: Set<MemoryCategory>) async throws -> [ProfileFactSnapshot]
    /// Keyword search across facts, for retrieval and for the Memory screen's search field.
    func searchFacts(matching text: String, limit: Int) async throws -> [ProfileFactSnapshot]
    func setFactPinned(_ pinned: Bool, id: UUID) async throws
    func setFactArchived(_ archived: Bool, id: UUID) async throws
    func deleteFacts(ids: [UUID]) async throws

    // MARK: People

    func people() async throws -> [PersonProfileSnapshot]
    func person(id: UUID) async throws -> PersonProfileSnapshot?
    /// Resolves a name the user used to a known person, matching nicknames too.
    func person(matchingName name: String) async throws -> PersonProfileSnapshot?
    func searchPeople(matching text: String, limit: Int) async throws -> [PersonProfileSnapshot]

    @discardableResult
    func createPerson(name: String, relationship: String?, sourceMemoryID: UUID?) async throws -> PersonProfileSnapshot
    @discardableResult
    func updatePerson(id: UUID, with mutation: PersonProfileMutation) async throws -> PersonProfileSnapshot
    func deletePeople(ids: [UUID]) async throws

    @discardableResult
    func addImportantDate(
        toPersonID personID: UUID?,
        title: String,
        date: Date,
        isRecurringAnnually: Bool,
        sourceMemoryID: UUID?
    ) async throws -> ImportantDateSnapshot
    func upcomingImportantDates(within days: Int, from reference: Date) async throws -> [ImportantDateSnapshot]
    func deleteImportantDates(ids: [UUID]) async throws

    // MARK: Wholesale

    /// Clears everything AURA knows about the user. Backs "Clear all data" (§49).
    func deleteAllProfileData() async throws
}

/// SwiftData-backed `UserProfileStoring`.
@ModelActor
actor UserProfileStore: UserProfileStoring {

    // MARK: - Profile

    func currentProfile() async throws -> UserProfileSnapshot {
        try resolveSingleton().snapshot
    }

    @discardableResult
    func update(_ mutation: UserProfileMutation) async throws -> UserProfileSnapshot {
        let profile = try resolveSingleton()
        guard !mutation.isEmpty else { return profile.snapshot }
        if profile.apply(mutation) {
            try persist()
        }
        return profile.snapshot
    }

    // MARK: - Facts

    @discardableResult
    func upsertFact(
        key: String,
        value: String,
        category: MemoryCategory = .other,
        confidence: Double = AuraDefaults.Confidence.explicit,
        sourceMemoryID: UUID? = nil
    ) async throws -> ProfileFactSnapshot {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedValue.isEmpty else {
            throw AuraError.saveFailed(reason: "A fact needs both a label and a value.")
        }

        let profile = try resolveSingleton()
        let now = Date()

        let existing = profile.activeFacts.first {
            $0.key.compare(trimmedKey, options: .caseInsensitive) == .orderedSame
        }

        // Same label, same value — nothing to record, and no reason to touch `updatedAt`.
        if let existing, existing.value == trimmedValue {
            var changed = false
            if existing.confidence < confidence {
                existing.confidence = confidence.clamped(to: 0...1)
                changed = true
            }
            if existing.category != category, category != .other {
                existing.category = category
                changed = true
            }
            if changed {
                existing.updatedAt = now
                try persist()
            }
            return existing.snapshot
        }

        let fact = ProfileFact(
            key: trimmedKey,
            value: trimmedValue,
            category: category,
            confidence: confidence,
            sourceMemoryID: sourceMemoryID
        )
        fact.profile = profile
        modelContext.insert(fact)

        // A changed value is a correction: keep the old one, archived and pointing forward.
        if let existing {
            existing.isArchived = true
            existing.supersededByFactID = fact.id
            existing.updatedAt = now
        }

        profile.updatedAt = now
        try persist()
        return fact.snapshot
    }

    func facts(in categories: Set<MemoryCategory> = []) async throws -> [ProfileFactSnapshot] {
        let profile = try resolveSingleton()
        let all = profile.activeFacts
        let filtered = categories.isEmpty ? all : all.filter { categories.contains($0.category) }
        return filtered
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
            .map(\.snapshot)
    }

    func searchFacts(matching text: String, limit: Int = AuraDefaults.RetrievalBudget.profileFacts) async throws -> [ProfileFactSnapshot] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let terms = needle.keywordTokens()

        let profile = try resolveSingleton()
        let scored = profile.activeFacts.compactMap { fact -> (ProfileFact, Int)? in
            let haystack = "\(fact.key) \(fact.value)".lowercased()
            let hits = terms.reduce(into: 0) { total, term in
                if haystack.contains(term) { total += 1 }
            }
            guard hits > 0 || fact.isPinned else { return nil }
            return (fact, hits)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.updatedAt > rhs.0.updatedAt
            }
            .prefix(limit)
            .map { $0.0.snapshot }
    }

    func setFactPinned(_ pinned: Bool, id: UUID) async throws {
        guard let fact = try fetchFact(id: id) else {
            throw AuraError.recordNotFound(entity: "fact")
        }
        guard fact.isPinned != pinned else { return }
        fact.isPinned = pinned
        fact.updatedAt = Date()
        try persist()
    }

    func setFactArchived(_ archived: Bool, id: UUID) async throws {
        guard let fact = try fetchFact(id: id) else {
            throw AuraError.recordNotFound(entity: "fact")
        }
        guard fact.isArchived != archived else { return }
        fact.isArchived = archived
        fact.updatedAt = Date()
        try persist()
    }

    func deleteFacts(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        // `#Predicate` is most reliable with a captured `Array`; `Set` support is uneven.
        let targets = Array(Set(ids))
        let descriptor = FetchDescriptor<ProfileFact>(
            predicate: #Predicate { targets.contains($0.id) }
        )
        let matches = try modelContext.fetch(descriptor)
        for fact in matches { modelContext.delete(fact) }
        try persist()
    }

    // MARK: - People

    func people() async throws -> [PersonProfileSnapshot] {
        try resolveSingleton()
            .activePeople
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map(\.snapshot)
    }

    func person(id: UUID) async throws -> PersonProfileSnapshot? {
        try fetchPerson(id: id)?.snapshot
    }

    func person(matchingName name: String) async throws -> PersonProfileSnapshot? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }

        let candidates = try resolveSingleton().activePeople

        // Exact match on any alias first — "Blake" should never resolve to "Blakely".
        if let exact = candidates.first(where: { person in
            person.aliases.contains { $0.lowercased() == needle }
        }) {
            return exact.snapshot
        }

        // Then a first-name match, which is how people actually refer to each other.
        return candidates.first { person in
            person.aliases.contains { alias in
                alias.lowercased().split(separator: " ").first.map(String.init) == needle
            }
        }?.snapshot
    }

    func searchPeople(matching text: String, limit: Int = AuraDefaults.RetrievalBudget.people) async throws -> [PersonProfileSnapshot] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let terms = needle.keywordTokens()

        let scored = try resolveSingleton().activePeople.compactMap { person -> (PersonProfile, Int)? in
            let hits = terms.reduce(into: 0) { total, term in
                if person.searchText.contains(term) { total += 1 }
            }
            guard hits > 0 else { return nil }
            return (person, hits)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.updatedAt > rhs.0.updatedAt
            }
            .prefix(limit)
            .map { $0.0.snapshot }
    }

    @discardableResult
    func createPerson(
        name: String,
        relationship: String? = nil,
        sourceMemoryID: UUID? = nil
    ) async throws -> PersonProfileSnapshot {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AuraError.saveFailed(reason: "A person needs a name.")
        }

        // Never create a second row for someone AURA already knows.
        if let existing = try await person(matchingName: trimmed) {
            if let relationship, relationship != existing.relationship {
                var mutation = PersonProfileMutation()
                mutation.relationship = .some(relationship)
                mutation.appendSourceMemoryID = sourceMemoryID
                return try await updatePerson(id: existing.id, with: mutation)
            }
            return existing
        }

        let profile = try resolveSingleton()
        let person = PersonProfile(name: trimmed, relationship: relationship)
        if let sourceMemoryID { person.sourceMemoryIDs = [sourceMemoryID] }
        person.profile = profile
        person.refreshSearchText()
        modelContext.insert(person)
        profile.updatedAt = Date()
        try persist()

        AuraLog.memory.info("Created a person profile.")
        return person.snapshot
    }

    @discardableResult
    func updatePerson(id: UUID, with mutation: PersonProfileMutation) async throws -> PersonProfileSnapshot {
        guard let person = try fetchPerson(id: id) else {
            throw AuraError.recordNotFound(entity: "person")
        }
        guard !mutation.isEmpty else { return person.snapshot }
        if person.apply(mutation) {
            try persist()
        }
        return person.snapshot
    }

    func deletePeople(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let targets = Array(Set(ids))
        let descriptor = FetchDescriptor<PersonProfile>(
            predicate: #Predicate { targets.contains($0.id) }
        )
        let matches = try modelContext.fetch(descriptor)
        // `importantDates` cascades from the relationship's delete rule.
        for person in matches { modelContext.delete(person) }
        try persist()
    }

    // MARK: - Important dates

    @discardableResult
    func addImportantDate(
        toPersonID personID: UUID?,
        title: String,
        date: Date,
        isRecurringAnnually: Bool = false,
        sourceMemoryID: UUID? = nil
    ) async throws -> ImportantDateSnapshot {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AuraError.saveFailed(reason: "A date needs a title.")
        }

        let importantDate = ImportantDate(
            title: trimmed,
            date: date,
            isRecurringAnnually: isRecurringAnnually
        )
        importantDate.sourceMemoryID = sourceMemoryID

        if let personID {
            guard let person = try fetchPerson(id: personID) else {
                throw AuraError.recordNotFound(entity: "person")
            }
            importantDate.person = person
            person.updatedAt = Date()
        }

        modelContext.insert(importantDate)
        try persist()
        return importantDate.snapshot
    }

    func upcomingImportantDates(
        within days: Int = 30,
        from reference: Date = Date()
    ) async throws -> [ImportantDateSnapshot] {
        let horizon = Calendar.current.date(byAdding: .day, value: max(1, days), to: reference) ?? reference
        let all = try modelContext.fetch(FetchDescriptor<ImportantDate>())

        return all
            .compactMap { entry -> (ImportantDate, Date)? in
                guard let next = entry.nextOccurrence(after: reference) else { return nil }
                guard next <= horizon else { return nil }
                return (entry, next)
            }
            .sorted { $0.1 < $1.1 }
            .map { $0.0.snapshot }
    }

    func deleteImportantDates(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let targets = Array(Set(ids))
        let descriptor = FetchDescriptor<ImportantDate>(
            predicate: #Predicate { targets.contains($0.id) }
        )
        for entry in try modelContext.fetch(descriptor) {
            modelContext.delete(entry)
        }
        try persist()
    }

    // MARK: - Wholesale

    func deleteAllProfileData() async throws {
        // Order matters: children before parents, so nothing is left orphaned if a save fails
        // partway through.
        for entry in try modelContext.fetch(FetchDescriptor<ImportantDate>()) {
            modelContext.delete(entry)
        }
        for fact in try modelContext.fetch(FetchDescriptor<ProfileFact>()) {
            modelContext.delete(fact)
        }
        for person in try modelContext.fetch(FetchDescriptor<PersonProfile>()) {
            modelContext.delete(person)
        }
        for profile in try modelContext.fetch(FetchDescriptor<UserProfile>()) {
            modelContext.delete(profile)
        }
        try persist()
        AuraLog.memory.notice("Deleted all user profile data at the user's request.")
    }

    // MARK: - Internals

    private func resolveSingleton() throws -> UserProfile {
        let descriptor = FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )

        let existing: [UserProfile]
        do {
            existing = try modelContext.fetch(descriptor)
        } catch {
            throw AuraError.persistentStoreUnavailable(reason: error.localizedDescription)
        }

        guard let winner = existing.max(by: { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }) else {
            let profile = UserProfile()
            modelContext.insert(profile)
            try persist()
            return profile
        }

        // Two devices onboarding offline can each create a profile. Move the losers' children onto
        // the winner before deleting them — dropping a duplicate must not drop what it held.
        if existing.count > 1 {
            for duplicate in existing where duplicate.id != winner.id {
                for fact in duplicate.facts ?? [] { fact.profile = winner }
                for person in duplicate.people ?? [] { person.profile = winner }
                modelContext.delete(duplicate)
            }
            try persist()
            AuraLog.sync.notice(
                "Merged \(existing.count - 1, privacy: .public) duplicate user profile row(s)."
            )
        }

        return winner
    }

    private func fetchFact(id: UUID) throws -> ProfileFact? {
        var descriptor = FetchDescriptor<ProfileFact>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchPerson(id: UUID) throws -> PersonProfile? {
        var descriptor = FetchDescriptor<PersonProfile>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func persist() throws {
        do {
            try modelContext.save()
        } catch {
            AuraLog.storage.error("Failed to save user profile data.")
            throw AuraError.saveFailed(reason: error.localizedDescription)
        }
    }
}
