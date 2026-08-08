import Foundation
import SwiftData
import Testing

@testable import AURA

@Suite("Assistant profile store")
struct AssistantProfileStoreTests {

    private func makeStore() throws -> AssistantProfileStore {
        let controller = try PersistenceController.inMemory()
        return AssistantProfileStore(modelContainer: controller.container)
    }

    @Test("First read creates the default profile")
    func createsDefaultProfile() async throws {
        let store = try makeStore()
        let profile = try await store.currentProfile()

        #expect(profile.assistantName == AuraDefaults.assistantName)
        #expect(profile.personalityPreset == .balanced)
        #expect(profile.aiMode == .automatic)
        #expect(profile.memory.automaticMemoryEnabled)
        #expect(!profile.memory.asksBeforeSaving)
    }

    @Test("Repeated reads return the same row rather than creating more")
    func isASingleton() async throws {
        let store = try makeStore()
        let first = try await store.currentProfile()
        let second = try await store.currentProfile()
        let third = try await store.currentProfile()

        #expect(first.id == second.id)
        #expect(second.id == third.id)
    }

    @Test("Renaming the assistant persists and normalises the name")
    func renamesAssistant() async throws {
        let store = try makeStore()

        var mutation = AssistantProfileMutation()
        mutation.assistantName = "   Nova   "
        let updated = try await store.update(mutation)
        #expect(updated.assistantName == "Nova")

        let reread = try await store.currentProfile()
        #expect(reread.assistantName == "Nova")
    }

    @Test("An empty name falls back to the default rather than leaving a nameless assistant")
    func rejectsEmptyName() async throws {
        let store = try makeStore()
        var mutation = AssistantProfileMutation()
        mutation.assistantName = "    "
        let updated = try await store.update(mutation)
        #expect(updated.assistantName == AuraDefaults.assistantName)
    }

    @Test("An over-long name is truncated to the documented limit")
    func truncatesLongName() async throws {
        let store = try makeStore()
        var mutation = AssistantProfileMutation()
        mutation.assistantName = String(repeating: "a", count: 200)
        let updated = try await store.update(mutation)
        #expect(updated.assistantName.count == AuraDefaults.assistantNameMaxLength)
    }

    @Test("Applying a preset sets the preset and the style it implies")
    func appliesPresetWithStyle() async throws {
        let store = try makeStore()
        let updated = try await store.update(.applying(preset: .direct))

        #expect(updated.personalityPreset == .direct)
        #expect(updated.style == PersonalityPreset.direct.defaultStyle)
        #expect(updated.style.humor == .none)
        #expect(updated.style.responseLength == .brief)
    }

    @Test("A no-op mutation leaves updatedAt alone")
    func noOpDoesNotTouchTimestamp() async throws {
        let store = try makeStore()
        let before = try await store.currentProfile()

        var mutation = AssistantProfileMutation()
        mutation.assistantName = before.assistantName
        mutation.aiMode = before.aiMode
        let after = try await store.update(mutation)

        // This matters beyond tidiness: a bumped timestamp is a CloudKit push once sync is on.
        #expect(after.updatedAt == before.updatedAt)
    }

    @Test("A real change does bump updatedAt")
    func realChangeBumpsTimestamp() async throws {
        let store = try makeStore()
        let before = try await store.currentProfile()

        var mutation = AssistantProfileMutation()
        mutation.humor = before.style.humor == .playful ? .none : .playful
        let after = try await store.update(mutation)

        #expect(after.updatedAt > before.updatedAt)
    }

    @Test("A custom description can be set and then cleared")
    func customDescriptionLifecycle() async throws {
        let store = try makeStore()

        var set = AssistantProfileMutation()
        set.personalityPreset = .custom
        set.customPersonalityPrompt = .some("Dry and precise.")
        let withDescription = try await store.update(set)
        #expect(withDescription.customPersonalityPrompt == "Dry and precise.")

        // The inner `nil` clears; an absent outer value would have meant "leave alone".
        var clear = AssistantProfileMutation()
        clear.customPersonalityPrompt = .some(nil)
        let cleared = try await store.update(clear)
        #expect(cleared.customPersonalityPrompt == nil)
    }

    @Test("Speech rate is clamped to Apple's valid range")
    func clampsSpeechRate() async throws {
        let store = try makeStore()

        var tooHigh = AssistantProfileMutation()
        tooHigh.speechRate = 9
        #expect(try await store.update(tooHigh).voice.speechRate == 1)

        var tooLow = AssistantProfileMutation()
        tooLow.speechRate = -4
        #expect(try await store.update(tooLow).voice.speechRate == 0)
    }

