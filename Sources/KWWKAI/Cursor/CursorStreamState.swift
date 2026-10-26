import Foundation
import NIOConcurrencyHelpers

/// Accumulates the assistant message as Cursor `InteractionUpdate`s arrive and
/// emits the corresponding `AssistantMessageEvent`s. Text, thinking, and tool
/// calls open/close as interleaved blocks, matching oh-my-pi's streaming state
/// machine: a new block is opened whenever a delta arrives with no block of
/// that kind currently open, and starting a tool call closes any open text or
/// thinking block.
final class CursorStreamState: Sendable {
    private let api: String
    private let model: Model
    private struct State {
        var blocks: [AssistantBlock] = []
        var textIndex: Int?
        var thinkingIndex: Int?

        var toolCallIndex: Int?
        /// Cumulative JSON-text snapshot of the streaming MCP args so far.
        var toolCallArgsBuffer = ""
        /// Whether the open tool call streams MCP args (todo blocks don't).
        var toolCallIsMcp = false

        var outputTokens = 0
        var sawTokenDelta = false
        /// What the turn's TurnEndedUpdate said it used; wins over the
        /// delta/checkpoint estimate when present. A step that ends on a tool
        /// call gets none, so the estimate stays the fallback.
        var turnUsage: Usage?
        var stopReason: StopReason = .stop
        /// Field numbers of the interaction updates and server messages this
        /// provider does not read, with how often each came: an empty reply
        /// names them, so a report says what was not understood.
        var unreadUpdates: [Int: Int] = [:]
        var unreadMessages: [Int: Int] = [:]
    }
    private let state = NIOLockedValueBox(State())

    init(api: String, model: Model) {
        self.api = api
        self.model = model
    }

    // MARK: - Text / thinking

