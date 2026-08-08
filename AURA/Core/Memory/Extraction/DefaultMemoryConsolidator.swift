import Foundation

/// Writes accepted candidates wherever they belong, and handles "forget that" (§20, §21, §23, §24).
///
/// ### Why this is separate from extraction
/// Deciding *what a statement means* and deciding *where it goes* are different problems with different
/// failure modes. Extraction being wrong produces a bad candidate the user can reject. Consolidation being
/// wrong writes to the wrong place, and the user may never find it — a preference filed as a passing note is
/// silently forgotten, and a passing note promoted to the profile is quietly wrong forever.
///
/// ### The routing rule
/// A durable statement about a stable trait becomes a profile fact *as well as* a memory. Everything else is
/// a memory only. The profile is what AURA states as settled fact about someone, so the bar for writing there
/// is the highest bar in the system: `.durable`, not hedged, and in a category that describes a person rather
/// than a moment.
struct DefaultMemoryConsolidator: MemoryConsolidating {

    private let memoryStore: any MemoryStoring
    private let userProfileStore: any UserProfileStoring

    init(memoryStore: any MemoryStoring, userProfileStore: any UserProfileStoring) {
        self.memoryStore = memoryStore
        self.userProfileStore = userProfileStore
    }

    // MARK: - Writing

    func consolidate(_ candidate: MemoryCandidateSnapshot) async throws -> ConsolidationOutcome {
        // Nothing that was not meant to be kept gets written, whatever the caller passed. The recommendation
        // is the retention decision, and re-checking it here means a mistake upstream cannot become a
        // permanent record.
        guard candidate.retentionRecommendation == .durable
                || candidate.retentionRecommendation == .episodic else {
            return .nothing
        }

        let content = candidate.content.normalizedWhitespace
        guard !content.isEmpty else { return .nothing }

        let saved = try await memoryStore.save(
            MemoryDraft(
                content: content,
                memoryType: Self.memoryType(for: candidate),
                category: candidate.category,
                importance: candidate.importance,
                confidence: candidate.confidence,
                wasExplicitlyRequested: candidate.wasExplicitlyRequested,
                sourceConversationID: candidate.sourceConversationID,
                sourceMessageIDs: candidate.sourceMessageID.map { [$0] } ?? [],
                entities: candidate.entities,
                supersedesMemoryID: candidate.supersedesMemoryID
            )
        )

        var outcome = ConsolidationOutcome(
            savedMemory: saved,
            supersededMemoryID: candidate.supersedesMemoryID
        )

        // Promotion to the profile is a second, stricter decision — not a consequence of having been saved.
        if Self.deservesProfilePromotion(candidate), let key = Self.profileFactKey(for: candidate) {
            let fact = try await userProfileStore.upsertFact(
                key: key,
                value: content,
                category: candidate.category,
                confidence: candidate.confidence,
                sourceMemoryID: saved.id
            )
            outcome.updatedProfileFactID = fact.id
        }

        return outcome
    }

    // MARK: - Forgetting

    @discardableResult
    func forget(matching request: ForgetRequest) async throws -> ForgetOutcome {
        // Explicit ids are the unambiguous case: the user pointed at something in the Memory screen.
        if !request.memoryIDs.isEmpty {
            let summaries = try await memoryStore.memories(ids: request.memoryIDs).map(\.summary)
            try await memoryStore.delete(ids: request.memoryIDs)
            return ForgetOutcome(deletedMemoryCount: request.memoryIDs.count, deletedSummaries: summaries)
        }

        // A subject means "forget about X", which is a search. Deleting search results is the one operation
        // here that can destroy more than the user meant, so the matches are counted and named in the outcome
        // — AURA reports what it actually removed rather than saying "done" (§24).
        guard let subject = request.subject, !subject.isBlank else {
            return .nothing
        }

        let matches = try await memoryStore.search(
            MemoryQuery(
                text: subject,
                personIDs: request.personID.map { [$0] } ?? [],
                projectIDs: request.projectID.map { [$0] } ?? [],
                conversationID: request.conversationID,
                // Archived and superseded records are included: "forget about the garage" means all of it,
                // and leaving a superseded copy behind would let it resurface in an audit view.
                includeSuperseded: true,
                includeArchived: true,
                limit: 200
            )
        )
        guard !matches.isEmpty else { return .nothing }

        try await memoryStore.delete(ids: matches.map(\.id))

        var outcome = ForgetOutcome(
            deletedMemoryCount: matches.count,
            deletedSummaries: matches.map(\.summary)
        )

        if request.includesProfileFacts {
            let profile = try await userProfileStore.currentProfile()
            let needle = subject.lowercased()
            let doomed = profile.facts.filter {
                $0.key.lowercased().contains(needle) || $0.value.lowercased().contains(needle)
            }
            // `deleteFacts(ids:)`, not a per-fact call — batched is the API that exists, and it also means
            // the deletion is one transaction rather than a partial wipe if one of them fails.
            if !doomed.isEmpty {
                try await userProfileStore.deleteFacts(ids: doomed.map(\.id))
            }
            outcome.deletedProfileFactCount = doomed.count
        }

        AuraLog.memory.notice(
            "Forgot \(outcome.totalCount, privacy: .public) record(s) at the user's request."
        )
        return outcome
    }

    // MARK: - Routing rules

    /// Which layer of memory a candidate belongs in (§15).
    ///
    /// `static` and pure so the routing table is one readable function rather than scattered conditionals.
    static func memoryType(for candidate: MemoryCandidateSnapshot) -> MemoryType {
        switch candidate.category {
        case .person, .relationship:
            return .person
        case .project:
            return .project
        case .personalPreference, .routine, .work, .education, .health, .finance:
            // Traits, not events: true until changed, so they belong in semantic memory.
            return .semantic
        case .decision, .importantDate, .temporaryContext:
            return .episodic
        default:
            // Anything durable enough to reach here without a clear layer is a trait; anything weaker is an
            // event. Judged on retention rather than category, because that is the stronger signal.
            return candidate.retentionRecommendation == .durable ? .semantic : .episodic
        }
    }

    /// Whether a candidate is strong enough to become a profile fact — something AURA will state as settled.
    ///
    /// Three conditions, all required. Durable, because the profile is not for guesses. Not hedged, because a
    /// hedge stated as fact is §22's whole concern. And in a category describing the person rather than a
    /// moment, because "decided to hold the garage until October" is true today and misleading next year.
    static func deservesProfilePromotion(_ candidate: MemoryCandidateSnapshot) -> Bool {
        guard candidate.retentionRecommendation == .durable else { return false }
        guard candidate.confidence >= AuraDefaults.Confidence.inferred else { return false }

        switch candidate.category {
        case .personalPreference, .routine, .work, .education, .health, .finance, .relationship:
            return true
        default:
            return false
        }
    }

    /// The key a promoted fact is filed under.
    ///
    /// Keys group revisions of the same thing, so "Coffee" set twice updates rather than accumulating. Derived
    /// from the category rather than the sentence, because a key built from free text would produce a new key
    /// on every rewording and the profile would fill with near-duplicates.
    static func profileFactKey(for candidate: MemoryCandidateSnapshot) -> String? {
        if let suggested = candidate.suggestedProfileFactKey, !suggested.isBlank {
            return suggested.normalizedWhitespace
        }
        switch candidate.category {
        case .personalPreference: return "Preference"
        case .routine: return "Routine"
        case .work: return "Work"
        case .education: return "Education"
        case .health: return "Health"
        case .finance: return "Finance"
        case .relationship: return "Relationship"
        default: return nil
        }
    }
}
