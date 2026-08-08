import Foundation

/// The four dials that make up "how my assistant talks" (§47).
struct AssistantStyle: Sendable, Equatable, Codable {
    var responseLength: ResponseLength
    var formality: FormalityLevel
    var humor: HumorLevel
    var proactivity: ProactivityLevel

    init(
        responseLength: ResponseLength = .concise,
        formality: FormalityLevel = .neutral,
        humor: HumorLevel = .subtle,
        proactivity: ProactivityLevel = .balanced
    ) {
        self.responseLength = responseLength
        self.formality = formality
        self.humor = humor
        self.proactivity = proactivity
    }
}

/// Memory behaviour the user controls (§48).
struct MemoryPreferences: Sendable, Equatable, Codable {
    /// Learn useful things without being told to.
    var automaticMemoryEnabled: Bool
    /// Confirm before anything is written to durable memory.
    var asksBeforeSaving: Bool
    /// Allow retrieved memory into model context at all.
    var usesMemoryInResponses: Bool
    /// Sync durable data through the user's private iCloud database.
    var cloudSyncEnabled: Bool

    init(
        automaticMemoryEnabled: Bool = true,
        asksBeforeSaving: Bool = false,
        usesMemoryInResponses: Bool = true,
        cloudSyncEnabled: Bool = true
    ) {
        self.automaticMemoryEnabled = automaticMemoryEnabled
        self.asksBeforeSaving = asksBeforeSaving
        self.usesMemoryInResponses = usesMemoryInResponses
        self.cloudSyncEnabled = cloudSyncEnabled
    }

    /// The configuration where AURA keeps no durable memory at all.
    static let disabled = MemoryPreferences(
        automaticMemoryEnabled: false,
        asksBeforeSaving: false,
        usesMemoryInResponses: false,
        cloudSyncEnabled: false
    )
}

/// How the assistant should speak out loud (§39).
struct VoicePreferences: Sendable, Equatable, Codable {
    /// `AVSpeechSynthesisVoice.identifier`, or `nil` for the system default for the current locale.
    var voiceIdentifier: String?
    /// Apple's 0...1 utterance rate.
    var speechRate: Double
    /// Speak replies without being asked to.
    var speaksResponsesAutomatically: Bool

    init(
        voiceIdentifier: String? = nil,
        speechRate: Double = AuraDefaults.speechRate,
        speaksResponsesAutomatically: Bool = true
    ) {
        self.voiceIdentifier = voiceIdentifier
        self.speechRate = speechRate.clamped(to: 0...1)
        self.speaksResponsesAutomatically = speaksResponsesAutomatically
    }
}

/// An immutable, `Sendable` read of the assistant's configuration.
///
/// The persistent `AssistantProfile` is a SwiftData class and therefore not `Sendable`; it stays
/// behind its store actor. Everything else in the app — the orchestrator, the personality engine,
/// views — works with this snapshot. That is the concurrency contract for the whole app.
struct AssistantProfileSnapshot: Sendable, Equatable, Identifiable {
    var id: UUID
    var assistantName: String
    var personalityPreset: PersonalityPreset
    /// Free text from the "Custom" preset, verbatim from the user.
    var customPersonalityPrompt: String?
    var style: AssistantStyle
    var greetingStyle: GreetingStyle
    var voice: VoicePreferences
    /// Allow the assistant to drift toward the user's own register over time (§9).
    var allowsPersonalityAdaptation: Bool
    var aiMode: AIMode
    var memory: MemoryPreferences
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        assistantName: String = AuraDefaults.assistantName,
        personalityPreset: PersonalityPreset = .balanced,
        customPersonalityPrompt: String? = nil,
        style: AssistantStyle = AssistantStyle(),
        greetingStyle: GreetingStyle = .timeAware,
        voice: VoicePreferences = VoicePreferences(),
        allowsPersonalityAdaptation: Bool = true,
        aiMode: AIMode = .automatic,
        memory: MemoryPreferences = MemoryPreferences(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.assistantName = assistantName
        self.personalityPreset = personalityPreset
        self.customPersonalityPrompt = customPersonalityPrompt
        self.style = style
        self.greetingStyle = greetingStyle
        self.voice = voice
        self.allowsPersonalityAdaptation = allowsPersonalityAdaptation
        self.aiMode = aiMode
        self.memory = memory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Placeholder used by SwiftUI previews and by views rendered before the store has answered.
    static let placeholder = AssistantProfileSnapshot()
}

/// A partial update. Only the fields you set are written, which keeps `updatedAt` churn (and
/// therefore CloudKit traffic) proportional to what actually changed.
struct AssistantProfileMutation: Sendable, Equatable {
    var assistantName: String?
    var personalityPreset: PersonalityPreset?
    var customPersonalityPrompt: String??
    var responseLength: ResponseLength?
    var formality: FormalityLevel?
    var humor: HumorLevel?
    var proactivity: ProactivityLevel?
    var greetingStyle: GreetingStyle?
    var voiceIdentifier: String??
    var speechRate: Double?
    var speaksResponsesAutomatically: Bool?
    var allowsPersonalityAdaptation: Bool?
    var aiMode: AIMode?
    var automaticMemoryEnabled: Bool?
    var asksBeforeSaving: Bool?
    var usesMemoryInResponses: Bool?
    var cloudSyncEnabled: Bool?

    init() {}

    /// `true` when applying this mutation would change nothing.
    var isEmpty: Bool {
        self == AssistantProfileMutation()
    }

    /// Applies a whole preset: the preset itself plus the style dials it implies.
    static func applying(preset: PersonalityPreset) -> AssistantProfileMutation {
        var mutation = AssistantProfileMutation()
        let style = preset.defaultStyle
        mutation.personalityPreset = preset
        mutation.responseLength = style.responseLength
        mutation.formality = style.formality
        mutation.humor = style.humor
        mutation.proactivity = style.proactivity
        return mutation
    }
}

extension Comparable {
    /// Small helper used wherever a stored value has a documented valid range.
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
