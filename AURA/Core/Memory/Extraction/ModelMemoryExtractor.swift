import FoundationModels
import Foundation

/// Decides what a turn is worth remembering (§20, §21, §22).
///
/// ### The split, and why it is not all handed to the model
/// A model is good at "what did this person actually tell me" and bad at being audited. So the work is
/// divided:
///
/// * **The model** produces candidate statements and classifies them. That needs language understanding.
/// * **Pure functions** detect the signals that carry consequences — an explicit "remember this", a "forget
///   that", a correction, a hedge, a question. Those are deterministic, unit-tested, and readable, which
///   matters because each one changes what AURA does with the user's data rather than merely how it words a
///   reply.
///
/// Asking the model whether the user said "remember this" would make §19's guarantee — the user's own words
/// outrank everything — depend on a probability. It is a text match, so it is written as one.
///
/// ### Pinned on-device
/// `ModelRequestPurpose.memoryExtraction.isOnDeviceOnly` is `true`, so the router refuses to send this to a
/// cloud provider whatever AI mode the user picked. Extraction sees raw speech before any relevance
/// filtering, which is exactly the material §50 protects.
///
/// ### APIs verified before use
/// | API | Verified shape |
/// |---|---|
/// | `@Generable` | attaches to a struct; properties generate in declaration order |
/// | `@Guide(description:)` | natural-language description per property |
/// | `respond(to:generating:includeSchemaInPrompt:options:)` | `async throws -> Response<Content> where Content: Generable` |
///
/// Category comes back as a `String` rather than a `@Generable` enum, and maps with a fallback to `.other`.
/// An unrecognised category then degrades to a usable memory instead of failing the whole extraction — the
/// classification is the least important thing on the candidate.
struct ModelMemoryExtractor: MemoryExtracting {

    private let router: any ModelRouting
    private let scorer: any MemoryImportanceScoring

    init(router: any ModelRouting, scorer: any MemoryImportanceScoring = DefaultMemoryImportanceScorer()) {
        self.router = router
        self.scorer = scorer
    }

    // MARK: - The model's output shape

    /// What the model is asked to produce for one turn.
    ///
    /// Declaration order is deliberate: the framework generates properties in the order they appear, so the
    /// model writes the statement before classifying it. Classifying first would have it commit to a category
    /// before deciding what the fact even is.
    @Generable
    struct ExtractedCandidate: Equatable {
        @Guide(description: "The single fact worth remembering, written as a standalone third-person statement about the user. No preamble.")
        var statement: String

        @Guide(description: "One of: personalPreference, person, relationship, project, goal, routine, decision, importantDate, work, education, travel, sports, entertainment, technology, household, health, finance, food, shopping, place, temporaryContext, other")
        var category: String

        @Guide(description: "Names of people, places or things this fact is about. Empty if none.")
        var entities: [String]

        @Guide(description: "True only if the user stated this as a settled, ongoing preference or habit rather than a one-off.")
        var isStandingPreference: Bool

        @Guide(description: "True if this records a decision the user made.")
        var isDecision: Bool

        @Guide(description: "True if this commits the user to doing something.")
        var isCommitment: Bool

        @Guide(description: "True if this contains a date or deadline worth keeping.")
        var containsDate: Bool
    }

    /// The whole extraction pass, so one model call handles a turn rather than one per candidate.
    @Generable
    struct ExtractionOutput: Equatable {
        @Guide(description: "Facts worth remembering from this turn. Empty if the turn was small talk, a question, or contained nothing durable.")
        var candidates: [ExtractedCandidate]
    }

    // MARK: - Extraction

