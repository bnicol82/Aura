import Foundation

/// The provider a router picked, and why.
///
/// The reason is not decoration — Settings shows the active provider (§7) and the privacy dashboard
/// has to explain when something left the device (§50). A router that returned only a provider would
/// leave both screens guessing.
struct ModelRoute: Sendable, Equatable {
    var providerID: LanguageModelProviderID
    var providerDisplayName: String
    var isOnDevice: Bool
    var reason: Reason

    enum Reason: Sendable, Equatable {
        /// The on-device model can handle it, so it does.
        case onDevicePreferred
        /// Purpose is pinned on-device regardless of mode (extraction, classification).
        case purposeRequiresOnDevice
        /// The user's mode restricts everything to the device.
        case privacyModeRestricted
        /// Escalated to a cloud model for a request the on-device model would handle poorly.
        case escalatedForCapability
        /// The user's mode prefers the strongest available model.
        case cloudPreferredByUser
        /// The on-device model is unavailable, so a configured cloud model is standing in.
        case onDeviceUnavailable(ModelAvailability)
        /// Only the fallback remained.
        case lastResort

        var userFacingExplanation: String {
            switch self {
            case .onDevicePreferred:
                return "Handled on your iPhone."
            case .purposeRequiresOnDevice:
                return "Handled on your iPhone — this kind of work never leaves the device."
            case .privacyModeRestricted:
                return "Handled on your iPhone because you've got me set to on-device only."
            case .escalatedForCapability:
                return "Sent to a cloud model because this needed more reasoning than the on-device model does well."
            case .cloudPreferredByUser:
                return "Sent to a cloud model, which is what you've asked me to prefer."
            case .onDeviceUnavailable(let availability):
                return "Sent to a cloud model because the on-device model isn't available. (\(availability.statusLabel))"
            case .lastResort:
                return "Using the only model available right now."
            }
        }

        /// `true` when data left the device. Drives the transcript's provenance indicator.
        var involvedCloudProcessing: Bool {
            switch self {
            case .escalatedForCapability, .cloudPreferredByUser, .onDeviceUnavailable:
                return true
            default:
                return false
            }
        }
    }
}

/// What the router needs to know beyond the request itself.
struct RoutingContext: Sendable, Equatable {
    var aiMode: AIMode
    var isOnline: Bool
    /// Set when a previous attempt failed with a context overflow, so the router can escalate to a
    /// provider with a larger window rather than retrying into the same wall.
    var previousFailure: RoutingFailure?
    /// Rough size of the assembled request, for capacity decisions.
    var estimatedPromptTokens: Int?
    /// `true` when the request offers tools.
    var requiresToolSupport: Bool

    enum RoutingFailure: Sendable, Equatable {
        case contextWindowExceeded
        case providerUnavailable(LanguageModelProviderID)
        case timedOut
    }

    init(
        aiMode: AIMode = .automatic,
        isOnline: Bool = true,
        previousFailure: RoutingFailure? = nil,
        estimatedPromptTokens: Int? = nil,
        requiresToolSupport: Bool = false
    ) {
        self.aiMode = aiMode
        self.isOnline = isOnline
        self.previousFailure = previousFailure
        self.estimatedPromptTokens = estimatedPromptTokens
        self.requiresToolSupport = requiresToolSupport
    }
}

/// Chooses which model answers a request (§7).
///
/// ### The rule that is not negotiable
/// `ModelRequestPurpose.isOnDeviceOnly` wins over everything, including `.cloudEnhanced`. Memory
/// extraction and classification see the user's raw words before any relevance filtering has
/// happened; routing them off-device would hand a third party exactly the unfiltered personal
/// material §50 exists to keep back. A router that treated the user's "prefer the best model"
/// setting as permission to do that would be a privacy bug wearing a feature's clothes.
protocol ModelRouting: Sendable {
    /// Picks a provider. Throws when nothing viable exists, so the caller can say why (§69).
    func route(
        purpose: ModelRequestPurpose,
        context: RoutingContext
    ) async throws -> (provider: any LanguageModelProvider, route: ModelRoute)

    /// Every registered provider with its current availability, for Settings.
    func providerStates() async -> [ProviderState]
}

/// A provider and its availability, for the Settings and Privacy screens.
struct ProviderState: Sendable, Equatable, Identifiable {
    var providerID: LanguageModelProviderID
    var displayName: String
    var isOnDevice: Bool
    var availability: ModelAvailability
    /// `true` when this provider would handle a plain conversational turn right now.
    var isActiveDefault: Bool

    var id: String { providerID.rawValue }
}
