import Foundation

/// Product-level constants. Everything the user can change lives in `AssistantProfile`; this type
/// only holds the values AURA starts from and the invariants it enforces.
enum AuraDefaults {

    /// Default assistant name before onboarding renames it.
    static let assistantName = "AURA"

    /// Names offered during onboarding. The user can always type their own.
    static let suggestedAssistantNames = ["AURA", "Nova", "Atlas", "Echo", "Sage", "Iris"]

    /// Longest assistant name we accept. Keeps prompts and UI predictable.
    static let assistantNameMaxLength = 24

    /// Default `AVSpeechUtterance` rate, expressed on Apple's 0...1 scale.
    static let speechRate: Double = 0.5

    /// How many turns of the live conversation are treated as working memory.
    static let workingMemoryTurnLimit = 12

    /// Maximum tools the controlled agent loop may run for a single request (§36).
    static let maxToolIterations = 5

    /// Retrieval budgets: how much remembered context may enter one model request (§28).
    enum RetrievalBudget {
        static let memories = 8
        static let people = 4
        static let projects = 3
        static let profileFacts = 12
    }

    /// Importance thresholds from §18. Tuned by the tests in `MemoryImportanceTests`.
    enum ImportanceThreshold {
        /// At or above this, information becomes durable semantic/profile memory.
        static let durable = 0.85
        /// At or above this, information becomes an episodic/project memory candidate.
        static let episodic = 0.60
        /// Below `episodic`, the turn is only kept in the conversation archive.
        static let explicitRequest = 1.0
    }

    /// Confidence assigned to a fact the user stated outright versus hedged (§22).
    enum Confidence {
        static let explicit = 0.95
        static let inferred = 0.6
        static let hedged = 0.35
    }

    /// Sanitises a user-entered assistant name into something safe to put in a prompt and in UI.
    static func normalizedAssistantName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return assistantName }
        let collapsed = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(assistantNameMaxLength))
    }
}