    func extract(from request: ExtractionRequest) async throws -> ExtractionResult {
        // Detected before the model runs, and independently of it. These decide what happens to the user's
        // data, so they are deterministic text matches rather than inferences.
        let explicitRequest = Self.containsExplicitMemoryRequest(request.userMessage)
        let forgetRequest = Self.containsForgetRequest(request.userMessage)
        let correction = Self.containsCorrection(request.userMessage)

        // A question is not a fact about the user, and small talk carries nothing. Returning early saves a
        // model call on the majority of turns — most of what anyone says is not worth remembering.
        if !explicitRequest, Self.isQuestionOnly(request.userMessage) || Self.isSmallTalk(request.userMessage) {
            return ExtractionResult(
                candidates: [],
                containsExplicitMemoryRequest: false,
                containsForgetRequest: forgetRequest,
                containsCorrection: correction
            )
        }

        let (provider, _) = try await router.route(
            purpose: .memoryExtraction,
            context: RoutingContext(aiMode: .onDeviceOnly, isOnline: false, requiresToolSupport: false)
        )

        guard let apple = provider as? AppleFoundationModelProvider else {
            // Guided generation is Apple-specific. Rather than fabricate candidates from a provider that
            // cannot produce the schema, extract nothing and say so in the log — a turn that is not mined is
            // a missed memory, which is recoverable; an invented one is not (§78).
            AuraLog.memory.notice("Extraction skipped: the routed provider does not support guided generation.")
            return ExtractionResult(
                candidates: [],
                containsExplicitMemoryRequest: explicitRequest,
                containsForgetRequest: forgetRequest,
                containsCorrection: correction
            )
        }

        let output = try await apple.generate(
            ExtractionOutput.self,
            instructions: Self.instructions,
            prompt: Self.prompt(for: request),
            options: ModelGenerationOptions.structured
        )

        let candidates = output.candidates.compactMap {
            Self.candidate(from: $0, request: request, explicitRequest: explicitRequest, scorer: scorer)
        }

        return ExtractionResult(
            candidates: candidates,
            containsExplicitMemoryRequest: explicitRequest,
            containsForgetRequest: forgetRequest,
            containsCorrection: correction
        )
    }

    // MARK: - Turning model output into a candidate

    /// Scores and shapes one extracted statement, or rejects it.
    ///
    /// `static` and pure so the whole translation from model output to stored candidate is testable without a
    /// model — which is the only way to assert that a hedged statement lands hedged and a question never
    /// lands at all.
    static func candidate(
        from extracted: ExtractedCandidate,
        request: ExtractionRequest,
        explicitRequest: Bool,
        scorer: any MemoryImportanceScoring
    ) -> MemoryCandidateSnapshot? {
        let statement = extracted.statement.normalizedWhitespace
        guard !statement.isEmpty else { return nil }

        // The model classifies, but the *consequential* signals are re-derived from the user's own words.
        // A model that decides a hedge is certain would store a guess as fact, so hedging is never taken on
        // its word.
        let hedged = containsHedge(request.userMessage)
        let transient = containsTransientScope(request.userMessage)

        let signals = MemoryImportanceSignals(
            isExplicitRequest: explicitRequest,
            isStablePreference: extracted.isStandingPreference,
            involvesImportantPerson: !extracted.entities.isEmpty
                && request.knownPeople.contains { person in
                    extracted.entities.contains { $0.caseInsensitiveCompare(person.name) == .orderedSame }
                },
            involvesProject: !request.knownProjects.isEmpty && extracted.category == "project",
            isDecision: extracted.isDecision,
            containsImportantDate: extracted.containsDate,
            isCommitment: extracted.isCommitment,
            isHedged: hedged,
            isTransient: transient,
            isQuestion: false,
            isSmallTalk: false,
            category: MemoryCategory(rawValue: extracted.category) ?? .other
        )

        let importance = scorer.importance(for: signals)
        let recommendation = scorer.recommendation(for: importance, signals: signals)

        // Nothing worth its own memory is dropped here rather than stored and filtered later: the
        // conversation archive already holds it, so there is nothing to lose and a smaller store to search.
        guard recommendation != .discard, recommendation != .archiveOnly else { return nil }

        // Labels taken from the declaration rather than from memory — it is `retentionRecommendation`, not
        // `recommendation`. `entities` is deliberately not set here even though the snapshot has one: the
        // extracted entities have already done their work in the importance signals above, and consolidation
        // is where they get attached to the stored memory alongside the resolved person and project ids.
        return MemoryCandidateSnapshot(
            content: statement,
            category: signals.category,
            importance: importance,
            confidence: hedged ? AuraDefaults.Confidence.hedged : AuraDefaults.Confidence.explicit,
            retentionRecommendation: recommendation,
            wasExplicitlyRequested: explicitRequest,
            sourceConversationID: request.conversationID,
            sourceMessageID: request.userMessageID
        )
    }

    // MARK: - Deterministic signal detection

    /// "Remember that…", "don't forget…", "make a note…" (§19).
    ///
    /// A text match rather than a model judgement, because §19 makes this the highest authority in the
    /// system: whether the user asked must not depend on a probability.
    static func containsExplicitMemoryRequest(_ text: String) -> Bool {
        matches(text, any: [
            "remember that", "remember this", "remember i", "remember my", "remember to",
            "don't forget", "dont forget", "make a note", "note that", "keep in mind",
            "for future reference", "from now on"
        ])
    }

