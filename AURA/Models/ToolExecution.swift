import Foundation
import SwiftData

/// A record of a tool AURA actually ran (§33, §36).
///
/// This table is the reason AURA can honour §78: nothing may claim an action succeeded unless a row
/// here says it did. `succeeded` is written from the executor's result, never from the model's
/// account of events.
@Model
final class ToolExecution {
    var id: UUID = UUID()

    var toolID: String = ""
    var toolName: String = ""

    /// Arguments as JSON. Kept because the Activity screen shows *what* was done, and because a
    /// failed call needs to be explicable after the fact.
    var argumentsJSON: String?

    /// Short human-readable outcome. Never the raw payload — a calendar tool records
    /// "3 events tomorrow", not the events themselves.
    var resultSummary: String?

    var succeeded: Bool = false
    var errorDescription: String?

    var riskLevelRaw: String = ToolRiskLevel.readOnly.rawValue
    /// Whether the user was asked before this ran.
    var requiredConfirmation: Bool = false
    /// Whether the user said yes. Meaningless when `requiredConfirmation` is `false`.
    var wasConfirmed: Bool = false

    var conversationID: UUID?
    var messageID: UUID?

    var startedAt: Date = Date()
    var duration: TimeInterval = 0
    /// Position within one request's agent loop, for diagnosing runaway sequences (§36).
    var iterationIndex: Int = 0

    init(
        toolID: String = "",
        toolName: String = "",
        riskLevel: ToolRiskLevel = .readOnly,
        startedAt: Date = Date()
    ) {
        self.toolID = toolID
        self.toolName = toolName
        self.riskLevelRaw = riskLevel.rawValue
        self.startedAt = startedAt
    }

    var riskLevel: ToolRiskLevel {
        get { ToolRiskLevel(rawValue: riskLevelRaw) ?? .readOnly }
        set { riskLevelRaw = newValue.rawValue }
    }

    var snapshot: ToolExecutionSnapshot {
        ToolExecutionSnapshot(
            id: id,
            toolID: toolID,
            toolName: toolName,
            resultSummary: resultSummary,
            succeeded: succeeded,
            errorDescription: errorDescription,
            riskLevel: riskLevel,
            requiredConfirmation: requiredConfirmation,
            wasConfirmed: wasConfirmed,
            conversationID: conversationID,
            messageID: messageID,
            startedAt: startedAt,
            duration: duration,
            iterationIndex: iterationIndex
        )
    }
}

struct ToolExecutionSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: UUID
    var toolID: String
    var toolName: String
    var resultSummary: String?
    var succeeded: Bool
    var errorDescription: String?
    var riskLevel: ToolRiskLevel
    var requiredConfirmation: Bool
    var wasConfirmed: Bool
    var conversationID: UUID?
    var messageID: UUID?
    var startedAt: Date
    var duration: TimeInterval
    var iterationIndex: Int
}
