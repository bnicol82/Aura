import Foundation
import Observation

/// Asks the user to approve an action, and blocks the tool until they answer (§34, Level 3).
///
/// ### Why a continuation rather than a callback
/// `ToolConfirmationRequesting` is `async -> Bool` because the tool executor genuinely cannot proceed
/// without the answer: the whole point of confirmation is that nothing happens until the user says so.
/// Bridging a SwiftUI dialog onto that shape means suspending the executor's task until a button is
/// tapped, which is exactly what `withCheckedContinuation` is for.
///
/// ### Everything that is not an approval is a refusal
/// Dismissing the sheet, cancelling the turn, backgrounding the app, a second request arriving while one
/// is open — all of them resolve to `false`. That is not defensive coding for its own sake; it is the
/// rule from §34 that silence is never consent. The one failure mode that must not exist is a
/// consequential action running because nobody said no.
///
/// ### Why exactly one at a time
/// A second prompt appearing over the first would let the user approve one thing while looking at
/// another. Rather than queue them — which has the same problem, spread over time — a request arriving
/// while one is open is declined outright. Models asking for two consequential actions in one turn is
/// rare, and refusing the second is recoverable: the user can ask again.
@MainActor
@Observable
final class ToolConfirmationCoordinator: ToolConfirmationRequesting {

    /// A request waiting on the user. `Identifiable` so SwiftUI can key a sheet on it.
    struct Request: Identifiable, Sendable, Equatable {
        let id = UUID()
        let toolName: String
        /// The sentence the user is approving. Written by the tool, and it states the concrete effect.
        let prompt: String
        let riskLevel: ToolRiskLevel
    }

    /// The open request, or `nil` when nothing is waiting. The view presents on this.
    private(set) var pending: Request?

    /// Resumed exactly once, by `answer(_:)` or `declinePending()`.
    ///
    /// Held rather than stored alongside `pending` so there is one place that can resume it, and so
    /// `nil`-ing it is what marks the request as answered.
    @ObservationIgnored
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Set when cancellation arrives in the window before the continuation has been stored.
    ///
    /// `withCheckedContinuation` is not cancellation-aware, so a turn cancelled at exactly the wrong
    /// moment would otherwise suspend the executor's task on a continuation nobody can reach. This is the
    /// one-bit handshake that closes that window.
    @ObservationIgnored
    private var cancelledBeforeSuspending = false

    // MARK: - ToolConfirmationRequesting

    func requestConfirmation(
        toolName: String,
        prompt: String,
        riskLevel: ToolRiskLevel
    ) async -> Bool {
        guard continuation == nil else {
            AuraLog.tools.notice(
                "Declining \(toolName, privacy: .public): another confirmation is already open."
            )
            return false
        }
        guard !Task.isCancelled else { return false }

        cancelledBeforeSuspending = false

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Checked inside the closure because cancellation can land between the guard above and
                // here. Resuming immediately is the only way out that does not leave a suspended task.
                if cancelledBeforeSuspending {
                    cancelledBeforeSuspending = false
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                self.pending = Request(toolName: toolName, prompt: prompt, riskLevel: riskLevel)
            }
        } onCancel: {
            // `onCancel` runs on whatever thread cancelled, so it hops rather than touching state here.
            Task { @MainActor in self.noteCancellation() }
        }
    }

    /// Turns a cancelled turn into a refusal, whichever side of the suspension it arrives on.
    private func noteCancellation() {
        if continuation != nil {
            declinePending()
        } else {
            cancelledBeforeSuspending = true
        }
    }

    // MARK: - Answering

    /// Resolves the open request. Safe to call when nothing is pending.
    func answer(_ approved: Bool) {
        guard let continuation else { return }
        // Cleared *before* resuming: the resumed task may immediately request another confirmation, and
        // it would otherwise see this one still open and be declined.
        self.continuation = nil
        self.pending = nil
        continuation.resume(returning: approved)
    }

    /// Refuses whatever is open. The path for a dismissed sheet or a cancelled turn.
    ///
    /// Without this, cancelling a turn mid-prompt would leave the executor's task suspended forever on a
    /// continuation nobody will resume — a leak that also means the tool never reports an outcome.
    func declinePending() {
        answer(false)
    }
}
