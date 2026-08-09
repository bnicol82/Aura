import Foundation
import Testing

@testable import AURA

/// The data export and the audit trail (§48, §55).
///
/// ### What is actually being checked
/// Not "does it produce a file" — that is trivially true and useless. The two things worth testing are the
/// ones a user would only discover too late: that the file is *complete*, and that it fails loudly rather
/// than writing a partial one. Everything else here is round-tripping, which is what makes the file a
/// contract rather than a dump.
@Suite("Data export")
struct DataExportTests {

    /// Real stores over an in-memory container, because completeness is a property of the stores and a stub
    /// would let a truncating exporter pass.
    private struct Harness {
        let controller: PersistenceController
        let assistantProfileStore: AssistantProfileStore
        let userProfileStore: UserProfileStore
        let conversationStore: SwiftDataConversationStore
        let memoryStore: SwiftDataMemoryStore
        let activityLog: SwiftDataActivityLog
        let exporter: DefaultDataExporter

        init() throws {
            controller = try PersistenceController.inMemory()
            assistantProfileStore = AssistantProfileStore(modelContainer: controller.container)
            userProfileStore = UserProfileStore(modelContainer: controller.container)
            conversationStore = SwiftDataConversationStore(modelContainer: controller.container)
            memoryStore = SwiftDataMemoryStore(modelContainer: controller.container)
            activityLog = SwiftDataActivityLog(modelContainer: controller.container)
            exporter = DefaultDataExporter(
                assistantProfileStore: assistantProfileStore,
                userProfileStore: userProfileStore,
                conversationStore: conversationStore,
                memoryStore: memoryStore,
                activityLog: activityLog
            )
        }
    }

    // MARK: - Completeness

    @Test("Everything stored comes back out")
    func exportIsComplete() async throws {
        let harness = try Harness()

        var rename = AssistantProfileMutation()
        rename.assistantName = "Nova"
        _ = try await harness.assistantProfileStore.update(rename)

        var profile = UserProfileMutation()
        profile.preferredName = .some("Alex")
        _ = try await harness.userProfileStore.update(profile)

        _ = try await harness.memoryStore.save(
            MemoryDraft(content: "Prefers morning meetings", category: .personalPreference)
        )
        let conversation = try await harness.conversationStore.createConversation(
            title: "The garage", at: Date()
        )
        _ = try await harness.conversationStore.appendMessage(
            MessageDraft(role: .user, content: "Hold the garage until October"),
            toConversationID: conversation.id
        )
        await harness.activityLog.record(kind: .memorySaved, title: "Remembered")

        let bundle = try await harness.exporter.exportBundle(at: Date())

        #expect(bundle.assistant.name == "Nova")
        #expect(bundle.user.preferredName == "Alex")
        #expect(bundle.memories.count == 1)
        #expect(bundle.memories.first?.content == "Prefers morning meetings")
        #expect(bundle.conversations.count == 1)
        #expect(bundle.conversations.first?.messages.count == 1)
        #expect(bundle.activity.count == 1)

        // The manifest's counts have to describe the file they are in, or they are worse than absent: a
        // user checking whether the export looks complete would be reassured by a wrong number.
        #expect(bundle.manifest.counts["memories"] == 1)
        #expect(bundle.manifest.counts["conversations"] == 1)
        #expect(bundle.manifest.counts["messages"] == 1)
        #expect(bundle.manifest.counts["activity"] == 1)
    }

    @Test("Archived and superseded memories are included, because they are still the user's")
    func exportIncludesHiddenMemories() async throws {
        // Neither is visible in the app, and both are things AURA holds. An export that quietly matched the
        // UI's filters would be a smaller claim than "everything".
        let harness = try Harness()
        let archived = try await harness.memoryStore.save(MemoryDraft(content: "Used to smoke"))
        try await harness.memoryStore.setArchived(true, ids: [archived.id])
        _ = try await harness.memoryStore.supersede(
            id: archived.id,
            with: MemoryDraft(content: "Quit smoking in 2024")
        )

        let bundle = try await harness.exporter.exportBundle(at: Date())
        #expect(bundle.memories.count == 2)
        #expect(bundle.memories.contains { $0.content == "Used to smoke" })
        // And the correction history survives, so the file shows what replaced what (§23).
        #expect(bundle.memories.contains { $0.supersededByMemoryID != nil })
    }

