import Foundation
import KWWKAI

// MARK: - Tool call hooks

public struct BeforeToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: ToolCall
    public var args: JSONValue
    public var context: AgentContext
}

public struct BeforeToolCallResult: Sendable {
    public var block: Bool
    public var reason: String?
    /// Optional replacement for the tool's input args. When non-nil (and
    /// `block` is false), the tool receives these args instead of the
    /// ones the LLM emitted. Useful for auditing/sanitizing paths,
    /// redacting secrets, or expanding shorthand — the hook speaks the
    /// same JSON schema as the tool itself.
    public var modifiedArgs: JSONValue?
    public init(block: Bool = false, reason: String? = nil, modifiedArgs: JSONValue? = nil) {
        self.block = block
        self.reason = reason
        self.modifiedArgs = modifiedArgs
    }
}

public struct AfterToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: ToolCall
    public var args: JSONValue
    public var result: AgentToolResult
    public var isError: Bool
    public var context: AgentContext
}

public struct AfterToolCallResult: Sendable {
    public var content: [ToolResultBlock]?
    public var details: JSONValue?
    public var isError: Bool?
    public init(content: [ToolResultBlock]? = nil, details: JSONValue? = nil, isError: Bool? = nil) {
        self.content = content
        self.details = details
        self.isError = isError
    }
}

public typealias BeforeToolCallHook = @Sendable (BeforeToolCallContext, CancellationHandle?) async -> BeforeToolCallResult?
public typealias AfterToolCallHook = @Sendable (AfterToolCallContext, CancellationHandle?) async -> AfterToolCallResult?

// MARK: - User-prompt-submit hook

public struct UserPromptSubmitContext: Sendable {
    public var message: UserMessage
    public var context: AgentContext
}

public struct UserPromptSubmitResult: Sendable {
    /// When true, drop this user message entirely — it will NOT be
    /// appended to the transcript, and if this was the only prompt
    /// queued the run will end cleanly. `reason` is surfaced to the
    /// caller via the synthetic stop message.
    public var block: Bool
    public var reason: String?
    /// Optional replacement for the submitted user message. Use this
    /// to inject extra context (system preambles, redacted attachments,
    /// instructions from a policy engine) without the user seeing two
    /// versions of their prompt. `nil` means "leave the message as-is".
    public var modifiedMessage: UserMessage?

    public init(block: Bool = false, reason: String? = nil, modifiedMessage: UserMessage? = nil) {
        self.block = block
        self.reason = reason
        self.modifiedMessage = modifiedMessage
    }
}

/// Fires once per user message about to enter the transcript — that
/// covers the initial `agent.prompt()` call, steering injections, and
/// follow-up drains. Mirrors the SDK's `UserPromptSubmit` hook. Returning
/// nil leaves the message unchanged; returning a result with `block=true`
/// drops it; `modifiedMessage` rewrites it in place.
public typealias UserPromptSubmitHook = @Sendable (UserPromptSubmitContext, CancellationHandle?) async -> UserPromptSubmitResult?

/// Transform the message list the LLM sees. Return nil to reuse the default
/// pass-through behavior. Mirrors pi-agent-core's `convertToLlm` /
/// `transformContext` hooks combined — use `transformContext` for pruning
/// (AgentMessage→AgentMessage) and `convertToLlm` for projecting to LLM
/// messages.
public typealias ConvertToLlmHook = @Sendable ([Message]) async -> [Message]
public typealias TransformContextHook = @Sendable ([Message], CancellationHandle?) async -> [Message]

/// Fires at every sub-turn boundary — right after `turnEnd` emits, before
/// the loop decides whether to make another LLM call. Returning a non-nil
/// context replaces the loop's running transcript (and optionally tools /
/// system prompt) for the next iteration. Use this for auto-compaction
/// mid-run: when the hook summarizes the transcript, the next request
/// goes out with the compacted version instead of the full history.
///
/// The hook runs synchronously within the agent loop — long work here
/// (e.g. an LLM summarization call) blocks the next LLM call, which is
/// usually what you want for a compact: the loop pauses, UI reflects the
/// compacting state, user input queues via `steer`, and when the hook
/// returns the loop resumes with the new context.
public typealias BetweenTurnsHook = @Sendable (AgentContext, CancellationHandle?) async -> AgentContext?

/// Optional host policy at natural run completion, after queued messages drain.
/// Return runtime messages to continue the same run, or an empty array to finish.
/// Errors, cancellation and hard turn limits bypass this hook. Hosts must honor
/// cancellation and bound any waiting they perform here. Default: no policy.
public typealias BeforeRunEndHook = @Sendable (AgentContext, CancellationHandle?) async -> [Message]

public enum AgentContextCompactionTrigger: Sendable, Hashable {
    case preflight(pendingMessages: [Message])
    case proactive
    case providerOverflow
}

/// Internal control-plane hook used before provider requests and for one-shot
/// input-overflow recovery. Returning nil leaves the context unchanged.
public typealias ContextCompactionHook = @Sendable (
    AgentContext,
    AgentContextCompactionTrigger,
    CancellationHandle?
) async throws -> AgentContext?
