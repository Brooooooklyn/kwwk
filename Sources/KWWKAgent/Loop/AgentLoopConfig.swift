import Foundation
import KWWKAI

/// Configuration for one invocation of the agent loop. Mirrors a subset of
/// pi-agent-core's AgentLoopConfig — the fields we currently wire through.
public struct AgentLoopConfig: Sendable {
    public var model: Model
    public var reasoning: ReasoningLevel?
    public var thinkingBudgets: ThinkingBudgets?
    public var sessionId: String?
    /// Workspace root reported to providers with a server-driven harness
    /// (Cursor's requestContext env). Nil = don't report one.
    public var cwd: String?
    public var verboseEnabled: Bool
    public var maxRetryDelayMs: Int?
    public var toolExecution: ToolExecutionMode
    public var toolChoice: ToolChoice?
    public var parallelToolCalls: Bool?
    // Hard ceiling on assistant turns per run. Mirrors the SDK's
    // `max_turns` — prevents runaway tool-loops from burning budget.
    // Nil = unlimited.
    public var maxTurns: Int?
    /// Internal subagent mode: reserve the last permitted provider turn for
    /// synthesis by hiding tools and requiring a text response. The ordinary
    /// Agent SDK keeps its existing hard-cap behavior unless explicitly
    /// enabled by the subagent runner.
    var finalTextOnlyOnLastTurn: Bool = false
    /// Internal completion contract used by subagents. A successful call to
    /// this tool is the only terminal success signal. Natural provider stops
    /// receive bounded runtime reminders instead of being mistaken for a
    /// completed delegated task.
    var terminalToolName: String?
    var terminalToolReminderLimit: Int = 0
    /// Streamed assistant output reaches a sink that cannot take it back, so an
    /// attempt that streamed text or tool-call blocks counts as having a side
    /// effect and is not retried. Default false: such output is discarded with
    /// `streamRewind` and the attempt is retried within the provider budget.
    public var streamsToIrreversibleSink: Bool = false
    // Base delay for exponential backoff between stream retries. Prod
    // defaults to 1_000 ms; tests override to something small.
    public var retryBaseDelayMs: UInt64
    public var getRuntimeMessages: @Sendable () async -> [Message]
    public var getSteeringMessages: @Sendable () async -> [Message]
    public var hasSteeringMessages: @Sendable () -> Bool
    public var getFollowUpMessages: @Sendable () async -> [Message]
    public var authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
    public var beforeToolCall: BeforeToolCallHook?
    public var afterToolCall: AfterToolCallHook?
    public var userPromptSubmit: UserPromptSubmitHook?
    public var convertToLlm: ConvertToLlmHook?
    public var transformContext: TransformContextHook?
    public var betweenTurns: BetweenTurnsHook?
    public var beforeRunEnd: BeforeRunEndHook?
    public var contextCompaction: ContextCompactionHook?
    /// Live tool set, read after every turn so tools activated mid-run
    /// (e.g. by `tool_search`) are declared on the next request. Nil keeps
    /// the tools the run started with.
    public var currentTools: (@Sendable () -> [AgentTool])?

    public init(
        model: Model,
        reasoning: ReasoningLevel? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        sessionId: String? = nil,
        cwd: String? = nil,
        verboseEnabled: Bool = false,
        maxRetryDelayMs: Int? = nil,
        toolExecution: ToolExecutionMode = .parallel,
        toolChoice: ToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        maxTurns: Int? = nil,
        retryBaseDelayMs: UInt64 = 1_000,
        getRuntimeMessages: @escaping @Sendable () async -> [Message] = { [] },
        getSteeringMessages: @escaping @Sendable () async -> [Message] = { [] },
        hasSteeringMessages: @escaping @Sendable () -> Bool = { false },
        getFollowUpMessages: @escaping @Sendable () async -> [Message] = { [] },
        authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil,
        beforeToolCall: BeforeToolCallHook? = nil,
        afterToolCall: AfterToolCallHook? = nil,
        userPromptSubmit: UserPromptSubmitHook? = nil,
        convertToLlm: ConvertToLlmHook? = nil,
        transformContext: TransformContextHook? = nil,
        betweenTurns: BetweenTurnsHook? = nil,
        beforeRunEnd: BeforeRunEndHook? = nil,
        contextCompaction: ContextCompactionHook? = nil
    ) {
        self.model = model
        self.reasoning = reasoning
        self.thinkingBudgets = thinkingBudgets
        self.sessionId = sessionId
        self.cwd = cwd
        self.verboseEnabled = verboseEnabled
        self.maxRetryDelayMs = maxRetryDelayMs
        self.toolExecution = toolExecution
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.maxTurns = maxTurns
        self.retryBaseDelayMs = retryBaseDelayMs
        self.getRuntimeMessages = getRuntimeMessages
        self.getSteeringMessages = getSteeringMessages
        self.hasSteeringMessages = hasSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
        self.authResolver = authResolver
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.userPromptSubmit = userPromptSubmit
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.betweenTurns = betweenTurns
        self.beforeRunEnd = beforeRunEnd
        self.contextCompaction = contextCompaction
    }
}
