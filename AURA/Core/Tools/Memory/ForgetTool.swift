import Foundation

/// "Forget that" — deletes what the user asks AURA to stop knowing (§24, §48).
///
/// ### Why this is `consequential` when `remember_this` is only `reversible`
/// The asymmetry is the point. A wrongly-remembered fact is an annoyance the user can delete. A
/// wrongly-*forgotten* one is gone: §24 requires a hard delete, not an archive, because a user who
/// asks AURA to forget something and later finds it still in the store has been lied to. There is no
/// undo to fall back on, so this always stops and asks — even when the user asked for it outright.
///
/// ### Why it reports what it removed rather than "done"
/// A text query can match nothing, one thing, or more than the user had in mind. Reporting the count
/// and the summaries is the difference between the user knowing what happened and having to take
/// AURA's word for it (§78). "Nothing matched" is a normal outcome and is stated plainly rather than
/// dressed up as success.
struct ForgetTool: AssistantTool {

    let id = "memory.forget"
    let name = "forget_this"

    var description: String {
        """
        Permanently delete something you have remembered, because the user asked you to forget it. \
        Use only on an explicit request. This cannot be undone, and it deletes every memory matching \
        the query, so make the query specific.
        """
    }

    var parameters: ToolParameterSchema {
        ToolParameterSchema([
            ToolParameter(
                name: "query",
                description: """
                    The distinctive words identifying what to forget. Every word must appear in a \
                    memory for it to be deleted, so more words means a narrower, safer deletion. Use \
                    the subject itself — "old landlord" — not the user's phrasing of the request.
                    """,
                type: .string,
                isRequired: true
            )
        ])
    }

    let riskLevel: ToolRiskLevel = .consequential

    /// Ceiling on one deletion.
    ///
    /// A vague query ("work") could otherwise match most of what AURA knows, and the user approving a
    /// prompt about one memory would lose thirty. Above this the tool refuses and asks for something
    /// narrower — which is recoverable, whereas the deletion would not have been. "Forget everything"
    /// is a Settings action with its own confirmation (§48), not something a tool call reaches.
    static let deletionCeiling = 10

    private let memoryStore: any MemoryStoring

    init(memoryStore: any MemoryStoring) {
        self.memoryStore = memoryStore
    }

    func progressLabel(for arguments: ToolArguments) -> String {
        "Forgetting that"
    }

    func confirmationPrompt(for arguments: ToolArguments) -> String {
        // Names the effect and its permanence. `confirmationPrompt` is synchronous, so it cannot count
        // the matches first — hence "everything I've stored about", which is what will actually happen
        // rather than an implied single item.
        guard let query = arguments.optionalString("query") else {
            return "Permanently forget what I've stored about this? This can't be undone."
        }
        return "Permanently forget everything I've stored about “\(RememberTool.trimmedForDisplay(query, limit: 60))”? This can't be undone."
    }

    func execute(arguments: ToolArguments, context: ToolExecutionContext) async throws -> ToolResult {
        let query = try arguments.string("query")

        // Archived memories are included: from the user's point of view an archived memory is still
        // something AURA knows, and leaving it behind would make "forget that" a half-truth.
        let matches = try await memoryStore.search(
            MemoryQuery(
                text: query,
                includeArchived: true,
                sortOrder: .newestFirst,
                // One past the ceiling, so "more than the ceiling" is distinguishable from "exactly it".
                limit: Self.deletionCeiling + 1
            )
        )

        guard !matches.isEmpty else {
            return ToolResult(
                modelFacingText: """
                    Nothing stored matches “\(query)”, so nothing was deleted. There was no such memory \
                    to begin with.
                    """,
                activityLabel: "Nothing to forget",
                outcomeSummary: "No match for “\(RememberTool.trimmedForDisplay(query, limit: 40))”",
                didMutateData: false
            )
        }

        guard matches.count <= Self.deletionCeiling else {
            // Refused rather than truncated. Deleting the first ten of a wider match would be the worst
            // available outcome: irreversible, arbitrary, and reported as though it were what was asked.
            throw AuraError.toolFailed(
                toolName: name,
                reason: """
                    “\(query)” matches more than \(Self.deletionCeiling) stored memories. Ask for \
                    something more specific, or clear memory from Settings.
                    """
            )
        }

        try await memoryStore.delete(ids: matches.map(\.id))

        return ToolResult(
            modelFacingText: Self.render(deleted: matches),
            activityLabel: "Forgot",
            outcomeSummary: Self.outcomeSummary(deleted: matches),
            didMutateData: true
        )
    }

    // MARK: - Pure rendering

    /// What the model is told after a successful deletion.
    ///
    /// Lists the memories by summary rather than saying "done", so the reply the user reads can name
    /// what actually went. `static` and pure so the wording is pinned by a test — this is the one
    /// message in the app that describes an irreversible act.
    static func render(deleted: [MemorySnapshot]) -> String {
        guard deleted.count > 1 else {
            return "Deleted permanently: \(deleted[0].content). You no longer know this."
        }
        let lines = deleted.map { "- \($0.summary)" }.joined(separator: "\n")
        return """
            Deleted \(deleted.count) memories permanently. You no longer know any of these:
            \(lines)
            """
    }

    static func outcomeSummary(deleted: [MemorySnapshot]) -> String {
        guard deleted.count > 1 else {
            return RememberTool.trimmedForDisplay(deleted[0].summary)
        }
        return "\(deleted.count) memories"
    }
}
