import Foundation
import SwiftData

/// Durable, structured knowledge about the person using AURA (§13).
///
/// ### Why this is not twenty-four columns
/// The specification lists many preference buckets — food, travel, sports, entertainment,
/// shopping, technology, favourite things. Modelling each as its own array would freeze the schema
/// around today's guesses and give the retrieval engine twenty-four places to look. Instead the
/// buckets are expressed as `ProfileFact` rows carrying a `MemoryCategory`, which means:
///
/// * a new bucket is a new enum case, not a migration;
/// * every fact gets confidence, provenance, pinning and archival for free (§22, §23);
/// * retrieval filters one relationship by category instead of unioning many arrays.
///
/// The genuinely singular fields — the user's name, how they want to be spoken to, their standing
/// instructions — stay as columns here, because there is exactly one of each.
///
/// Exactly one row exists; `UserProfileStore` owns that invariant.
@Model
final class UserProfile {
    var id: UUID = UUID()

    /// What the assistant should call the user. `nil` means "hasn't said" — AURA must not guess.
    var preferredName: String?
    var pronouns: String?

    /// One-line summaries kept as plain text because the model reads them, nothing queries them.
    var workContext: String?
    var educationContext: String?
    var locationContext: String?

    /// Free-form lists that the user (or extraction) appends to over time.
    var communicationPreferences: [String] = []
    var interests: [String] = []
    var hobbies: [String] = []
    var longTermGoals: [String] = []
    var routines: [String] = []
    var importantPlaces: [String] = []