    @Test("Reset restores defaults but keeps the row's identity")
    func resetKeepsIdentity() async throws {
        let store = try makeStore()
        let original = try await store.currentProfile()

        var mutation = AssistantProfileMutation()
        mutation.assistantName = "Atlas"
        mutation.aiMode = .onDeviceOnly
        mutation.personalityPreset = .refined
        _ = try await store.update(mutation)

        let reset = try await store.resetToDefaults()
        #expect(reset.assistantName == AuraDefaults.assistantName)
        #expect(reset.aiMode == .automatic)
        #expect(reset.personalityPreset == .balanced)
        // Same row, so sync sees an edit rather than a delete-then-create.
        #expect(reset.id == original.id)
    }

    @Test("Duplicate profile rows are reconciled to the most recently updated one")
    func reconcilesDuplicates() async throws {
        let controller = try PersistenceController.inMemory()

        // Each `ModelContext` is confined to its own synchronous helper. `ModelContext` is not
        // `Sendable`, so holding one across an `await` is exactly the mistake this codebase avoids.
        try seedDuplicateProfiles(in: controller)

        let store = AssistantProfileStore(modelContainer: controller.container)
        let resolved = try await store.currentProfile()
        #expect(resolved.assistantName == "Newer")

        #expect(try profileRowCount(in: controller) == 1)
    }

    /// Two devices completing onboarding offline, then syncing, produce exactly this.
    private func seedDuplicateProfiles(in controller: PersistenceController) throws {
        let context = ModelContext(controller.container)

        let older = AssistantProfile()
        older.assistantName = "Older"
        older.createdAt = Date(timeIntervalSince1970: 1000)
        older.updatedAt = Date(timeIntervalSince1970: 1000)

        let newer = AssistantProfile()
        newer.assistantName = "Newer"
        newer.createdAt = Date(timeIntervalSince1970: 2000)
        newer.updatedAt = Date(timeIntervalSince1970: 5000)

        context.insert(older)
        context.insert(newer)
        try context.save()
    }

    private func profileRowCount(in controller: PersistenceController) throws -> Int {
        try ModelContext(controller.container)
            .fetchCount(FetchDescriptor<AssistantProfile>())
    }
}

@Suite("User profile store")
struct UserProfileStoreTests {

    private func makeStore() throws -> UserProfileStore {
        let controller = try PersistenceController.inMemory()
        return UserProfileStore(modelContainer: controller.container)
    }

    @Test("A fresh profile knows nothing")
    func startsEmpty() async throws {
        let store = try makeStore()
        let profile = try await store.currentProfile()

        #expect(profile.isEssentiallyEmpty)
        #expect(profile.preferredName == nil)
        #expect(profile.knownItemCount == 0)
    }

    @Test("The preferred name can be set and cleared")
    func preferredNameLifecycle() async throws {
        let store = try makeStore()

        var set = UserProfileMutation()
        set.preferredName = .some("Blake")
        #expect(try await store.update(set).preferredName == "Blake")

        // An empty string means "clear it" — how a user deletes something they typed.
        var clear = UserProfileMutation()
        clear.preferredName = .some("")
        #expect(try await store.update(clear).preferredName == nil)
    }

    @Test("List fields are trimmed and de-duplicated case-insensitively")
    func normalisesLists() async throws {
        let store = try makeStore()

        var mutation = UserProfileMutation()
        mutation.interests = ["  NASCAR ", "nascar", "Woodworking", "", "   "]
        let updated = try await store.update(mutation)

        #expect(updated.interests == ["NASCAR", "Woodworking"])
    }

    // MARK: Facts

    @Test("A fact is stored with the confidence it was given")
    func storesFact() async throws {
        let store = try makeStore()
        let fact = try await store.upsertFact(
            key: "Favourite NASCAR driver",
            value: "Christopher Bell",
            category: .sports,
            confidence: AuraDefaults.Confidence.explicit,
            sourceMemoryID: nil
        )

        #expect(fact.value == "Christopher Bell")
        #expect(fact.category == .sports)
        #expect(fact.confidence == AuraDefaults.Confidence.explicit)
    }

