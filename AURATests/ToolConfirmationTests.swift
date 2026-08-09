import Foundation
import Testing

@testable import AURA

/// The confirmation gate as the user meets it (§34, Level 3).
///
/// Tested closely because the failure this guards against is the worst one in the app: a consequential
/// action running when nobody approved it. Every path that is not an explicit "yes" has to end in `false`,
/// and — the property the first implementation lacked — every path has to *end*.
@Suite("Tool confirmation", .timeLimit(.minutes(1)))
@MainActor
struct ToolConfirmationTests {

    /// Short deadlines so the timeout path is testable in milliseconds rather than minutes.
    private static func makeCoordinator(
        timeout: Duration = .seconds(5)
    ) -> ToolConfirmationCoordinator {
        ToolConfirmationCoordinator(timeout: timeout, pollInterval: .milliseconds(5))
    }

    @Test("Approving resolves to true and clears the prompt")
    func approving() async throws {
        let coordinator = Self.makeCoordinator()

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
        let coordinator = Self.makeCoordinator()
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
        // The alert's `isPresented` setter calls this when the prompt leaves the screen without a button
        // having been tapped.
        let coordinator = Self.makeCoordinator()
        let answer = Task {
            await coordinator.requestConfirmation(
                toolName: "forget_this", prompt: "Forget it?", riskLevel: .consequential
            )
        }

        try await Self.waitForPending(coordinator)
        coordinator.promptDismissed()
        #expect(await answer.value == false)
    }

    @Test("A second request while one is open is declined rather than queued")
    func secondRequestDeclines() async throws {
        // Queueing has the same hazard spread over time: the user would approve one thing while a second
        // prompt was waiting behind it. Refusing the second is recoverable — they can ask again.
        let coordinator = Self.makeCoordinator()
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

    @Test("A dismissal after an approval does not overwrite it")
    func dismissalAfterApprovalKeepsTheApproval() async throws {
        // SwiftUI drives an alert's `isPresented` binding to `false` after a button action runs, so this
        // sequence is the real one, not a contrived order. Declining unconditionally on dismissal would
        // invert the user's decision a moment after they made it.
        let coordinator = Self.makeCoordinator()
        let answer = Task {
            await coordinator.requestConfirmation(
                toolName: "forget_this", prompt: "Forget it?", riskLevel: .consequential
            )
        }

        try await Self.waitForPending(coordinator)
        coordinator.answer(true)
        coordinator.promptDismissed()

        #expect(await answer.value)
    }

    @Test("A prompt nobody answers refuses on its own")
    func unansweredPromptRefuses() async throws {
        // Silence is never consent, made total: a user who put the phone down mid-prompt gets the action
        // not happening, rather than a tool held open indefinitely.
        let coordinator = Self.makeCoordinator(timeout: .milliseconds(150))
        let approved = await coordinator.requestConfirmation(
            toolName: "forget_this", prompt: "Forget it?", riskLevel: .consequential
        )
        #expect(approved == false)
        // And the prompt is gone, rather than left on screen with nothing waiting behind it.
        #expect(coordinator.pending == nil)
    }

    @Test("A cancelled turn refuses instead of hanging")
    func cancellationRefuses() async throws {
        let coordinator = Self.makeCoordinator()
        let answer = Task {
            await coordinator.requestConfirmation(
                toolName: "forget_this", prompt: "Forget it?", riskLevel: .consequential
            )
        }

        try await Self.waitForPending(coordinator)
        answer.cancel()

        // The wait checks `Task.isCancelled` every pass, so this returns rather than hanging. The first
        // implementation suspended on a checked continuation, which ignores cancellation — that version hung
        // CI twice and could not even be killed by `.timeLimit`.
        #expect(await answer.value == false)
        #expect(coordinator.pending == nil)
    }

    @Test("Answering when nothing is pending does nothing")
    func answeringNothingIsSafe() {
        // Reachable from a stale button tap or a second dismissal.
        let coordinator = Self.makeCoordinator()
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
