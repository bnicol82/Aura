import Foundation

/// Every failure AURA surfaces to a person goes through this type.
///
/// The point is §69 of the specification: AURA must never fail silently and must never imply
/// success it did not achieve. Each case carries a user-facing sentence written in the app's voice,
/// plus a recovery hint where one genuinely exists.
enum AuraError: LocalizedError, Equatable, Sendable {

    // MARK: Model

    /// Apple Intelligence is not usable on this device right now.
    case onDeviceModelUnavailable(ModelAvailability)
    /// A provider was asked for but is not configured (for example: no API key entered).
    case providerNotConfigured(providerName: String)
    /// A cloud provider was needed but the user has restricted AURA to on-device processing.
    case cloudDisabledByPrivacySetting
    /// The model produced nothing usable.
    case emptyModelResponse
    /// The conversation plus context no longer fits the model's context window.
    case contextWindowExceeded
    /// The model declined to answer.
    case modelRefusedRequest
    /// The model took too long.
    case modelTimedOut
    /// A provider-level failure with an already-user-safe description.
    case modelFailed(reason: String)

    // MARK: Connectivity

    case noInternetConnection

    // MARK: Storage & sync

    case persistentStoreUnavailable(reason: String)
    case saveFailed(reason: String)
    case recordNotFound(entity: String)
    case iCloudAccountUnavailable
    case syncFailed(reason: String)

    // MARK: Voice

    case microphonePermissionDenied
    case speechRecognitionPermissionDenied
    case speechRecognitionUnavailable(reason: String)
    case speechSynthesisUnavailable

    // MARK: Permissions & tools

    case permissionDenied(AuraPermission)
    case toolNotFound(name: String)
    case toolArgumentsInvalid(toolName: String, detail: String)
    case toolConfirmationDeclined(toolName: String)
    case toolFailed(toolName: String, reason: String)
    case toolIterationLimitReached(limit: Int)

    // MARK: Security

    case keychainFailure(status: Int32)

    /// Set when the user cancels; callers should stay quiet rather than showing an alert.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .onDeviceModelUnavailable(let availability):
            return availability.userFacingDescription
        case .providerNotConfigured(let providerName):
            return "\(providerName) isn't set up yet."
        case .cloudDisabledByPrivacySetting:
            return "That needs a cloud model, and you've got me set to on-device only."
        case .emptyModelResponse:
            return "I didn't get an answer back that time."
        case .contextWindowExceeded:
            return "This conversation got too long for me to hold all at once."
        case .modelRefusedRequest:
            return "I'm not able to help with that one."
        case .modelTimedOut:
            return "That took too long, so I stopped waiting."
        case .modelFailed(let reason):
            return reason
        case .noInternetConnection:
            return "I need an internet connection for that."
        case .persistentStoreUnavailable(let reason):
            return "I can't reach my local storage right now. (\(reason))"
        case .saveFailed:
            return "I couldn't save that."
        case .recordNotFound(let entity):
            return "I couldn't find that \(entity.lowercased())."
        case .iCloudAccountUnavailable:
            return "You're not signed in to iCloud, so I can't sync."
        case .syncFailed:
            return "iCloud sync didn't finish."
        case .microphonePermissionDenied:
            return "I need microphone access to hear you."
        case .speechRecognitionPermissionDenied:
            return "I need speech recognition access to understand what you said."
        case .speechRecognitionUnavailable(let reason):
            return "I can't transcribe speech right now. (\(reason))"
        case .speechSynthesisUnavailable:
            return "I can't speak out loud right now."
        case .permissionDenied(let permission):
            return "I don't have \(permission.displayName.lowercased()) access."
        case .toolNotFound(let name):
            return "I tried to use something called \(name), but I don't have it."
        case .toolArgumentsInvalid(_, let detail):
            return "I didn't have what I needed to do that. (\(detail))"
        case .toolConfirmationDeclined:
            return "Okay — I didn't do it."
        case .toolFailed(_, let reason):
            return "That didn't work. (\(reason))"
        case .toolIterationLimitReached:
            return "I went in circles on that one and stopped."
        case .keychainFailure:
            return "I couldn't reach the secure keychain."
        case .cancelled:
            return "Cancelled."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .onDeviceModelUnavailable(let availability):
            return availability.userFacingRecovery
        case .providerNotConfigured:
            return "Add it in Settings → AI Model."
        case .cloudDisabledByPrivacySetting:
            return "You can change that in Settings → AI Model."
        case .contextWindowExceeded:
            return "Start a new conversation and I'll carry over what matters."
        case .noInternetConnection, .syncFailed:
            return "Try again once you're back online."
        case .iCloudAccountUnavailable:
            return "Sign in to iCloud in Settings to sync across your devices."
        case .microphonePermissionDenied, .speechRecognitionPermissionDenied:
            return "You can grant it in Settings → Privacy."
        case .permissionDenied(let permission):
            return "You can grant \(permission.displayName.lowercased()) access in Settings → Permissions."
        default:
            return nil
        }
    }

    /// `true` when the failure is the user's own choice and no alert should be shown.
    var isSilent: Bool {
        switch self {
        case .cancelled, .toolConfirmationDeclined:
            return true
        default:
            return false
        }
    }
}
