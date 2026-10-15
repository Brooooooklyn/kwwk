import Foundation
import KWWKAI
import KWWKAgent

/// Run the shared compact flow: plan a tool-safe cut, iteratively update the
/// durable summary, retain the recent raw tail, attach deterministic file and
/// running-task facts, then revision-check the projected replacement. Returns
/// the outcome; never surfaces anything to the UI itself.
///
/// Used by the manual `/compact` slash command. The automatic path uses
/// the same KWWKAgent compactor directly from `Agent`, so every agent
/// entry point shares one bottom-layer behavior.
@MainActor
func performCompact(
    agent: Agent,
    backgroundManager: BackgroundTaskManager,
    sessionId: String,
    settle: @escaping @MainActor @Sendable (AgentContextCompactionOutcome) async -> Void = { _ in }
) async -> AgentContextCompactionOutcome {
    if agent.state.isStreaming {
        let outcome = AgentContextCompactionOutcome.refusedAgentBusy
        await settle(outcome)
        return outcome
    }
    let compact: @Sendable (CancellationHandle?) async -> AgentContextCompactionOutcome = { cancellation in
        await AgentContextCompactor.compactAgent(
            agent: agent,
            backgroundManager: backgroundManager,
            sessionId: sessionId,
            config: agent.autoCompact?.config ?? AgentContextCompactionConfig(),
            // `withMaintenance` is the authoritative ownership guard. Skip
            // the secondary streaming check while that ownership is held.
            ignoreStreaming: true,
            cancellation: cancellation
        )
    }

    let outcome: AgentContextCompactionOutcome
    do {
        outcome = try await agent.withMaintenance { cancellation in
            let outcome = await compact(cancellation)
            // Settlement is part of the maintenance transaction. In
            // particular, background-delivery idle waiters are not resumed
            // until the compacted projection is durable and its UI boundary
            // has been committed.
            await settle(outcome)
            return outcome
        }
    } catch AgentError.alreadyRunning {
        outcome = .refusedAgentBusy
        await settle(outcome)
    } catch {
        outcome = .failed("\(error)")
        await settle(outcome)
    }

    return outcome
}

/// Render a dimmed, full-width boundary marker that sits in scrollback
/// to show the user "everything above this line was summarized". Used
/// by both `/compact` and the auto-compact driver so the two paths
/// leave an identical visual trail.
///
/// Returns three lines (leading blank, rule, trailing blank) so callers
/// can hand them straight to `TUI.commit(_:)`.
func renderCompactBoundary(messagesCompacted: Int, hasRunningTasksLedger: Bool, width: Int) -> [String] {
    var label = "compacted"
    if hasRunningTasksLedger { label += " (+ running-task ledger)" }
    let prefix = "── "
    let spacedLabel = " \(label) "
    let overhead = prefix.count + spacedLabel.count
    let fill = max(3, width - overhead)
    let rule = Style.dimmed(prefix + spacedLabel + String(repeating: "─", count: fill))
    return ["", rule, ""]
}
