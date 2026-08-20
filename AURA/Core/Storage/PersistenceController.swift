import Foundation
import SwiftData

/// Owns the app's single `ModelContainer`.
///
/// One container, created once at launch, shared by every store actor and by SwiftUI's `@Query`.
/// Two containers over one store file is a corruption hazard, so nothing else in the app is
/// permitted to construct one — tests use `PersistenceController.inMemory()`.
///
/// A `struct` rather than a `final class`, for a language reason worth recording: a class's throwing
/// initializer may only throw *after* every stored property it introduces has been set, and this
/// initializer has to throw from the middle — the container is what fails, and there is nothing
/// sensible to assign before knowing whether it opened. A value type has no such restriction.
/// `ModelContainer` is itself a `Sendable` reference type, so wrapping it in a struct costs nothing.
struct PersistenceController: Sendable {

    enum Storage: Sendable, Equatable {
        /// On-disk SQLite in the app's Application Support directory.
        case persistent
        /// Nothing touches the disk. Used by tests and previews.
        case inMemory
    }

    let container: ModelContainer
    let storage: Storage
    let sync: SyncConfiguration

    /// - Parameters:
    ///   - storage: on-disk or ephemeral.
    ///   - sync: local-only or CloudKit-mirrored. Forced to `.localOnly` for in-memory stores,
    ///     because mirroring an ephemeral store is meaningless.
    init(storage: Storage = .persistent, sync: SyncConfiguration = .default) throws {
        let effectiveSync: SyncConfiguration = storage == .inMemory ? .localOnly : sync
        let schema = AuraSchemaV1.schema

        // A note on a change that was tried and reverted, so nobody repeats it.
        //
        // Every store shares the configuration name "AURA", and a run where each test's in-memory store
        // got a unique name instead was measured: per-test duration went from about 10.1 seconds to about
        // 22.3 seconds. Unique names are roughly twice as slow here, presumably because each distinct
        // identity does its own store setup rather than reusing one. The shared name stays.
        //
        // The ~10 second per-test cost is real and still unexplained; it is not this.
        let configuration = ModelConfiguration(
            "AURA",
            schema: schema,
            isStoredInMemoryOnly: storage == .inMemory,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: effectiveSync.cloudKitDatabase
        )

        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: AuraMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            AuraLog.storage.error(
                "ModelContainer creation failed (storage: \(String(describing: storage), privacy: .public))"
            )
            throw AuraError.persistentStoreUnavailable(reason: error.localizedDescription)
        }

        self.storage = storage
        self.sync = effectiveSync

        AuraLog.storage.info(
            """
            Model container ready — storage: \(String(describing: storage), privacy: .public), \
            cloudKit: \(effectiveSync.isCloudEnabled, privacy: .public), \
            models: \(AuraSchemaV1.models.count, privacy: .public)
            """
        )
    }

    /// An ephemeral container for tests and previews.
    static func inMemory() throws -> PersistenceController {
        try PersistenceController(storage: .inMemory, sync: .localOnly)
    }

    /// Builds the real container, falling back to an ephemeral one if the store cannot be opened.
    ///
    /// A corrupt or unreadable store must not be a launch crash: AURA comes up, works for the
    /// session, and `didFallBackToMemory` lets the UI say so plainly rather than silently losing the
    /// user's data (§69).
    static func makeForApp() -> (controller: PersistenceController, failure: AuraError?) {
        do {
            return (try PersistenceController(), nil)
        } catch {
            let auraError = (error as? AuraError) ?? .persistentStoreUnavailable(
                reason: error.localizedDescription
            )
            AuraLog.storage.fault("Persistent store unavailable; falling back to in-memory storage.")
            do {
                return (try PersistenceController.inMemory(), auraError)
            } catch {
                // Both an on-disk and a purely in-memory SQLite store failed to open. There is no
                // remaining storage strategy, and continuing would mean an app that silently
                // discards everything the user says.
                preconditionFailure("Unable to create any SwiftData container: \(error)")
            }
        }
    }

    /// `true` when the app is running on a throwaway store and nothing will be kept.
    var isEphemeral: Bool { storage == .inMemory }
}