    /// "Forget that", "delete what I said" (§24).
    static func containsForgetRequest(_ text: String) -> Bool {
        matches(text, any: [
            "forget that", "forget what", "forget about", "delete that", "delete what",
            "erase that", "stop remembering", "don't remember that", "dont remember that",
            "remove that from"
        ])
    }

    /// "Actually…", "no, it's…", "I was wrong" (§23).
    static func containsCorrection(_ text: String) -> Bool {
        matches(text, any: [
            "actually,", "actually it", "actually i", "no, i", "no i meant", "i meant",
            "that's wrong", "thats wrong", "i was wrong", "correction", "not quite",
            "it's actually", "its actually", "change that to"
        ])
    }

    /// Hedging language (§22). Kept, but recorded at reduced confidence rather than as settled fact.
    static func containsHedge(_ text: String) -> Bool {
        matches(text, any: [
            "i think", "i believe", "maybe", "might", "probably", "possibly", "not sure",
            "i guess", "perhaps", "could be", "pretty sure", "fairly sure", "or so"
        ])
    }

    /// Scoped to right now, so it must not become permanent.
    static func containsTransientScope(_ text: String) -> Bool {
        matches(text, any: [
            "for now", "for today", "rest of today", "rest of the day", "just today",
            "this morning", "this afternoon", "this evening", "tonight only",
            "until this meeting", "for the next hour", "temporarily"
        ])
    }

    /// A turn that only asks something. Questions are not facts about the user.
    ///
    /// Requires the *absence* of a statement rather than merely the presence of a question mark: "I'm saving
    /// the garage until October — does that work?" contains both, and the fact in it is worth keeping.
    static func isQuestionOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let sentences = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Every clause reads as a question: either the whole thing ends in "?" with no declarative sentence,
        // or each clause opens with an interrogative.
        let interrogatives = ["what", "who", "when", "where", "why", "how", "which", "is", "are", "do", "does", "did", "can", "could", "will", "would", "should"]
        guard trimmed.hasSuffix("?") else { return false }
        return sentences.allSatisfy { sentence in
            let first = sentence.lowercased().components(separatedBy: " ").first ?? ""
            return interrogatives.contains(first)
        }
    }

    /// Conversational filler with no content.
    static func isSmallTalk(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pleasantries: Set<String> = [
            "hi", "hello", "hey", "thanks", "thank you", "thanks!", "ok", "okay", "cool",
            "great", "nice", "sure", "yep", "yes", "no", "nope", "good morning",
            "good afternoon", "good evening", "goodnight", "bye", "goodbye", "sounds good",
            "got it", "perfect", "awesome", "lol", "haha"
        ]
        return pleasantries.contains(normalized)
    }

    private static func matches(_ text: String, any needles: [String]) -> Bool {
        let haystack = text.lowercased()
        return needles.contains { haystack.contains($0) }
    }

    // MARK: - Prompt

    static let instructions = """
        You extract facts worth remembering from a conversation, for a personal assistant's long-term memory.

        Only extract what the user actually stated about themselves, their life, their people, or their \
        decisions. Write each as a standalone third-person statement that will still make sense months from \
        now, with no pronouns left dangling.

        Do not extract questions, do not extract anything the assistant said, and do not infer beyond what \
        was stated. If the turn contains nothing durable, return no candidates — that is the common case and \
        is always an acceptable answer.

        Never invent detail to fill a field. A sparse candidate is correct; an embellished one is not.
        """

    /// The extraction prompt. `static` and pure so what the model is asked is assertable.
    static func prompt(for request: ExtractionRequest) -> String {
        var sections: [String] = []

        if !request.knownPeople.isEmpty {
            sections.append(
                "People already known: " + request.knownPeople.map(\.name).joined(separator: ", ")
            )
        }
        if !request.recentTurns.isEmpty {
            sections.append("Recent turns, for resolving references:\n" + request.recentTurns.suffix(3).joined(separator: "\n"))
        }

        sections.append("The user said:\n\(request.userMessage)")
        if let assistantMessage = request.assistantMessage, !assistantMessage.isBlank {
            sections.append("The assistant replied:\n\(assistantMessage)\n\nExtract only from what the user said.")
        }

        return sections.joined(separator: "\n\n")
    }
}