    /// Standing instructions the user has given the assistant, e.g. "always show me the numbers".
    /// These outrank inferred preferences in the context priority order (§29).
    var assistantInstructions: [String] = []

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \ProfileFact.profile)
    var facts: [ProfileFact]?

    @Relationship(deleteRule: .cascade, inverse: \PersonProfile.profile)
    var people: [PersonProfile]?

    init() {}

    /// Facts still in play — pinned or not, but not archived.
    var activeFacts: [ProfileFact] {
        (facts ?? []).filter { !$0.isArchived }
    }

    var activePeople: [PersonProfile] {
        (people ?? []).filter { !$0.isArchived }
    }

    var snapshot: UserProfileSnapshot {
        UserProfileSnapshot(
            id: id,
            preferredName: preferredName,
            pronouns: pronouns,
            workContext: workContext,
            educationContext: educationContext,
            locationContext: locationContext,
            communicationPreferences: communicationPreferences,
            interests: interests,
            hobbies: hobbies,
            longTermGoals: longTermGoals,
            routines: routines,
            importantPlaces: importantPlaces,
            assistantInstructions: assistantInstructions,
            facts: activeFacts.map(\.snapshot),
            people: activePeople.map(\.snapshot),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    @discardableResult
    func apply(_ mutation: UserProfileMutation, now: Date = Date()) -> Bool {
        var changed = false

        func setOptionalString(
            _ keyPath: ReferenceWritableKeyPath<UserProfile, String?>,
            _ update: String??
        ) {
            guard let update else { return }
            let trimmed = update?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = (trimmed?.isEmpty ?? true) ? nil : trimmed
            guard self[keyPath: keyPath] != resolved else { return }
            self[keyPath: keyPath] = resolved
            changed = true
        }

        func setList(
            _ keyPath: ReferenceWritableKeyPath<UserProfile, [String]>,
            _ update: [String]?
        ) {
            guard let update else { return }
            let cleaned = update.normalizedProfileList()
            guard self[keyPath: keyPath] != cleaned else { return }
            self[keyPath: keyPath] = cleaned
            changed = true
        }

        setOptionalString(\.preferredName, mutation.preferredName)
        setOptionalString(\.pronouns, mutation.pronouns)
        setOptionalString(\.workContext, mutation.workContext)
        setOptionalString(\.educationContext, mutation.educationContext)
        setOptionalString(\.locationContext, mutation.locationContext)

        setList(\.communicationPreferences, mutation.communicationPreferences)
        setList(\.interests, mutation.interests)
        setList(\.hobbies, mutation.hobbies)
        setList(\.longTermGoals, mutation.longTermGoals)
        setList(\.routines, mutation.routines)
        setList(\.importantPlaces, mutation.importantPlaces)
        setList(\.assistantInstructions, mutation.assistantInstructions)

        if changed { updatedAt = now }
        return changed
    }
}

/// A single categorised fact about the user: `key` is what it answers, `value` is the answer.
///
/// "Favourite NASCAR driver" → "Christopher Bell", category `.sports`, confidence 0.95.
@Model
final class ProfileFact {
    var id: UUID = UUID()

    /// What this fact is about, phrased as a label — "Preferred seat", "Favourite driver".
    var key: String = ""
    /// The fact itself.
    var value: String = ""
    var categoryRaw: String = MemoryCategory.other.rawValue

    /// 0...1. Hedged statements land low and must never be presented as certain (§22).
    var confidence: Double = AuraDefaults.Confidence.explicit

    /// Pinned facts survive pruning and always rank into context.
    var isPinned: Bool = false
    /// Archived facts are hidden and excluded from retrieval, but kept for audit (§23).
    var isArchived: Bool = false

    /// The memory this was promoted from, so the Memory screen can show provenance.
    var sourceMemoryID: UUID?
    /// Set when a correction replaced this fact, preserving the history (§23).
    var supersededByFactID: UUID?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var profile: UserProfile?

    /// A single designated initialiser with defaults for everything — the shape SwiftData is
    /// happiest with, and it keeps `ProfileFact()` valid for previews and tests.
    init(
        key: String = "",
        value: String = "",
        category: MemoryCategory = .other,
        confidence: Double = AuraDefaults.Confidence.explicit,
        sourceMemoryID: UUID? = nil
    ) {
        self.key = key
        self.value = value
        self.categoryRaw = category.rawValue
        self.confidence = confidence.clamped(to: 0...1)
        self.sourceMemoryID = sourceMemoryID
    }

    var category: MemoryCategory {
        get { MemoryCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    /// How this fact reads when handed to the model, including a hedge when confidence is low.
    var contextLine: String {
        if confidence < AuraDefaults.Confidence.inferred {
            return "\(key): \(value) (uncertain — the user was tentative about this)"
        }
        return "\(key): \(value)"
    }

    var snapshot: ProfileFactSnapshot {
        ProfileFactSnapshot(
            id: id,
            key: key,
            value: value,
            category: category,
            confidence: confidence,
            isPinned: isPinned,
            isArchived: isArchived,
            sourceMemoryID: sourceMemoryID,
            supersededByFactID: supersededByFactID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Snapshots

struct ProfileFactSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: UUID
    var key: String
    var value: String
    var category: MemoryCategory
    var confidence: Double
    var isPinned: Bool
    var isArchived: Bool
    var sourceMemoryID: UUID?
    var supersededByFactID: UUID?
    var createdAt: Date
    var updatedAt: Date

    var contextLine: String {
        confidence < AuraDefaults.Confidence.inferred
            ? "\(key): \(value) (uncertain)"
            : "\(key): \(value)"
    }
}

struct UserProfileSnapshot: Sendable, Equatable, Identifiable {
    var id: UUID
    var preferredName: String?
    var pronouns: String?
    var workContext: String?
    var educationContext: String?
    var locationContext: String?
    var communicationPreferences: [String]
    var interests: [String]
    var hobbies: [String]
    var longTermGoals: [String]
    var routines: [String]
    var importantPlaces: [String]
    var assistantInstructions: [String]
    var facts: [ProfileFactSnapshot]
    var people: [PersonProfileSnapshot]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        preferredName: String? = nil,
        pronouns: String? = nil,
        workContext: String? = nil,
        educationContext: String? = nil,
        locationContext: String? = nil,
        communicationPreferences: [String] = [],
        interests: [String] = [],
        hobbies: [String] = [],
        longTermGoals: [String] = [],
        routines: [String] = [],
        importantPlaces: [String] = [],
        assistantInstructions: [String] = [],
        facts: [ProfileFactSnapshot] = [],
        people: [PersonProfileSnapshot] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.preferredName = preferredName
        self.pronouns = pronouns
        self.workContext = workContext
        self.educationContext = educationContext
        self.locationContext = locationContext
        self.communicationPreferences = communicationPreferences
        self.interests = interests
        self.hobbies = hobbies
        self.longTermGoals = longTermGoals
        self.routines = routines
        self.importantPlaces = importantPlaces
        self.assistantInstructions = assistantInstructions
        self.facts = facts
        self.people = people
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static let placeholder = UserProfileSnapshot()

    /// `true` when the user has told AURA essentially nothing yet. Drives the empty state on the
    /// "What AURA Knows About You" screen.
    var isEssentiallyEmpty: Bool {
        preferredName == nil
            && facts.isEmpty
            && people.isEmpty
            && interests.isEmpty
            && hobbies.isEmpty
            && longTermGoals.isEmpty
            && routines.isEmpty
            && assistantInstructions.isEmpty
            && workContext == nil
            && educationContext == nil
    }

    /// Total count of discrete things AURA knows, shown in the Privacy dashboard.
    var knownItemCount: Int {
        facts.count
            + people.count
            + interests.count
            + hobbies.count
            + longTermGoals.count
            + routines.count
            + importantPlaces.count
            + assistantInstructions.count
            + communicationPreferences.count
            + [preferredName, pronouns, workContext, educationContext, locationContext]
                .compactMap { $0 }.count
    }
}

/// Partial update for `UserProfile`. Double optionals mean "leave alone" vs "clear".
struct UserProfileMutation: Sendable, Equatable {
    var preferredName: String??
    var pronouns: String??
    var workContext: String??
    var educationContext: String??
    var locationContext: String??
    var communicationPreferences: [String]?
    var interests: [String]?
    var hobbies: [String]?
    var longTermGoals: [String]?
    var routines: [String]?
    var importantPlaces: [String]?
    var assistantInstructions: [String]?

    init() {}

    var isEmpty: Bool { self == UserProfileMutation() }
}

extension Array where Element == String {
    /// Trims, drops blanks, and removes case-insensitive duplicates while preserving order.
    /// Profile lists are appended to by both the user and the extractor, so they need this.
    func normalizedProfileList() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in self {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
