import Foundation
import SwiftData

/// The audit trail, persisted (§36, §45).
///
/// ### Why writing never throws
/// Every `record` method swallows its own failures. That is not carelessness: the alternative is a tool
/// that succeeded and then reported a failure because *logging* it failed, which would make AURA lie about
/// an action it really took. The log is a record of what happened, so a log write that fails must not
/// change what happened. Failures go to `OSLog`, where an engineer can see them and a user is not misled.
///
/// ### Two rows per tool call, on purpose
/// A `ToolExecution` is the machine-readable audit row — arguments, duration, whether it was confirmed. An
/// `ActivityRecord` is the line the user reads. They are separate because they have different audiences and
/// different lifetimes: §48 lets the user clear the Activity screen, and the execution rows are what a
/// future "what exactly did it send" view would need.
///
/// ### What is deliberately absent
/// There is no parameter anywhere here for *why* the model chose an action, and the schema behind it has no
/// field for one. An audit trail of reasoning would be a record of guesses presented with the authority of
/// a record of facts.
@ModelActor
actor SwiftDataActivityLog: ActivityLogging {

    // MARK: - Writing

    func record(
        kind: ActivityKind,
        title: String,
        detail: String?,
        succeeded: Bool,
        references: ActivityReferences
    ) async {
        let row = ActivityRecord(kind: kind, title: title, detail: detail, succeeded: succeeded)
        row.conversationID = references.conversationID
        row.memoryID = references.memoryID
        row.personID = references.personID
        row.projectID = references.projectID
        row.taskID = references.taskID
        row.toolExecutionID = references.toolExecutionID

        modelContext.insert(row)
        persist("activity row")
    }

    func recordToolExecution(
        _ record: ToolExecutionRecord,
        conversationID: UUID?,
        messageID: UUID?,
        iterationIndex: Int
    ) async {
        let execution = ToolExecution(
            toolID: record.toolID,
            toolName: record.toolName,
            startedAt: Date().addingTimeInterval(-record.duration)
        )
        execution.id = record.executionID
        execution.argumentsJSON = nil
        execution.resultSummary = record.result.outcomeSummary
        // A declined proposal is not a success. This is the same rule as `ToolExecutionRecord.activityNote`,
        // and it has to hold here too or the audit trail and the transcript would disagree about the same
        // event.
        execution.succeeded = !record.wasDeclined
        execution.requiredConfirmation = record.requiredConfirmation
        execution.wasConfirmed = record.wasConfirmed
        execution.conversationID = conversationID
        execution.messageID = messageID
        execution.duration = record.duration
        execution.iterationIndex = iterationIndex

        modelContext.insert(execution)

        let row = ActivityRecord(
            kind: .toolExecuted,
            title: record.result.activityLabel,
            detail: record.wasDeclined ? "You said no" : record.result.outcomeSummary,
            succeeded: !record.wasDeclined
        )
        row.conversationID = conversationID
        row.toolExecutionID = execution.id
        modelContext.insert(row)

        persist("tool execution")
    }

    func recordToolFailure(
        toolID: String,
        toolName: String,
        error: any Error,
        conversationID: UUID?,
        messageID: UUID?,
        iterationIndex: Int
    ) async {
        let execution = ToolExecution(toolID: toolID, toolName: toolName)
        execution.succeeded = false
        execution.errorDescription = error.localizedDescription
        execution.conversationID = conversationID
        execution.messageID = messageID
        execution.iterationIndex = iterationIndex
        modelContext.insert(execution)

        let row = ActivityRecord(
            kind: .toolExecuted,
            // The user-facing name, not the model-facing one: "search memory", not "search_memory".
            title: "Couldn't \(ToolActivityNote.humanisedName(toolName))",
            detail: error.localizedDescription,
            succeeded: false
        )
        row.conversationID = conversationID
        row.toolExecutionID = execution.id
        modelContext.insert(row)

        persist("tool failure")
    }

    // MARK: - Reading

    func recentActivity(limit: Int) async throws -> [ActivityRecordSnapshot] {
        var descriptor = FetchDescriptor<ActivityRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    func activity(since date: Date) async throws -> [ActivityRecordSnapshot] {
        let descriptor = FetchDescriptor<ActivityRecord>(
            predicate: #Predicate { $0.createdAt >= date },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    // MARK: - Deleting

    func deleteAllActivity() async throws {
        // Both tables, because the user clearing their history means the history, not the half of it they
        // could see. Unlike the writes above this one *does* throw: a delete that silently failed would
        // leave data the user believes is gone.
        try modelContext.delete(model: ActivityRecord.self)
        try modelContext.delete(model: ToolExecution.self)
        try modelContext.save()
    }

    // MARK: - Saving

    /// Saves, reporting a failure to `OSLog` rather than to the caller.
    ///
    /// See the type's note: a tool that ran must not be reported as having failed because its log entry
    /// could not be written.
    private func persist(_ what: String) {
        do {
            try modelContext.save()
        } catch {
            AuraLog.activity.error(
                "Could not save \(what, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
