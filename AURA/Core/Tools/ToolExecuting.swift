import Foundation

/// Asks the user to approve a consequential action (§34, Level 3).
///
/// Implemented by the UI layer. It is a protocol so the orchestrator can be tested without a view,
/// and so unattended entry points (a widget, a Shortcut) can supply an implementation that simply
/// declines rather than blocking forever on a prompt nobody will see.
protocol ToolConfirmationRequesting: Sendable {
    /// - Returns: `true` only on an affirmative answer. Timeouts, dismissals and unattended contexts
    ///   must all return `false` — silence is never consent.
    func requestConfirmation(
        toolName: String,
        prompt: String,
        riskLevel: ToolRiskLevel
    ) async -> Bool
}

/// A confirmation requester that always declines.
///
/// The correct behaviour for any context with no human present: AURA reports that it did not act,
/// rather than acting unsupervised or hanging (§34, §78).
struct DecliningConfirmationRequester: ToolConfirmationRequesting {
    func requestConfirmation(toolName: String, prompt: String, riskLevel: ToolRiskLevel) async -> Bool {
        AuraLog.tools.notice(
            "Declining \(toolName, privacy: .public) — no one available to confirm a \(riskLevel.rawValue, privacy: .public) action."
        )
        return false
    }
}

/// Runs tools, with the safety machinery attached (§34).
///
/// Every invocation goes through the same five steps, in this order, and none may be skipped:
///
/// 1. **Resolve** the tool by name — an unknown name is an error, never a silent no-op.
/// 2. **Check permissions**, requesting contextually if not yet determined.
/// 3. **Gate on confirmation** for the tier and the invocation's origin.
/// 4. **Execute**, with a timeout.
/// 5. **Record** a `ToolExecution` row and an `ActivityRecord` — success or failure, always.
///
/// Because `ToolExecutor` is the sole `ToolInvoking` implementation, a provider that runs tools
/// itself (Apple's `LanguageModelSession`) is subject to the same gate as one that hands calls back.
protocol ToolExecuting: Sendable, ToolInvoking {
    /// Runs a tool the model asked for by name.
    func execute(
        toolNamed name: String,
        arguments: [String: JSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionRecord

    /// Runs a specific tool, for callers that already hold it — App Intents, for instance.
    func execute(
        _ tool: any AssistantTool,
        arguments: ToolArguments,
        context: ToolExecutionContext
    ) async throws -> ToolExecutionRecord
}

/// The outcome of one tool invocation, as the orchestrator sees it.
///
/// Carries the result *and* the audit identity, so nothing has to re-derive what happened from the
/// model's description of it.
struct ToolExecutionRecord: Sendable, Equatable {
    var executionID: UUID
    var toolID: String
    var toolName: String
    var result: ToolResult
    var duration: TimeInterval
    var requiredConfirmation: Bool
    var wasConfirmed: Bool

    init(
        executionID: UUID = UUID(),
        toolID: String,
        toolName: String,
        result: ToolResult,
        duration: TimeInterval = 0,
        requiredConfirmation: Bool = false,
        wasConfirmed: Bool = false
    ) {
        self.executionID = executionID
        self.toolID = toolID
        self.toolName = toolName
        self.result = result
        self.duration = duration
        self.requiredConfirmation = requiredConfirmation
        self.wasConfirmed = wasConfirmed
    }

    /// The user-visible note for the transcript.
    var activityNote: ToolActivityNote {
        ToolActivityNote(
            toolName: toolName,
            label: result.activityLabel,
            succeeded: true,
            outcome: result.outcomeSummary
        )
    }
}

extension ToolExecuting {
    /// Bridges `ToolInvoking` — the handle given to `providerManaged` providers — onto the guarded
    /// execution path, so provider-initiated calls cannot route around the safety steps.
    func invokeTool(
        named name: String,
        arguments: [String: JSONValue]
    ) async throws -> ToolInvocationOutcome {
        let record = try await execute(
            toolNamed: name,
            arguments: arguments,
            context: ToolExecutionContext()
        )
        return ToolInvocationOutcome(
            modelFacingText: record.result.modelFacingText,
            activity: record.activityNote
        )
    }
}