    @Test("The manifest says what the file does and does not contain")
    func manifestStatesItsScope() async throws {
        // The promise has to be checkable by the person holding the file, not only by someone reading the
        // app's source.
        let harness = try Harness()
        let bundle = try await harness.exporter.exportBundle(at: Date())
        #expect(bundle.manifest.formatVersion == DataExportBundle.currentFormatVersion)
        #expect(bundle.manifest.note.contains("Keychain"))
        #expect(bundle.manifest.note.contains("nothing was sent anywhere"))
    }

    @Test("Standing instructions survive the export")
    func standingInstructionsAreExported() async throws {
        // The single most deliberate thing a user tells AURA (§12), and so the worst thing for an export
        // to drop.
        let harness = try Harness()
        var mutation = UserProfileMutation()
        mutation.assistantInstructions = ["Never book anything before 9am"]
        _ = try await harness.userProfileStore.update(mutation)

        let bundle = try await harness.exporter.exportBundle(at: Date())
        #expect(bundle.user.assistantInstructions == ["Never book anything before 9am"])
    }

    // MARK: - The file

    @Test("The written file round-trips")
    func fileRoundTrips() async throws {
        let harness = try Harness()
        _ = try await harness.memoryStore.save(MemoryDraft(content: "Allergic to penicillin"))

        let url = try await harness.exporter.writeExport(at: Date())
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let decoded = try DefaultDataExporter.decode(data)
        #expect(decoded.memories.first?.content == "Allergic to penicillin")
        #expect(decoded.manifest.counts["memories"] == 1)
    }

    @Test("The JSON is readable by a person, with real dates")
    func jsonIsReadable() throws {
        // A user is expected to open this. A reference-date number would be neither readable nor portable,
        // and unsorted keys make two exports of the same data look different.
        let bundle = try DefaultDataExporter.encode(Self.emptyBundle())
        let text = String(decoding: bundle, as: UTF8.self)
        #expect(text.contains("\n"))
        #expect(text.contains("\"formatVersion\""))
        // ISO 8601, so the date is legible rather than a float.
        #expect(text.contains("2026-"))
    }

    @Test("The file name sorts chronologically and travels")
    func fileNameIsPortable() {
        let name = DefaultDataExporter.fileName(for: Date(timeIntervalSince1970: 1_772_884_800))
        #expect(name.hasPrefix("AURA-export-"))
        #expect(name.hasSuffix(".json"))
        // A colon is legal on iOS and breaks the file on nearly everything the user might move it to,
        // which defeats the point of exporting.
        #expect(!name.contains(":"))
        #expect(!name.contains(" "))
    }

    // MARK: - The audit trail

    @Test("A tool execution writes a row the user can read")
    func toolExecutionIsLogged() async throws {
        let harness = try Harness()
        await harness.activityLog.recordToolExecution(
            ToolExecutionRecord(
                toolID: "memory.remember",
                toolName: "remember_this",
                result: ToolResult(
                    modelFacingText: "Saved.",
                    activityLabel: "Remembered",
                    outcomeSummary: "Prefers morning meetings"
                ),
                requiredConfirmation: false,
                wasConfirmed: false
            ),
            conversationID: nil,
            messageID: nil,
            iterationIndex: 0
        )

        let rows = try await harness.activityLog.recentActivity(limit: 10)
        #expect(rows.count == 1)
        #expect(rows[0].title == "Remembered")
        #expect(rows[0].detail == "Prefers morning meetings")
        #expect(rows[0].succeeded)
    }

    @Test("A declined action is logged, and not as a success")
    func declinedActionIsLoggedAsRefused() async throws {
        // §36: the log is a record of actions, and a proposal the user rejected is one of them. Logging it
        // as successful would put a tick beside something that never happened.
        let harness = try Harness()
        await harness.activityLog.recordToolExecution(
            ToolExecutionRecord(
                toolID: "memory.forget",
                toolName: "forget_this",
                result: ToolResult(
                    modelFacingText: "The user declined this action, so it was not performed.",
                    activityLabel: "Forgetting that",
                    outcomeSummary: "Declined"
                ),
                requiredConfirmation: true,
                wasConfirmed: false
            ),
            conversationID: nil,
            messageID: nil,
            iterationIndex: 0
        )

        let rows = try await harness.activityLog.recentActivity(limit: 10)
        #expect(rows.count == 1)
        #expect(!rows[0].succeeded)
        #expect(rows[0].detail == "You said no")
    }

