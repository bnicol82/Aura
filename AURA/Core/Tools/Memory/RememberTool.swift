import Foundation

/// "Remember that…" — writes a fact the user asked to be kept (§24, §33).
///
/// ### Why this exists when extraction already runs
/// `ModelMemoryExtractor` decides what is worth keeping from every turn, and it is deliberately
/// conservative. This tool is the override: when the user says "remember this", the decision has
/// already been made by the person whose memory it is, and AURA's judgement about importance is not
/// wanted. So the draft goes in at `explicitRequest` importance with `wasExplicitlyRequested` set,
/// which is the same signal `DefaultMemoryImportanceScorer` treats as an absolute.
///
/// ### Why `reversible` rather than `readOnly`
/// It writes. A tool the *model* reached for on its own therefore gets confirmed, which is the point:
/// AURA quietly deciding to record something about the user is exactly the behaviour §24 is written
/// against. When the user asked in so many words, it just happens.
struct RememberTool: AssistantTool {

    let id = "memory.remember"
    let name = "remember_this"

    var description: String {
        """
        Store something the user has explicitly asked you to remember about them, their preferences, \
        their people, or their plans. Use this only when they asked you to remember — ordinary facts \
        mentioned in passing are captured automatically and do not need this tool. Never use it to \
        store something you inferred.
        """
    }

    var parameters: ToolParameterSchema {
        ToolParameterSchema([
            ToolParameter(
                name: "content",
                description: """
                    The fact to remember, written as a standalone statement in the third person: \
                    "Prefers morning meetings", not "you prefer morning meetings". It must make sense \
                    read months later with no surrounding conversation.
                    """,
                type: .string,
                isRequired: true
            ),
            ToolParameter(
                name: "category",
                description: "What the fact is about. Omit if none of the values clearly fits.",
                type: .string,
                isRequired: false,
                allowedValues: MemoryCategory.allCases.map(\.rawValue)
            )
        ])
    }

    let riskLevel: ToolRiskLevel = .reversible

    private let memoryStore: any MemoryStoring

    init(memoryStore: any MemoryStoring) {
        self.memoryStore = memoryStore
    }

    func progressLabel(for arguments: ToolArguments) -> String {
        "Remembering that"
    }

    func confirmationPrompt(for arguments: ToolArguments) -> String {
        // Quotes the content rather than naming the tool, because what the user needs to approve is the
        // sentence that will be kept about them, not the fact that a tool ran.
        guard let content = arguments.optionalString("content") else {
            return "Remember something from this conversation?"
        }
        return "Remember “\(Self.trimmedForDisplay(content))”?"
    }

    func execute(arguments: ToolArguments, context: ToolExecutionContext) async throws -> ToolResult {
        let content = try arguments.string("content")
        let category = Self.category(from: arguments.optionalString("category"))

        let draft = MemoryDraft(
            content: content,
            memoryType: Self.memoryType(for: category),
            category: category,
            // The user asked. AURA does not get a second opinion on how important that is (§18).
            importance: AuraDefaults.ImportanceThreshold.explicitRequest,
            confidence: AuraDefaults.Confidence.explicit,
            wasExplicitlyRequested: true,
            sourceConversationID: context.conversationID,
            sourceMessageIDs: [context.messageID].compactMap { $0 }
        )

        let saved = try await memoryStore.save(draft)

        return ToolResult(
            // Factual and past-tense, so the model has nothing to embroider. It knows the write
            // happened because this text exists; it never has to guess.
            modelFacingText: "Saved to long-term memory: \(saved.content)",
            activityLabel: "Remembered",
            outcomeSummary: Self.trimmedForDisplay(saved.summary),
            structuredResult: .object([
                "memory_id": .string(saved.id.uuidString),
                "category": .string(saved.category.rawValue)
            ]),
            didMutateData: true
        )
    }

    // MARK: - Pure helpers

    /// Maps a category onto the memory layer it belongs in (§17).
    ///
    /// `static` and pure so the mapping is one readable table with a test, rather than a decision made
    /// inline while a database transaction is open. Anything the user asked to be kept is durable by
    /// default — an explicit request is not a passing remark — so only the genuinely time-bound
    /// categories land anywhere else.
    static func memoryType(for category: MemoryCategory) -> MemoryType {
        switch category {
        case .person, .relationship: return .person
        case .project, .goal: return .project
        case .temporaryContext: return .episodic
        default: return .semantic
        }
    }

    /// Parses the model's category string, falling back to `.other` rather than failing the write.
    ///
    /// A wrong category costs a slightly worse retrieval. Refusing to remember something the user
    /// asked for because the model spelled a taxonomy value oddly costs the user their fact, which is
    /// far worse — the whole tool exists to honour that request.
    static func category(from raw: String?) -> MemoryCategory {
        guard let raw else { return .other }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return MemoryCategory.allCases.first { $0.rawValue.lowercased() == normalized } ?? .other
    }

    /// Shortens text for a confirmation prompt or an Activity row.
    ///
    /// Truncation is on a word boundary with an ellipsis, because a prompt that stops mid-word reads
    /// like a bug in the moment the user is deciding whether to trust what they are approving.
    static func trimmedForDisplay(_ text: String, limit: Int = 80) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }

        let clipped = collapsed.prefix(limit)
        guard let lastSpace = clipped.lastIndex(of: " ") else { return String(clipped) + "…" }
        return String(clipped[clipped.startIndex..<lastSpace]) + "…"
    }
}
