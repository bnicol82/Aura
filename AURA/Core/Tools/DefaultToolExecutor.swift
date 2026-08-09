import Foundation

/// Runs tools, and is the only thing that decides whether a tool is allowed to run (§34, §35, §36).
///
/// ### Why every gate is here rather than in the tools
/// A tool that checked its own permissions could forget to. Concentrating the checks means a new tool is safe
/// by construction: it declares what it needs and what it costs, and this type enforces both. A tool cannot
/// opt out of confirmation, cannot run without its permissions, and cannot avoid being recorded.
///
/// ### The order of the gates, which is not arbitrary
/// 1. **Existence** — an unknown name is a model hallucinating a capability, not an error to paper over.
/// 2. **Offline** — a network tool while offline fails with a reason the user can act on (§54).
/// 3. **Permissions** — missing authorization is reported as itself, so the UI can offer to fix it.
/// 4. **Confirmation** — asked *last*, because asking the user to approve something that was going to fail
///    anyway wastes the one moment of their attention this whole mechanism is spending.
///
/// ### The audit trail is not optional
/// Every attempt returns a `ToolExecutionRecord`, including the ones that were refused. §36 promises the user
/// can see what AURA did; a refusal is part of what it did, and hiding declined attempts would make the
/// Activity log a record of successes rather than of actions.
actor DefaultToolExecutor: ToolExecuting {

    private let registry: ToolRegistry
    private let permissions: any PermissionManaging
    private let networkMonitor: any NetworkStatusProviding
    private let confirmationRequester: any ToolConfirmationRequesting

    /// Where every attempt is recorded (§36). Optional so a test can run the gates without a store, but
    /// absent in the app would mean an Activity screen that stays empty while AURA acts.
    private let activityLog: (any ActivityLogging)?

    /// Ceiling on what may run without the user having asked for it in so many words.
    ///
    /// Not a constant: §34's tiers are the policy, but a future setting ("never take consequential actions")
    /// is a ceiling, and it belongs here rather than being scattered through the tools.
    private let maximumRiskLevel: ToolRiskLevel

    init(
        registry: ToolRegistry,
        permissions: any PermissionManaging,
        networkMonitor: any NetworkStatusProviding,
        confirmationRequester: any ToolConfirmationRequesting = DecliningConfirmationRequester(),
        activityLog: (any ActivityLogging)? = nil,
        maximumRiskLevel: ToolRiskLevel = .consequential
    ) {
        self.registry = registry
        self.permissions = permissions
        self.networkMonitor = networkMonitor
        self.confirmationRequester = confirmationRequester
        self.activityLog = activityLog
        self.maximumRiskLevel = maximumRiskLevel
    }

    // MARK: - Entry points

    func execute(
        toolNamed name: String,
        arguments: [String: JSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionRecord {
        guard let tool = await registry.tool(named: name) else {
            // A model asking for a tool that does not exist has invented a capability. Saying so is the
            // §78-honest response; quietly returning "done" would let it report an action it never took.
            throw AuraError.toolNotFound(name: name)
        }
        return try await execute(
            tool,
            arguments: ToolArguments(toolName: tool.name, values: arguments),
            context: context
        )
    }

    func execute(
        _ tool: any AssistantTool,
        arguments: ToolArguments,
        context: ToolExecutionContext
    ) async throws -> ToolExecutionRecord {
        let started = Date()

        // 1. Offline. Checked before permissions because it is the cheaper question and the more common
        //    cause, and because a permission prompt for a tool that cannot run anyway is pure noise.
        if !tool.worksOffline, await !networkMonitor.isOnline {
            throw await refuse(tool, context: context, with: AuraError.noInternetConnection)
        }

        // 2. Permissions, reported as themselves so the UI can offer the fix rather than a generic failure.
        //    A tool that would see nothing under a partial grant insists on the full one — see
        //    `AssistantTool.requiresFullPermissionAccess`.
        for permission in tool.requiredPermissions {
            let status = await permissions.status(for: permission)
            let sufficient = tool.requiresFullPermissionAccess
                ? status == .authorized
                : status.isUsable
            guard sufficient else {
                throw await refuse(tool, context: context, with: AuraError.permissionDenied(permission))
            }
        }

        // 3. The risk ceiling. Independent of confirmation: a tool above the ceiling is refused outright
        //    rather than offered for approval, because the ceiling exists to mean "not even if asked".
        guard tool.riskLevel <= maximumRiskLevel else {
            // `toolFailed` with the reason, because no `toolNotPermitted` case exists and inventing one is
            // not this commit's business. The reason has to name the ceiling, or the user sees a bare failure
            // for something AURA declined on purpose.
            throw await refuse(
                tool,
                context: context,
                with: AuraError.toolFailed(
                    toolName: tool.name,
                    reason: "this needs a higher level of trust than AURA is currently allowed to act on"
                )
            )
        }

        // 4. Confirmation, last, so the user is only ever asked about something that would actually run.
        let needsConfirmation = Self.requiresConfirmation(tool, context: context)
        var wasConfirmed = false

        if needsConfirmation {
            wasConfirmed = await confirmationRequester.requestConfirmation(
                toolName: tool.name,
                prompt: tool.confirmationPrompt(for: arguments),
                riskLevel: tool.riskLevel
            )
            guard wasConfirmed else {
                // Declining is a normal outcome, not a failure. It still produces a record, so the Activity
                // log shows what AURA proposed and that the user said no.
                let declined = ToolExecutionRecord(
                    toolID: tool.id,
                    toolName: tool.name,
                    result: ToolResult(
                        modelFacingText: "The user declined this action, so it was not performed.",
                        activityLabel: tool.progressLabel(for: arguments),
                        outcomeSummary: "Declined",
                        didMutateData: false
                    ),
                    duration: Date().timeIntervalSince(started),
                    requiredConfirmation: true,
                    wasConfirmed: false
                )
                await log(declined, context: context)
                return declined
            }
        }

        let result: ToolResult
        do {
            result = try await tool.execute(arguments: arguments, context: context)
        } catch {
            // A tool that threw still did something as far as the user is concerned: AURA tried and could
            // not. Recording it is what keeps the Activity screen a record of actions rather than of
            // successes (§36).
            throw await refuse(tool, context: context, with: error)
        }

        let record = ToolExecutionRecord(
            toolID: tool.id,
            toolName: tool.name,
            result: result,
            duration: Date().timeIntervalSince(started),
            requiredConfirmation: needsConfirmation,
            wasConfirmed: wasConfirmed
        )
        await log(record, context: context)
        return record
    }

    // MARK: - Recording

    private func log(_ record: ToolExecutionRecord, context: ToolExecutionContext) async {
        await activityLog?.recordToolExecution(
            record,
            conversationID: context.conversationID,
            messageID: context.messageID,
            iterationIndex: context.iterationIndex
        )
    }

    /// Records a refusal and hands the error back for throwing.
    ///
    /// Shaped as `throw await refuse(...)` so a gate cannot log and then forget to throw, or throw and
    /// forget to log. Every path out of `execute` other than a successful run goes through here.
    private func refuse(
        _ tool: any AssistantTool,
        context: ToolExecutionContext,
        with error: any Error
    ) async -> any Error {
        await activityLog?.recordToolFailure(
            toolID: tool.id,
            toolName: tool.name,
            error: error,
            conversationID: context.conversationID,
            messageID: context.messageID,
            iterationIndex: context.iterationIndex
        )
        return error
    }

    // MARK: - Availability

    func availableToolDefinitions() async -> [ToolDefinition] {
        let statuses = await permissions.allStatuses()
        return await registry.availableDefinitions(
            for: ToolRegistry.AvailabilityCriteria(
                grantedPermissions: Set(statuses.filter { $0.value.isUsable }.keys),
                // Read from the same snapshot as the granted set, so the two cannot describe different
                // moments — a permission revoked between two reads would otherwise look both usable and
                // fully granted.
                partiallyGrantedPermissions: Set(statuses.filter { $0.value == .limited }.keys),
                isOnline: await networkMonitor.isOnline,
                maximumRiskLevel: maximumRiskLevel,
                restrictedToIDs: nil
            )
        )
    }

    // MARK: - ToolInvoking

    /// The handle a `providerManaged` provider uses mid-generation.
    ///
    /// Apple's framework calls tools itself, so this is the seam where a model-initiated call still passes
    /// through every gate above. Without it, provider-managed tools would bypass the safety tiers entirely —
    /// which is the whole reason `ToolInvoking` exists rather than handing providers the registry.
    func invokeTool(
        named name: String,
        arguments: [String: JSONValue]
    ) async throws -> ToolInvocationOutcome {
        let record = try await execute(
            toolNamed: name,
            arguments: arguments,
            // Not user-requested: the model reached for this on its own, so a reversible tool still needs
            // confirmation. Claiming otherwise here would silently downgrade every provider-managed call.
            context: ToolExecutionContext(userExplicitlyRequested: false)
        )
        return ToolInvocationOutcome(
            modelFacingText: record.result.modelFacingText,
            activity: record.activityNote
        )
    }

    // MARK: - Policy

    /// Whether this call needs the user's approval.
    ///
    /// `static` and pure so §34's tiers are one readable rule and a test can pin every combination. The
    /// tool's own `alwaysRequiresConfirmation` can only *add* a requirement, never remove one — a tool must
    /// not be able to talk its way out of being confirmed.
    static func requiresConfirmation(_ tool: any AssistantTool, context: ToolExecutionContext) -> Bool {
        if tool.alwaysRequiresConfirmation { return true }
        return tool.riskLevel.requiresConfirmation(
            userExplicitlyRequested: context.userExplicitlyRequested
        )
    }
}
