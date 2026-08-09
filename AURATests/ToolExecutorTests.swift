import Foundation
import Testing

@testable import AURA

/// The tool safety machinery (§34, §35, §36).
///
/// Tested harder than most things here because the failure modes are not "wrong answer" — they are AURA taking
/// an action the user did not authorise, or reporting one it never took. Both are unrecoverable in a way a bad
/// sentence is not.
@Suite("Tool executor")
struct ToolExecutorTests {

    // MARK: Confirmation policy

    @Test("Read-only tools never need confirmation")
    func readOnlyNeedsNoConfirmation() {
        let tool = StubTool(riskLevel: .readOnly)
        #expect(!DefaultToolExecutor.requiresConfirmation(
            tool, context: ToolExecutionContext(userExplicitlyRequested: false)
        ))
        #expect(!DefaultToolExecutor.requiresConfirmation(
            tool, context: ToolExecutionContext(userExplicitlyRequested: true)
        ))
    }

    @Test("A reversible tool needs confirmation only when the model decided on it")
    func reversibleDependsOnWhoAsked() {
        // §34's distinction: the user saying "remind me at six" is authorisation. The model deciding to create
        // a reminder because it seemed helpful is not.
        let tool = StubTool(riskLevel: .reversible)
        #expect(DefaultToolExecutor.requiresConfirmation(
            tool, context: ToolExecutionContext(userExplicitlyRequested: false)
        ))
        #expect(!DefaultToolExecutor.requiresConfirmation(
            tool, context: ToolExecutionContext(userExplicitlyRequested: true)
        ))
    }

    @Test("A consequential tool always needs confirmation, even when asked for outright")
    func consequentialAlwaysConfirms() {
        // Sending a message or spending money is confirmed even if the user asked, because the cost of a
        // misheard instruction is not recoverable.
        let tool = StubTool(riskLevel: .consequential)
        #expect(DefaultToolExecutor.requiresConfirmation(
            tool, context: ToolExecutionContext(userExplicitlyRequested: true)
        ))
    }

    @Test("A tool can add a confirmation requirement but never remove one")
    func alwaysRequiresConfirmationOnlyAdds() {
        // Otherwise a tool could talk its way out of being confirmed, and the tier system would be advisory.
        let cautious = StubTool(riskLevel: .readOnly, alwaysRequiresConfirmation: true)
        #expect(DefaultToolExecutor.requiresConfirmation(
            cautious, context: ToolExecutionContext(userExplicitlyRequested: true)
        ))

        let reckless = StubTool(riskLevel: .consequential, alwaysRequiresConfirmation: false)
        #expect(DefaultToolExecutor.requiresConfirmation(
            reckless, context: ToolExecutionContext(userExplicitlyRequested: true)
        ))
    }

    // MARK: Gates

    @Test("An unknown tool name is an error, not a silent no-op")
    func unknownToolThrows() async throws {
        // A model asking for a capability that does not exist has invented it. Returning "done" would let it
        // report an action it never took (§78).
        let executor = await Self.makeExecutor(tools: [])
        await #expect(throws: AuraError.self) {
            try await executor.execute(
                toolNamed: "nonexistent_tool",
                arguments: [:],
                context: ToolExecutionContext(userExplicitlyRequested: true)
            )
        }
    }

    @Test("A missing permission is refused, and the tool never runs")
    func missingPermissionRefuses() async throws {
        let tool = StubTool(riskLevel: .readOnly, requiredPermissions: [.calendar])
        let executor = await Self.makeExecutor(tools: [tool], granted: [])

        await #expect(throws: AuraError.self) {
            try await executor.execute(
                tool,
                arguments: ToolArguments(toolName: tool.name),
                context: ToolExecutionContext(userExplicitlyRequested: true)
            )
        }
        // The gate has to prevent execution, not merely report afterwards.
        #expect(await tool.runs.count == 0)
    }

    @Test("A network tool is refused while offline, and never runs")
    func offlineRefusesNetworkTools() async throws {
        let tool = StubTool(riskLevel: .readOnly, worksOffline: false)
        let executor = await Self.makeExecutor(tools: [tool], isOnline: false)

        await #expect(throws: AuraError.self) {
            try await executor.execute(
                tool,
                arguments: ToolArguments(toolName: tool.name),
                context: ToolExecutionContext(userExplicitlyRequested: true)
            )
        }
        #expect(await tool.runs.count == 0)
    }

    @Test("A tool above the risk ceiling is refused outright, not offered for approval")
    func riskCeilingRefusesRatherThanAsks() async throws {
        // The ceiling means "not even if asked", so it must not turn into a confirmation prompt.
        let tool = StubTool(riskLevel: .consequential)
        let requester = RecordingConfirmationRequester(answer: true)
        let executor = await Self.makeExecutor(
            tools: [tool],
            requester: requester,
            maximumRiskLevel: .reversible
        )

        await #expect(throws: AuraError.self) {
            try await executor.execute(
                tool,
                arguments: ToolArguments(toolName: tool.name),
                context: ToolExecutionContext(userExplicitlyRequested: true)
            )
        }
        #expect(await tool.runs.count == 0)
        #expect(await requester.asks.count == 0)
    }

    // MARK: Confirmation behaviour

    @Test("Declining produces a record rather than an error, and the tool never runs")
    func decliningIsRecordedNotThrown() async throws {
        // §36: the Activity log is a record of actions, and a proposal the user rejected is one of them.
        // Throwing would lose it.
        let tool = StubTool(riskLevel: .consequential)
        let executor = await Self.makeExecutor(
            tools: [tool],
            requester: RecordingConfirmationRequester(answer: false)
        )

        let record = try await executor.execute(
            tool,
            arguments: ToolArguments(toolName: tool.name),
            context: ToolExecutionContext(userExplicitlyRequested: true)
        )

        #expect(record.requiredConfirmation)
        #expect(!record.wasConfirmed)
        #expect(record.result.didMutateData == false)
        #expect(record.result.outcomeSummary == "Declined")
        #expect(await tool.runs.count == 0)
        // What the model is told has to say it did not happen, or it will report success.
        #expect(record.result.modelFacingText.lowercased().contains("declined"))
    }

    @Test("A declined action is not written into the transcript as a success")
    func declinedActivityNoteIsNotASuccess() async throws {
        // The record and the note are separate renderings of the same event, and the note is the one the user
        // reads. A tick beside an action nobody approved is the §78 failure in its most literal form.
        let tool = StubTool(riskLevel: .consequential)
        let executor = await Self.makeExecutor(
            tools: [tool],
            requester: RecordingConfirmationRequester(answer: false)
        )

        let declined = try await executor.execute(
            tool,
            arguments: ToolArguments(toolName: tool.name),
            context: ToolExecutionContext(userExplicitlyRequested: true)
        )
        #expect(declined.wasDeclined)
        #expect(!declined.activityNote.succeeded)

        let approvingExecutor = await Self.makeExecutor(
            tools: [tool],
            requester: RecordingConfirmationRequester(answer: true)
        )
        let performed = try await approvingExecutor.execute(
            tool,
            arguments: ToolArguments(toolName: tool.name),
            context: ToolExecutionContext(userExplicitlyRequested: true)
        )
        #expect(!performed.wasDeclined)
        #expect(performed.activityNote.succeeded)
    }

    @Test("Approving runs the tool and records that it was confirmed")
    func approvingRunsTheTool() async throws {
        let tool = StubTool(riskLevel: .consequential)
        let executor = await Self.makeExecutor(
            tools: [tool],
            requester: RecordingConfirmationRequester(answer: true)
        )

        let record = try await executor.execute(
            tool,
            arguments: ToolArguments(toolName: tool.name),
            context: ToolExecutionContext(userExplicitlyRequested: true)
        )

        #expect(record.requiredConfirmation)
        #expect(record.wasConfirmed)
        #expect(await tool.runs.count == 1)
    }

    @Test("The default requester declines, so an unattended build cannot take consequential actions")
    func defaultRequesterDeclines() async {
        // Silence is never consent. A build that forgot to wire a confirmation UI must fail closed.
        let declined = await DecliningConfirmationRequester().requestConfirmation(
            toolName: "send_message", prompt: "Send it?", riskLevel: .consequential
        )
        #expect(!declined)
    }

    // MARK: Provider-managed calls

    @Test("A model-initiated call is not treated as user-requested")
    func providerManagedCallsAreNotUserRequested() async throws {
        // The seam that matters: Apple's framework calls tools itself, and if that path claimed the user had
        // asked, every reversible tool would silently skip confirmation.
        let tool = StubTool(riskLevel: .reversible)
        let requester = RecordingConfirmationRequester(answer: false)
        let executor = await Self.makeExecutor(tools: [tool], requester: requester)

        let outcome = try await executor.invokeTool(named: tool.name, arguments: [:])

        #expect(await requester.asks.count == 1)
        #expect(await tool.runs.count == 0)
        #expect(outcome.modelFacingText.lowercased().contains("declined"))
    }
}

