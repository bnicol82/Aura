import Foundation

/// The three safety tiers from §34. A tool's tier decides whether AURA may just do the thing.
enum ToolRiskLevel: String, Codable, CaseIterable, Sendable, Comparable {
    /// Reads nothing but data the user already has. Searching memory, reading the calendar,
    /// fetching weather. No confirmation once the underlying permission is granted.
    case readOnly

    /// Creates something the user can trivially undo: a reminder, a calendar event, a saved memory.
    /// Runs without a prompt **when the user asked for it in this turn**; a tool the model reached
    /// for on its own still gets confirmed.
    case reversible

    /// Consequential and not cheaply undone: deleting in bulk, sending messages, spending money,
    /// changing accounts, running sensitive automations. Always confirmed immediately before it runs.
    case consequential

    var displayName: String {
        switch self {
        case .readOnly: return "Read only"
        case .reversible: return "Reversible"
        case .consequential: return "Consequential"
        }
    }

    /// Whether this tier needs explicit confirmation given how the tool came to be invoked.
    ///
    /// - Parameter userExplicitlyRequested: `true` when the user's own words in this turn asked for
    ///   this action, rather than the model deciding to take it.
    func requiresConfirmation(userExplicitlyRequested: Bool) -> Bool {
        switch self {
        case .readOnly: return false
        case .reversible: return !userExplicitlyRequested
        case .consequential: return true
        }
    }

    private var order: Int {
        switch self {
        case .readOnly: return 0
        case .reversible: return 1
        case .consequential: return 2
        }
    }

    static func < (lhs: ToolRiskLevel, rhs: ToolRiskLevel) -> Bool {
        lhs.order < rhs.order
    }
}
