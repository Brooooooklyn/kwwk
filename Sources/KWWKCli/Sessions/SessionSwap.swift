import Foundation
import KWWKAI
import KWWKAgent

/// Owns the complete session-scoped coding runtime. An Agent's session id and
/// its bash/task/subagent tools are immutable by design, so a hot session switch
/// replaces this whole value rather than mutating transcript state in place.
@MainActor
final class AgentSessionBox {
    private(set) var codingAgent: CodingAgent
    var eventUnsubscribe: Unsubscribe?
    private(set) var generation: UInt64 = 0

    init(_ codingAgent: CodingAgent) {
        self.codingAgent = codingAgent
    }

    var agent: Agent { codingAgent.agent }
    var sessionId: String { agent.sessionId ?? "" }

    func replace(with replacement: CodingAgent) {
        codingAgent = replacement
        generation &+= 1
    }

    func isCurrent(agent expectedAgent: Agent, generation expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration && agent === expectedAgent
    }
}

/// Carry user/runtime preferences across a session replacement without
/// copying session-scoped tools, queues, listeners, messages, or background
/// attachments. Those are intentionally rebuilt for the new identity.
@MainActor
func copyAgentRuntimePreferences(from source: Agent, to destination: Agent) {
    destination.state.systemPrompt = source.state.systemPrompt
    destination.state.model = source.state.model
    destination.state.thinkingLevel = source.state.thinkingLevel
    destination.state.thinkingDisplay = source.state.thinkingDisplay
    destination.state.verboseEnabled = source.state.verboseEnabled
    destination.thinkingBudgets = source.thinkingBudgets
    destination.maxRetryDelayMs = source.maxRetryDelayMs
    destination.maxTurns = source.maxTurns
    destination.toolExecution = source.toolExecution
    destination.toolChoice = source.toolChoice
    destination.parallelToolCalls = source.parallelToolCalls
    destination.beforeToolCall = source.beforeToolCall
    destination.afterToolCall = source.afterToolCall
    destination.userPromptSubmit = source.userPromptSubmit
    destination.convertToLlm = source.convertToLlm
    destination.transformContext = source.transformContext
    destination.betweenTurns = source.betweenTurns
    destination.compactionModel = source.compactionModel
    destination.idleCompact = source.idleCompact
}

/// Mutable holder for the live session recorder + its agent subscription.
/// `/resume` swaps both to repoint persistence at the restored session file;
/// a reference type lets the resume closure mutate them without capturing a
/// `var` (rejected under Swift 6 strict concurrency).
@MainActor
final class RecorderBox {
    var recorder: SessionRecorder
    var unsubscribe: Unsubscribe
    var sessionId: String

    init(recorder: SessionRecorder, unsubscribe: @escaping Unsubscribe, sessionId: String) {
        self.recorder = recorder
        self.unsubscribe = unsubscribe
        self.sessionId = sessionId
    }
}

/// Reset the per-session transient state that must not survive a session swap
/// (`/new` or `/resume`): drain the steering queue, clear the `/retry` record,
/// drop outgoing attachments, and forget the Alt+↑ dequeue cursor. Shared by both
/// session-swap paths so neither leaks stale state into the incoming session
/// (e.g. a `failed`/`lastText` record that `/retry` would resubmit into the
/// wrong transcript). Does NOT touch `agent.state.messages` or the input
/// buffer — each caller manages those (clear vs. load).
@MainActor
func resetSessionTransientState(
    agent: Agent,
    retry: TurnRetryState,
    attachments: AttachmentStore,
    dequeueCycle: DequeueCycleState,
    discardingAttachments snapshot: AttachmentPromptSnapshot? = nil
) {
    agent.clearSteeringQueue()
    retry.clear()
    if let snapshot {
        attachments.consume(snapshot)
    } else {
        attachments.clear()
    }
    dequeueCycle.last = nil
}

/// Start a fresh, empty session in place: repoint persistence at a brand-new
/// session file, clear the live agent context + steering queue, reset retry and
/// attachment state, and commit a labeled separator to scrollback. A draft
/// composed while the async handoff is running belongs to the new session and
/// is preserved. This helper is extracted from the `/new` handler so the reset
/// is unit-testable.
@MainActor
func performNewSession(
    newId: String = UUID().uuidString,
    recorderBox: RecorderBox,
    sessionStore: SessionStore,
    agent: Agent,
    replaceSessionAgent: (@MainActor @Sendable (String, [Message]) async -> Agent)? = nil,
    cwd: String,
    attachments: AttachmentStore,
    retry: TurnRetryState,
    dequeueCycle: DequeueCycleState,
    frame: CodingFrame,
    width: Int,
    commit: ([String]) -> Void,
    recompute: () -> Void,
    updateStatus: () -> Void,
    requestRender: () -> Void
) async {
    let inputBeforeSwitch = frame.input.value
    let attachmentsBeforeSwitch = attachments.promptSnapshot(for: inputBeforeSwitch)

    // Stop the outgoing recorder before the runtime replacement so a late
    // callback cannot append to the new session file.
    recorderBox.unsubscribe()
    let sessionAgent: Agent
    if let replaceSessionAgent {
        sessionAgent = await replaceSessionAgent(newId, [])
    } else {
        // Retained for focused helper tests and embedders that don't own a
        // rebuild factory. The interactive TUI always supplies the factory.
        agent.state.messages = []
        sessionAgent = agent
    }
    let recorder = SessionRecorder(
        store: sessionStore,
        sessionId: newId,
        cwd: cwd,
        model: sessionAgent.state.model.id,
        provider: sessionAgent.state.model.provider,
        persistedCount: 0
    )
    await recorder.ensureCreated()
    recorderBox.recorder = recorder
    recorderBox.unsubscribe = recorder.attach(to: sessionAgent)
    recorderBox.sessionId = newId

    // Reset the live context. Native scrollback can't be cleared, so the prior
    // conversation stays above a labeled separator and the fresh session begins
    // below it.
    resetSessionTransientState(
        agent: sessionAgent,
        retry: retry,
        attachments: attachments,
        dequeueCycle: dequeueCycle,
        discardingAttachments: attachmentsBeforeSwitch
    )
    if frame.input.value == inputBeforeSwitch {
        frame.input.value = ""
    }

    commit([
        "",
        Theme.borderText(String(repeating: "─", count: max(8, width - 2))),
        Theme.accentText("✦ new session \(newId.prefix(8))", bold: false),
    ])

    recompute()
    updateStatus()
    requestRender()
}
