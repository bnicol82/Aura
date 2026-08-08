import Foundation
import Testing

@testable import AURA

/// The retention policy (§18, §19, §22).
///
/// Worth heavy testing because it is pure, because the spec calls it out as the piece most worth testing,
/// and because its failure mode is invisible: nobody notices a memory that should have been kept, and nobody
/// finds a wrong one until AURA repeats it back as fact.
@Suite("Memory importance")
struct MemoryImportanceTests {

    private let scorer = DefaultMemoryImportanceScorer()

    // MARK: The user's own words outrank everything

    @Test("An explicit request scores maximum and is always durable")
    func explicitRequestWins() {
        // §19: "remember that…" is the highest authority in the system. Running it through the weighted
        // model and possibly landing under a threshold would be AURA overruling the user.
        let signals = MemoryImportanceSignals(isExplicitRequest: true, category: .other)
        #expect(scorer.importance(for: signals) == AuraDefaults.ImportanceThreshold.explicitRequest)
        #expect(scorer.recommendation(for: 1, signals: signals) == .durable)
    }

    @Test("An explicit request survives signals that would otherwise suppress it")
    func explicitRequestBeatsSuppressors() {
        // "Remember that I might be free Tuesday" is hedged and transient, and the user still asked.
        let signals = MemoryImportanceSignals(
            isExplicitRequest: true,
            isHedged: true,
            isTransient: true,
            category: .temporaryContext
        )
        #expect(scorer.importance(for: signals) == 1)
        #expect(scorer.recommendation(for: 1, signals: signals) == .durable)
    }

    // MARK: Absolute suppressors

    @Test("A question is never a fact, however many other signals fire")
    func questionsAreNeverKept() {
        // The failure this prevents: "Is Blake still at Tennessee?" stored as "Blake is at Tennessee".
        let signals = MemoryImportanceSignals(
            isStablePreference: true,
            involvesImportantPerson: true,
            isDecision: true,
            containsImportantDate: true,
            isCommitment: true,
            isQuestion: true,
            category: .relationship
        )
        #expect(scorer.importance(for: signals) == 0)
        #expect(scorer.recommendation(for: 0, signals: signals) == .discard)
    }

    @Test("Small talk is discarded")
    func smallTalkIsDiscarded() {
        let signals = MemoryImportanceSignals(isSmallTalk: true, category: .other)
        #expect(scorer.importance(for: signals) == 0)
        #expect(scorer.recommendation(for: 0, signals: signals) == .discard)
    }

    @Test("Suppressors are checked against the signals, not trusted from the score")
    func suppressorsOverrideAHighScore() {
        // A caller passing a mistakenly high score must not be able to store a question as a memory. The
        // recommendation re-checks rather than trusting the number it was handed.
        let question = MemoryImportanceSignals(isQuestion: true, category: .work)
        #expect(scorer.recommendation(for: 0.99, signals: question) == .discard)

        let smallTalk = MemoryImportanceSignals(isSmallTalk: true, category: .work)
        #expect(scorer.recommendation(for: 0.99, signals: smallTalk) == .discard)
    }

    // MARK: Hedging

    @Test("A hedge is kept but never as settled fact")
    func hedgesNeverBecomeDurable() {
        // §22. Durable memory is recalled as fact, and a guess recalled as fact is the longest-lived way to
        // be wrong — the user may never find it to correct it.
        let strong = MemoryImportanceSignals(
            isStablePreference: true,
            involvesImportantPerson: true,
            isDecision: true,
            isCommitment: true,
            category: .relationship
        )
        let strongScore = scorer.importance(for: strong)
        #expect(strongScore >= AuraDefaults.ImportanceThreshold.durable)
        #expect(scorer.recommendation(for: strongScore, signals: strong) == .durable)

        var hedged = strong
        hedged.isHedged = true
        let hedgedScore = scorer.importance(for: hedged)

        #expect(hedgedScore < strongScore)
        // Even if something else pushed the score back up, the recommendation still refuses durable.
        #expect(scorer.recommendation(for: 0.99, signals: hedged) == .episodic)
    }

    // MARK: Transience

