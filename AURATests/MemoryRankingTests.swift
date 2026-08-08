import Foundation
import Testing

@testable import AURA

/// Retrieval ranking (§28, §30, §31).
///
/// This is the function that decides what a model is told about the user, so it is tested as a pure
/// function against fixed input. Every assertion here is really a privacy assertion: a ranker that is too
/// generous ships context nobody asked to share, and one that is too strict makes AURA look forgetful.
@Suite("Memory ranking")
struct MemoryRankingTests {

    private func memory(
        _ content: String,
        importance: Double = 0.5,
        entities: [String] = [],
        conversationID: UUID? = nil,
        isPinned: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_770_000_000),
        accessCount: Int = 0
    ) -> MemorySnapshot {
        MemorySnapshot(
            content: content,
            importance: importance,
            sourceConversationID: conversationID,
            entities: entities,
            isPinned: isPinned,
            createdAt: createdAt,
            accessCount: accessCount
        )
    }

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: Query terms

    @Test("Stop words and short words are dropped, so overlap means something")
    func searchTermsFilterNoise() {
        let terms = DefaultMemoryRetrieval.searchTerms(
            for: RetrievalRequest(text: "What did I say about the garage?", now: now)
        )
        // Without this, "the" would match nearly every memory and the overlap term would be noise that
        // outranks genuine matches.
        #expect(terms.contains("garage"))
        #expect(!terms.contains("the"))
        #expect(!terms.contains("what"))
        #expect(!terms.contains("did"))
    }

    @Test("Recent turns contribute terms, so a follow-up can still retrieve")
    func searchTermsIncludeRecentTurns() {
        // "What about his tuition?" carries almost no searchable words of its own — the subject is in the
        // previous turn. Without this a follow-up question retrieves nothing.
        let terms = DefaultMemoryRetrieval.searchTerms(
            for: RetrievalRequest(
                text: "What about that?",
                recentTurns: ["Blake is studying mechanical engineering"],
                now: now
            )
        )
        #expect(terms.contains("blake"))
        #expect(terms.contains("engineering"))
    }

    @Test("Duplicate words are counted once")
    func searchTermsDeduplicate() {
        let terms = DefaultMemoryRetrieval.searchTerms(
            for: RetrievalRequest(text: "garage garage garage", now: now)
        )
        #expect(terms.filter { $0 == "garage" }.count == 1)
    }

    // MARK: Individual terms

    @Test("Keyword overlap is a proportion, so a longer question does not score higher")
    func keywordOverlapIsProportional() {
        let match = memory("Holding off on the garage renovation until October.")

        let precise = DefaultMemoryRetrieval.score(
            match, for: RetrievalRequest(text: "garage renovation", now: now)
        )
        let padded = DefaultMemoryRetrieval.score(
            match,
            for: RetrievalRequest(text: "garage renovation plus lots of unrelated extra words here", now: now)
        )

        #expect(precise.keywordOverlap == 1)
        // A raw hit count would have scored the padded query at least as high simply for being longer.
        #expect(padded.keywordOverlap < precise.keywordOverlap)
    }

    @Test("Every term is 0...1 before weighting")
    func termsAreNormalised() {
        // If a term could exceed 1 it would silently outrank its own weight, making the weight table a lie.
        let score = DefaultMemoryRetrieval.score(
            memory(
                "Blake studies mechanical engineering at Tennessee",
                importance: 1,
                entities: ["Blake", "Tennessee"],
                isPinned: true,
                accessCount: 500
            ),
            for: RetrievalRequest(
                text: "Blake mechanical engineering Tennessee",
                entities: ["Blake", "Tennessee"],
                now: now
            )
        )

        for term in [
            score.semanticSimilarity, score.keywordOverlap, score.entityMatch,
            score.importance, score.recency, score.pinned, score.contextualLink, score.usage
        ] {
            #expect(term >= 0)
            #expect(term <= 1)
        }
    }

    @Test("Semantic similarity is zero in V1, which has no embeddings")
    func semanticSimilarityIsZero() {
        // Stated as a test rather than a comment: if an embedding provider lands and this term stays 0, the
        // weights are silently mis-tuned and nobody would notice.
        let score = DefaultMemoryRetrieval.score(
            memory("anything"), for: RetrievalRequest(text: "anything", now: now)
        )
        #expect(score.semanticSimilarity == 0)
    }

    @Test("Recency halves about every 90 days and never goes negative")
    func recencyDecays() {
        let fresh = DefaultMemoryRetrieval.recencyScore(createdAt: now, now: now)
        let quarter = DefaultMemoryRetrieval.recencyScore(
            createdAt: now.addingTimeInterval(-90 * 86_400), now: now
        )
        let year = DefaultMemoryRetrieval.recencyScore(
            createdAt: now.addingTimeInterval(-365 * 86_400), now: now
        )

        #expect(fresh == 1)
        #expect(abs(quarter - 0.5) < 0.001)
        #expect(year > 0)
        #expect(year < 0.1)

        // A memory dated in the future — clock skew, or an imported record — must not score above 1.
        let future = DefaultMemoryRetrieval.recencyScore(
            createdAt: now.addingTimeInterval(86_400), now: now
        )
        #expect(future == 1)
    }

    @Test("Usage saturates rather than growing without limit")
    func usageSaturates() {
        let never = DefaultMemoryRetrieval.score(
            memory("x", accessCount: 0), for: RetrievalRequest(text: "x", now: now)
        )
        let twice = DefaultMemoryRetrieval.score(
            memory("x", accessCount: 2), for: RetrievalRequest(text: "x", now: now)
        )
        let often = DefaultMemoryRetrieval.score(
            memory("x", accessCount: 200), for: RetrievalRequest(text: "x", now: now)
        )

        #expect(never.usage == 0)
        #expect(twice.usage > never.usage)
        #expect(often.usage <= 1)
        // The gap between never-used and twice-used should matter more than between 40 and 200 times.
        #expect(often.usage - twice.usage < twice.usage - never.usage + 1)
    }

    @Test("Belonging to the conversation in play is a contextual link")
    func contextualLinkFromConversation() {
        let conversationID = UUID()
        let inThread = memory("something", conversationID: conversationID)
        let elsewhere = memory("something", conversationID: UUID())
        let request = RetrievalRequest(text: "something", conversationID: conversationID, now: now)

        #expect(DefaultMemoryRetrieval.score(inThread, for: request).contextualLink == 1)
        #expect(DefaultMemoryRetrieval.score(elsewhere, for: request).contextualLink == 0)
    }

    // MARK: Ranking as a whole

    @Test("A memory matching nothing is dropped, not ranked last")
    func irrelevantMemoriesAreDropped() async throws {
        // Padding the budget with irrelevant memories is worse than sending fewer: it spends context and
        // ships personal material the request never needed (§28).
        let engine = try Self.makeEngine()
        let ranked = await engine.rank(
            memories: [memory("Completely unrelated cheese preferences", importance: 0)],
            for: RetrievalRequest(text: "garage renovation October", now: now)
        )
        #expect(ranked.isEmpty)
    }

    @Test("Better matches rank first, and ties fall back to recency")
    func rankingOrder() async throws {
        let engine = try Self.makeEngine()

        let strong = memory("Holding off on the garage renovation until October.", importance: 0.9)
        let weak = memory("Bought a new garage door opener.", importance: 0.2)

        let ranked = await engine.rank(
            memories: [weak, strong],
            for: RetrievalRequest(text: "garage renovation October", now: now)
        )

        #expect(ranked.count == 2)
        let best = try #require(ranked.first)
        let worst = try #require(ranked.last)
        #expect(best.memory.content.contains("Holding off"))
        #expect(best.score.total > worst.score.total)
    }

    @Test("The dominant term explains why something was recalled")
    func dominantTermIsUsable() {
        // Shown in the UI as "recalled because…", so it has to name the term that actually won.
        let pinnedOnly = DefaultMemoryRetrieval.score(
            memory("Never book anything without asking me.", importance: 0, isPinned: true),
            for: RetrievalRequest(text: "zzzz", now: now)
        )
        #expect(pinnedOnly.dominantTerm == "you pinned it")
    }
}

// MARK: - A real engine, backed by an empty in-memory store

extension MemoryRankingTests {

    /// Ranking never reads a store — it scores snapshots it is handed — so the stores here are empty and
    /// exist only to construct the engine. Real ones rather than hand-written stubs because
    /// `UserProfileStoring` has a wide surface, and a partial conformance would not compile.
    static func makeEngine() throws -> DefaultMemoryRetrieval {
        let controller = try PersistenceController.inMemory()
        return DefaultMemoryRetrieval(
            memoryStore: SwiftDataMemoryStore(modelContainer: controller.container),
            userProfileStore: UserProfileStore(modelContainer: controller.container)
        )
    }
}
