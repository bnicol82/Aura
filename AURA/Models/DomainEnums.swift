import Foundation

// MARK: - Assistant identity & behaviour

/// Personality starting points offered in onboarding and Settings (§10).
enum PersonalityPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case balanced
    case professional
    case casual
    case friendly
    case direct
    case refined
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .balanced: return "Balanced"
        case .professional: return "Professional"
        case .casual: return "Casual"
        case .friendly: return "Friendly"
        case .direct: return "Direct"
        case .refined: return "Refined"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .balanced: return "Friendly, capable, concise, conversational."
        case .professional: return "Precise and polished, humour held in reserve."
        case .casual: return "Relaxed and informal, like a friend who's good at this."
        case .friendly: return "Warm, personable, encouraging."
        case .direct: return "Efficient and factual. Very little small talk."
        case .refined: return "Highly competent, calm, quick, quietly witty. Proactive without hovering."
        case .custom: return "Describe the assistant you want in your own words."
        }
    }

    var symbolName: String {
        switch self {
        case .balanced: return "circle.lefthalf.filled"
        case .professional: return "briefcase"
        case .casual: return "sun.max"
        case .friendly: return "hand.wave"
        case .direct: return "arrow.right.to.line"
        case .refined: return "sparkles"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// The style defaults a preset implies. Onboarding applies these, then lets the user override
    /// each one individually — which is what turns any preset into `.custom`.
    var defaultStyle: AssistantStyle {
        switch self {
        case .balanced:
            return AssistantStyle(responseLength: .concise, formality: .neutral, humor: .subtle, proactivity: .balanced)
        case .professional:
            return AssistantStyle(responseLength: .concise, formality: .professional, humor: .none, proactivity: .importantOnly)
        case .casual:
            return AssistantStyle(responseLength: .concise, formality: .casual, humor: .medium, proactivity: .balanced)
        case .friendly:
            return AssistantStyle(responseLength: .balanced, formality: .casual, humor: .medium, proactivity: .balanced)
        case .direct:
            return AssistantStyle(responseLength: .brief, formality: .neutral, humor: .none, proactivity: .importantOnly)
        case .refined:
            return AssistantStyle(responseLength: .concise, formality: .professional, humor: .subtle, proactivity: .balanced)
        case .custom:
            return AssistantStyle(responseLength: .concise, formality: .neutral, humor: .subtle, proactivity: .balanced)
        }
    }
}

/// How long the assistant's answers should run.
enum ResponseLength: String, Codable, CaseIterable, Sendable, Identifiable {
    case brief
    case concise
    case balanced
    case detailed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brief: return "Brief"
        case .concise: return "Concise"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }

    /// Wording handed to the model. Kept here so §11's "never duplicate personality prompt logic"
    /// holds: `PersonalityEngine` is the only reader.
    var instruction: String {
        switch self {
        case .brief: return "Answer in one or two sentences. Lead with the answer."
        case .concise: return "Keep answers short and conversational. Skip preamble."
        case .balanced: return "Give a complete answer without padding it."
        case .detailed: return "Give thorough answers with the relevant reasoning and context."
        }
    }
}

/// Register the assistant writes in.
enum FormalityLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case casual
    case neutral
    case professional

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .casual: return "Casual"
        case .neutral: return "Neutral"
        case .professional: return "Professional"
        }
    }

    var instruction: String {
        switch self {
        case .casual: return "Speak casually and naturally, the way a person texts a friend. Contractions are good."
        case .neutral: return "Speak plainly and naturally — neither stiff nor overly familiar."
        case .professional: return "Speak in a polished, composed register. Precise word choice, no slang."
        }
    }
}

/// How much humour the assistant is allowed.
enum HumorLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case subtle
    case medium
    case playful

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .subtle: return "Subtle"
        case .medium: return "Medium"
        case .playful: return "Playful"
        }
    }

    var instruction: String? {
        switch self {
        case .none: return nil
        case .subtle: return "Occasional understated humour, only where it fits. Never at the user's expense."
        case .medium: return "Light humour and wit are welcome when the moment allows it."
        case .playful: return "Be playful and quick-witted, but never let a joke get in the way of the answer."
        }
    }
}

