import Foundation

/// One turn, handed to the extractor.
struct ExtractionRequest: Sendable, Equatable {
    /// What the user said, verbatim.
    var userMessage: String
    /// What AURA replied. Useful because a confirmation ("so October, then?") often carries the fact.
    var assistantMessage: String?
    var conversationID: UUID?
    var userMessageID: UUID?
    /// Prior turns, for resolving references.
    var recentTurns: [String]
    /// People AURA already knows, so "Blake" attaches to the existing profile rather than creating a
    /// second one.
    var knownPeople: [PersonProfileSnapshot]
    var knownProjects: [ProjectSnapshot]
    /// Current memories that this turn might correct.
    var candidateSupersedables: [MemorySnapshot]
    var now: Date

    init(
        userMessage: String,
        assistantMessage: String? = nil,
        conversationID: UUID? = nil,
        userMessageID: UUID? = nil,
        recentTurns: [String] = [],
        knownPeople: [PersonProfileSnapshot] = [],
        knownProjects: [ProjectSnapshot] = [],
        candidateSupersedables: [MemorySnapshot] = [],
        now: Date = Date()
    ) {
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.recentTurns = recentTurns
        self.knownPeople = knownPeople
        self.knownProjects = knownProjects
        self.candidateSupersedables = candidateSupersedables
        self.now = now
    }
}

/// What the extractor concluded about a turn.
struct ExtractionResult: Sendable, Equatable {
    var candidates: [MemoryCandidateSnapshot]
    /// `true` when the user said "remember this" outright, which bypasses scoring (§19).
    var containsExplicitMemoryRequest: Bool
    /// `true` when the user said "forget that" — handled by the forget path, not by saving (§24).
    var containsForgetRequest: Bool
    /// `true` when the turn corrects something already stored (§23).
    var containsCorrection: Bool

    init(
        candidates: [MemoryCandidateSnapshot] = [],
        containsExplicitMemoryRequest: Bool = false,
        containsForgetRequest: Bool = false,
        containsCorrection: Bool = false
    ) {
        self.candidates = candidates
        self.containsExplicitMemoryRequest = containsExplicitMemoryRequest
        self.containsForgetRequest = containsForgetRequest
        self.containsCorrection = containsCorrection
    }

    static let nothing = ExtractionResult()

    /// Candidates the pipeline recommends keeping in some durable form.
    var retainableCandidates: [MemoryCandidateSnapshot] {
        candidates.filter {
            $0.retentionRecommendation == .durable || $0.retentionRecommendation == .episodic
        }
    }
}

/// Decides what in a conversation is worth remembering (§17, §18, §20).
///
/// The specification's hard rule is "do not save everything", and this is where that is enforced.
/// The extractor is expected to reject most turns outright — small talk, questions, filler — and to
/// produce a candidate only when something looks durable.
///
/// Implementations run **on-device only** (`ModelRequestPurpose.memoryExtraction`). Extraction sees
/// raw, unfiltered user speech before any relevance judgement has been made, so sending it to a
/// third-party provider would leak precisely what §50 exists to protect.
protocol MemoryExtracting: Sendable {
    func extract(from request: ExtractionRequest) async throws -> ExtractionResult
}

/// Scores how much a statement deserves durable storage (§18).
///
/// A protocol with a pure function behind it, separate from extraction, because it is the piece most
/// worth testing in isolation: given a sentence and its signals, the score must be stable and
/// explainable.
protocol MemoryImportanceScoring: Sendable {
    /// - Returns: 0...1, compared against `AuraDefaults.ImportanceThreshold`.
    func importance(for signals: MemoryImportanceSignals) -> Double

    /// Turns a score into a storage decision.
    func recommendation(for score: Double, signals: MemoryImportanceSignals) -> RetentionRecommendation
}

/// The inputs to an importance score. Deliberately explicit rather than "here's the sentence, guess"
/// — every signal is separately assertable in a test.
struct MemoryImportanceSignals: Sendable, Equatable {
    /// The user asked for this to be remembered in so many words.
    var isExplicitRequest: Bool
    /// Phrased as a standing preference: "I always…", "I prefer…", "I never…".
    var isStablePreference: Bool
    /// Concerns a person in the user's life.
    var involvesImportantPerson: Bool
    /// Attaches to an ongoing project.
    var involvesProject: Bool
    /// Records a decision the user made.
    var isDecision: Bool
    /// Contains a date worth keeping.
    var containsImportantDate: Bool
    /// States an obligation.
    var isCommitment: Bool
    /// Hedged — "I think", "maybe", "probably" (§22).
    var isHedged: Bool
    /// Scoped to right now: "for the rest of today", "until this meeting ends".
    var isTransient: Bool
    /// A question rather than a statement. Questions are not facts about the user.
    var isQuestion: Bool
    /// Conversational filler with no content.
    var isSmallTalk: Bool
    var category: MemoryCategory