// MARK: - Doubles

/// A shared tally the doubles can bump from any isolation domain.
///
/// An actor rather than making the doubles themselves actors: `AssistantTool` has *synchronous*
/// requirements (`progressLabel`, `confirmationPrompt`), and an actor-isolated method cannot witness
/// one. Keeping the doubles as values and putting only the mutable state behind an actor sidesteps
/// that without weakening the checks.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// A tool that records whether it ran.
private struct StubTool: AssistantTool {
    let id = "stub.tool"
    let name = "stub_tool"
    var description: String { "A tool for tests." }
    var parameters: ToolParameterSchema { .none }
    let requiredPermissions: Set<AuraPermission>
    let riskLevel: ToolRiskLevel
    let alwaysRequiresConfirmation: Bool
    let worksOffline: Bool

    /// A reference, so copies of this value share the tally — the executor is handed `any
    /// AssistantTool` and the test keeps its own copy.
    let runs = CallCounter()

    init(
        riskLevel: ToolRiskLevel,
        requiredPermissions: Set<AuraPermission> = [],
        alwaysRequiresConfirmation: Bool = false,
        worksOffline: Bool = true
    ) {
        self.riskLevel = riskLevel
        self.requiredPermissions = requiredPermissions
        self.alwaysRequiresConfirmation = alwaysRequiresConfirmation
        self.worksOffline = worksOffline
    }

