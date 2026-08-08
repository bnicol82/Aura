import Foundation
import SwiftData

/// Version 1 of AURA's persistent schema (§63).
///
/// Declaring the schema as a `VersionedSchema` from day one — rather than passing a bare list of
/// model types to `ModelContainer` — means the first real migration is a new enum plus a
/// `MigrationStage`, not a retrofit of the store's identity.
///
/// ### The CloudKit rules every model here obeys
/// SwiftData's CloudKit mirroring refuses schemas that use features CloudKit cannot express. All
/// fifteen models below are written to satisfy them, and new models must too:
///
/// 1. **Every attribute has a default value or is optional.** CloudKit records arrive field by field
///    and a non-optional column with no default has nothing to hold.
/// 2. **No unique constraints.** `@Attribute(.unique)` and `#Unique` are unsupported. Where AURA
///    needs a single row — `AssistantProfile`, `UserProfile` — the owning store actor enforces it.
/// 3. **Every relationship is optional and has an explicit inverse.** Hence `[Message]?` rather
///    than `[Message]`.
/// 4. **No `.deny` delete rules.**
/// 5. **Enums are stored as raw `String` columns.** A `Codable` enum becomes opaque binary in
///    CloudKit and cannot be used in a `#Predicate`; raw columns stay queryable in both.
///
/// Cross-entity references that would create a dense or cyclic graph (memory → person, memory →
/// project, task → memory) are `UUID` columns rather than relationships, resolved in batches by the
/// retrieval engine.
enum AuraSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            // Identity and personalization
            AssistantProfile.self,
            UserProfile.self,
            ProfileFact.self,
            PersonProfile.self,
            ImportantDate.self,

            // Conversation
            Conversation.self,
            Message.self,

            // Memory
            MemoryItem.self,
            MemoryCandidate.self,

            // Work
            Project.self,
            AssistantTask.self,

            // Audit
            ToolExecution.self,
            ActivityRecord.self,

            // Future-facing, empty in V1
            KnowledgeDocument.self,
            UserPreference.self
        ]
    }
}

/// Migration plan for the store.
///
/// V1 has no stages because there is nothing to migrate from. When the schema changes, add
/// `AuraSchemaV2`, list it here after V1, and append the `MigrationStage` that bridges them.
enum AuraMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AuraSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

extension AuraSchemaV1 {
    /// The schema value handed to `ModelContainer`.
    static var schema: Schema { Schema(versionedSchema: AuraSchemaV1.self) }
}
