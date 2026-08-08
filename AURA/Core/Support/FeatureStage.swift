import Foundation

/// Whether a capability is finished, and if not, when it lands.
///
/// AURA is built in phases, and §75/§78 forbid presenting unfinished work as working. Rather than
/// leaving that to each view's good intentions, an unfinished capability is *declared* here and the
/// UI reads the declaration: a control backed by a non-live stage renders disabled with a specific,
/// honest note instead of failing silently or lying.
///
/// The rule for maintaining this file: a capability's stage flips to `.live` in the same commit that
/// makes it work. Never before.
enum FeatureStage: Sendable, Equatable {
    /// Implemented and working.
    case live
    /// Not implemented yet. `phase` matches the build order in §74.
    case pending(phase: Int, phaseName: String, note: String)

    var isLive: Bool { self == .live }

    /// What the UI tells the user. `nil` when the feature works.
    var userFacingNote: String? {
        switch self {
        case .live:
            return nil
        case .pending(_, _, let note):
            return note
        }
    }

    /// Short badge text: "Phase 2".
    var badgeText: String? {
        switch self {
        case .live:
            return nil
        case .pending(let phase, _, _):
            return "Phase \(phase)"
        }
    }
}

/// The current state of AURA's capabilities.
///
/// Phase 1 delivered the foundation: the schema, the core contracts, the profile stores, the
/// personality engine and the navigation shell. Everything that needs a model, a microphone, or a
/// tool is declared pending, with the note the UI shows.
enum FeatureFlags {

    /// Typed conversation with the assistant.
    ///
    /// Live as of Phase 2: `AppleFoundationModelProvider`, `DefaultModelRouter`,
    /// `AssistantOrchestrator` and `SwiftDataConversationStore` are all real. What a given device can
    /// actually do still depends on Apple Intelligence being available there — that is a runtime
    /// question answered by `ModelAvailability`, not a build-stage one.
    static let textConversation = FeatureStage.live

    /// Voice input.
    static let voiceInput = FeatureStage.pending(
        phase: 5,
        phaseName: "Voice",
        note: "Talking to me isn't wired up yet. Voice comes after the conversation layer."
    )

    /// Spoken replies.
    static let voiceOutput = FeatureStage.pending(
        phase: 5,
        phaseName: "Voice",
        note: "I can't speak out loud yet."
    )

    /// Saved conversation history.
    ///
    /// Live as of Phase 2 rather than Phase 6: the orchestrator has to persist a turn to have anywhere
    /// to put it, so `SwiftDataConversationStore` arrived with it. Phase 6's remaining work is history
    /// browsing and archive search UI, not the storage itself.
    static let conversationHistory = FeatureStage.live

    /// Automatic and explicit memory.
    static let memory = FeatureStage.pending(
        phase: 7,
        phaseName: "Memory",
        note: "I'm not learning anything from conversations yet. You can still add and edit what I know by hand."
    )

    /// Manually curating the profile — the "What AURA Knows About You" editor.
    ///
    /// Live in Phase 1: the stores, the models and the editing UI are all real, which means the user
    /// can teach AURA about themselves before the model layer exists.
    static let manualProfileEditing = FeatureStage.live

    /// Assistant naming, personality, style, voice preferences.
    static let personalityCustomization = FeatureStage.live

    /// iCloud sync.
    static let cloudSync = FeatureStage.pending(
        phase: 9,
        phaseName: "CloudKit",
        note: "Everything stays on this iPhone for now. iCloud sync is coming."
    )

    /// Tool execution.
    static let tools = FeatureStage.pending(
        phase: 10,
        phaseName: "Tool System",
        note: "I can't take actions yet — no reminders, calendar entries or app launching."
    )

    /// Calendar, Reminders, Weather, Contacts, Location.
    static let systemIntegrations = FeatureStage.pending(
        phase: 12,
        phaseName: "Productivity Tools",
        note: "I can't reach your calendar, reminders or the weather yet."
    )

    /// Siri, Shortcuts, App Intents, Action Button.
    static let appIntents = FeatureStage.pending(
        phase: 11,
        phaseName: "iOS Integration",
        note: "Siri and Shortcuts support is coming."
    )

    /// Activity audit trail.
    static let activityLog = FeatureStage.pending(
        phase: 10,
        phaseName: "Tool System",
        note: "There's nothing to show yet — this fills in once I can take actions."
    )

    /// Exporting stored data.
    static let dataExport = FeatureStage.pending(
        phase: 13,
        phaseName: "Privacy & Hardening",
        note: "Export isn't built yet."
    )
}