    @Test("Something scoped to now is suppressed even when strongly signalled")
    func transientMaterialIsSuppressed() {
        // "Cancel my meetings for the rest of today" is a decision, about a date, involving people. Keeping
        // it forever would be actively wrong rather than merely useless.
        let signals = MemoryImportanceSignals(
            involvesImportantPerson: true,
            isDecision: true,
            containsImportantDate: true,
            isTransient: true,
            category: .temporaryContext
        )
        let score = scorer.importance(for: signals)
        #expect(score < AuraDefaults.ImportanceThreshold.episodic)
        #expect(scorer.recommendation(for: score, signals: signals) == .archiveOnly)
    }

    // MARK: The ordinary path

    @Test("A standing preference is durable on its own")
    func standingPreferenceIsDurable() {
        // The most useful thing to know about someone, because it applies to every future turn.
        let signals = MemoryImportanceSignals(isStablePreference: true, category: .personalPreference)
        let score = scorer.importance(for: signals)
        #expect(score >= AuraDefaults.ImportanceThreshold.durable)
        #expect(scorer.recommendation(for: score, signals: signals) == .durable)
    }

    @Test("A decision about a project is worth an episodic memory")
    func projectDecisionIsEpisodic() {
        // §2's own example: holding the garage renovation until October.
        let signals = MemoryImportanceSignals(
            involvesProject: true,
            isDecision: true,
            category: .household
        )
        let score = scorer.importance(for: signals)
        #expect(score >= AuraDefaults.ImportanceThreshold.episodic)
        #expect(scorer.recommendation(for: score, signals: signals) == .episodic)
    }

    @Test("An unremarkable statement is archived rather than remembered")
    func unremarkableStatementIsArchiveOnly() {
        // Nothing is lost — the conversation stays searchable, which is what makes not remembering safe.
        let signals = MemoryImportanceSignals(category: .other)
        let score = scorer.importance(for: signals)
        #expect(score < AuraDefaults.ImportanceThreshold.episodic)
        #expect(scorer.recommendation(for: score, signals: signals) == .archiveOnly)
    }

    // MARK: Invariants

    @Test("Scores stay within 0...1 for every combination of signals")
    func scoresAreAlwaysInRange() {
        // Exhaustive over the boolean signals, because the weights add to more than 1 and a clamp that only
        // works for the combinations someone thought of is not a clamp.
        let flags = 11
        for mask in 0..<(1 << flags) {
            func bit(_ index: Int) -> Bool { mask & (1 << index) != 0 }

            for category in MemoryCategory.allCases {
                let signals = MemoryImportanceSignals(
                    isExplicitRequest: bit(0),
                    isStablePreference: bit(1),
                    involvesImportantPerson: bit(2),
                    involvesProject: bit(3),
                    isDecision: bit(4),
                    containsImportantDate: bit(5),
                    isCommitment: bit(6),
                    isHedged: bit(7),
                    isTransient: bit(8),
                    isQuestion: bit(9),
                    isSmallTalk: bit(10),
                    category: category
                )
                let score = scorer.importance(for: signals)
                #expect(score >= 0)
                #expect(score <= 1)
            }
        }
    }

    @Test("Adding a positive signal never lowers a score")
    func positiveSignalsAreMonotonic() {
        // Guards against a category weight or a multiplier being given the wrong sign, which would make the
        // policy quietly invert for one kind of statement.
        let base = MemoryImportanceSignals(category: .other)
        let baseScore = scorer.importance(for: base)

        var withPreference = base
        withPreference.isStablePreference = true
        #expect(scorer.importance(for: withPreference) >= baseScore)

        var withPerson = base
        withPerson.involvesImportantPerson = true
        #expect(scorer.importance(for: withPerson) >= baseScore)

        var withDate = base
        withDate.containsImportantDate = true
        #expect(scorer.importance(for: withDate) >= baseScore)
    }

    @Test("Every category has a weight, and only temporary context is negative")
    func categoryWeightsAreDeliberate() {
        for category in MemoryCategory.allCases {
            let weight = DefaultMemoryImportanceScorer.categoryWeight(category)
            #expect(weight >= -0.15)
            #expect(weight <= 0.20)
            if weight < 0 {
                // If another category ever goes negative it should be a decision, not a typo.
                #expect(category == .temporaryContext)
            }
        }
    }
}