    @Test("Re-stating the same fact does not create a second row")
    func idempotentUpsert() async throws {
        let store = try makeStore()
        for _ in 0..<3 {
            _ = try await store.upsertFact(
                key: "Preferred seat",
                value: "Aisle",
                category: .travel,
                confidence: AuraDefaults.Confidence.explicit,
                sourceMemoryID: nil
            )
        }
        let facts = try await store.facts(in: [.travel])
        #expect(facts.count == 1)
    }

    @Test("Correcting a fact supersedes the old value instead of overwriting it")
    func correctionSupersedes() async throws {
        let store = try makeStore()

        let original = try await store.upsertFact(
            key: "Major",
            value: "Aerospace Engineering",
            category: .education,
            confidence: AuraDefaults.Confidence.explicit,
            sourceMemoryID: nil
        )

        let corrected = try await store.upsertFact(
            key: "Major",
            value: "Mechanical Engineering",
            category: .education,
            confidence: AuraDefaults.Confidence.explicit,
            sourceMemoryID: nil
        )

        #expect(corrected.id != original.id)

        // Only the current value is live — the old one must never come back as fact (§23).
        let live = try await store.facts(in: [.education])
        #expect(live.count == 1)
        #expect(live.first?.value == "Mechanical Engineering")
    }

    @Test("A hedged fact keeps its low confidence and is flagged in context")
    func lowConfidenceIsPreserved() async throws {
        let store = try makeStore()
        let fact = try await store.upsertFact(
            key: "Jennifer's favourite restaurant",
            value: "Maybe the Italian place",
            category: .food,
            confidence: AuraDefaults.Confidence.hedged,
            sourceMemoryID: nil
        )

        #expect(fact.confidence == AuraDefaults.Confidence.hedged)
        #expect(fact.contextLine.contains("uncertain"))
    }

