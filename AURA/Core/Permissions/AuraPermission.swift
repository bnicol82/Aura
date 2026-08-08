import Foundation

/// Every system authorization AURA can ask for.
///
/// Permissions are requested *contextually* (§52) — the first time a feature actually needs one —
/// never in a batch during onboarding. A denial disables exactly one capability and nothing else.
enum AuraPermission: String, Codable, CaseIterable, Sendable, Identifiable {
    case microphone
    case speechRecognition
    case calendar
    case reminders
    case contacts
    case location
    case notifications

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .location: return "Location"
        case .notifications: return "Notifications"
        }
    }

    var symbolName: String {
        switch self {
        case .microphone: return "mic"
        case .speechRecognition: return "waveform"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .contacts: return "person.crop.circle"
        case .location: return "location"
        case .notifications: return "bell"
        }
    }

    /// Shown in the sheet that precedes the system prompt, so the ask is never a surprise.
    var rationale: String {
        switch self {
        case .microphone:
            return "so you can talk instead of typing."
        case .speechRecognition:
            return "so I can turn what you said into text I can work with."
        case .calendar:
            return "so I can answer questions about your schedule and add events you ask for."
        case .reminders:
            return "so I can create the reminders you ask for."
        case .contacts:
            return "so I know who the people you mention are."
        case .location:
            return "so answers about weather and travel time are about where you actually are."
        case .notifications:
            return "so I can reach you about the things you asked me to follow up on."
        }
    }

    /// What stops working if this is denied. Used verbatim in the Privacy dashboard.
    var degradationNotice: String {
        switch self {
        case .microphone, .speechRecognition:
            return "Voice input is off. Typing still works."
        case .calendar:
            return "I can't see or change your schedule."
        case .reminders:
            return "I can remember a commitment, but I can't create a system reminder for it."
        case .contacts:
            return "I only know the people you've told me about directly."
        case .location:
            return "You'll need to tell me the place you mean."
        case .notifications:
            return "I can't reach you unless the app is open."
        }
    }
}

/// Normalized authorization state across Apple's several per-framework enums.
enum PermissionStatus: String, Codable, CaseIterable, Sendable {
    /// Never asked.
    case notDetermined
    /// Fully granted.
    case authorized
    /// Granted, but narrower than requested — for example write-only calendar access.
    case limited
    /// The user said no.
    case denied
    /// Blocked by device management or parental controls; asking again will not help.
    case restricted

    var isUsable: Bool { self == .authorized || self == .limited }

    var displayName: String {
        switch self {
        case .notDetermined: return "Not asked yet"
        case .authorized: return "Allowed"
        case .limited: return "Limited"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        }
    }
}
