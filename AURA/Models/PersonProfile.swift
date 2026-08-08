import Foundation
import SwiftData

/// Someone who matters to the user (§14).
///
/// This is what makes "What's Blake studying again?" answerable without the user re-explaining who
/// Blake is. Structured columns hold the things AURA is asked about repeatedly — relationship,
/// school, work — and `importantFacts` absorbs everything else.
@Model
final class PersonProfile {
    var id: UUID = UUID()

    var name: String = ""
    var nickname: String?
    /// Free text on purpose: "son", "wife", "my brother-in-law", "manager at work".
    /// Enumerating human relationships is a losing game.
    var relationship: String?

    var education: String?
    var work: String?
    var notes: String?

    var importantFacts: [String] = []
    var preferences: [String] = []
    var interests: [String] = []

    /// Which memories produced this profile, for the provenance row in the Memory screen.
    var sourceMemoryIDs: [UUID] = []

    /// Lower-cased concatenation of every searchable field.
    ///
    /// `#Predicate` cannot search inside `[String]` columns, so V1 keyword retrieval (§31) needs one
    /// flat text column to match against. Always maintained through `refreshSearchText()`.
    var searchText: String = ""

    var isPinned: Bool = false
    var isArchived: Bool = false

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var profile: UserProfile?

    @Relationship(deleteRule: .cascade, inverse: \ImportantDate.person)
    var importantDates: [ImportantDate]?

    init(
        name: String = "",
        nickname: String? = nil,
        relationship: String? = nil,
        education: String? = nil,
        work: String? = nil
    ) {
        self.name = name
        self.nickname = nickname
        self.relationship = relationship
        self.education = education
        self.work = work
        self.searchText = Self.searchText(
            name: name,
            nickname: nickname,
            relationship: relationship,
            education: education,
            work: work,
            notes: nil,
            lists: []
        )
    }