    @Test("A fact needs both a label and a value")
    func rejectsIncompleteFact() async throws {
        let store = try makeStore()
        await #expect(throws: AuraError.self) {
            _ = try await store.upsertFact(
                key: "  ",
                value: "Something",
                category: .other,
                confidence: 1,
                sourceMemoryID: nil
            )
        }
    }

    @Test("Facts can be pinned, archived and deleted")
    func factLifecycle() async throws {
        let store = try makeStore()
        let fact = try await store.upsertFact(
            key: "Coffee",
            value: "Black",
            category: .food,
            confidence: 1,
            sourceMemoryID: nil
        )

        try await store.setFactPinned(true, id: fact.id)
        #expect(try await store.facts(in: [.food]).first?.isPinned == true)

        try await store.setFactArchived(true, id: fact.id)
        #expect(try await store.facts(in: [.food]).isEmpty)

        try await store.setFactArchived(false, id: fact.id)
        try await store.deleteFacts(ids: [fact.id])
        #expect(try await store.facts(in: [.food]).isEmpty)
    }

    @Test("Fact search matches on both the label and the value")
    func searchesFacts() async throws {
        let store = try makeStore()
        _ = try await store.upsertFact(key: "Favourite driver", value: "Christopher Bell", category: .sports, confidence: 1, sourceMemoryID: nil)
        _ = try await store.upsertFact(key: "Preferred seat", value: "Aisle", category: .travel, confidence: 1, sourceMemoryID: nil)

        #expect(try await store.searchFacts(matching: "christopher", limit: 5).count == 1)
        #expect(try await store.searchFacts(matching: "seat", limit: 5).count == 1)
        #expect(try await store.searchFacts(matching: "", limit: 5).isEmpty)
    }

    // MARK: People

    @Test("Creating a person records their relationship")
    func createsPerson() async throws {
        let store = try makeStore()
        let person = try await store.createPerson(name: "Blake", relationship: "son", sourceMemoryID: nil)

        #expect(person.name == "Blake")
        #expect(person.relationship == "son")
        #expect(try await store.people().count == 1)
    }

    @Test("The same person is never created twice")
    func deduplicatesPeople() async throws {
        let store = try makeStore()
        _ = try await store.createPerson(name: "Blake", relationship: "son", sourceMemoryID: nil)
        _ = try await store.createPerson(name: "Blake", relationship: nil, sourceMemoryID: nil)

        #expect(try await store.people().count == 1)
    }

    @Test("A person is matched by name and by nickname, but not by prefix")
    func matchesPeopleByName() async throws {
        let store = try makeStore()
        let blake = try await store.createPerson(name: "Blake Nicol", relationship: "son", sourceMemoryID: nil)

        var mutation = PersonProfileMutation()
        mutation.nickname = .some("Bee")
        _ = try await store.updatePerson(id: blake.id, with: mutation)

        #expect(try await store.person(matchingName: "Blake")?.id == blake.id)
        #expect(try await store.person(matchingName: "blake nicol")?.id == blake.id)
        #expect(try await store.person(matchingName: "Bee")?.id == blake.id)
        // "Blakely" is a different person, not a fuzzy match for Blake.
        #expect(try await store.person(matchingName: "Blakely") == nil)
    }

    @Test("The Blake scenario from the specification works end to end")
    func blakeScenario() async throws {
        let store = try makeStore()

        // "My son Blake is studying aerospace engineering at Tennessee."
        let blake = try await store.createPerson(name: "Blake", relationship: "son", sourceMemoryID: nil)
        var initial = PersonProfileMutation()
        initial.education = .some("Aerospace Engineering at the University of Tennessee")
        _ = try await store.updatePerson(id: blake.id, with: initial)

        let afterFirst = try #require(try await store.person(matchingName: "Blake"))
        #expect(afterFirst.contextLine.contains("son"))
        #expect(afterFirst.contextLine.contains("Aerospace Engineering"))

        // "Actually, Blake switched to mechanical engineering."
        var correction = PersonProfileMutation()
        correction.education = .some("Mechanical Engineering at the University of Tennessee")
        _ = try await store.updatePerson(id: blake.id, with: correction)

        let afterCorrection = try #require(try await store.person(matchingName: "Blake"))
        #expect(afterCorrection.education == "Mechanical Engineering at the University of Tennessee")
        // The superseded major must not survive anywhere a future answer could pick it up.
        #expect(!afterCorrection.contextLine.contains("Aerospace"))
    }

    @Test("Person search matches facts and interests, not just the name")
    func searchesPeople() async throws {
        let store = try makeStore()
        let blake = try await store.createPerson(name: "Blake", relationship: "son", sourceMemoryID: nil)

        var mutation = PersonProfileMutation()
        mutation.interests = ["mountain biking", "rocketry"]
        _ = try await store.updatePerson(id: blake.id, with: mutation)

        #expect(try await store.searchPeople(matching: "rocketry", limit: 5).count == 1)
        #expect(try await store.searchPeople(matching: "knitting", limit: 5).isEmpty)
    }

    @Test("Deleting a person removes them")
    func deletesPeople() async throws {
        let store = try makeStore()
        let person = try await store.createPerson(name: "John", relationship: "colleague", sourceMemoryID: nil)
        try await store.deletePeople(ids: [person.id])
        #expect(try await store.people().isEmpty)
    }

    // MARK: Important dates

    @Test("An annual date projects forward to its next occurrence")
    func upcomingRecurringDate() async throws {
        let store = try makeStore()
        let person = try await store.createPerson(name: "Jennifer", relationship: "wife", sourceMemoryID: nil)

        let calendar = Calendar(identifier: .gregorian)
        let birthday = try #require(calendar.date(from: DateComponents(year: 1985, month: 5, day: 6)))
        _ = try await store.addImportantDate(
            toPersonID: person.id,
            title: "Jennifer's birthday",
            date: birthday,
            isRecurringAnnually: true,
            sourceMemoryID: nil
        )

        let reference = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 1)))
        let upcoming = try await store.upcomingImportantDates(within: 30, from: reference)
        #expect(upcoming.count == 1)
        #expect(upcoming.first?.title == "Jennifer's birthday")

        // A one-off date decades in the past should not appear at all.
        let far = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        #expect(try await store.upcomingImportantDates(within: 7, from: far).isEmpty)
    }

    // MARK: Wholesale deletion

    @Test("Deleting all profile data leaves nothing behind")
    func deletesEverything() async throws {
        let store = try makeStore()

        var mutation = UserProfileMutation()
        mutation.preferredName = .some("Blake")
        mutation.interests = ["NASCAR"]
        _ = try await store.update(mutation)

        let person = try await store.createPerson(name: "Jennifer", relationship: "wife", sourceMemoryID: nil)
        _ = try await store.addImportantDate(
            toPersonID: person.id,
            title: "Anniversary",
            date: .now,
            isRecurringAnnually: true,
            sourceMemoryID: nil
        )
        _ = try await store.upsertFact(key: "Coffee", value: "Black", category: .food, confidence: 1, sourceMemoryID: nil)

        try await store.deleteAllProfileData()

        let profile = try await store.currentProfile()
        #expect(profile.isEssentiallyEmpty)
        #expect(try await store.people().isEmpty)
        #expect(try await store.facts(in: []).isEmpty)
    }
}
