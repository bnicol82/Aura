import Foundation

/// Everything AURA holds about the user, in one file (§48, §55).
///
/// ### Why the export has its own types rather than encoding the snapshots
/// The exported file is a contract with the user: they should be able to open it in five years and read
/// it, and a script they wrote against it should keep working. Encoding `MemorySnapshot` directly would
/// make every internal rename a silent breaking change to that file. So the shape is declared here, once,
/// and mapping into it is explicit — which also means a new internal field is not exported by accident.
///
/// ### Why it is JSON and not something prettier
/// It has to be *readable by the user* and *complete*, in that order of who it serves. JSON is the only
/// format that is both without a viewer: a person can open it, and a program can parse it. A PDF would be
/// nicer to look at and would quietly lose structure.
struct DataExportBundle: Codable, Sendable, Equatable {

    /// What this file is, so it is self-describing rather than needing AURA to interpret it.
    struct Manifest: Codable, Sendable, Equatable {
        /// Bumped when the shape changes incompatibly. A reader can refuse rather than misparse.
        var formatVersion: Int
        var exportedAt: Date
        var appVersion: String
        /// Counts, so anyone — including the user — can tell at a glance whether the file looks complete.
        var counts: [String: Int]
        /// Stated in the file itself, because a promise about scope that lives only in the app is not
        /// checkable by the person holding the export.
        var note: String
    }

    var manifest: Manifest
    var assistant: AssistantExport
    var user: UserExport
    var facts: [FactExport]
    var people: [PersonExport]
    var memories: [MemoryExport]
    var conversations: [ConversationExport]
    var activity: [ActivityExport]

    static let currentFormatVersion = 1

    /// The sentence written into every export.
    static let scopeNote = """
        This file contains everything AURA stored about you on this device: your profile, the people and \
        facts it knows, everything it remembered, every conversation, and its record of the actions it \
        took. It does not contain API keys or other credentials, which are held in the iOS Keychain and \
        are not yours to move. Nothing in this file was sent anywhere to produce it.
        """
}

struct AssistantExport: Codable, Sendable, Equatable {
    var name: String
    var personalityPreset: String
    /// Verbatim, because it is the user's own words about who they want AURA to be.
    var customPersonalityPrompt: String?
    var responseLength: String
    var formality: String
    var humor: String
    var proactivity: String
    var greetingStyle: String
    var allowsPersonalityAdaptation: Bool
    var aiMode: String
    var createdAt: Date
    var updatedAt: Date
}

struct UserExport: Codable, Sendable, Equatable {
    var preferredName: String?
    var pronouns: String?
    var workContext: String?
    var educationContext: String?
    var locationContext: String?
    var communicationPreferences: [String]
    var interests: [String]
    var hobbies: [String]
    var longTermGoals: [String]
    var routines: [String]
    var importantPlaces: [String]
    /// The standing instructions from §12 — the most deliberate thing the user has told AURA, so it would
    /// be the worst single thing for an export to drop.
    var assistantInstructions: [String]
    var createdAt: Date
    var updatedAt: Date
}

struct FactExport: Codable, Sendable, Equatable {
    var id: UUID
    var category: String
    var key: String
    var value: String
    var confidence: Double
    var isPinned: Bool
    var isArchived: Bool
    var sourceMemoryID: UUID?
    var supersededByFactID: UUID?
    var createdAt: Date
    var updatedAt: Date
}

struct PersonExport: Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var nickname: String?
    var relationship: String?
    var education: String?
    var work: String?
    var notes: String?
    var importantFacts: [String]
    var preferences: [String]
    var interests: [String]
    var importantDates: [ImportantDateExport]
    var isPinned: Bool
    var isArchived: Bool
}

struct ImportantDateExport: Codable, Sendable, Equatable {
    var id: UUID
    var label: String
    var date: Date
    var recursAnnually: Bool
}

struct MemoryExport: Codable, Sendable, Equatable {
    var id: UUID
    var content: String
    var summary: String
    var type: String
    var category: String
    var importance: Double
    var confidence: Double
    var wasExplicitlyRequested: Bool
    var isPinned: Bool
    var isArchived: Bool
    var tags: [String]
    var entities: [String]
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date?
    var accessCount: Int
    /// Present when this memory replaced an earlier one, so the correction history in §23 survives export.
    var supersededByMemoryID: UUID?
}

struct ConversationExport: Codable, Sendable, Equatable {
    var id: UUID
    var title: String
    var summary: String?
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    var messages: [MessageExport]
}

struct MessageExport: Codable, Sendable, Equatable {
    var id: UUID
    var role: String
    var content: String
    var sequence: Int
    var createdAt: Date
    var isFailure: Bool
    var providerIdentifier: String?
    /// The tools AURA ran during this turn, so the export is a record of actions and not only of words.
    var toolActivity: [ToolActivityExport]
}

struct ToolActivityExport: Codable, Sendable, Equatable {
    var toolName: String
    var label: String
    var succeeded: Bool
    var outcome: String?
}

struct ActivityExport: Codable, Sendable, Equatable {
    var id: UUID
    var kind: String
    var title: String
    var detail: String?
    var succeeded: Bool
    var createdAt: Date
}

/// Produces the export (§55).
protocol DataExporting: Sendable {
    /// Gathers everything and returns it.
    ///
    /// Throws rather than returning a partial bundle. An export is a promise of completeness, and a file
    /// that silently omits a store is worse than no file: the user would keep it, delete the app, and only
    /// find out later.
    func exportBundle(at date: Date) async throws -> DataExportBundle

    /// Writes the bundle to a file and returns its location, ready to hand to a share sheet.
    func writeExport(at date: Date) async throws -> URL
}
