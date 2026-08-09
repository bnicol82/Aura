import Foundation

/// Looks through what AURA already knows (§30, §33).
///
/// ### Why a tool, when memory is already injected into every turn
/// `DefaultMemoryRetrieval` puts the most relevant memories into the prompt before the model sees the
/// question, which covers the ordinary case. It cannot cover the case where the model realises
/// mid-answer that it needs something the retrieval query missed — "what did I say about the garage
/// again?" after three turns about something else. This tool is that second look, and it is the only
/// honest alternative to the model inventing a recollection.
///
/// ### Why `readOnly` is genuinely read-only
/// It reads AURA's own store and nothing else: no calendar, no contacts, no network. So it needs no
/// permission and no confirmation, and it stays available offline. `recordAccess` does write, but it
/// writes usage counters that feed ranking — it changes nothing the user would recognise as their
/// data, which is why `didMutateData` stays `false`.
struct SearchMemoryTool: AssistantTool {

    let id = "memory.search"
    let name = "search_memory"

    var description: String {
        """
        Search everything you have remembered about the user. Use this when you need a detail that \
        isn't in front of you and you would otherwise be guessing. Returns nothing when nothing \
        matches — in that case say you don't know rather than filling the gap.
        """
    }

    var parameters: ToolParameterSchema {
        ToolParameterSchema([
            ToolParameter(
                name: "query",
                description: """
                    What to look for, as the words you would expect to appear in the memory itself. \
                    Keep it to the distinctive terms — "garage renovation" rather than "what did the \
                    user say about renovating their garage". Every word must appear for a memory to \
                    match, so extra words narrow the search.
                    """,
                type: .string,
                isRequired: true
            ),
            ToolParameter(
                name: "category",
                description: "Restrict to one subject area. Omit to search everything.",
                type: .string,
                isRequired: false,
                allowedValues: MemoryCategory.allCases.map(\.rawValue)
            )
        ])
    }

    let riskLevel: ToolRiskLevel = .readOnly

    /// How many memories one search may return.
    ///
    /// Bounded for the §28 reason rather than for performance: an unbounded search would be a way to
    /// pull the user's entire history into a prompt one tool call at a time.
    static let resultLimit = AuraDefaults.RetrievalBudget.memories

    private let memoryStore: any MemoryStoring

    init(memoryStore: any MemoryStoring) {
        self.memoryStore = memoryStore
    }

    func progressLabel(for arguments: ToolArguments) -> String {
        "Checking what I remember"
    }

    func execute(arguments: ToolArguments, context: ToolExecutionContext) async throws -> ToolResult {
        let query = try arguments.string("query")
        let category = arguments.optionalString("category").flatMap(Self.explicitCategory(from:))

        let matches = try await memoryStore.search(
            MemoryQuery(
                text: query,
                categories: category.map { [$0] } ?? [],
                // Most important first rather than newest: a search is looking for the *relevant*
                // memory, and a trivial recent one outranking a standing preference would be wrong.
                sortOrder: .mostImportantFirst,
                limit: Self.resultLimit
            )
        )

        guard !matches.isEmpty else {
            return ToolResult(
                // Stated flatly and unmistakably. Anything softer — "I couldn't find much" — invites the
                // model to fill the gap from the question itself (§78).
                modelFacingText: "No stored memories match “\(query)”. You do not know this.",
                activityLabel: "Searched memory",
                outcomeSummary: "Nothing about “\(RememberTool.trimmedForDisplay(query, limit: 40))”",
                didMutateData: false
            )
        }

        // Recorded before returning, so a memory the model actually used ranks higher next time. Failures
        // are swallowed inside the store: ranking is not worth failing a turn over.
        await memoryStore.recordAccess(ids: matches.map(\.id), at: context.now)

        return ToolResult(
            modelFacingText: Self.render(matches, matching: query, now: context.now),
            activityLabel: "Searched memory",
            outcomeSummary: Self.outcomeSummary(count: matches.count),
            structuredResult: .array(matches.map { .string($0.content) }),
            // Access counters are not the user's data in any sense they would recognise, so this is not
            // a mutation the orchestrator needs to refresh anything for.
            didMutateData: false
        )
    }

    // MARK: - Pure rendering

    /// The category the model named, or `nil` when it named nothing recognisable.
    ///
    /// Deliberately different from `RememberTool.category(from:)`, which falls back to `.other`. On a
    /// *write*, `.other` is a reasonable place to put a fact. On a *search* it would silently narrow to
    /// the one bucket the answer is least likely to be in, and the model would be told "you do not know
    /// this" about something AURA has written down. An unrecognised filter must widen to everything.
    static func explicitCategory(from raw: String) -> MemoryCategory? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return MemoryCategory.allCases.first { $0.rawValue.lowercased() == normalized }
    }

    /// Formats matches for the model.
    ///
    /// `static` and pure so the exact wording is pinned by a test. Two things it must do and one it
    /// must not: date each memory, because "prefers mornings" recorded two years ago is weaker
    /// evidence than the same line from last week; flag hedged memories, because §22's confidence is
    /// worthless if it is dropped on the way into the prompt. What it must not do is offer any
    /// conclusion — that is the model's job, from the facts as they actually are.
    static func render(_ memories: [MemorySnapshot], matching query: String, now: Date) -> String {
        let lines = memories.map { memory -> String in
            var line = "- \(memory.content)"
            line += " (recorded \(relativeAge(of: memory.createdAt, now: now))"
            if memory.confidence <= AuraDefaults.Confidence.hedged {
                line += ", uncertain"
            }
            line += ")"
            return line
        }
        return """
            \(memories.count) stored \(memories.count == 1 ? "memory" : "memories") matching “\(query)”:
            \(lines.joined(separator: "\n"))
            """
    }

    static func outcomeSummary(count: Int) -> String {
        count == 1 ? "Found 1 memory" : "Found \(count) memories"
    }

    /// A coarse age for a memory, in the terms a person would use.
    ///
    /// Deliberately vague at the long end: "over a year ago" is what matters about an old fact, and a
    /// precise date would invite the model to quote it as though the user had said so.
    static func relativeAge(of date: Date, now: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        case 60..<365: return "\(days / 30) months ago"
        default: return "over a year ago"
        }
    }
}
