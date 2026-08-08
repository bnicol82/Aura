import Foundation
import Testing

@testable import AURA

/// Memory query narrowing and ordering (§28, §30).
///
/// `narrow` and `sort` are pure and take snapshots, so the rules that decide what reaches a model are
/// testable without a database. That matters more here than elsewhere: this is where §28's "only what this
/// request needs" is actually kept or broken, and a filter that is too loose leaks context silently.
@Suite("Memory store queries")
struct MemoryStoreTests {

    private func memory(
        content: String = "",
        summary: String = "",
        category: MemoryCategory = .other,
        memoryType: MemoryType = .semantic,
        importance: Double = 0.7,
        tags: [String] = [],
        entities: [String] = [],
        personIDs: [UUID] = [],
        isPinned: Bool = false,
        createdAt: Date = Date(),
        lastAccessedAt: Date? = nil
    ) -> MemorySnapshot {
        MemorySnapshot(
            content: content,
            summary: summary,
            memoryType: memoryType,
            category: category,
            importance: importance,
            relatedPersonIDs: personIDs,
            tags: tags,
            entities: entities,
            isPinned: isPinned,
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt
        )
    }

    // MARK: Text matching

    @Test("Every word in a query must appear somewhere")
    func textRequiresAllWords() {
        let garage = memory(content: "Holding off on the garage renovation until October.")
        let unrelated = memory(content: "The garage door opener needs a new battery.")

        let matches = SwiftDataMemoryStore.narrow(
            [garage, unrelated],
            with: MemoryQuery(text: "garage October")
        )

        // Requiring all words is what stops "garage October" matching every garage memory ever stored.
        #expect(matches.count == 1)
        #expect(matches.first?.content.contains("until October") == true)
    }

    @Test("Matching is substring, so a plural or suffix still matches")
    func textMatchesSubstrings() {
        let memories = [memory(content: "Planning the garage renovations for spring.")]
        #expect(!SwiftDataMemoryStore.narrow(memories, with: MemoryQuery(text: "renovation")).isEmpty)
    }

    @Test("Single characters are ignored rather than matching everything")
    func textIgnoresNoiseWords() {
        // Without the length filter, "a" or "I" would match every memory in the database and the query
        // would silently become unfiltered — the exact failure §28 is written against.
        let memories = [memory(content: "Blake studies mechanical engineering.")]
        #expect(SwiftDataMemoryStore.narrow(memories, with: MemoryQuery(text: "zzz")).isEmpty)
        #expect(!SwiftDataMemoryStore.narrow(memories, with: MemoryQuery(text: "a Blake")).isEmpty)
    }

    @Test("Tags and entities are searchable, not just content")
    func haystackCoversTagsAndEntities() {
        let tagged = memory(content: "Booked the flights.", tags: ["holiday"], entities: ["Lisbon"])
        let haystack = SwiftDataMemoryStore.haystack(for: tagged)

        #expect(haystack.contains("holiday"))
        #expect(haystack.contains("lisbon"))
        #expect(!SwiftDataMemoryStore.narrow([tagged], with: MemoryQuery(text: "Lisbon")).isEmpty)
    }

    // MARK: Structured filters

    @Test("Category, type and person filters all exclude non-matches")
    func structuredFiltersExclude() {
        let blake = UUID()
        let jennifer = UUID()

        let aboutBlake = memory(category: .education, memoryType: .person, personIDs: [blake])
        let aboutJennifer = memory(category: .food, memoryType: .episodic, personIDs: [jennifer])

        let byCategory = SwiftDataMemoryStore.narrow(
            [aboutBlake, aboutJennifer],
            with: MemoryQuery(categories: [.education])
        )
        #expect(byCategory.count == 1)

        let byPerson = SwiftDataMemoryStore.narrow(
            [aboutBlake, aboutJennifer],
            with: MemoryQuery(personIDs: [jennifer])
        )
        #expect(byPerson.count == 1)
        #expect(byPerson.first?.relatedPersonIDs == [jennifer])

        let byType = SwiftDataMemoryStore.narrow(
            [aboutBlake, aboutJennifer],
            with: MemoryQuery(memoryTypes: [.episodic])
        )
        #expect(byType.count == 1)
    }

    @Test("An empty filter set does not filter")
    func emptyFiltersMatchEverything() {
        // An empty set means "no opinion", not "match nothing" — treating it as the latter would make a
        // partially-specified query return nothing and look like a memory loss.
        let memories = [memory(category: .food), memory(category: .work)]
        #expect(SwiftDataMemoryStore.narrow(memories, with: MemoryQuery()).count == 2)
    }

    // MARK: Pinning

    @Test("A pinned memory bypasses matching when the caller asks for that")
    func pinnedBypassesMatching() {
        // Pinning is the user saying "always consider this", so it must survive a query it does not match.
        let pinned = memory(content: "Never book anything without asking me.", isPinned: true)
        let other = memory(content: "Something about cheese.")

        let matches = SwiftDataMemoryStore.narrow(
            [pinned, other],
            with: MemoryQuery(text: "garage", includePinnedRegardlessOfMatch: true)
        )
        #expect(matches.count == 1)
        #expect(matches.first?.isPinned == true)

        // And it does not bypass when the caller did not ask.
        let strict = SwiftDataMemoryStore.narrow([pinned, other], with: MemoryQuery(text: "garage"))
        #expect(strict.isEmpty)
    }

    // MARK: Ordering

    @Test("Sort orders do what they say, and never-used memories sort last")
    func sortOrders() throws {
        let old = memory(content: "old", importance: 0.9, createdAt: Date(timeIntervalSince1970: 1_000))
        let recent = memory(content: "recent", importance: 0.5, createdAt: Date(timeIntervalSince1970: 9_000))
        let used = memory(
            content: "used",
            importance: 0.6,
            createdAt: Date(timeIntervalSince1970: 5_000),
            lastAccessedAt: Date(timeIntervalSince1970: 9_500)
        )
        let all = [old, recent, used]

        #expect(SwiftDataMemoryStore.sort(all, by: .newestFirst).first?.content == "recent")
        #expect(SwiftDataMemoryStore.sort(all, by: .oldestFirst).first?.content == "old")
        #expect(SwiftDataMemoryStore.sort(all, by: .mostImportantFirst).first?.content == "old")

        let byUse = SwiftDataMemoryStore.sort(all, by: .recentlyUsedFirst)
        #expect(byUse.first?.content == "used")
        // `nil` last accessed must sort last, not first, which is what a naive optional comparison gives.
        #expect(byUse.last?.lastAccessedAt == nil)
    }

    @Test("Equal importance falls back to recency rather than an arbitrary order")
    func importanceTiesBreakOnRecency() {
        let older = memory(content: "older", importance: 0.8, createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = memory(content: "newer", importance: 0.8, createdAt: Date(timeIntervalSince1970: 2_000))

        let sorted = SwiftDataMemoryStore.sort([older, newer], by: .mostImportantFirst)
        #expect(sorted.first?.content == "newer")
    }
}