    init(
        isExplicitRequest: Bool = false,
        isStablePreference: Bool = false,
        involvesImportantPerson: Bool = false,
        involvesProject: Bool = false,
        isDecision: Bool = false,
        containsImportantDate: Bool = false,
        isCommitment: Bool = false,
        isHedged: Bool = false,
        isTransient: Bool = false,
        isQuestion: Bool = false,
        isSmallTalk: Bool = false,
        category: MemoryCategory = .other
    ) {
        self.isExplicitRequest = isExplicitRequest
        self.isStablePreference = isStablePreference
        self.involvesImportantPerson = involvesImportantPerson
        self.involvesProject = involvesProject
        self.isDecision = isDecision
        self.containsImportantDate = containsImportantDate
        self.isCommitment = isCommitment
        self.isHedged = isHedged
        self.isTransient = isTransient
        self.isQuestion = isQuestion
        self.isSmallTalk = isSmallTalk
        self.category = category
    }
}

/// Applies accepted candidates to the stores (§20, §21, §23).
///
/// Kept apart from extraction because deciding *what* a statement means and deciding *where it goes*
/// are different problems with different failure modes. This is the side that knows a favourite
/// driver belongs on the profile while a hotel choice belongs in episodic memory, and that a
/// correction supersedes rather than overwrites.
protocol MemoryConsolidating: Sendable {
    /// Writes one candidate wherever it belongs, returning everything it touched.
    func consolidate(_ candidate: MemoryCandidateSnapshot) async throws -> ConsolidationOutcome

    /// Handles "forget that" (§24).
    /// - Returns: how many records were removed, so AURA can confirm honestly rather than assuming.
    @discardableResult
    func forget(matching request: ForgetRequest) async throws -> ForgetOutcome
}

/// What consolidating one candidate actually changed.
struct ConsolidationOutcome: Sendable, Equatable {
    var savedMemory: MemorySnapshot?
    var supersededMemoryID: UUID?
    var updatedProfileFactID: UUID?
    var createdPersonID: UUID?
    var updatedPersonID: UUID?
    var createdProjectID: UUID?
    var createdTaskID: UUID?

    init(
        savedMemory: MemorySnapshot? = nil,
        supersededMemoryID: UUID? = nil,
        updatedProfileFactID: UUID? = nil,
        createdPersonID: UUID? = nil,
        updatedPersonID: UUID? = nil,
        createdProjectID: UUID? = nil,
        createdTaskID: UUID? = nil
    ) {
        self.savedMemory = savedMemory
        self.supersededMemoryID = supersededMemoryID
        self.updatedProfileFactID = updatedProfileFactID
        self.createdPersonID = createdPersonID
        self.updatedPersonID = updatedPersonID
        self.createdProjectID = createdProjectID
        self.createdTaskID = createdTaskID
    }

    static let nothing = ConsolidationOutcome()

    var didChangeAnything: Bool { self != .nothing }
}

/// A request to forget something (§24).
struct ForgetRequest: Sendable, Equatable {
    /// Explicit ids, when the user tapped a specific memory.
    var memoryIDs: [UUID]
    /// Free text — "everything about my old job".
    var subject: String?
    /// Everything tied to a person: "delete what you remember about John".
    var personID: UUID?
    var projectID: UUID?
    var conversationID: UUID?
    /// Also drop matching structured profile facts, not just memories.
    var includesProfileFacts: Bool

    init(
        memoryIDs: [UUID] = [],
        subject: String? = nil,
        personID: UUID? = nil,
        projectID: UUID? = nil,
        conversationID: UUID? = nil,
        includesProfileFacts: Bool = true
    ) {
        self.memoryIDs = memoryIDs
        self.subject = subject
        self.personID = personID
        self.projectID = projectID
        self.conversationID = conversationID
        self.includesProfileFacts = includesProfileFacts
    }

    /// Broad deletions need confirmation before they run (§24).
    var requiresConfirmation: Bool {
        personID != nil || projectID != nil || (subject?.isEmpty == false)
    }
}

/// The result of a forget operation — counted, so AURA reports what it actually did (§78).
struct ForgetOutcome: Sendable, Equatable {
    var deletedMemoryCount: Int
    var deletedProfileFactCount: Int
    var deletedPersonCount: Int
    /// Titles of what was removed, for a confirmation the user can verify.
    var deletedSummaries: [String]

    init(
        deletedMemoryCount: Int = 0,
        deletedProfileFactCount: Int = 0,
        deletedPersonCount: Int = 0,
        deletedSummaries: [String] = []
    ) {
        self.deletedMemoryCount = deletedMemoryCount
        self.deletedProfileFactCount = deletedProfileFactCount
        self.deletedPersonCount = deletedPersonCount
        self.deletedSummaries = deletedSummaries
    }

    static let nothing = ForgetOutcome()

    var totalCount: Int {
        deletedMemoryCount + deletedProfileFactCount + deletedPersonCount
    }

    var didDeleteAnything: Bool { totalCount > 0 }
}
