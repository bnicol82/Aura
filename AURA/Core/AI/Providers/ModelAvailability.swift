import Foundation

/// Whether a language model can be used right now (§68).
///
/// The cases mirror `SystemLanguageModel.Availability` plus the states only a networked provider can
/// be in. Keeping one enum for both means `ModelRouter` and the UI never have to know which family
/// of provider they are looking at.
enum ModelAvailability: Equatable, Sendable {
    case available
    /// The hardware cannot run Apple Intelligence.
    case deviceUnsupported
    /// Eligible hardware, but Apple Intelligence is switched off in Settings.
    case appleIntelligenceDisabled
    /// Assets are still downloading or the model is warming up.
    case modelNotReady
    /// A transient failure — worth retrying.
    case temporarilyUnavailable(reason: String)
    /// A cloud provider with no credentials or no configuration.
    case notConfigured
    /// A cloud provider that needs the network.
    case requiresNetwork
    /// A cloud provider blocked by the user's on-device-only setting.
    case blockedByPrivacySetting
    /// The provider reported something we do not model.
    case unknown

    var isAvailable: Bool { self == .available }

    /// `true` when trying again later could plausibly succeed without the user doing anything.
    var isTransient: Bool {
        switch self {
        case .modelNotReady, .temporarilyUnavailable, .requiresNetwork: return true
        default: return false
        }
    }

    var userFacingDescription: String {
        switch self {
        case .available:
            return "Ready."
        case .deviceUnsupported:
            return "This iPhone can't run Apple's on-device model."
        case .appleIntelligenceDisabled:
            return "Apple Intelligence is turned off."
        case .modelNotReady:
            return "The on-device model is still getting ready."
        case .temporarilyUnavailable(let reason):
            return "The model isn't available at the moment. (\(reason))"
        case .notConfigured:
            return "That model isn't set up yet."
        case .requiresNetwork:
            return "That model needs an internet connection."
        case .blockedByPrivacySetting:
            return "That model is a cloud model, and you've got me set to on-device only."
        case .unknown:
            return "I can't tell whether that model is available."
        }
    }

    var userFacingRecovery: String? {
        switch self {
        case .deviceUnsupported:
            return "You can connect a cloud model in Settings → AI Model, or keep using memory, search and your profile offline."
        case .appleIntelligenceDisabled:
            return "Turn it on in Settings → Apple Intelligence & Siri."
        case .modelNotReady:
            return "Give it a few minutes on Wi-Fi and try again."
        case .notConfigured:
            return "Add it in Settings → AI Model."
        case .requiresNetwork:
            return "Try again once you're back online."
        case .blockedByPrivacySetting:
            return "Change that in Settings → AI Model."
        default:
            return nil
        }
    }

    /// Short label for the Settings and Privacy screens.
    var statusLabel: String {
        switch self {
        case .available: return "Available"
        case .deviceUnsupported: return "Not supported"
        case .appleIntelligenceDisabled: return "Disabled"
        case .modelNotReady: return "Preparing"
        case .temporarilyUnavailable: return "Unavailable"
        case .notConfigured: return "Not configured"
        case .requiresNetwork: return "Needs network"
        case .blockedByPrivacySetting: return "Blocked"
        case .unknown: return "Unknown"
        }
    }
}
