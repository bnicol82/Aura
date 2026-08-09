import Foundation
import Observation

/// Asks the user to approve an action, and blocks the tool until they answer (§34, Level 3).
///
/// ### Everything that is not an approval is a refusal
/// Dismissing the prompt, cancelling the turn, a second request arriving while one is open, or simply
/// nobody answering — all of them resolve to `false`. That is not defensive coding for its own sake; it is
/// §34's rule that silence is never consent, made total. The one outcome that must not exist is a
/// consequential action running because nobody said no.
///
/// ### Why this polls instead of suspending on a continuation
/// The obvious implementation is `withCheckedContinuation`, resumed by the button handler. It was the first
/// implementation, and it was wrong in a way worth recording: a checked continuation is not
/// cancellation-aware, so any path that failed to resume it left the tool executor's task suspended
/// **forever**. Not slow — permanently stuck, holding the turn open, and immune to task cancellation and to
/// Swift Testing's `.timeLimit` alike. It cost two CI runs that looked like slowness and were deadlocks.
///
/// A bounded wait cannot fail that way. Every path out is a `return`, cancellation is checked each pass, and
/// a prompt nobody ever answers resolves on its own. The cost is a 50 ms granularity on a decision a human
/// takes seconds over, which is imperceptible; the gain is that the class of bug is gone rather than
/// guarded against.
///
/// ### Why the timeout is product behaviour and not a safety net
/// A confirmation has a person on the other end. If they put the phone down, the honest outcome is that the
/// action did not happen — so the deadline resolves to a refusal, and AURA reports it as one.
///
/// ### Why exactly one at a time
/// A second prompt over the first would let the user approve one thing while looking at another. Queueing
/// has the same hazard spread over time, so a request arriving while one is open is refused outright. Two
/// consequential actions in one turn is rare, and refusing the second is recoverable: they can ask again.
@MainActor
@Observable
final class ToolConfirmationCoordinator: ToolConfirmationRequesting {

    /// A request waiting on the user.
    struct Request: Identifiable, Sendable, Equatable {
        let id = UUID()
        let toolName: String
        /// The sentence the user is approving. Written by the tool, and it states the concrete effect.
        let prompt: String
        let riskLevel: ToolRiskLevel
    }

    /// The open request, or `nil` when nothing is waiting. The view presents on this.
    private(set) var pending: Request?

    /// The user's answer, once given.
    ///
    /// Keyed by request id rather than a bare `Bool` so a stale answer — a button tapped as one prompt was
    /// replaced by the next — cannot be read as an answer to the wrong question. Named distinctly from
    /// `answer(_:)` so neither the compiler nor a reader has to work out which is meant.
    @ObservationIgnored
    private var recordedAnswer: (requestID: UUID, approved: Bool)?

    /// How long a prompt waits before it refuses on its own.
    ///
    /// Two minutes: long enough that a user reading the sentence is never rushed, short enough that a turn
    /// abandoned mid-prompt does not hold a tool open indefinitely. Injectable so tests do not wait it out.
    private let timeout: Duration

    /// How often the wait checks for an answer. Imperceptible against a human decision.
    private let pollInterval: Duration

    init(timeout: Duration = .seconds(120), pollInterval: Duration = .milliseconds(50)) {
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    // MARK: - ToolConfirmationRequesting

    func requestConfirmation(
        toolName: String,
        prompt: String,
        riskLevel: ToolRiskLevel
    ) async -> Bool {
        guard pending == nil else {
            AuraLog.tools.notice(
                "Declining \(toolName, privacy: .public): another confirmation is already open."
            )
            return false
        }

        let request = Request(toolName: toolName, prompt: prompt, riskLevel: riskLevel)
        pending = request
        recordedAnswer = nil

        // Cleared on every exit — answered, cancelled, or timed out — so a prompt can never be left on
        // screen with nothing waiting behind it.
        defer {
            if pending?.id == request.id {
                pending = nil
            }
            if recordedAnswer?.requestID == request.id {
                recordedAnswer = nil
            }
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let recordedAnswer, recordedAnswer.requestID == request.id {
                return recordedAnswer.approved
            }
            // A cancelled turn is a refusal. Checked every pass rather than relied on to interrupt a
            // suspension, which is the mistake this design exists to avoid.
            if Task.isCancelled {
                return false
            }
            // `try?` because the only way this throws is cancellation, which the next pass — or rather this
            // one, since the check above runs first — already handles as a refusal.
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return false
            }
        }

        AuraLog.tools.notice(
            "Confirmation for \(toolName, privacy: .public) went unanswered, so it was refused."
        )
        return false
    }

    // MARK: - Answering

    /// Resolves the open request. Safe to call when nothing is pending.
    ///
    /// Records the answer but leaves `pending` set; the waiting call clears it on its way out. That keeps
    /// "exactly one at a time" airtight — clearing it here would open a poll-interval-wide window in which a
    /// second request could start and overwrite the answer the first is still waiting to read. The cost is
    /// that the prompt stays on screen for up to one poll interval after the tap, which is 50 ms.
    func answer(_ approved: Bool) {
        guard let pending else { return }
        recordedAnswer = (requestID: pending.id, approved: approved)
    }

    /// Refuses whatever is open.
    func declinePending() {
        answer(false)
    }

    /// Called when the prompt leaves the screen, from wherever that happened.
    ///
    /// This exists because of a bug it would otherwise cause. SwiftUI drives an alert's `isPresented`
    /// binding to `false` *after* running a button's action, so a setter that declined unconditionally would
    /// turn the user's "Do it" into a refusal a moment after they gave it — the exact inversion §34 is
    /// written to prevent, arriving through the dismissal path rather than the decision path. So a dismissal
    /// only refuses when no button answered first.
    func promptDismissed() {
        guard recordedAnswer == nil else { return }
        declinePending()
    }
}
