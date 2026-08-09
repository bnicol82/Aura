import Foundation
import Testing

@testable import AURA

/// The confirmation gate as the user meets it (§34, Level 3).
///
/// Tested closely because the failure this guards against is the worst one in the app: a consequential
/// action running when nobody approved it. Every path that is not an explicit "yes" has to end in `false`,
/// and the executor's task must never be left suspended.
@Suite("Tool confirmation")
@MainActor
struct ToolConfirmationTests {

    @Test("Approving resolves to true and clears the prompt")
    func approving() async throws {
        let coordinator = ToolConfirmationCoordinator()

        let answer = Task {
            await coordinator.requestConfirmation(
                toolName: "forget_this", prompt: "Forget it?", riskLevel: .consequential
            )
        }

        try await Self.waitForPending(coordinator)
        #expect(coordinator.pending?.prompt == "Forget it?")
        #expect(coordinator.pending?.riskLevel == .consequential)

        coordinator.answer(true)
        #expect(await answer.value)
        #expect(coordinator.pending == nil)
    }

    @Test("Declining resolves to false")
    func declining() async throws {
        let coordinator = ToolConfirmationCoordinator()
        let answer = Task {
            await coordinator.requestConfirmation(
                toolName: "forget_this", prompt: "Forget it?", riskLevel: .consequential
            )
        }

        try await Self.waitForPending(coordinator)
        coordinator.answer(false)
        #expect(await answer.value == false)
        #expect(coordinator.pending == nil)
    }

    @Test("A dismissed prompt is a refusal, not a no-op")
    func dismissing() async throws {
        // The alert's `isPresented` setter calls this. Without it the tool's task would stay suspended on
        // a continuation nobody resumes, and the tool would never report an outcome at all.
        let coordinator = ToolConfirmationCoordinator()
        let answer = Task {
            await coordinator.requestConfirmation(
                toolName: "forget_this", prompt: "Forget it?", riskLevel: .consequential
            )
        }

        try await Self.waitForPending(coordinator)
        coordinator.declinePending()
        #expect(await answer.value == false)
    }

    @Test("A second request while one is open is declined rather than queued")
    func secondRequestDeclines() async throws {
        // Queueing has the same hazard spread over time: the user would approve one thing while a second
        // prompt was waiting behind it. Refusing the second is recoverable — they can ask again.
        let coordinator = ToolConfirmationCoordinator()
        let first = Task {
            await coordinator.requestConfirmation(
                toolName: "forget_this", prompt: "First?", riskLevel: .consequential
            )
        }
        try await Self.waitForPending(coordinator)

        let second = await coordinator.requestConfirmation(
            toolName: "remember_this", prompt: "Second?", riskLevel: .reversible
        )
        #expect(second == false)
        // The first is untouched and still waiting on a real answer.
        #expect(coordinator.pending?.prompt == "First?")

        coordinator.answer(true)
        #expect(await first.value)
    }

    @Test("A cancelled turn refuses instead of hanging")
    func cancellationRefuses() async throws {
        let coordinator = ToolConfirmationCoordinator()
        let answer = Task {
            await coordinator.requestConfirmation(
                toolName: "forget_this", prompt: "Forget it?", riskLevel: .consequential
            )
        }

        try await Self.waitForPending(coordinator)
        answer.cancel()

        // `withCheckedContinuation` is not cancellation-aware, so this only passes because the coordinator
        // handles cancellation explicitly. Without it the test would hang rather than fail, which is why
        // the assertion is on the value and not on a flag.
        #expect(await answer.value == false)
        #expect(coordinator.pending == nil)
    }

    @Test("Answering when nothing is pending does nothing")
    func answeringNothingIsSafe() {
        // Reachable from a stale button tap or a second dismissal, and resuming a nil continuation would
        // trap rather than fail gracefully.
        let coordinator = ToolConfirmationCoordinator()
        coordinator.answer(true)
        coordinator.declinePending()
        #expect(coordinator.pending == nil)
    }

    /// Waits until the coordinator has actually suspended on a prompt.
    ///
    /// Polling rather than a fixed sleep: the request runs on another task, and a sleep long enough to be
    /// reliable would make the whole suite slower for no benefit.
    private static func waitForPending(_ coordinator: ToolConfirmationCoordinator) async throws {
        for _ in 0..<200 {
            if coordinator.pending != nil { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The coordinator never presented a prompt.")
    }
}
