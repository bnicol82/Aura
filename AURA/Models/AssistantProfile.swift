import Foundation
import SwiftData

/// Who the assistant *is*: its name, personality, voice, and the AI/memory policies it operates
/// under (§9). Exactly one row exists; `AssistantProfileStore` owns that invariant.
///
/// ### Why raw strings for enums
/// Every enum is stored as its `rawValue` with a computed accessor. Two reasons, both load-bearing:
/// `#Predicate` cannot reach through a computed property or a `Codable` enum, and CloudKit stores
/// `Codable` enums as opaque binary, which makes them unqueryable. Raw columns keep both working.
///
/// ### CloudKit rules honoured here
/// Every property has a default value, nothing is uniquely constrained, and there are no
/// non-optional relationships — the three things SwiftData's CloudKit mirroring refuses.
@Model
final class AssistantProfile {
    var id: UUID = UUID()

    // MARK: Identity

    var assistantName: String = AuraDefaults.assistantName
    var personalityPresetRaw: String = PersonalityPreset.balanced.rawValue
    var customPersonalityPrompt: String?

    // MARK: Style

    var responseLengthRaw: String = ResponseLength.concise.rawValue
    var formalityRaw: String = FormalityLevel.neutral.rawValue
    var humorRaw: String = HumorLevel.subtle.rawValue
    var proactivityRaw: String = ProactivityLevel.balanced.rawValue
    var greetingStyleRaw: String = GreetingStyle.timeAware.rawValue
    var allowsPersonalityAdaptation: Bool = true

    // MARK: Voice

    var voiceIdentifier: String?
    var speechRate: Double = AuraDefaults.speechRate
    var speaksResponsesAutomatically: Bool = true

    // MARK: Policy

    var aiModeRaw: String = AIMode.automatic.rawValue
    var automaticMemoryEnabled: Bool = true
    var asksBeforeSavingMemory: Bool = false
    var usesMemoryInResponses: Bool = true
    var cloudSyncEnabled: Bool = true

    // MARK: Bookkeeping

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}

    // MARK: - Typed accessors

    var personalityPreset: PersonalityPreset {
        get { PersonalityPreset(rawValue: personalityPresetRaw) ?? .balanced }
        set { personalityPresetRaw = newValue.rawValue }
    }

    var responseLength: ResponseLength {
        get { ResponseLength(rawValue: responseLengthRaw) ?? .concise }
        set { responseLengthRaw = newValue.rawValue }
    }

    var formality: FormalityLevel {
        get { FormalityLevel(rawValue: formalityRaw) ?? .neutral }
        set { formalityRaw = newValue.rawValue }
    }

    var humor: HumorLevel {
        get { HumorLevel(rawValue: humorRaw) ?? .subtle }
        set { humorRaw = newValue.rawValue }
    }

    var proactivity: ProactivityLevel {
        get { ProactivityLevel(rawValue: proactivityRaw) ?? .balanced }
        set { proactivityRaw = newValue.rawValue }
    }

    var greetingStyle: GreetingStyle {
        get { GreetingStyle(rawValue: greetingStyleRaw) ?? .timeAware }
        set { greetingStyleRaw = newValue.rawValue }
    }

    var aiMode: AIMode {
        get { AIMode(rawValue: aiModeRaw) ?? .automatic }
        set { aiModeRaw = newValue.rawValue }
    }

    // MARK: - Snapshotting

    var snapshot: AssistantProfileSnapshot {
        AssistantProfileSnapshot(
            id: id,
            assistantName: assistantName,
            personalityPreset: personalityPreset,
            customPersonalityPrompt: customPersonalityPrompt,
            style: AssistantStyle(
                responseLength: responseLength,
                formality: formality,
                humor: humor,
                proactivity: proactivity
            ),
            greetingStyle: greetingStyle,
            voice: VoicePreferences(
                voiceIdentifier: voiceIdentifier,
                speechRate: speechRate,
                speaksResponsesAutomatically: speaksResponsesAutomatically
            ),
            allowsPersonalityAdaptation: allowsPersonalityAdaptation,
            aiMode: aiMode,
            memory: MemoryPreferences(
                automaticMemoryEnabled: automaticMemoryEnabled,
                asksBeforeSaving: asksBeforeSavingMemory,
                usesMemoryInResponses: usesMemoryInResponses,
                cloudSyncEnabled: cloudSyncEnabled
            ),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Applies a partial update. Returns `true` if anything actually changed, so callers can avoid
    /// pointless `updatedAt` bumps and the CloudKit pushes they would cause.
    @discardableResult
    func apply(_ mutation: AssistantProfileMutation, now: Date = Date()) -> Bool {
        var changed = false

        func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AssistantProfile, Value>, _ newValue: Value?) {
            guard let newValue, self[keyPath: keyPath] != newValue else { return }
            self[keyPath: keyPath] = newValue
            changed = true
        }

        if let name = mutation.assistantName {
            let normalized = AuraDefaults.normalizedAssistantName(name)
            if assistantName != normalized {
                assistantName = normalized
                changed = true
            }
        }

        set(\.personalityPresetRaw, mutation.personalityPreset?.rawValue)
        set(\.responseLengthRaw, mutation.responseLength?.rawValue)
        set(\.formalityRaw, mutation.formality?.rawValue)
        set(\.humorRaw, mutation.humor?.rawValue)
        set(\.proactivityRaw, mutation.proactivity?.rawValue)
        set(\.greetingStyleRaw, mutation.greetingStyle?.rawValue)
        set(\.aiModeRaw, mutation.aiMode?.rawValue)
        set(\.allowsPersonalityAdaptation, mutation.allowsPersonalityAdaptation)
        set(\.speaksResponsesAutomatically, mutation.speaksResponsesAutomatically)
        set(\.automaticMemoryEnabled, mutation.automaticMemoryEnabled)
        set(\.asksBeforeSavingMemory, mutation.asksBeforeSaving)
        set(\.usesMemoryInResponses, mutation.usesMemoryInResponses)
        set(\.cloudSyncEnabled, mutation.cloudSyncEnabled)

        // Double optionals: the outer level means "leave alone", the inner means "clear it".
        if let newPrompt = mutation.customPersonalityPrompt {
            let trimmed = newPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = (trimmed?.isEmpty ?? true) ? nil : trimmed
            if customPersonalityPrompt != resolved {
                customPersonalityPrompt = resolved
                changed = true
            }
        }

        if let newVoice = mutation.voiceIdentifier, voiceIdentifier != newVoice {
            voiceIdentifier = newVoice
            changed = true
        }

        if let rate = mutation.speechRate {
            let clamped = rate.clamped(to: 0...1)
            if speechRate != clamped {
                speechRate = clamped
                changed = true
            }
        }

        if changed { updatedAt = now }
        return changed
    }
}
