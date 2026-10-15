import Foundation
import KWWKAI

/// Events emitted by the agent runtime. Mirrors pi-agent-core's AgentEvent.
public enum AgentEvent: Sendable {
    case agentStart
    case agentEnd(messages: [Message], summary: AgentRunSummary)

    case turnStart
    case turnEnd(message: Message, toolResults: [ToolResultMessage])

    case messageStart(message: Message)
    case messageUpdate(message: AssistantMessage, assistantMessageEvent: AssistantMessageEvent)
    case messageEnd(message: Message)

    case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue)
    case toolExecutionUpdate(toolCallId: String, toolName: String, args: JSONValue, partialResult: AgentToolResult)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)
    case runtimeEvent(AgentRuntimeEvent)

    case compactStart(messagesCount: Int, usage: AgentContextUsage)
    case compactEnd(outcome: AgentContextCompactionOutcome)

    /// Emitted just before the agent loop sleeps to back off after a
    /// retryable stream failure. `attempt` is zero-indexed and counts the
    /// attempt that just failed (so `attempt: 0` means "first attempt failed,
    /// retry #1 scheduled"). `delayMs` is the upcoming sleep duration.
    case streamRetry(attempt: Int, delayMs: UInt64, reason: String)

    /// Emitted during retry to tell the UI to discard any in-progress live
    /// render for the current turn. The agent loop live-streams events so
    /// the user sees tokens as they arrive; when a retryable error kills
    /// the stream mid-flight, the partial text is no longer truthful and
    /// the renderer must reset (not commit). The retried stream then
    /// produces a fresh `messageStart` + updates.
    case streamRewind

    /// Diagnostic event emitted only when verbose mode is enabled.
    case verbose(VerboseEvent)

    public var type: String {
        switch self {
        case .agentStart: return "agent_start"
        case .agentEnd: return "agent_end"
        case .turnStart: return "turn_start"
        case .turnEnd: return "turn_end"
        case .messageStart: return "message_start"
        case .messageUpdate: return "message_update"
        case .messageEnd: return "message_end"
        case .toolExecutionStart: return "tool_execution_start"
        case .toolExecutionUpdate: return "tool_execution_update"
        case .toolExecutionEnd: return "tool_execution_end"
        case .runtimeEvent(let event): return event.type
        case .compactStart: return "compact_start"
        case .compactEnd: return "compact_end"
        case .streamRetry: return "stream_retry"
        case .streamRewind: return "stream_rewind"
        case .verbose: return "verbose"
        }
    }
}
