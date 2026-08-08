import Foundation

/// A memory the ranker chose, with the score that got it there.
///
/// The per-term breakdown is kept rather than collapsed into one number, for two reasons: the
/// Memory screen can show *why* something was recalled, and the ranking tests can assert on
/// individual terms instead of a single opaque total.
struct RankedMemory: Sendable, Equatable, Identifiable {
    var memory: MemorySnapshot
    var score: MemoryRelevanceScore

    var id: UUID { memory.id }
}

/// The weighted terms behind a relevance score (§30).
struct MemoryRelevanceScore: Sendable, Equatable, Hashable {
    /// Vector similarity. Always 0 in V1, which has no embeddings (§31).
    var semanticSimilarity: Double
    /// Overlap between query terms and the memory's `searchText`.
    var keywordOverlap: Double
    /// Named entities shared with the query.
    var entityMatch: Double
    /// The memory's own stored importance.
    var importance: Double
    /// Decay by age.
    var recency: Double
    /// Bonus for pinned memories.
    var pinned: Double
    /// Bonus for belonging to the conversation, project, or person in play.
    var contextualLink: Double
    /// Bonus for having proved useful before.
    var usage: Double

    init(
        semanticSimilarity: Double = 0,
        keywordOverlap: Double = 0,
        entityMatch: Double = 0,
        importance: Double = 0,
        recency: Double = 0,
        pinned: Double = 0,
        contextualLink: Double = 0,
        usage: Double = 0
    ) {
        self.semanticSimilarity = semanticSimilarity
        self.keywordOverlap = keywordOverlap
        self.entityMatch = entityMatch
        self.importance = importance
        self.recency = recency
        self.pinned = pinned
        self.contextualLink = contextualLink
        self.usage = usage
    }

    /// Relative weights. Tuned by `MemoryRankingTests`; changing one changes retrieval behaviour, so
    /// they live in one place rather than being scattered through the ranker.
    enum Weight {
        static let semanticSimilarity = 3.0
        static let keywordOverlap = 2.5
        static let entityMatch = 2.0
        static let importance = 1.5
        static let recency = 1.0
        static let pinned = 1.25
        static let contextualLink = 1.75
        static let usage = 0.5
    }

    var total: Double {
        semanticSimilarity * Weight.semanticSimilarity
            + keywordOverlap * Weight.keywordOverlap
            + entityMatch * Weight.entityMatch
            + importance * Weight.importance
            + recency * Weight.recency
            + pinned * Weight.pinned
            + contextualLink * Weight.contextualLink
            + usage * Weight.usage
    }

    /// The single largest contributor, for the "recalled because…" line in the UI.
    var dominantTerm: String {
        let terms: [(String, Double)] = [
            ("meaning", semanticSimilarity * Weight.semanticSimilarity),
            ("wording", keywordOverlap * Weight.keywordOverlap),
            ("who or what it mentions", entityMatch * Weight.entityMatch),
            ("how important it is", importance * Weight.importance),
            ("how recent it is", recency * Weight.recency),
            ("you pinned it", pinned * Weight.pinned),
            ("what you're working on", contextualLink * Weight.contextualLink),
            ("you've come back to it", usage * Weight.usage)
        ]
        return terms.max { $0.1 < $1.1 }?.0 ?? "wording"
    }
}

/// Everything one request's retrieval pass found, across all the stores it consulted.
struct RetrievalResult: Sendable, Equatable {
    var memories: [RankedMemory]
    var people: [PersonProfileSnapshot]
    var projects: [ProjectSnapshot]
    var profileFacts: [ProfileFactSnapshot]
    var tasks: [AssistantTaskSnapshot]
    /// Earlier conversations worth referring to.
    var conversations: [ConversationSnapshot]

    init(
        memories: [RankedMemory] = [],
        people: [PersonProfileSnapshot] = [],
        projects: [ProjectSnapshot] = [],
        profileFacts: [ProfileFactSnapshot] = [],
        tasks: [AssistantTaskSnapshot] = [],
        conversations: [ConversationSnapshot] = []
    ) {
        self.memories = memories
        self.people = people
        self.projects = projects
        self.profileFacts = profileFacts
        self.tasks = tasks
        self.conversations = conversations
    }

    static let empty = RetrievalResult()

    var isEmpty: Bool {
        memories.isEmpty
            && people.isEmpty
            && projects.isEmpty
            && profileFacts.isEmpty
            && tasks.isEmpty
            && conversations.isEmpty
    }

    var totalItemCount: Int {
        memories.count + people.count + projects.count
            + profileFacts.count + tasks.count + conversations.count
    }
}

/// What the retrieval engine is given to work with.
struct RetrievalRequest: Sendable, Equatable {
    /// The user's message, verbatim.
    var text: String
    /// Entities lifted from the message — names, places, products.
    var entities: [String]
    /// Which conversation this belongs to, so its own history ranks higher.
    var conversationID: UUID?
    /// Recent turns, used to resolve pronouns and follow-ups ("what about *that*?").
    var recentTurns: [String]
    var now: Date
    var budget: Budget

    struct Budget: Sendable, Equatable {
        var memories: Int
        var people: Int
        var projects: Int
        var profileFacts: Int

        init(
            memories: Int = AuraDefaults.RetrievalBudget.memories,
            people: Int = AuraDefaults.RetrievalBudget.people,
            projects: Int = AuraDefaults.RetrievalBudget.projects,
            profileFacts: Int = AuraDefaults.RetrievalBudget.profileFacts
        ) {
            self.memories = memories
            self.people = people
            self.projects = projects
            self.profileFacts = profileFacts
        }

        static let `default` = Budget()
        /// Nothing retrieved. What "Use memories in responses = off" resolves to (§48).
        static let none = Budget(memories: 0, people: 0, projects: 0, profileFacts: 0)

        var isEmpty: Bool {
            memories == 0 && people == 0 && projects == 0 && profileFacts == 0
        }
    }

    init(
        text: String,
        entities: [String] = [],
        conversationID: UUID? = nil,
        recentTurns: [String] = [],
        now: Date = Date(),
        budget: Budget = .default
    ) {
        self.text = text
        self.entities = entities
        self.conversationID = conversationID
        self.recentTurns = recentTurns
        self.now = now
        self.budget = budget
    }
}

/// Finds the stored knowledge that a specific request needs — and nothing else (§28, §30).
///
/// The whole point of this type is that it is the *only* thing that decides what a model gets to see
/// about the user. Concentrating that decision in one place is what makes the privacy claim in §50
/// something you can audit rather than hope for.
protocol MemoryRetrieving: Sendable {
    /// The full pipeline: interpret the query, search every store, rank, and cut to budget.
    func retrieve(for request: RetrievalRequest) async throws -> RetrievalResult

    /// Ranking only, over memories a caller already has. Split out so the ranking function can be
    /// tested as a pure function against fixed input.
    func rank(
        memories: [MemorySnapshot],
        for request: RetrievalRequest
    ) async -> [RankedMemory]
}
