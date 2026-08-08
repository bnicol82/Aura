import Foundation

/// Scores how much a statement is worth remembering (§18).
///
/// ### Why this is a pure function with no model in it
/// Deciding *what a sentence means* needs a language model. Deciding *whether that meaning is worth
/// keeping* does not — it is policy, and policy belongs somewhere it can be argued with and tested. Every
/// weight below is visible, every threshold comes from `AuraDefaults.ImportanceThreshold`, and the whole
/// thing is deterministic. A model that scored importance directly would be unauditable and would drift
/// between OS releases.
///
/// ### The asymmetry that matters
/// Remembering something trivial is mildly annoying and one tap to delete. Remembering something *wrong* —
/// treating a question as a fact, keeping a hedge as certain, storing "for the rest of today" forever — is
/// what makes an assistant feel untrustworthy, and the user may never find it to correct it.
///
/// So the suppressors are absolute, not weighted. A question is not a fact about someone no matter how many
/// other signals fire. That is deliberately not a tunable knob.
struct DefaultMemoryImportanceScorer: MemoryImportanceScoring {

    func importance(for signals: MemoryImportanceSignals) -> Double {
        // Asked for outright, and nothing outranks that (§19). The user's own words are the highest
        // authority in the system; scoring their explicit request through a weighted model and possibly
        // landing under a threshold would be the system overruling them.
        if signals.isExplicitRequest {
            return AuraDefaults.ImportanceThreshold.explicitRequest
        }

        // Absolute suppressors, checked before anything is added up.
        if signals.isQuestion || signals.isSmallTalk {
            return 0
        }

        var score = 0.0

        // A standing preference is the single most useful thing to know about someone, because it applies to
        // every future turn rather than to one moment.
        //
        // Weighted at 0.70 so that a preference in a trait-ish category clears the 0.85 durable threshold on
        // its own — "I always take the aisle seat" belongs on the profile, and an earlier 0.45 left it at
        // 0.65, permanently episodic. Caught by `standingPreferenceIsDurable` before this ever ran.
        if signals.isStablePreference { score += 0.70 }
        // A decision is what the user will ask AURA to recall later — "what did I decide about the garage".
        //
        // 0.35 rather than 0.30 on purpose: at 0.30 a project decision landed on exactly 0.60, bit-identical
        // to the episodic threshold, so the policy passed by a rounding coincidence. A threshold case that
        // depends on floating-point luck is one weight tweak away from flipping for no visible reason.
        if signals.isDecision { score += 0.35 }
        // A commitment has a deadline attached to someone else's expectations.
        if signals.isCommitment { score += 0.30 }
        if signals.containsImportantDate { score += 0.25 }
        if signals.involvesImportantPerson { score += 0.20 }
        if signals.involvesProject { score += 0.15 }

        // Category weighting, small on purpose. What a statement is *about* is weaker evidence than what it
        // *does*, so it adjusts rather than decides.
        score += Self.categoryWeight(signals.category)

        // Hedged material is kept at reduced confidence rather than dropped (§22) — "possibly the Italian
        // place on Main" is worth having, labelled. Halving is what keeps it below the durable threshold so
        // it lands as episodic and gets shown with a hedge instead of stated as fact.
        if signals.isHedged { score *= 0.5 }

        // Explicitly scoped to now. Multiplied last so it suppresses even a strongly-signalled statement:
        // "cancel my meetings for the rest of today" is a decision about a person and a date, and keeping it
        // forever would be actively wrong.
        if signals.isTransient { score *= 0.25 }

        return min(max(score, 0), 1)
    }

    func recommendation(
        for score: Double,
        signals: MemoryImportanceSignals
    ) -> RetentionRecommendation {
        // Checked before the thresholds, because a suppressed statement must never be kept regardless of
        // what a caller passed as a score. Trusting the number alone would let a miscomputed score store a
        // question as a fact.
        if signals.isQuestion || signals.isSmallTalk {
            return .discard
        }

        if signals.isExplicitRequest {
            return .durable
        }

        if score >= AuraDefaults.ImportanceThreshold.durable {
            // A hedge never becomes durable, whatever it scored. Durable memory is recalled as settled
            // fact, and a guess presented as settled is exactly the §78 failure with the longest life.
            return signals.isHedged ? .episodic : .durable
        }
        if score >= AuraDefaults.ImportanceThreshold.episodic {
            return .episodic
        }
        // Not worth its own memory, but the conversation is still searchable — nothing the user said is
        // ever actually lost, which is what makes discarding safe.
        return .archiveOnly
    }

    /// How much a category shifts a score.
    ///
    /// `static` and pure so the table is readable and assertable in one place. Categories that describe a
    /// durable trait lift; categories that usually describe a passing moment drag.
    static func categoryWeight(_ category: MemoryCategory) -> Double {
        switch category {
        // Durable traits: true for months or years, and useful on almost any future turn.
        case .personalPreference, .person, .relationship, .routine, .work, .education, .health, .finance:
            return 0.20

        // Things with a shape and an end: worth keeping while they run.
        case .project, .goal, .decision, .importantDate, .household:
            return 0.15

        // Real but narrow. Knowing someone's coffee order helps occasionally.
        case .food, .travel, .sports, .entertainment, .technology, .shopping, .place:
            return 0.05

        // Explicitly about right now. Named for exactly the thing that must not become permanent.
        case .temporaryContext:
            return -0.15

        case .other:
            return 0
        }
    }
}