    func progressLabel(for arguments: ToolArguments) -> String { "Doing the thing" }
    func confirmationPrompt(for arguments: ToolArguments) -> String { "Do the thing?" }

    func execute(arguments: ToolArguments, context: ToolExecutionContext) async throws -> ToolResult {
        await runs.increment()
        return ToolResult(
            modelFacingText: "Did the thing.",
            activityLabel: "Doing the thing",
            outcomeSummary: "Done",
            didMutateData: true
        )
    }
}

/// Answers confirmation the same way every time, and counts how often it was asked.
private struct RecordingConfirmationRequester: ToolConfirmationRequesting {
    let answer: Bool
    let asks = CallCounter()

    init(answer: Bool) { self.answer = answer }

    func requestConfirmation(toolName: String, prompt: String, riskLevel: ToolRiskLevel) async -> Bool {
        await asks.increment()
        return answer
    }
}

extension ToolExecutorTests {

    static func makeExecutor(
        tools: [any AssistantTool],
        granted: Set<AuraPermission> = Set(AuraPermission.allCases),
        isOnline: Bool = true,
        requester: any ToolConfirmationRequesting = DecliningConfirmationRequester(),
        maximumRiskLevel: ToolRiskLevel = .consequential
    ) async -> DefaultToolExecutor {
        let registry = ToolRegistry()
        await registry.register(tools)

        return DefaultToolExecutor(
            registry: registry,
            permissions: StubPermissionManager(
                statuses: Dictionary(
                    uniqueKeysWithValues: AuraPermission.allCases.map {
                        ($0, granted.contains($0) ? PermissionStatus.authorized : .denied)
                    }
                )
            ),
            networkMonitor: StubNetworkMonitor(isOnline: isOnline),
            confirmationRequester: requester,
            maximumRiskLevel: maximumRiskLevel
        )
    }
}
