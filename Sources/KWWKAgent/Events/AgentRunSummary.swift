import Foundation
import KWWKAI

/// Per-run aggregate surfaced on `agentEnd`. Mirrors the SDK's
/// `ResultMessage` — consumers (TUI, cost dashboards, audit logs) can
/// read this once at the end of a run instead of re-deriving totals
/// from the message delta.
public struct AgentRunSummary: Sendable {
    /// Number of assistant turns that actually streamed in this run.
    /// Zero if the run was capped out before any request fired.
    public var turns: Int
    /// Summed token counts across every assistant message in this run.
    /// `totalTokens` is the provider-reported sum where available,
    /// otherwise the naive `input + output`.
    public var usage: Usage
    /// USD cost derived from `usage` and the configured model's
    /// per-1M-token pricing. Zero for models without cost metadata.
    public var cost: Cost
    /// Wall-clock duration from `agentStart` to `agentEnd`, in ms.
    public var durationMs: Int
    /// Stop reason of the final assistant message in this run.
    /// `.stop` for normal completion, `.aborted` on user cancel,
    /// `.error` on retries-exhausted / turn-cap / synthetic failures,
    /// or the provider's native reason. Nil if the run emitted no
    /// assistant messages at all.
    public var finalStopReason: StopReason?
    /// True only when the loop itself synthesized the max-turn terminal
    /// message. This keeps downstream failure classification independent of
    /// provider/localized error text.
    public var reachedMaxTurns: Bool
    /// Subagent invocations observed during this run. Foreground subagents
    /// carry final usage; background subagents are recorded at spawn time and
    /// report completion through background-task notifications.
    public var subagents: [SubagentRunSummary]

    public init(
        turns: Int = 0,
        usage: Usage = Usage(),
        cost: Cost = Cost(),
        durationMs: Int = 0,
        finalStopReason: StopReason? = nil,
        reachedMaxTurns: Bool = false,
        subagents: [SubagentRunSummary] = []
    ) {
        self.turns = turns
        self.usage = usage
        self.cost = cost
        self.durationMs = durationMs
        self.finalStopReason = finalStopReason
        self.reachedMaxTurns = reachedMaxTurns
        self.subagents = subagents
    }
}

public enum SubagentRunStatus: String, Sendable, Hashable {
    case completed
    case backgroundStarted = "background_started"
    case failed
}

public struct SubagentRunSummary: Sendable, Hashable {
    public var subagentType: String
    public var childSessionId: String?
    public var description: String?
    public var status: SubagentRunStatus
    public var model: String?
    public var stopReason: StopReason?
    public var usage: Usage?
    public var turns: Int?
    public var cost: Cost?
    public var durationMs: Int?
    public var backgroundTaskId: String?
    public var outputFile: String?
    public var errorMessage: String?

    public init(
        subagentType: String,
        childSessionId: String? = nil,
        description: String? = nil,
        status: SubagentRunStatus,
        model: String? = nil,
        stopReason: StopReason? = nil,
        usage: Usage? = nil,
        turns: Int? = nil,
        cost: Cost? = nil,
        durationMs: Int? = nil,
        backgroundTaskId: String? = nil,
        outputFile: String? = nil,
        errorMessage: String? = nil
    ) {
        self.subagentType = subagentType
        self.childSessionId = childSessionId
        self.description = description
        self.status = status
        self.model = model
        self.stopReason = stopReason
        self.usage = usage
        self.turns = turns
        self.cost = cost
        self.durationMs = durationMs
        self.backgroundTaskId = backgroundTaskId
        self.outputFile = outputFile
        self.errorMessage = errorMessage
    }
}
