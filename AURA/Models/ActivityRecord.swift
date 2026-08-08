import Foundation
import SwiftData

/// One line on the Activity screen (§45).
///
/// The contract for this table is narrow and worth stating plainly: it records **what AURA did**,
/// in language the user can check — "Created reminder “Order air filter”", "Searched memory for
/// “University of Tennessee tuition”". It never records why the model chose to do it. There is no
/// field on this type for reasoning, and that is deliberate.
@Model
final class ActivityRecord {
    var id: UUID = UUID()

    var kindRaw: String = ActivityKind.toolExecuted.rawValue

    /// The action, in the past tense: "Created reminder".
    var title: String = ""
    /// The specifics: "Order air filter". Optional because some actions have no object.
    var detail: String?

    var createdAt: Date = Date()

    /// Links back to whatever this was about, so a row can be tapped through to its subject.
    var conversationID: UUID?
    var memoryID: UUID?
    var personID: UUID?
    var projectID: UUID?
    var taskID: UUID?
    var toolExecutionID: UUID?

    /// Records a failed attempt, so the audit trail shows what AURA tried and could not do.
    var succeeded: Bool = true

    init(
        kind: ActivityKind = .toolExecuted,
        title: String = "",
        detail: String? = nil,
        succeeded: Bool = true,
        createdAt: Date = Date()
    ) {
        self.kindRaw = kind.rawValue
        self.title = title
        self.detail = detail
        self.succeeded = succeeded
        self.createdAt = createdAt
    }

    var kind: ActivityKind {
        get { ActivityKind(rawValue: kindRaw) ?? .toolExecuted }
        set { kindRaw = newValue.rawValue }
    }

    var snapshot: ActivityRecordSnapshot {
        ActivityRecordSnapshot(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            succeeded: succeeded,
            createdAt: createdAt,
            conversationID: conversationID,
            memoryID: memoryID,
            personID: personID,
            projectID: projectID,
            taskID: taskID,
            toolExecutionID: toolExecutionID
        )
    }
}

struct ActivityRecordSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: UUID
    var kind: ActivityKind
    var title: String
    var detail: String?
    var succeeded: Bool
    var createdAt: Date
    var conversationID: UUID?
    var memoryID: UUID?
    var personID: UUID?
    var projectID: UUID?
    var taskID: UUID?
    var toolExecutionID: UUID?

    init(
        id: UUID = UUID(),
        kind: ActivityKind = .toolExecuted,
        title: String = "",
        detail: String? = nil,
        succeeded: Bool = true,
        createdAt: Date = Date(),
        conversationID: UUID? = nil,
        memoryID: UUID? = nil,
        personID: UUID? = nil,
        projectID: UUID? = nil,
        taskID: UUID? = nil,
        toolExecutionID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.succeeded = succeeded
        self.createdAt = createdAt
        self.conversationID = conversationID
        self.memoryID = memoryID
        self.personID = personID
        self.projectID = projectID
        self.taskID = taskID
        self.toolExecutionID = toolExecutionID
    }
}
