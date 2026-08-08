import Foundation

/// The assistant's identity, as the rest of the app needs it.
struct AssistantIdentity: Sendable, Equatable {
    var name: String
    var userPreferredName: String?

    init(name: String, userPreferredName: String? = nil) {
        self.name = name
        self.userPreferredName = userPreferredName
    }
}

/// Everything one request is permitted to know (§27).
///
/// This type is the privacy boundary made concrete. A `ModelRequest`'s instructions are built from
/// exactly this and nothing else, so the answer to "what did AURA send about me?" is always "the
/// contents of one `PersonalizationContext`" — inspectable, bounded, and small.
struct PersonalizationContext: Sendable, Equatable {
    var identity: AssistantIdentity
    /// Behavioural instructions from `PersonalityEngine`. Already complete; never appended to.
    var personalityInstructions: String
    /// The user's standing instructions, verbatim.
    var standingInstructions: [String]
    var relevantFacts: [ProfileFactSnapshot]
    var relevantPeople: [PersonProfileSnapshot]
    var relevantProjects: [ProjectSnapshot]
    var relevantMemories: [RankedMemory]
    var outstandingTasks: [AssistantTaskSnapshot]
    var sensitivityMode: SensitivityMode
    /// `true` when memory was withheld because the user turned it off (§48).
    var memoryWasSuppressedByPreference: Bool
    var assembledAt: Date

    init(
        identity: AssistantIdentity,
        personalityInstructions: String,
        standingInstructions: [String] = [],
        relevantFacts: [ProfileFactSnapshot] = [],
        relevantPeople: [PersonProfileSnapshot] = [],
        relevantProjects: [ProjectSnapshot] = [],
        relevantMemories: [RankedMemory] = [],
        outstandingTasks: [AssistantTaskSnapshot] = [],
        sensitivityMode: SensitivityMode = .normal,
        memoryWasSuppressedByPreference: Bool = false,
        assembledAt: Date = Date()
    ) {
        self.identity = identity
        self.personalityInstructions = personalityInstructions
        self.standingInstructions = standingInstructions
        self.relevantFacts = relevantFacts
        self.relevantPeople = relevantPeople
        self.relevantProjects = relevantProjects
        self.relevantMemories = relevantMemories
        self.outstandingTasks = outstandingTasks
        self.sensitivityMode = sensitivityMode
        self.memoryWasSuppressedByPreference = memoryWasSuppressedByPreference
        self.assembledAt = assembledAt
    }

    /// `true` when nothing personal is attached — a first conversation, or memory switched off.
    var carriesNoPersonalContext: Bool {
        relevantFacts.isEmpty
            && relevantPeople.isEmpty
            && relevantProjects.isEmpty
            && relevantMemories.isEmpty
            && outstandingTasks.isEmpty
    }

    /// How many discrete personal items this request carries. Surfaced in the Privacy dashboard so
    /// "what was sent" is a number the user can actually see.
    var personalItemCount: Int {
        relevantFacts.count
            + relevantPeople.count
            + relevantProjects.count
            + relevantMemories.count
            + outstandingTasks.count
    }

    /// The complete `instructions` string for a `ModelRequest`.
    ///
    /// Assembled here rather than in each provider so every provider receives byte-identical context
    /// and the privacy audit has one place to look.
    func modelInstructions(now: Date = Date()) -> String {
        var sections: [String] = [personalityInstructions]

        var knowledge: [String] = []

        if let userName = identity.userPreferredName, !userName.isBlank {
            knowledge.append("The user's name is \(userName).")
        }

        if !relevantFacts.isEmpty {
            knowledge.append("")
            knowledge.append("What you know about the user that's relevant here:")
            knowledge.append(contentsOf: relevantFacts.map { "- \($0.contextLine)" })
        }

        if !relevantPeople.isEmpty {
            knowledge.append("")
            knowledge.append("People relevant to this request:")
            knowledge.append(contentsOf: relevantPeople.map { "- \($0.contextLine)" })
        }

        if !relevantProjects.isEmpty {
            knowledge.append("")
            knowledge.append("Ongoing projects relevant to this request:")
            knowledge.append(contentsOf: relevantProjects.map { "- \($0.contextLine)" })
        }

        if !relevantMemories.isEmpty {
            knowledge.append("")
            knowledge.append("Things you remember that bear on this request:")
            knowledge.append(contentsOf: relevantMemories.map { "- \($0.memory.contextLine)" })
        }

        if !outstandingTasks.isEmpty {
            knowledge.append("")
            knowledge.append("Outstanding commitments:")
            knowledge.append(contentsOf: outstandingTasks.map { task in
                if let due = task.dueDate {
                    return "- \(task.title) (due \(due.formatted(date: .abbreviated, time: .omitted)))"
                }
                return "- \(task.title)"
            })
        }

        if knowledge.isEmpty {
            // Stated explicitly so the model doesn't fill the silence with plausible invention (§78).
            knowledge.append("")
            knowledge.append("You have no stored information relevant to this request. Do not guess at any.")
        }

        sections.append(knowledge.joined(separator: "\n"))

        sections.append("")
        sections.append("The current date and time is \(now.formatted(date: .complete, time: .shortened)).")

        return sections.joined(separator: "\n")
    }
}

/// What the engine is asked to build context for.
struct PersonalizationRequest: Sendable, Equatable {
    /// The user's message, verbatim.
    var userMessage: String
    var conversationID: UUID?
    /// Recent turns, for reference resolution.
    var recentTurns: [String]
    var now: Date
    /// How much retrieved material may be included. `.none` when memory is switched off.
    var budget: RetrievalRequest.Budget

    init(
        userMessage: String,
        conversationID: UUID? = nil,
        recentTurns: [String] = [],
        now: Date = Date(),
        budget: RetrievalRequest.Budget = .default
    ) {
        self.userMessage = userMessage
        self.conversationID = conversationID
        self.recentTurns = recentTurns
        self.now = now
        self.budget = budget
    }
}

/// Assembles the context for a request (§27, §28, §29).
///
/// The engine's contract is *selectivity*: retrieve what this request needs and stop. It never loads
/// the whole profile or the whole memory store, because "send everything and let the model sort it
/// out" is worse on privacy, latency, cost and accuracy at the same time.
///
/// It also owns the priority order in §29 — a standing preference for short answers loses to "explain
/// this in detail" in the current message, because current instructions outrank stored ones.
protocol PersonalizationEngineProtocol: Sendable {
    func buildContext(for request: PersonalizationRequest) async throws -> PersonalizationContext
}
