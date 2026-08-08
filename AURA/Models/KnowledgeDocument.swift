import Foundation
import SwiftData

/// A file the user imported for AURA to draw on (§60).
///
/// **Intentional future stub.** Nothing writes to this table in V1 and no UI creates rows. It is in
/// the schema now for one reason: adding a `@Model` type later is a store migration, and adding it
/// up front while the store is empty costs nothing. The document pipeline — extract, chunk, embed,
/// retrieve — is a V2 deliverable.
///
/// The file itself is *not* stored here. Only its location and derived metadata are; the bytes live
/// in the app's iCloud container so a large PDF never inflates a CloudKit record.
@Model
final class KnowledgeDocument {
    var id: UUID = UUID()

    var title: String = ""
    var filename: String = ""
    /// Path relative to the app's document container, never an absolute URL — absolute paths do not
    /// survive reinstalls or move between devices.
    var relativePath: String = ""
    var mimeType: String?
    var byteCount: Int = 0

    /// Whether text extraction has run. Extraction is expensive, so this gates re-processing.
    var isTextExtracted: Bool = false
    /// AI-generated description of what the document contains, used to decide relevance before any
    /// chunk is loaded.
    var summary: String?
    var chunkCount: Int = 0

    var tags: [String] = []
    var searchText: String = ""

    var importedAt: Date = Date()
    var lastProcessedAt: Date?

    init(
        title: String = "",
        filename: String = "",
        relativePath: String = "",
        importedAt: Date = Date()
    ) {
        self.title = title
        self.filename = filename
        self.relativePath = relativePath
        self.importedAt = importedAt
        self.searchText = "\(title) \(filename)".lowercased()
    }
}

/// Loose key/value settings that do not deserve a column on `AssistantProfile`.
///
/// Used for things that are device-local or experimental: which onboarding build the user saw, a
/// feature flag, a dismissed tip. Anything the user manages in Settings belongs on
/// `AssistantProfile` instead, where it syncs as one coherent unit.
@Model
final class UserPreference {
    /// Not uniquely constrained — CloudKit mirroring rejects unique constraints — so
    /// `PreferenceStore` enforces one row per key.
    var key: String = ""
    /// The value as JSON text, via `JSONValue`.
    var valueJSON: String = "null"
    var updatedAt: Date = Date()

    init(key: String = "", value: JSONValue = .null, updatedAt: Date = Date()) {
        self.key = key
        self.valueJSON = value.jsonString() ?? "null"
        self.updatedAt = updatedAt
    }

    var value: JSONValue {
        get { JSONValue(jsonString: valueJSON) ?? .null }
        set { valueJSON = newValue.jsonString() ?? "null" }
    }
}