    /// How the person is referred to in conversation, preferring the nickname the user uses.
    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return name
    }

    /// Every name this person answers to, used for entity matching during retrieval.
    var aliases: [String] {
        var result = [name]
        if let nickname, !nickname.isEmpty { result.append(nickname) }
        return result.filter { !$0.isEmpty }
    }

    /// Compact description handed to the model — one line per person, never the whole record (§28).
    var contextLine: String {
        var parts: [String] = []
        if let relationship, !relationship.isEmpty {
            parts.append("\(displayName) — \(relationship)")
        } else {
            parts.append(displayName)
        }
        if let education, !education.isEmpty { parts.append("studies: \(education)") }
        if let work, !work.isEmpty { parts.append("work: \(work)") }
        parts.append(contentsOf: importantFacts.prefix(4))
        if !interests.isEmpty { parts.append("interests: \(interests.prefix(4).joined(separator: ", "))") }
        if !preferences.isEmpty { parts.append("prefers: \(preferences.prefix(4).joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }

    func refreshSearchText() {
        searchText = Self.searchText(
            name: name,
            nickname: nickname,
            relationship: relationship,
            education: education,
            work: work,
            notes: notes,
            lists: [importantFacts, preferences, interests]
        )
    }

    private static func searchText(
        name: String,
        nickname: String?,
        relationship: String?,
        education: String?,
        work: String?,
        notes: String?,
        lists: [[String]]
    ) -> String {
        var pieces: [String] = [name]
        pieces.append(contentsOf: [nickname, relationship, education, work, notes].compactMap { $0 })
        for list in lists { pieces.append(contentsOf: list) }
        return pieces
            .joined(separator: " ")
            .lowercased()
    }

    var snapshot: PersonProfileSnapshot {
        PersonProfileSnapshot(
            id: id,
            name: name,
            nickname: nickname,
            relationship: relationship,
            education: education,
            work: work,
            notes: notes,
            importantFacts: importantFacts,
            preferences: preferences,
            interests: interests,
            importantDates: (importantDates ?? []).map(\.snapshot).sorted { $0.date < $1.date },
            sourceMemoryIDs: sourceMemoryIDs,
            isPinned: isPinned,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    @discardableResult
    func apply(_ mutation: PersonProfileMutation, now: Date = Date()) -> Bool {
        var changed = false

        func setOptional(_ keyPath: ReferenceWritableKeyPath<PersonProfile, String?>, _ update: String??) {
            guard let update else { return }
            let trimmed = update?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = (trimmed?.isEmpty ?? true) ? nil : trimmed
            guard self[keyPath: keyPath] != resolved else { return }
            self[keyPath: keyPath] = resolved
            changed = true
        }

        func setList(_ keyPath: ReferenceWritableKeyPath<PersonProfile, [String]>, _ update: [String]?) {
            guard let update else { return }
            let cleaned = update.normalizedProfileList()
            guard self[keyPath: keyPath] != cleaned else { return }
            self[keyPath: keyPath] = cleaned
            changed = true
        }

        if let newName = mutation.name {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, name != trimmed {
                name = trimmed
                changed = true
            }
        }

        setOptional(\.nickname, mutation.nickname)
        setOptional(\.relationship, mutation.relationship)
        setOptional(\.education, mutation.education)
        setOptional(\.work, mutation.work)
        setOptional(\.notes, mutation.notes)
        setList(\.importantFacts, mutation.importantFacts)
        setList(\.preferences, mutation.preferences)
        setList(\.interests, mutation.interests)

        if let pinned = mutation.isPinned, isPinned != pinned {
            isPinned = pinned
            changed = true
        }
        if let archived = mutation.isArchived, isArchived != archived {
            isArchived = archived
            changed = true
        }
        if let sourceID = mutation.appendSourceMemoryID, !sourceMemoryIDs.contains(sourceID) {
            sourceMemoryIDs.append(sourceID)
            changed = true
        }

        if changed {
            refreshSearchText()
            updatedAt = now
        }
        return changed
    }
}

/// A date the user cares about — a birthday, an anniversary, a renewal, a deadline (§44).
@Model
final class ImportantDate {
    var id: UUID = UUID()
    var title: String = ""
    var date: Date = Date()
    /// Birthdays and anniversaries recur; an insurance renewal on a specific date does not.
    var isRecurringAnnually: Bool = false
    var notes: String?

    /// Not a relationship: projects reference by ID to keep the object graph shallow, which keeps
    /// CloudKit mirroring simple and avoids cycles.
    var projectID: UUID?
    var sourceMemoryID: UUID?

    var createdAt: Date = Date()

    var person: PersonProfile?

    init(
        title: String = "",
        date: Date = Date(),
        isRecurringAnnually: Bool = false,
        notes: String? = nil
    ) {
        self.title = title
        self.date = date
        self.isRecurringAnnually = isRecurringAnnually
        self.notes = notes
    }

    /// The next time this date comes around, projecting annual recurrences forward.
    func nextOccurrence(after reference: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard isRecurringAnnually else {
            return date >= reference ? date : nil
        }
        let components = calendar.dateComponents([.month, .day], from: date)
        return calendar.nextDate(
            after: reference,
            matching: components,
            matchingPolicy: .nextTimePreservingSmallerComponents
        )
    }

    var snapshot: ImportantDateSnapshot {
        ImportantDateSnapshot(
            id: id,
            title: title,
            date: date,
            isRecurringAnnually: isRecurringAnnually,
            notes: notes,
            personID: person?.id,
            projectID: projectID,
            sourceMemoryID: sourceMemoryID
        )
    }
}

// MARK: - Snapshots

struct ImportantDateSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var date: Date
    var isRecurringAnnually: Bool
    var notes: String?
    var personID: UUID?
    var projectID: UUID?
    var sourceMemoryID: UUID?
}

struct PersonProfileSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var nickname: String?
    var relationship: String?
    var education: String?
    var work: String?
    var notes: String?
    var importantFacts: [String]
    var preferences: [String]
    var interests: [String]
    var importantDates: [ImportantDateSnapshot]
    var sourceMemoryIDs: [UUID]
    var isPinned: Bool
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        nickname: String? = nil,
        relationship: String? = nil,
        education: String? = nil,
        work: String? = nil,
        notes: String? = nil,
        importantFacts: [String] = [],
        preferences: [String] = [],
        interests: [String] = [],
        importantDates: [ImportantDateSnapshot] = [],
        sourceMemoryIDs: [UUID] = [],
        isPinned: Bool = false,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.relationship = relationship
        self.education = education
        self.work = work
        self.notes = notes
        self.importantFacts = importantFacts
        self.preferences = preferences
        self.interests = interests
        self.importantDates = importantDates
        self.sourceMemoryIDs = sourceMemoryIDs
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return name
    }

    var aliases: [String] {
        ([name, nickname].compactMap { $0 }).filter { !$0.isEmpty }
    }

    var subtitle: String? {
        [relationship, education, work].compactMap { $0 }.first
    }

    /// One line, for the model. Mirrors `PersonProfile.contextLine`.
    var contextLine: String {
        var parts: [String] = []
        if let relationship, !relationship.isEmpty {
            parts.append("\(displayName) — \(relationship)")
        } else {
            parts.append(displayName)
        }
        if let education, !education.isEmpty { parts.append("studies: \(education)") }
        if let work, !work.isEmpty { parts.append("work: \(work)") }
        parts.append(contentsOf: importantFacts.prefix(4))
        if !interests.isEmpty { parts.append("interests: \(interests.prefix(4).joined(separator: ", "))") }
        if !preferences.isEmpty { parts.append("prefers: \(preferences.prefix(4).joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }
}

struct PersonProfileMutation: Sendable, Equatable {
    var name: String?
    var nickname: String??
    var relationship: String??
    var education: String??
    var work: String??
    var notes: String??
    var importantFacts: [String]?
    var preferences: [String]?
    var interests: [String]?
    var isPinned: Bool?
    var isArchived: Bool?
    var appendSourceMemoryID: UUID?

    init() {}

    var isEmpty: Bool { self == PersonProfileMutation() }
}
