import Foundation

/// Records what AURA did, for the Activity screen (§45).
///
/// This is an *audit* log, not a debug log — a different thing from `OSLog`. `OSLog` is for
/// engineers and must never carry personal content; this is for the user and is expected to, because
/// "Created reminder “Order air filter”" is only useful if it names the reminder.
///
/// What it must never carry is reasoning. There is no parameter here for why the model chose an
/// action, and the schema behind it has no field for one.
protocol ActivityLogging: Sendable {
    /// Records a completed action.
    func record(
        kind: ActivityKind,
        title: String,
        detail: String?,
        succeeded: Bool,
        references: ActivityReferences
    ) async

    /// Records a tool execution — both the `ToolExecution` audit row and its Activity line.
    func recordToolExecution(
        _ record: ToolExecutionRecord,
        conversationID: UUID?,
        messageID: UUID?,
        iterationIndex: Int
    ) async

    /// Records a tool that failed or was declined. Failures are logged as loudly as successes: a
    /// silent failure is how an assistant ends up appearing to have done something it did not (§78).
    func recordToolFailure(
        toolID: String,
        toolName: String,
        error: any Error,
        conversationID: UUID?,
        messageID: UUID?,
        iterationIndex: Int
    ) async

    func recentActivity(limit: Int) async throws -> [ActivityRecordSnapshot]
    func activity(since date: Date) async throws -> [ActivityRecordSnapshot]

    /// Clears the audit trail. The user's data, the user's call.
    func deleteAllActivity() async throws
}

/// Optional links from an activity row back to its subject.
struct ActivityReferences: Sendable, Equatable, Hashable {
    var conversationID: UUID?
    var memoryID: UUID?
    var personID: UUID?
    var projectID: UUID?
    var taskID: UUID?
    var toolExecutionID: UUID?

    init(
        conversationID: UUID? = nil,
        memoryID: UUID? = nil,
        personID: UUID? = nil,
        projectID: UUID? = nil,
        taskID: UUID? = nil,
        toolExecutionID: UUID? = nil
    ) {
        self.conversationID = conversationID
        self.memoryID = memoryID
        self.personID = personID
        self.projectID = projectID
        self.taskID = taskID
        self.toolExecutionID = toolExecutionID
    }

    static let none = ActivityReferences()
}

extension ActivityLogging {
    /// Convenience for the common case with no links.
    func record(kind: ActivityKind, title: String, detail: String? = nil) async {
        await record(
            kind: kind,
            title: title,
            detail: detail,
            succeeded: true,
            references: .none
        )
    }
}
