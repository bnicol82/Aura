import Foundation

/// Gathers everything AURA holds and writes it to a file (§48, §55).
///
/// ### Completeness is the whole feature
/// An export the user keeps and then relies on has to be right. So the one rule this type follows is that
/// it either produces everything or it throws: no partial bundle, no "best effort", no store quietly
/// skipped because a read failed. A file that looks complete and is not would be discovered only after the
/// user had deleted the app.
///
/// That is why memories are counted before they are fetched and the two are compared. `MemoryStoring` has
/// no "give me everything" call — deliberately, because §28's privacy argument rests on retrieval being
/// bounded — so an export has to ask for a very large page, and a page is exactly the thing that can
/// silently truncate.
///
/// ### Nothing leaves the device to produce this
/// No model is consulted and no network call is made. The export is a transcription of local storage, which
/// is what makes it safe to promise in the manifest.
actor DefaultDataExporter: DataExporting {

    private let assistantProfileStore: any AssistantProfileStoring
    private let userProfileStore: any UserProfileStoring
    private let conversationStore: any ConversationStoring
    private let memoryStore: any MemoryStoring
    private let activityLog: (any ActivityLogging)?

    /// A page size chosen to be larger than any plausible library, and then checked against a count rather
    /// than trusted. Not `Int.max`: SwiftData's `fetchLimit` is applied by SQLite, and an absurd value is a
    /// worse bet than a large one plus a verification.
    static let pageSize = 100_000

    init(
        assistantProfileStore: any AssistantProfileStoring,
        userProfileStore: any UserProfileStoring,
        conversationStore: any ConversationStoring,
        memoryStore: any MemoryStoring,
        activityLog: (any ActivityLogging)? = nil
    ) {
        self.assistantProfileStore = assistantProfileStore
        self.userProfileStore = userProfileStore
        self.conversationStore = conversationStore
        self.memoryStore = memoryStore
        self.activityLog = activityLog
    }

    // MARK: - Gathering

    func exportBundle(at date: Date = Date()) async throws -> DataExportBundle {
        let assistant = try await assistantProfileStore.currentProfile()
        let user = try await userProfileStore.currentProfile()
        let facts = try await userProfileStore.facts(in: [])
        let people = try await userProfileStore.people()
        let memories = try await allMemories()
        let conversations = try await allConversations()
        let activity = try await activityLog?.recentActivity(limit: Self.pageSize) ?? []

        let bundle = DataExportBundle(
            manifest: DataExportBundle.Manifest(
                formatVersion: DataExportBundle.currentFormatVersion,
                exportedAt: date,
                appVersion: Self.appVersion(),
                counts: [
                    "facts": facts.count,
                    "people": people.count,
                    "memories": memories.count,
                    "conversations": conversations.count,
                    "messages": conversations.reduce(0) { $0 + $1.messages.count },
                    "activity": activity.count
                ],
                note: DataExportBundle.scopeNote
            ),
            assistant: Self.export(assistant),
            user: Self.export(user),
            facts: facts.map(Self.export(_:)),
            people: people.map(Self.export(_:)),
            memories: memories.map(Self.export(_:)),
            conversations: conversations,
            activity: activity.map(Self.export(_:))
        )
        return bundle
    }

    /// Every memory, verified against the store's own count.
    ///
    /// The count is taken *after* the fetch. Taken before, a memory written in between would make the
    /// numbers disagree and fail an export that was actually fine; taken after, a truncated page is caught
    /// and a concurrent write can only make the fetch look short, which is the direction that should fail.
    private func allMemories() async throws -> [MemorySnapshot] {
        let query = MemoryQuery(
            // Archived and superseded included: the user asked for everything AURA holds, and a correction
            // history they cannot see in the app is still theirs (§23).
            includeSuperseded: true,
            includeArchived: true,
            sortOrder: .oldestFirst,
            limit: Self.pageSize
        )
        let fetched = try await memoryStore.search(query)
        let total = try await memoryStore.count(matching: query)

        guard fetched.count >= total else {
            throw AuraError.toolFailed(
                toolName: "export",
                reason: """
                    the export would have been incomplete — \(fetched.count) of \(total) memories were \
                    read, so no file was written
                    """
            )
        }
        return fetched
    }

    private func allConversations() async throws -> [ConversationExport] {
        let conversations = try await conversationStore.recentConversations(
            limit: Self.pageSize,
            includeArchived: true
        )

        var exported: [ConversationExport] = []
        exported.reserveCapacity(conversations.count)

        for conversation in conversations {
            let messages = try await conversationStore.messages(inConversationID: conversation.id)
            // Checked per conversation, because a message count that disagrees means this thread was
            // exported short — and a transcript missing its middle is worse than an obvious failure.
            guard messages.count >= conversation.messageCount else {
                throw AuraError.toolFailed(
                    toolName: "export",
                    reason: """
                        the export would have been incomplete — conversation “\(conversation.title)” has \
                        \(conversation.messageCount) messages but only \(messages.count) were read
                        """
                )
            }
            exported.append(
                ConversationExport(
                    id: conversation.id,
                    title: conversation.title,
                    summary: conversation.summary,
                    isArchived: conversation.isArchived,
                    createdAt: conversation.createdAt,
                    updatedAt: conversation.updatedAt,
                    messages: messages.map(Self.export(_:))
                )
            )
        }
        return exported
    }

    // MARK: - Writing

    func writeExport(at date: Date = Date()) async throws -> URL {
        let bundle = try await exportBundle(at: date)
        let data = try Self.encode(bundle)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.fileName(for: date))

        do {
            // `.atomic` so a share sheet can never pick up a half-written file, and `.completeFileProtection`
            // so the export is encrypted at rest while the device is locked — it is the single most sensitive
            // file this app will ever produce (§51).
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw AuraError.saveFailed(reason: error.localizedDescription)
        }
        return url
    }

    /// Removes a previously written export.
    ///
    /// Worth having rather than leaving it to the system to clean the temporary directory whenever it feels
    /// like it: this file is a complete copy of everything AURA knows, and it should not sit around after
    /// the user has finished sharing it.
    func discardExport(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Encoding

    /// `static` and pure so the exact bytes are testable, and so the format cannot drift depending on which
    /// call site did the encoding.
    static func encode(_ bundle: DataExportBundle) throws -> Data {
        let encoder = JSONEncoder()
        // Sorted keys and pretty printing because a person is expected to open this. ISO 8601 dates because
        // a reference-date number is not readable and not portable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(bundle)
        } catch {
            throw AuraError.saveFailed(reason: "the export could not be encoded: \(error.localizedDescription)")
        }
    }

    static func decode(_ data: Data) throws -> DataExportBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DataExportBundle.self, from: data)
    }

    /// A file name that sorts chronologically and says what it is.
    ///
    /// Dashes rather than colons: a colon is legal on iOS and breaks the file on nearly everything the user
    /// might move it to, which is the whole point of exporting.
    static func fileName(for date: Date) -> String {
        let stamp = date.formatted(
            Date.ISO8601FormatStyle(dateSeparator: .dash, timeSeparator: .omitted, timeZone: .current)
                .year().month().day().time(includingFractionalSeconds: false)
        )
        return "AURA-export-\(stamp).json"
    }

    static func appVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    // MARK: - Mapping
    //
    // Written out rather than derived, so adding an internal field never silently changes the user's file,
    // and so the export can name things in the user's terms instead of the schema's.

    static func export(_ profile: AssistantProfileSnapshot) -> AssistantExport {
        AssistantExport(
            name: profile.assistantName,
            personalityPreset: profile.personalityPreset.rawValue,
            customPersonalityPrompt: profile.customPersonalityPrompt,
            responseLength: profile.style.responseLength.rawValue,
            formality: profile.style.formality.rawValue,
            humor: profile.style.humor.rawValue,
            proactivity: profile.style.proactivity.rawValue,
            greetingStyle: profile.greetingStyle.rawValue,
            allowsPersonalityAdaptation: profile.allowsPersonalityAdaptation,
            aiMode: profile.aiMode.rawValue,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt
        )
    }

    static func export(_ profile: UserProfileSnapshot) -> UserExport {
        UserExport(
            preferredName: profile.preferredName,
            pronouns: profile.pronouns,
            workContext: profile.workContext,
            educationContext: profile.educationContext,
            locationContext: profile.locationContext,
            communicationPreferences: profile.communicationPreferences,
            interests: profile.interests,
            hobbies: profile.hobbies,
            longTermGoals: profile.longTermGoals,
            routines: profile.routines,
            importantPlaces: profile.importantPlaces,
            assistantInstructions: profile.assistantInstructions,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt
        )
    }

    static func export(_ fact: ProfileFactSnapshot) -> FactExport {
        FactExport(
            id: fact.id,
            category: fact.category.rawValue,
            key: fact.key,
            value: fact.value,
            confidence: fact.confidence,
            isPinned: fact.isPinned,
            isArchived: fact.isArchived,
            sourceMemoryID: fact.sourceMemoryID,
            supersededByFactID: fact.supersededByFactID,
            createdAt: fact.createdAt,
            updatedAt: fact.updatedAt
        )
    }

    static func export(_ person: PersonProfileSnapshot) -> PersonExport {
        PersonExport(
            id: person.id,
            name: person.name,
            nickname: person.nickname,
            relationship: person.relationship,
            education: person.education,
            work: person.work,
            notes: person.notes,
            importantFacts: person.importantFacts,
            preferences: person.preferences,
            interests: person.interests,
            importantDates: person.importantDates.map(Self.export(_:)),
            isPinned: person.isPinned,
            isArchived: person.isArchived
        )
    }

    static func export(_ date: ImportantDateSnapshot) -> ImportantDateExport {
        ImportantDateExport(
            id: date.id,
            label: date.title,
            date: date.date,
            recursAnnually: date.isRecurringAnnually
        )
    }

    static func export(_ memory: MemorySnapshot) -> MemoryExport {
        MemoryExport(
            id: memory.id,
            content: memory.content,
            summary: memory.summary,
            type: memory.memoryType.rawValue,
            category: memory.category.rawValue,
            importance: memory.importance,
            confidence: memory.confidence,
            wasExplicitlyRequested: memory.wasExplicitlyRequested,
            isPinned: memory.isPinned,
            isArchived: memory.isArchived,
            tags: memory.tags,
            entities: memory.entities,
            createdAt: memory.createdAt,
            updatedAt: memory.updatedAt,
            lastAccessedAt: memory.lastAccessedAt,
            accessCount: memory.accessCount,
            supersededByMemoryID: memory.supersededByMemoryID
        )
    }

    static func export(_ message: MessageSnapshot) -> MessageExport {
        MessageExport(
            id: message.id,
            role: message.role.rawValue,
            content: message.content,
            sequence: message.sequence,
            createdAt: message.createdAt,
            isFailure: message.isFailure,
            providerIdentifier: message.providerIdentifier,
            toolActivity: message.toolActivity.map {
                ToolActivityExport(
                    toolName: $0.toolName,
                    label: $0.label,
                    succeeded: $0.succeeded,
                    outcome: $0.outcome
                )
            }
        )
    }

    static func export(_ record: ActivityRecordSnapshot) -> ActivityExport {
        ActivityExport(
            id: record.id,
            kind: record.kind.rawValue,
            title: record.title,
            detail: record.detail,
            succeeded: record.succeeded,
            createdAt: record.createdAt
        )
    }
}
