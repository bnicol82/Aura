import Foundation

/// The only thing that decides what a model learns about the user (§28, §30, §50).
///
/// ### Why the ranking is a pure static function
/// `score(_:for:)` takes a snapshot and a request and returns a breakdown. No store, no clock beyond the
/// one in the request, no model. That is deliberate: this function decides what leaves the device when a
/// cloud provider is in play, so it has to be verifiable by reading it and assertable without a database.
///
/// The per-term breakdown is kept rather than collapsed to one number so the Memory screen can say *why*
/// something was recalled, and so a ranking test can fail on the term that actually regressed.
///
/// ### V1 has no embeddings
/// `semanticSimilarity` is always 0 (§31), which is why keyword and entity overlap carry the most weight.
/// When an `EmbeddingProvider` exists the term fills in and the weights already account for it — nothing
/// else has to change.
struct DefaultMemoryRetrieval: MemoryRetrieving {

    private let memoryStore: any MemoryStoring
    private let userProfileStore: any UserProfileStoring

    init(memoryStore: any MemoryStoring, userProfileStore: any UserProfileStoring) {
        self.memoryStore = memoryStore
        self.userProfileStore = userProfileStore
    }

    // MARK: - The pipeline

    func retrieve(for request: RetrievalRequest) async throws -> RetrievalResult {
        // Memory off means nothing retrieved, and that check comes first so no query is even built (§48).
        guard !request.budget.isEmpty else {
            return RetrievalResult(memories: [], people: [], projects: [], profileFacts: [], tasks: [])
        }

        let terms = Self.searchTerms(for: request)

        // Deliberately over-fetches, then ranks, then cuts. Asking the store for exactly the budget would
        // hand back whatever matched first rather than what matched best — the limit has to bite *after*
        // ranking or "the five most relevant things" is really "five things".
        let candidates = try await memoryStore.search(
            MemoryQuery(
                text: terms.isEmpty ? nil : terms.joined(separator: " "),
                entities: request.entities,
                conversationID: nil,
                includePinnedRegardlessOfMatch: true,
                sortOrder: .mostImportantFirst,
                limit: max(request.budget.memories * 6, 30)
            )
        )

        let ranked = Array(
            await rank(memories: candidates, for: request).prefix(request.budget.memories)
        )

        // Usage feeds later ranking, and only what was actually selected counts — recording every
        // candidate would make "you've come back to it" mean "it was considered once".
        if !ranked.isEmpty {
            await memoryStore.recordAccess(ids: ranked.map(\.memory.id), at: request.now)
        }

        return RetrievalResult(
            memories: ranked,
            people: try await relevantPeople(for: request, terms: terms),
            projects: [],
            profileFacts: [],
            tasks: []
        )
    }

    func rank(memories: [MemorySnapshot], for request: RetrievalRequest) async -> [RankedMemory] {
        memories
            .map { RankedMemory(memory: $0, score: Self.score($0, for: request)) }
            // Anything scoring nothing at all is dropped rather than padding the budget: sending a model
            // an irrelevant memory is worse than sending it fewer (§28).
            .filter { $0.score.total > 0 }
            .sorted { lhs, rhs in
                lhs.score.total == rhs.score.total
                    ? lhs.memory.createdAt > rhs.memory.createdAt
                    : lhs.score.total > rhs.score.total
            }
    }

    // MARK: - Scoring

