import Foundation
import KWWKAI

/// Thinking/reasoning level passed to the model on each turn.
public enum ThinkingLevel: String, Sendable, Hashable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
}

/// How the transcript UI should surface assistant thinking blocks. Orthogonal
/// to `ThinkingLevel` (which controls what the provider is asked to
/// produce) — this is purely a display preference.
///
///  - `collapsed` (default): show a one-line marker with elapsed time —
///    `[thinking 2s…]` while in progress, `[thought for 3.4s]` once done.
///    Tidier, keeps focus on the answer.
///  - `expanded`: show the full thinking body dimmed inline.
public enum ThinkingDisplay: String, Sendable, Hashable {
    case collapsed
    case expanded
}

/// Streaming function used by the agent loop. Implementations must encode all
/// failures as stream events ending in an assistant message with stopReason
/// `.error` or `.aborted` — never throw.
public typealias StreamFn = @Sendable (Model, Context, StreamOptions?) async throws -> AssistantMessageStream

internal struct StructuredToolExecutionError: LocalizedError, @unchecked Sendable {
    let message: String
    /// Optional model-facing content when the concise error message is not
    /// enough. Callers use this for explicitly delimited, untrusted salvage
    /// evidence without making that evidence part of `errorDescription` or UI
    /// chrome.
    let content: [ToolResultBlock]?
    let details: JSONValue?
    let runtimeEvents: [AgentRuntimeEvent]?

    var errorDescription: String? { message }

    init(
        message: String,
        content: [ToolResultBlock]? = nil,
        details: JSONValue? = nil,
        runtimeEvents: [AgentRuntimeEvent]? = nil
    ) {
        self.message = message
        self.content = content
        self.details = details
        self.runtimeEvents = runtimeEvents
    }
}

public enum ToolExecutionMode: String, Sendable { case sequential, parallel }

/// How queued steering/follow-up messages are drained between turns.
public enum QueueMode: String, Sendable { case oneAtATime, all }
