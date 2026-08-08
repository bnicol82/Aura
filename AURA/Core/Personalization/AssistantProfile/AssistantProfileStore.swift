import Foundation
import SwiftData

/// Reads and writes the assistant's identity and settings (§9).
protocol AssistantProfileStoring: Sendable {
    /// The current profile, creating the default one on first launch.
    func currentProfile() async throws -> AssistantProfileSnapshot

    /// Applies a partial update and returns the result.
    @discardableResult
    func update(_ mutation: AssistantProfileMutation) async throws -> AssistantProfileSnapshot

    /// Restores factory settings, keeping the row's identity so sync sees an edit and not a
    /// delete-then-create.
    @discardableResult
    func resetToDefaults() async throws -> AssistantProfileSnapshot
}

/// SwiftData-backed `AssistantProfileStoring`.
///
/// ### Why an actor
/// `@ModelActor` gives this type its own `ModelContext` on its own executor. Every read and write
/// happens there, and only `Sendable` snapshots cross the boundary — SwiftData model objects are not
/// `Sendable` and must never be handed to another isolation domain.
///
/// ### The singleton problem
/// Exactly one profile row should exist, but CloudKit makes that harder than it sounds:
/// `@Attribute(.unique)` is unsupported when mirroring, and two devices that both complete onboarding
/// while offline will each create a row and then sync both. `resolveSingleton()` handles that
/// collision explicitly — most recently updated row wins, extras are deleted, and the merge is
/// logged. Ignoring it would leave the user with an assistant whose name changes depending on which
/// row a fetch happened to return first.
@ModelActor
actor AssistantProfileStore: AssistantProfileStoring {

    func currentProfile() async throws -> AssistantProfileSnapshot {
        try resolveSingleton().snapshot
    }

    @discardableResult
    func update(_ mutation: AssistantProfileMutation) async throws -> AssistantProfileSnapshot {
        let profile = try resolveSingleton()
        guard !mutation.isEmpty else { return profile.snapshot }

        let changed = profile.apply(mutation)
        if changed {
            try persist()
            AuraLog.app.info("Assistant profile updated.")
        }
        return profile.snapshot
    }

    @discardableResult
    func resetToDefaults() async throws -> AssistantProfileSnapshot {
        let profile = try resolveSingleton()
        let fresh = AssistantProfile()

        profile.assistantName = fresh.assistantName
        profile.personalityPresetRaw = fresh.personalityPresetRaw
        profile.customPersonalityPrompt = nil
        profile.responseLengthRaw = fresh.responseLengthRaw
        profile.formalityRaw = fresh.formalityRaw
        profile.humorRaw = fresh.humorRaw
        profile.proactivityRaw = fresh.proactivityRaw
        profile.greetingStyleRaw = fresh.greetingStyleRaw
        profile.allowsPersonalityAdaptation = fresh.allowsPersonalityAdaptation
        profile.voiceIdentifier = nil
        profile.speechRate = fresh.speechRate
        profile.speaksResponsesAutomatically = fresh.speaksResponsesAutomatically
        profile.aiModeRaw = fresh.aiModeRaw
        profile.automaticMemoryEnabled = fresh.automaticMemoryEnabled
        profile.asksBeforeSavingMemory = fresh.asksBeforeSavingMemory
        profile.usesMemoryInResponses = fresh.usesMemoryInResponses
        profile.cloudSyncEnabled = fresh.cloudSyncEnabled
        profile.updatedAt = Date()

        try persist()
        AuraLog.app.notice("Assistant profile reset to defaults.")
        return profile.snapshot
    }

    // MARK: - Internals

    /// Returns the one true profile, creating it or reconciling duplicates as needed.
    private func resolveSingleton() throws -> AssistantProfile {
        let descriptor = FetchDescriptor<AssistantProfile>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )

        let existing: [AssistantProfile]
        do {
            existing = try modelContext.fetch(descriptor)
        } catch {
            throw AuraError.persistentStoreUnavailable(reason: error.localizedDescription)
        }

        guard let winner = Self.preferredProfile(from: existing) else {
            let profile = AssistantProfile()
            modelContext.insert(profile)
            try persist()
            AuraLog.app.info("Created the initial assistant profile.")
            return profile
        }

        if existing.count > 1 {
            for duplicate in existing where duplicate.id != winner.id {
                modelContext.delete(duplicate)
            }
            try persist()
            AuraLog.sync.notice(
                "Reconciled \(existing.count - 1, privacy: .public) duplicate assistant profile row(s)."
            )
        }

        return winner
    }

    /// Picks the surviving row: most recently updated, then oldest, then lowest id.
    ///
    /// Deterministic all the way down, so two devices resolving the same duplicate set independently
    /// reach the same answer and do not fight over it.
    static func preferredProfile(from profiles: [AssistantProfile]) -> AssistantProfile? {
        profiles.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func persist() throws {
        do {
            try modelContext.save()
        } catch {
            AuraLog.storage.error("Failed to save assistant profile.")
            throw AuraError.saveFailed(reason: error.localizedDescription)
        }
    }
}