    /// Scores one memory against one request.
    ///
    /// `static` and pure. Every term is 0...1 before weighting, so the weights in
    /// `MemoryRelevanceScore.Weight` are the only thing that decides relative importance — a term that
    /// could exceed 1 would silently outrank its own weight.
    static func score(_ memory: MemorySnapshot, for request: RetrievalRequest) -> MemoryRelevanceScore {
        let terms = searchTerms(for: request)
        let haystack = SwiftDataMemoryStore.haystack(for: memory)

        var score = MemoryRelevanceScore()

        // Proportion of the query's words present, not a raw count — otherwise a long question scores
        // higher than a precise one simply by having more words.
        if !terms.isEmpty {
            let hits = terms.filter { haystack.contains($0) }.count
            score.keywordOverlap = Double(hits) / Double(terms.count)
        }

        if !request.entities.isEmpty {
            let lowered = request.entities.map { $0.lowercased() }
            let hits = lowered.filter { haystack.contains($0) }.count
            score.entityMatch = Double(hits) / Double(lowered.count)
        }

        score.importance = memory.importance.clamped(to: 0...1)
        score.recency = recencyScore(createdAt: memory.createdAt, now: request.now)
        score.pinned = memory.isPinned ? 1 : 0

        if let conversationID = request.conversationID, memory.sourceConversationID == conversationID {
            score.contextualLink = 1
        }

        // Saturating rather than linear: the difference between never used and used twice matters, the
        // difference between forty and fifty times does not.
        score.usage = memory.accessCount == 0
            ? 0
            : min(1, log(Double(memory.accessCount) + 1) / log(11))

        return score
    }

    /// Age decay, 1 for something recorded now and approaching 0 over a year.
    ///
    /// Halves roughly every 90 days. Exponential rather than linear because usefulness drops off fast at
    /// first — last week matters far more than the week before it — and then flattens, so a two-year-old
    /// memory and a three-year-old one are equally distant.
    static func recencyScore(createdAt: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(createdAt) / 86_400)
        return pow(0.5, days / 90)
    }

    /// The words worth matching on, from the message and the turns leading up to it.
    ///
    /// `static` and pure. Recent turns are included at all because a follow-up like "what about his
    /// tuition?" carries almost no searchable words of its own — the subject is in the previous turn.
    static func searchTerms(for request: RetrievalRequest) -> [String] {
        let recentContext = request.recentTurns.suffix(2).joined(separator: " ")
        let combined = ([request.text] + [recentContext]).joined(separator: " ").lowercased()

        var seen = Set<String>()
        return combined
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            // Words of three or more characters, and not stop words: "the garage" must not match every
            // memory containing "the", which would make the overlap term meaningless.
            .filter { $0.count >= 3 && !stopWords.contains($0) }
            .filter { seen.insert($0).inserted }
    }

    /// Words carrying no retrieval signal.
    ///
    /// Short rather than exhaustive on purpose: an aggressive list starts removing words that matter
    /// ("work", "home", "time"), and the length filter already handles most noise.
    static let stopWords: Set<String> = [
        "the", "and", "for", "was", "were", "are", "you", "your", "yours", "our", "its",
        "did", "does", "done", "have", "has", "had", "what", "when", "where", "which", "who",
        "whom", "how", "why", "that", "this", "these", "those", "there", "then", "than",
        "with", "from", "about", "into", "onto", "but", "not", "can", "could", "would",
        "should", "will", "just", "any", "all", "some", "get", "got", "tell", "told", "say",
        "said", "much", "many", "very", "really", "please", "thanks"
    ]

    // MARK: - People

    /// People the request mentions, so the model can be told who they are.
    ///
    /// Matched by name against the query rather than retrieved wholesale: §28's promise is that a question
    /// about one person does not ship the other, and that is enforced here.
    private func relevantPeople(
        for request: RetrievalRequest,
        terms: [String]
    ) async throws -> [PersonProfileSnapshot] {
        guard request.budget.people > 0 else { return [] }

        let profile = try await userProfileStore.currentProfile()
        let needles = Set(terms + request.entities.map { $0.lowercased() })
        guard !needles.isEmpty else { return [] }

        return profile.people
            .filter { person in
                let name = person.name.lowercased()
                let nickname = person.nickname?.lowercased()
                // Whole-name matching, not substring: "Ali" must not pull in "Alison", and a person called
                // "A" must not match everything.
                return needles.contains(name)
                    || (nickname.map { needles.contains($0) } ?? false)
            }
            .prefix(request.budget.people)
            .map { $0 }
    }
}
