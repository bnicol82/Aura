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

    /// The tools that could actually run right now, for offering to a model.
    ///
    /// Asked of the executor rather than of `ToolRegistry` directly, because the answer depends on
    /// exactly the state the executor already holds — granted permissions, connectivity, the risk
    /// ceiling — and those are the same values its gates enforce. Two places computing "is this tool
    /// available" would eventually disagree, and the failure would be a model promising something that
    /// is then refused (§78).
    func availableToolDefinitions() async -> [ToolDefinition]
}

extension ToolActivityNote {

    /// A tool's model-facing name, rendered for a person.
    ///
    /// A tool's own `progressLabel(for:)` is better and is used wherever the tool itself is in hand.
    /// This is the fallback for the two places that hold a name and nothing else: a call the orchestrator
    /// is about to make, and a failure that happened before any tool was resolved.
    static func humanisedName(_ toolName: String) -> String {
        toolName.replacingOccurrences(of: "_", with: " ")
    }

    /// A note for a call that has started and not yet finished.
    static func started(toolName: String) -> ToolActivityNote {
        ToolActivityNote(
            toolName: toolName,
            label: humanisedName(toolName),
            // Not yet. This note describes a call in flight; `succeeded` becomes meaningful on the
            // `.toolFinished` note that supersedes it.
            succeeded: false,
            outcome: nil
        )
    }
}

extension ToolInvocationOutcome {

    /// What the model is told when a tool call could not run.
    ///
    /// Reported as an outcome rather than thrown, so the model can explain the problem in its own voice
    /// — "I can't get at your calendar until you allow it" beats the whole turn collapsing into an error
    /// banner. The text is unambiguous about failure, so the model is never left able to conclude the
    /// action happened, and the note it carries is marked unsuccessful so the transcript agrees.
    ///
    /// Shared by both tool paths on purpose: Apple's framework calls tools out of the orchestrator's
    /// reach, the orchestrator runs them itself for `orchestratorManaged` providers, and a failure has to
    /// read identically either way.
    static func failure(toolName: String, error: any Error) -> ToolInvocationOutcome {
        ToolInvocationOutcome(
            // `AuraError` is a `LocalizedError`, so `localizedDescription` is already its
            // `errorDescription` — the same sentence the UI would show, with no second wording to keep
            // in step.
            modelFacingText: "The \(toolName) tool did not run. Reason: \(error.localizedDescription) "
                + "Tell the user it did not happen.",
            activity: ToolActivityNote(
                toolName: toolName,
                label: ToolActivityNote.humanisedName(toolName),
                succeeded: false,
                outcome: error.localizedDescription
            )
        )
    }
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

    /// `true` when the action was proposed and the user said no.
    ///
    /// The only way a record can exist for something that did not run: a thrown error never produces
    /// a record at all, so a record plus an unanswered confirmation means exactly "declined".
    var wasDeclined: Bool { requiredConfirmation && !wasConfirmed }

    /// The user-visible note for the transcript.
    var activityNote: ToolActivityNote {
        ToolActivityNote(
            toolName: toolName,
            label: result.activityLabel,
            // A declined proposal is not a success. Hard-coding `true` here would put a tick beside
            // something that never happened, which is the §78 failure in its most literal form.
            succeeded: !wasDeclined,
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
