import Foundation

/// Assembles the context for a request (§27, §28, §29).
///
/// The contract is *selectivity*. This never loads the whole profile or the whole memory store — it
/// looks up what the current message appears to be about and stops. "Send everything and let the model
/// sort it out" is worse on privacy, latency, cost and accuracy simultaneously.
///
/// ### What it draws on in Phase 2
/// The full retrieval engine is Phase 7, and `memoryRetrieval` is `nil` until then. That does not leave
/// this engine with nothing to do: `UserProfileStore` already has real keyword search over facts and
/// people, so a question about Blake genuinely pulls Blake's record and nothing else. The selectivity
/// promise is honoured from the first conversation, not deferred until the memory system lands.
///
/// ### Priority order (§29)
/// Standing instructions are always included, whatever the query looks like, because they are the
/// user's own explicit directions and outrank anything inferred. Everything else has to earn its place
/// by matching the request.
struct DefaultPersonalizationEngine: PersonalizationEngineProtocol {

    private let assistantProfileStore: any AssistantProfileStoring
    private let userProfileStore: any UserProfileStoring
    private let personalityEngine: PersonalityEngine
    private let sensitivityClassifier: SensitivityClassifier
    /// Wired in Phase 7. Until then, profile search carries retrieval.
    private let memoryRetrieval: (any MemoryRetrieving)?

    init(
        assistantProfileStore: any AssistantProfileStoring,
        userProfileStore: any UserProfileStoring,
        personalityEngine: PersonalityEngine = PersonalityEngine(),
        sensitivityClassifier: SensitivityClassifier = SensitivityClassifier(),
        memoryRetrieval: (any MemoryRetrieving)? = nil
    ) {
        self.assistantProfileStore = assistantProfileStore
        self.userProfileStore = userProfileStore
        self.personalityEngine = personalityEngine
        self.sensitivityClassifier = sensitivityClassifier
        self.memoryRetrieval = memoryRetrieval
    }

    func buildContext(for request: PersonalizationRequest) async throws -> PersonalizationContext {
        let assistantProfile = try await assistantProfileStore.currentProfile()
        let userProfile = try await userProfileStore.currentProfile()

        // "Use memories in responses = off" and an empty budget resolve to the same thing: personality
        // and standing instructions only, nothing retrieved (§48).
        let memoryAllowed = assistantProfile.memory.usesMemoryInResponses && !request.budget.isEmpty

        let retrieved = memoryAllowed
            ? try await retrieve(for: request, userProfile: userProfile)
            : RetrievalResult.empty

        // Sensitivity reads both the words and what those words pulled back: "what did they say again?"
        // is innocuous until you notice the memory it retrieved is a health record (§12).
        let retrievedCategories = Set(
            retrieved.memories.map(\.memory.category) + retrieved.profileFacts.map(\.category)
        )
        let sensitivity = sensitivityClassifier.classify(
            text: request.userMessage,
            retrievedCategories: retrievedCategories
        )

        let standingInstructions = userProfile.assistantInstructions

        let personalityInstructions = personalityEngine.instructions(
            for: assistantProfile,
            sensitivity: sensitivity,
            userPreferredName: userProfile.preferredName,
            standingInstructions: standingInstructions
        )

        return PersonalizationContext(
            identity: AssistantIdentity(
                name: assistantProfile.assistantName,
                userPreferredName: userProfile.preferredName
            ),
            personalityInstructions: personalityInstructions,
            standingInstructions: standingInstructions,
            relevantFacts: retrieved.profileFacts,
            relevantPeople: retrieved.people,
            relevantProjects: retrieved.projects,
            relevantMemories: retrieved.memories,
            outstandingTasks: retrieved.tasks,
            sensitivityMode: sensitivity,
            memoryWasSuppressedByPreference: !assistantProfile.memory.usesMemoryInResponses,
            assembledAt: request.now
        )
    }

    // MARK: - Retrieval

    private func retrieve(
        for request: PersonalizationRequest,
        userProfile: UserProfileSnapshot
    ) async throws -> RetrievalResult {
        let entities = request.userMessage.likelyProperNouns()

        // Phase 7 onward: the ranking engine answers everything in one pass.
        if let memoryRetrieval {
            return try await memoryRetrieval.retrieve(
                for: RetrievalRequest(
                    text: request.userMessage,
                    entities: entities,
                    conversationID: request.conversationID,
                    recentTurns: request.recentTurns,
                    now: request.now,
                    budget: request.budget
                )
            )
        }

        // Phase 2: profile keyword search, which is genuine selective retrieval over what exists today.
        let facts = try await userProfileStore.searchFacts(
            matching: request.userMessage,
            limit: request.budget.profileFacts
        )

        let people = try await matchPeople(
            in: request.userMessage,
            entities: entities,
            userProfile: userProfile,
            limit: request.budget.people
        )

        return RetrievalResult(
            memories: [],
            people: people,
            projects: [],
            profileFacts: facts,
            tasks: [],
            conversations: []
        )
    }

    /// Resolves the people a message is about.
    ///
    /// Entity-first, then free-text. Matching entities first matters for accuracy: "What is Blake
    /// studying?" should pull Blake's record because the message names him, not because a keyword
    /// happened to overlap with several people's notes.
    private func matchPeople(
        in text: String,
        entities: [String],
        userProfile: UserProfileSnapshot,
        limit: Int
    ) async throws -> [PersonProfileSnapshot] {
        guard limit > 0 else { return [] }

        var matched: [PersonProfileSnapshot] = []
        var seen = Set<UUID>()

        // Every alias of every known person, checked against the message. This catches first names,
        // which `likelyProperNouns` misses when they open a sentence.
        let lowercasedText = " \(text.lowercased().normalizedWhitespace) "
        for person in userProfile.people {
            let isNamed = person.aliases.contains { alias in
                let needle = alias.lowercased()
                guard !needle.isEmpty else { return false }
                // Padded so "Al" does not match "already".
                return lowercasedText.contains(" \(needle) ")
                    || lowercasedText.contains(" \(needle)'")
                    || lowercasedText.contains(" \(needle),")
                    || lowercasedText.contains(" \(needle).")
                    || lowercasedText.contains(" \(needle)?")
            }
            guard isNamed, seen.insert(person.id).inserted else { continue }
            matched.append(person)
            if matched.count >= limit { return matched }
        }

        for entity in entities {
            guard matched.count < limit else { break }
            if let person = try await userProfileStore.person(matchingName: entity),
               seen.insert(person.id).inserted {
                matched.append(person)
            }
        }

        if matched.isEmpty {
            let searched = try await userProfileStore.searchPeople(matching: text, limit: limit)
            for person in searched where seen.insert(person.id).inserted {
                matched.append(person)
            }
        }

        return Array(matched.prefix(limit))
    }
}