    func appendText(_ delta: String, emit: (AssistantMessageEvent) -> Void) {
        let (index, isNew): (Int, Bool) = state.withLockedValue { state in
            if let idx = state.textIndex { return (idx, false) }
            let idx = state.blocks.count
            state.textIndex = idx
            state.blocks.append(.text(TextContent(text: "")))
            return (idx, true)
        }
        if isNew {
            emit(.textStart(contentIndex: index, partial: snapshot()))
        }
        state.withLockedValue { state in
            if case .text(var t) = state.blocks[index] {
                t.text += delta
                state.blocks[index] = .text(t)
            }
        }
        emit(.textDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    func appendThinking(_ delta: String, emit: (AssistantMessageEvent) -> Void) {
        let (index, isNew): (Int, Bool) = state.withLockedValue { state in
            if let idx = state.thinkingIndex { return (idx, false) }
            let idx = state.blocks.count
            state.thinkingIndex = idx
            state.blocks.append(.thinking(ThinkingContent(thinking: "")))
            return (idx, true)
        }
        if isNew {
            emit(.thinkingStart(contentIndex: index, partial: snapshot()))
        }
        state.withLockedValue { state in
            if case .thinking(var t) = state.blocks[index] {
                t.thinking += delta
                state.blocks[index] = .thinking(t)
            }
        }
        emit(.thinkingDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    func endText(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = state.withLockedValue { state in
            guard let idx = state.textIndex, case .text(let t) = state.blocks[idx] else { return nil }
            state.textIndex = nil
            return (idx, t.text)
        }
        if let (index, content) = closed {
            emit(.textEnd(contentIndex: index, content: content, partial: snapshot()))
        }
    }

    func endThinking(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = state.withLockedValue { state in
            guard let idx = state.thinkingIndex, case .thinking(let t) = state.blocks[idx] else { return nil }
            state.thinkingIndex = nil
            return (idx, t.thinking)
        }
        if let (index, content) = closed {
            emit(.thinkingEnd(contentIndex: index, content: content, partial: snapshot()))
        }
    }

    // MARK: - Tool calls

    /// Open a streaming MCP tool-call block (`tool_call_started` with an
    /// `mcp_tool_call`). Args accumulate via `args_text_delta` snapshots until
    /// `completeToolCall`.
    func startMcpToolCall(id: String, name: String, emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        endThinking(emit: emit)
        let index: Int = state.withLockedValue { state in
            let idx = state.blocks.count
            state.toolCallIndex = idx
            state.toolCallArgsBuffer = ""
            state.toolCallIsMcp = true
            state.blocks.append(.toolCall(ToolCall(id: id, name: name, arguments: .object([:]))))
            return idx
        }
        emit(.toolCallStart(contentIndex: index, partial: snapshot()))
    }

    /// Open a todo tool-call block (Cursor's server-native todo tool). The
    /// server already applied the update, so the block is marked resolved.
    func startTodoToolCall(id: String, arguments: JSONValue, emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        endThinking(emit: emit)
        let index: Int = state.withLockedValue { state in
            let idx = state.blocks.count
            state.toolCallIndex = idx
            state.toolCallArgsBuffer = ""
            state.toolCallIsMcp = false
            state.blocks.append(.toolCall(ToolCall(
                id: id,
                name: "todo",
                arguments: arguments,
                cursorExecResolved: true
            )))
            return idx
        }
        emit(.toolCallStart(contentIndex: index, partial: snapshot()))
    }

    /// Apply a cumulative `args_text_delta` snapshot: strip the prefix we
    /// already have and emit only the new suffix (falling back to treating a
    /// non-extending snapshot as an incremental fragment, like oh-my-pi).
    func appendToolCallArgs(snapshot argsSnapshot: String, emit: (AssistantMessageEvent) -> Void) {
        let update: (index: Int, chunk: String)? = state.withLockedValue { state in
            guard let idx = state.toolCallIndex, state.toolCallIsMcp else { return nil }
            let chunk = argsSnapshot.hasPrefix(state.toolCallArgsBuffer)
                ? String(argsSnapshot.dropFirst(state.toolCallArgsBuffer.count))
                : argsSnapshot
            guard !chunk.isEmpty else { return nil }
            state.toolCallArgsBuffer += chunk
            return (idx, chunk)
        }
        if let (index, chunk) = update {
            emit(.toolCallDelta(contentIndex: index, delta: chunk, partial: snapshot()))
        }
    }

    /// Close the open tool-call block. The accumulated JSON-text buffer is the
    /// primary source of args; `completionArgs` (decoded from the completion
    /// frame's `McpArgs` map) fills in per-key, except where the completion
    /// downgraded a structured streamed value to a raw string.
    func completeToolCall(completionArgs: JSONValue?, emit: (AssistantMessageEvent) -> Void) {
        let completed: (index: Int, call: ToolCall)? = state.withLockedValue { state in
            guard let idx = state.toolCallIndex, case .toolCall(var call) = state.blocks[idx] else { return nil }
            if state.toolCallIsMcp {
                let streamed = (try? JSONDecoder().decode(
                    JSONValue.self,
                    from: Data(state.toolCallArgsBuffer.utf8)
                )) ?? JSONValue.object([:])
                call.arguments = Self.mergeMcpArgs(streamed: streamed, completion: completionArgs)
            } else if let completionArgs {
                call.arguments = completionArgs
            }
            state.blocks[idx] = .toolCall(call)
            state.toolCallIndex = nil
            state.toolCallArgsBuffer = ""
            return (idx, call)
        }
        if let (index, call) = completed {
            emit(.toolCallEnd(contentIndex: index, toolCall: call, partial: snapshot()))
        }
    }

    /// Append a completed `toolCall` block for a tool the provider already
    /// executed over the exec channel (native bridge, or an MCP exec without a
    /// matching streamed block). Marked resolved so the agent loop skips it.
    ///
    /// Cursor sends one tool call id on every exec of a single tool (an edit
    /// reads the file, then writes it), so an id already in this message is
    /// taken as `<id>_<n>`, the lowest free `n`. Returns the id the block
    /// got; the exec runs under it so its result pairs with this block.
    @discardableResult
    func synthesizeResolvedToolCall(
        id: String,
        name: String,
        arguments: JSONValue,
        emit: (AssistantMessageEvent) -> Void
    ) -> String {
        endText(emit: emit)
        endThinking(emit: emit)
        let (index, call): (Int, ToolCall) = state.withLockedValue { state in
            let used = Set(state.blocks.compactMap { block -> String? in
                if case .toolCall(let call) = block { return call.id }
                return nil
            })
            var id = id
            if used.contains(id) {
                var n = 2
                while used.contains("\(id)_\(n)") { n += 1 }
                id = "\(id)_\(n)"
            }
            let call = ToolCall(id: id, name: name, arguments: arguments, cursorExecResolved: true)
            state.blocks.append(.toolCall(call))
            return (state.blocks.count - 1, call)
        }
        emit(.toolCallStart(contentIndex: index, partial: snapshot()))
        emit(.toolCallEnd(contentIndex: index, toolCall: call, partial: snapshot()))
        return call.id
    }

    /// Mark the tool-call block with `id` as resolved (the provider executed it
    /// inline via the exec channel). Returns whether a block matched.
    func markToolCallResolved(id: String) -> Bool {
        state.withLockedValue { state in
            for (idx, block) in state.blocks.enumerated() {
                guard case .toolCall(var call) = block, call.id == id else { continue }
                call.cursorExecResolved = true
                state.blocks[idx] = .toolCall(call)
                return true
            }
            return false
        }
    }

    /// Merge completion-frame args into streamed args per key: absent → keep
    /// streamed; string over structured → keep streamed (the completion frame
    /// downgraded it); otherwise completion wins.
    static func mergeMcpArgs(streamed: JSONValue, completion: JSONValue?) -> JSONValue {
        guard case .object(let completionObj)? = completion else { return streamed }
        guard case .object(var merged) = streamed else {
            return completion ?? streamed
        }
        for (key, value) in completionObj {
            if case .string = value {
                switch merged[key] {
                case .object, .array: continue
                default: break
                }
            }
            merged[key] = value
        }
        return .object(merged)
    }

    // MARK: - Usage

    func addOutputTokens(_ tokens: Int) {
        state.withLockedValue { state in
            state.sawTokenDelta = true
            state.outputTokens += tokens
        }
    }

    /// Conversation-wide `used_tokens` from a checkpoint. Only a fallback for
    /// when the stream carried no `token_delta` updates — it measures total
    /// context occupancy, not this turn's output, so it must never override
    /// delta-accumulated counts.
    func applyCheckpointUsedTokens(_ used: Int) {
        state.withLockedValue { state in
            guard !state.sawTokenDelta, used > 0 else { return }
            state.outputTokens = used
        }
    }

    /// Cursor counts `input` as the whole prompt, cache reads and writes
    /// included; kwwk's `input` is the uncached rest, as every other provider
    /// reports it.
    func applyTurnEnded(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int) {
        guard input > 0 || output > 0 else { return }
        state.withLockedValue { state in
            state.turnUsage = Usage(
                input: max(input - cacheRead - cacheWrite, 0),
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning
            )
        }
    }

    // MARK: - Empty replies

    func noteUnread(update number: Int) {
        state.withLockedValue { $0.unreadUpdates[number, default: 0] += 1 }
    }

    func noteUnread(message number: Int) {
        state.withLockedValue { $0.unreadMessages[number, default: 0] += 1 }
    }

    /// A turn that ends having written no text and made no tool call is an
    /// empty reply, not a finished turn: the failure to ask again on, nil
    /// when there is a reply. Cursor ends some turns on thinking alone
    /// (magpie's cursor plugin #11; #60 counted 14 on grok-4.7-fast in a
    /// week), and finished as a turn that is a silent, blank answer. The
    /// words name what did come, as the plugin's do (`emptyWhy`,
    /// conversation.test.mjs), so the causes can be told apart: `how` the
    /// Run ended, the thinking, Cursor's own count of output when it gave
    /// one, and what Cursor sent that is not read (agent.v1 field numbers).
    func emptyReplyFailure(how: String) -> ProviderFailure? {
        state.withLockedValue { state in
            var thinking = 0
            for block in state.blocks {
                switch block {
                case .text(let t):
                    if !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                case .thinking(let t):
                    thinking += t.thinking.count
                default:
                    return nil
                }
            }
            func list(_ counts: [Int: Int]) -> String {
                counts.sorted { $0.key < $1.key }
                    .map { $0.value > 1 ? "#\($0.key) ×\($0.value)" : "#\($0.key)" }
                    .joined(separator: ", ")
            }
            var parts = [how]
            parts.append(thinking > 0
                ? "after \(thinking) chars of thinking, no text and no tool call"
                : "with no thinking, no text and no tool call")
            if let turnUsage = state.turnUsage { parts.append("Cursor counted \(turnUsage.output) output tokens") }
            if !state.unreadUpdates.isEmpty { parts.append("updates not read: \(list(state.unreadUpdates))") }
            if !state.unreadMessages.isEmpty { parts.append("messages not read: \(list(state.unreadMessages))") }
            return ProviderFailure(
                message: "Cursor sent an empty reply (\(parts.joined(separator: "; ")))",
                shouldRetry: true
            )
        }
    }

    // MARK: - Finalization

    /// Emit end events for any blocks still open at end of stream.
    func closeOpenBlocks(emit: (AssistantMessageEvent) -> Void) {
        completeToolCall(completionArgs: nil, emit: emit)
        endThinking(emit: emit)
        endText(emit: emit)
    }

    func snapshot() -> AssistantMessage {
        state.withLockedValue { state in
            AssistantMessage(
                content: state.blocks,
                api: api,
                provider: model.provider,
                model: model.id,
                usage: usageLocked(state),
                stopReason: state.stopReason,
                timestamp: Timestamp.now()
            )
        }
    }

    func finalize() -> AssistantMessage {
        snapshot()
    }

    func aborted() -> AssistantMessage {
        state.withLockedValue { $0.stopReason = .aborted }
        var m = finalize()
        m.errorMessage = "Request was aborted"
        return m
    }

    private func usageLocked(_ state: State) -> Usage {
        var usage = state.turnUsage ?? Usage(output: state.outputTokens)
        usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
        usage.cost = calculateCost(model: model, usage: usage)
        return usage
    }
}