/// How willing the assistant is to volunteer things (§57).
enum ProactivityLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case importantOnly
    case balanced
    case proactive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .importantOnly: return "Important Only"
        case .balanced: return "Balanced"
        case .proactive: return "Proactive"
        }
    }

    var instruction: String {
        switch self {
        case .off: return "Answer what was asked. Do not volunteer suggestions or follow-ups."
        case .importantOnly: return "Only raise something unprompted when it is genuinely important, such as a deadline or a conflict."
        case .balanced: return "Offer a relevant next step when there is obvious value, but do not interrupt with minor things."
        case .proactive: return "Actively surface related commitments, follow-ups and conflicts you notice."
        }
    }
}

/// Whether and how the assistant opens a session.
enum GreetingStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case simple
    case personal
    case timeAware

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "No greeting"
        case .simple: return "Simple"
        case .personal: return "Use my name"
        case .timeAware: return "Time of day"
        }
    }
}

/// Where inference is allowed to happen (§7).
enum AIMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case onDeviceOnly
    case automatic
    case cloudEnhanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDeviceOnly: return "On-Device Only"
        case .automatic: return "Automatic"
        case .cloudEnhanced: return "Cloud Enhanced"
        }
    }

    var summary: String {
        switch self {
        case .onDeviceOnly:
            return "Nothing you say leaves your iPhone. Some complex requests will be beyond me."
        case .automatic:
            return "I handle what I can on device and only reach for a cloud model when a request genuinely needs it."
        case .cloudEnhanced:
            return "I prefer the strongest model available. Relevant context is sent to your configured provider."
        }
    }

    var allowsCloudProviders: Bool { self != .onDeviceOnly }
}

/// Subject-matter gear change (§12). Personality bends to the topic; accuracy never does.
enum SensitivityMode: String, Codable, CaseIterable, Sendable {
    /// Ordinary conversation — full personality.
    case normal
    /// Health, safety, money, legal, security, death, difficult family matters.
    case sensitive
    /// Something that reads as an emergency.
    case urgent

    var instruction: String? {
        switch self {
        case .normal:
            return nil
        case .sensitive:
            return """
            This topic is sensitive. Drop humour entirely and become careful and straightforward. \
            Do not soften or dress up facts. If the answer depends on professional advice, say so plainly.
            """
        case .urgent:
            return """
            This may be urgent. Be direct and brief. Lead with the most useful action. No humour, no preamble. \
            If someone may be in danger, say clearly that emergency services are the right call.
            """
        }
    }
}

// MARK: - Memory

/// Which memory layer an item belongs to (§15).
enum MemoryType: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Stable facts and preferences.
    case semantic
    /// A meaningful past discussion or event.
    case episodic
    /// Knowledge attached to an ongoing effort.
    case project
    /// An outstanding obligation.
    case task
    /// A fact promoted onto the structured user profile.
    case profileFact
    /// A fact about a specific person.
    case person

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .semantic: return "Fact"
        case .episodic: return "Moment"
        case .project: return "Project note"
        case .task: return "Commitment"
        case .profileFact: return "About you"
        case .person: return "Person"
        }
    }

    /// Layers that are durable by design and should never expire on their own.
    var isDurableByDefault: Bool {
        switch self {
        case .semantic, .profileFact, .person: return true
        case .episodic, .project, .task: return false
        }
    }
}

/// Subject classification for a memory or candidate (§17).
enum MemoryCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case personalPreference
    case person
    case relationship
    case project
    case goal
    case routine
    case decision
    case importantDate
    case work
    case education
    case travel
    case sports
    case entertainment
    case technology
    case household
    case health
    case finance
    case food
    case shopping
    case place
    case temporaryContext
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .personalPreference: return "Preference"
        case .person: return "Person"
        case .relationship: return "Relationship"
        case .project: return "Project"
        case .goal: return "Goal"
        case .routine: return "Routine"
        case .decision: return "Decision"
        case .importantDate: return "Important date"
        case .work: return "Work"
        case .education: return "Education"
        case .travel: return "Travel"
        case .sports: return "Sports"
        case .entertainment: return "Entertainment"
        case .technology: return "Technology"
        case .household: return "Household"
        case .health: return "Health"
        case .finance: return "Finance"
        case .food: return "Food"
        case .shopping: return "Shopping"
        case .place: return "Place"
        case .temporaryContext: return "Temporary"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .personalPreference: return "heart"
        case .person: return "person"
        case .relationship: return "person.2"
        case .project: return "hammer"
        case .goal: return "target"
        case .routine: return "repeat"
        case .decision: return "checkmark.seal"
        case .importantDate: return "calendar"
        case .work: return "briefcase"
        case .education: return "graduationcap"
        case .travel: return "airplane"
        case .sports: return "sportscourt"
        case .entertainment: return "film"
        case .technology: return "desktopcomputer"
        case .household: return "house"
        case .health: return "cross.case"
        case .finance: return "dollarsign.circle"
        case .food: return "fork.knife"
        case .shopping: return "cart"
        case .place: return "mappin.and.ellipse"
        case .temporaryContext: return "clock.arrow.circlepath"
        case .other: return "tray"
        }
    }

    /// Categories that force `SensitivityMode.sensitive` regardless of personality settings (§12).
    var isSensitive: Bool {
        switch self {
        case .health, .finance: return true
        default: return false
        }
    }

    /// Categories the retrieval engine treats as durable "about the user" knowledge (§21).
    var belongsOnUserProfile: Bool {
        switch self {
        case .personalPreference, .goal, .routine, .work, .education,
             .travel, .sports, .entertainment, .technology, .food, .shopping:
            return true
        default:
            return false
        }
    }
}