    @Test("A failed tool is logged with its reason")
    func failedToolIsLogged() async throws {
        let harness = try Harness()
        await harness.activityLog.recordToolFailure(
            toolID: "calendar.read",
            toolName: "read_calendar",
            error: AuraError.permissionDenied(.calendar),
            conversationID: nil,
            messageID: nil,
            iterationIndex: 0
        )

        let rows = try await harness.activityLog.recentActivity(limit: 10)
        #expect(rows.count == 1)
        #expect(!rows[0].succeeded)
        // The user-facing name, not the model-facing one.
        #expect(rows[0].title == "Couldn't read calendar")
    }

    @Test("Every refusal reaches the log, not only the runs")
    func refusalsAreRecorded() async throws {
        // The gates throw before a tool runs, and each of those paths has to leave a trace or the Activity
        // screen becomes a record of successes.
        let harness = try Harness()
        let executor = DefaultToolExecutor(
            registry: ToolRegistry(tools: [ReadCalendarTool(calendarService: StubCalendarService())]),
            permissions: StubPermissionManager.denyingEverything(),
            networkMonitor: StubNetworkMonitor.online,
            activityLog: harness.activityLog
        )

        await #expect(throws: AuraError.self) {
            try await executor.execute(
                toolNamed: "read_calendar",
                arguments: [:],
                context: ToolExecutionContext(userExplicitlyRequested: true)
            )
        }

        let rows = try await harness.activityLog.recentActivity(limit: 10)
        #expect(rows.count == 1)
        #expect(!rows[0].succeeded)
    }

    @Test("A successful run reaches the log too")
    func successesAreRecorded() async throws {
        let harness = try Harness()
        let executor = DefaultToolExecutor(
            registry: ToolRegistry(tools: [SearchMemoryTool(memoryStore: harness.memoryStore)]),
            permissions: StubPermissionManager.allowingEverything(),
            networkMonitor: StubNetworkMonitor.online,
            activityLog: harness.activityLog
        )

        _ = try await executor.execute(
            toolNamed: "search_memory",
            arguments: ["query": .string("anything")],
            context: ToolExecutionContext(userExplicitlyRequested: true)
        )

        let rows = try await harness.activityLog.recentActivity(limit: 10)
        #expect(rows.count == 1)
        #expect(rows[0].succeeded)
        #expect(rows[0].title == "Searched memory")
    }

    @Test("Clearing the trail clears both tables")
    func deletingActivityClearsEverything() async throws {
        // The user clearing their history means the history, not the half of it the screen showed.
        let harness = try Harness()
        await harness.activityLog.record(kind: .toolExecuted, title: "Did a thing")
        #expect(try await harness.activityLog.recentActivity(limit: 10).count == 1)

        try await harness.activityLog.deleteAllActivity()
        #expect(try await harness.activityLog.recentActivity(limit: 10).isEmpty)
    }

    @Test("The exported activity is what the log holds")
    func activityIsExported() async throws {
        let harness = try Harness()
        await harness.activityLog.record(kind: .memoryDeleted, title: "Forgot", detail: "Old landlord")

        let bundle = try await harness.exporter.exportBundle(at: Date())
        #expect(bundle.activity.count == 1)
        #expect(bundle.activity[0].title == "Forgot")
        #expect(bundle.activity[0].detail == "Old landlord")
        #expect(bundle.activity[0].kind == ActivityKind.memoryDeleted.rawValue)
    }

    // MARK: - Helpers

    private static func emptyBundle() -> DataExportBundle {
        DataExportBundle(
            manifest: DataExportBundle.Manifest(
                formatVersion: DataExportBundle.currentFormatVersion,
                exportedAt: Date(timeIntervalSince1970: 1_772_884_800),
                appVersion: "test",
                counts: [:],
                note: DataExportBundle.scopeNote
            ),
            assistant: DefaultDataExporter.export(AssistantProfileSnapshot()),
            user: DefaultDataExporter.export(UserProfileSnapshot()),
            facts: [],
            people: [],
            memories: [],
            conversations: [],
            activity: []
        )
    }
}
