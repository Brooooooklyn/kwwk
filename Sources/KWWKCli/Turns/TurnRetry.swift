import Foundation
import KWWKAI
import KWWKAgent

/// Tracks the most recent prompt submission so `/retry` can resubmit it when
/// the turn ended in error or was interrupted. A reference type so the submit
/// path, the failure edges (catch / Esc-abort), and the `/retry` handler all
/// share one mutable record under Swift 6 strict concurrency.
@MainActor
final class TurnRetryState {
    /// The built prompt text of the last submission (already attachment-expanded).
    var lastText: String?
    /// The built image attachments of the last submission.
    var lastImages: [ImageContent] = []
    /// True when the last turn ended in error or was aborted — the only state
    /// in which `/retry` resubmits.
    var failed = false
    /// True while a user-initiated turn (direct submit or steer) is in flight
    /// and eligible for `/retry`. Command-driven prompts (`/init`, custom
    /// commands) never set this, so a failure on one of those internal turns
    /// can't arm `/retry` with a stale internal prompt. Consumed (reset to
    /// false) at every `.agentEnd` and on Esc-abort.
    var trackedActive = false

    func clear() {
        lastText = nil
        lastImages.removeAll(keepingCapacity: false)
        failed = false
        trackedActive = false
    }
}

/// Whether a finished run should be marked retryable for `/retry`: true when it
/// ended in a hard error (retries exhausted / turn cap / synthetic failure) or
/// was aborted by the user. This is the authoritative failure signal — genuine
/// failures return normally from `agent.prompt()` and surface only as an
/// `.agentEnd` whose `summary.finalStopReason` is `.error` / `.aborted`.
func turnEndedRetryable(_ summary: AgentRunSummary) -> Bool {
    summary.finalStopReason == .error || summary.finalStopReason == .aborted
}

/// Derive the `/retry` target for a just-finished (or just-aborted) turn, or
/// `nil` when the turn must not arm `/retry`. Two gates must both hold:
///
///   1. The turn is *retryable*: it was aborted by the user (`aborted`), or its
///      `summary.finalStopReason` is `.error` / `.aborted` (see
///      `turnEndedRetryable`).
///   2. The turn was *user-initiated*: `trackedActive` is true. Command-driven
///      turns (`/init`, custom commands) never set it, so a failed internal
///      prompt can't leak into `/retry`.
///
/// When both hold, the target is derived from the LAST `.user` message actually
/// in `messages` — the message the agent was executing — so a direct submit, a
/// steered follow-up, or a `/retry` resubmit all resolve to the real prompt in
/// flight rather than any separately-recorded copy. Text is the message's
/// `.text` blocks joined with newlines; images are its `.image` blocks.
@MainActor
func retryArmTarget(
    summary: AgentRunSummary?,
    aborted: Bool,
    trackedActive: Bool,
    messages: [Message]
) -> (text: String, images: [ImageContent])? {
    guard trackedActive else { return nil }
    let retryable = aborted || (summary.map(turnEndedRetryable) ?? false)
    guard retryable else { return nil }
    guard let last = messages.last(where: { if case .user = $0 { return true } else { return false } }),
          case .user(let u) = last else { return nil }
    let text = u.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined(separator: "\n")
    let images = u.content.compactMap { block -> ImageContent? in
        if case .image(let i) = block { return i }
        return nil
    }
    return (text: text, images: images)
}