/// What the extraction pipeline recommends doing with a candidate (§17).
enum RetentionRecommendation: String, Codable, CaseIterable, Sendable {
    /// Save as durable memory, and promote to the profile when the category warrants it.
    case durable
    /// Save as episodic or project memory.
    case episodic
    /// Keep only in the conversation archive.
    case archiveOnly
    /// Do not keep at all.
    case discard
}

/// Lifecycle of a candidate the extractor produced.
enum MemoryCandidateStatus: String, Codable, CaseIterable, Sendable {
    /// Not yet examined by the extractor.
    case notEvaluated
    /// Waiting for the user, because "Ask before saving" is on.
    case awaitingReview
    /// Saved as a `MemoryItem`.
    case accepted
    /// The user said no.
    case rejected
    /// The extractor decided it was not worth keeping.
    case discarded
}

// MARK: - Conversation

enum MessageRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    /// Instructions, never shown in the transcript.
    case system
    /// A tool result folded back into the conversation.
    case tool
}

// MARK: - Projects & tasks

enum ProjectStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case active
    case paused
    case completed
    case abandoned

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active: return "Active"
        case .paused: return "On hold"
        case .completed: return "Done"
        case .abandoned: return "Dropped"
        }
    }
}

enum TaskStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case open
    case inProgress
    case completed
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In progress"
        case .completed: return "Done"
        case .cancelled: return "Cancelled"
        }
    }

    var isOutstanding: Bool { self == .open || self == .inProgress }
}

enum TaskPriority: String, Codable, CaseIterable, Sendable, Identifiable {
    case low
    case normal
    case high
    case urgent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }

    var sortWeight: Int {
        switch self {
        case .urgent: return 3
        case .high: return 2
        case .normal: return 1
        case .low: return 0
        }
    }
}

// MARK: - Activity

/// The kinds of thing that appear on the Activity screen (§45). Deliberately about *actions taken*,
/// never about reasoning.
enum ActivityKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case conversationStarted
    case memorySaved
    case memoryUpdated
    case memoryDeleted
    case memorySearched
    case profileUpdated
    case personAdded
    case personUpdated
    case projectCreated
    case projectUpdated
    case taskCreated
    case taskCompleted
    case toolExecuted
    case permissionGranted
    case permissionDenied
    case settingsChanged
    case syncCompleted
    case dataExported
    case dataCleared

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .conversationStarted: return "bubble.left.and.bubble.right"
        case .memorySaved: return "brain"
        case .memoryUpdated: return "arrow.triangle.2.circlepath"
        case .memoryDeleted: return "trash"
        case .memorySearched: return "magnifyingglass"
        case .profileUpdated: return "person.text.rectangle"
        case .personAdded, .personUpdated: return "person.crop.circle.badge.plus"
        case .projectCreated, .projectUpdated: return "hammer"
        case .taskCreated: return "checklist"
        case .taskCompleted: return "checkmark.circle"
        case .toolExecuted: return "wrench.and.screwdriver"
        case .permissionGranted: return "lock.open"
        case .permissionDenied: return "lock"
        case .settingsChanged: return "gearshape"
        case .syncCompleted: return "icloud"
        case .dataExported: return "square.and.arrow.up"
        case .dataCleared: return "eraser"
        }
    }
}
