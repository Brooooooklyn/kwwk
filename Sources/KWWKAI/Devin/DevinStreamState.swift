import Foundation

// MARK: - Stream state

/// Accumulates the assistant message from `GetChatMessageResponse` deltas and
/// emits the matching `AssistantMessageEvent`s.
final class DevinStreamState: @unchecked Sendable {
    private let api: String
    private let model: Model
    private let lock = NSLock()

    private var blocks: [AssistantBlock] = []
    private var textIndex: Int?
    private var thinkingIndex: Int?
    /// Tool-call block index + accumulated JSON args, keyed by call id.
    private var toolIndexById: [String: Int] = [:]
    private var toolArgs: [String: String] = [:]
    private var toolOrder: [String] = []
    private var activeToolCallId: String?
    /// Ids given here to calls Devin opened without one.
    private var mintedToolCallIds: Set<String> = []
    private var responseId: String?
    private var responseModel: String?
    private var lastStopReason: UInt64 = DevinProto.StopReason.unspecified
    private var usage = Usage()
    private var stopReasonOverride: StopReason?

    init(api: String, model: Model) {
        self.api = api
        self.model = model
    }

    func setResponseModel(_ uid: String) {
        lock.withLock { responseModel = uid }
    }

    func apply(_ msg: DevinProto.GetChatMessageResponse, emit: (AssistantMessageEvent) -> Void) {
        lock.withLock {
            if !msg.messageId.isEmpty, responseId == nil { responseId = msg.messageId }
            if let actual = msg.actualModelUid, !actual.isEmpty { responseModel = actual }
            if msg.stopReason != DevinProto.StopReason.unspecified { lastStopReason = msg.stopReason }
            if let u = msg.usage {
                usage.input = Int(u.inputTokens)
                usage.output = Int(u.outputTokens)
                usage.cacheRead = Int(u.cacheReadTokens)
                usage.cacheWrite = Int(u.cacheWriteTokens)
                usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
            }
        }
        if !msg.deltaThinking.isEmpty {
            endText(emit: emit)
            appendThinking(msg.deltaThinking, signature: msg.deltaSignature, emit: emit)
        } else if !msg.deltaSignature.isEmpty {
            // Devin's Claude models send the signature in a frame of its own
            // after the last thinking delta and before the text (measured
            // 2026-10-11 on Opus 5: 700 bytes in field 10, no field 9).
            // Replayed with it, the thinking is kept; without, Devin drops it.
            lock.withLock {
                let index = thinkingIndex ?? blocks.lastIndex { if case .thinking = $0 { return true }; return false }
                if let index, case .thinking(var t) = blocks[index] {
                    t.thinkingSignature = msg.deltaSignature
                    blocks[index] = .thinking(t)
                }
            }
        }
        if !msg.deltaText.isEmpty {
            endThinking(emit: emit)
            appendText(msg.deltaText, emit: emit)
        }
        if !msg.deltaToolCalls.isEmpty {
            endText(emit: emit)
            endThinking(emit: emit)
            for call in msg.deltaToolCalls { applyToolDelta(call, emit: emit) }
        }
    }

    private func appendText(_ delta: String, emit: (AssistantMessageEvent) -> Void) {
        let (index, isNew): (Int, Bool) = lock.withLock {
            if let idx = textIndex { return (idx, false) }
            blocks.append(.text(TextContent(text: "")))
            textIndex = blocks.count - 1
            return (blocks.count - 1, true)
        }
        if isNew { emit(.textStart(contentIndex: index, partial: snapshot())) }
        lock.withLock {
            if case .text(var t) = blocks[index] { t.text += delta; blocks[index] = .text(t) }
        }
        emit(.textDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    private func appendThinking(_ delta: String, signature: String, emit: (AssistantMessageEvent) -> Void) {
        let (index, isNew): (Int, Bool) = lock.withLock {
            if let idx = thinkingIndex { return (idx, false) }
            blocks.append(.thinking(ThinkingContent(thinking: "")))
            thinkingIndex = blocks.count - 1
            return (blocks.count - 1, true)
        }
        if isNew { emit(.thinkingStart(contentIndex: index, partial: snapshot())) }
        lock.withLock {
            if case .thinking(var t) = blocks[index] {
                t.thinking += delta
                if !signature.isEmpty { t.thinkingSignature = signature }
                blocks[index] = .thinking(t)
            }
        }
        emit(.thinkingDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    private func endText(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = lock.withLock {
            guard let idx = textIndex, case .text(let t) = blocks[idx] else { return nil }
            textIndex = nil
            return (idx, t.text)
        }
        if let (index, content) = closed { emit(.textEnd(contentIndex: index, content: content, partial: snapshot())) }
    }

    private func endThinking(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = lock.withLock {
            guard let idx = thinkingIndex, case .thinking(let t) = blocks[idx] else { return nil }
            thinkingIndex = nil
            return (idx, t.thinking)
        }
        if let (index, content) = closed {
            emit(.thinkingEnd(contentIndex: index, content: content, partial: snapshot()))
        }
    }

    /// Tool-call deltas carry the call id on the first frame (later frames may
    /// omit it) and either cumulative or incremental argument JSON.
    private func applyToolDelta(_ call: DevinProto.ChatToolCall, emit: (AssistantMessageEvent) -> Void) {
        enum Step { case skip, started(Int), existing(Int) }
        let step: Step = lock.withLock {
            var named = call.id.isEmpty ? activeToolCallId : call.id
            // A call that opens with a name and no id still runs: it gets an
            // id of ours, as magpie's Devin plugin gives one (`events`). A
            // name is what opens a call there, so a second name with no id
            // after such a call is the next call, not more of the first:
            // taken as one, their arguments would run together and decode
            // to `{}`.
            if call.id.isEmpty, !call.name.isEmpty,
               activeToolCallId.map(mintedToolCallIds.contains) ?? true {
                let minted = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                mintedToolCallIds.insert(minted)
                named = minted
            }
            guard let id = named else { return .skip }
            activeToolCallId = id
            if let idx = toolIndexById[id] {
                if !call.name.isEmpty, case .toolCall(var tc) = blocks[idx] {
                    tc.name = call.name; blocks[idx] = .toolCall(tc)
                }
                return .existing(idx)
            }
            blocks.append(.toolCall(ToolCall(id: id, name: call.name, arguments: .object([:]))))
            let idx = blocks.count - 1
            toolIndexById[id] = idx
            toolArgs[id] = ""
            toolOrder.append(id)
            return .started(idx)
        }
        let index: Int
        switch step {
        case .skip: return
        case .started(let idx):
            index = idx
            emit(.toolCallStart(contentIndex: idx, partial: snapshot()))
        case .existing(let idx):
            index = idx
        }
        guard !call.argumentsJson.isEmpty else { return }
        let delta: String = lock.withLock {
            let id = activeToolCallId ?? ""
            let previous = toolArgs[id] ?? ""
            let accumulated = call.argumentsJson.hasPrefix(previous)
                ? call.argumentsJson
                : previous + call.argumentsJson
            toolArgs[id] = accumulated
            return String(accumulated.dropFirst(previous.count))
        }
        if !delta.isEmpty { emit(.toolCallDelta(contentIndex: index, delta: delta, partial: snapshot())) }
    }

    func closeOpenBlocks(emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        endThinking(emit: emit)
        let completed: [(Int, ToolCall)] = lock.withLock {
            var out: [(Int, ToolCall)] = []
            for id in toolOrder {
                guard let idx = toolIndexById[id], case .toolCall(var tc) = blocks[idx] else { continue }
                let json = toolArgs[id] ?? ""
                tc.arguments = json.isEmpty
                    ? .object([:])
                    : (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:])
                blocks[idx] = .toolCall(tc)
                out.append((idx, tc))
            }
            toolOrder.removeAll()
            return out
        }
        for (index, call) in completed {
            emit(.toolCallEnd(contentIndex: index, toolCall: call, partial: snapshot()))
        }
    }

    func snapshot() -> AssistantMessage {
        lock.withLock { messageLocked(stopReason: stopReasonOverride ?? derivedStopReasonLocked()) }
    }

    func finalize() -> AssistantMessage { snapshot() }

    func aborted() -> AssistantMessage {
        lock.withLock { stopReasonOverride = .aborted }
        var m = snapshot()
        m.errorMessage = "Request was aborted"
        return m
    }

    func failed(_ failure: ProviderFailure) -> AssistantMessage {
        lock.withLock { stopReasonOverride = .error }
        var m = snapshot()
        m.errorMessage = failure.message
        m.failure = failure
        return m
    }

    private func derivedStopReasonLocked() -> StopReason {
        if !toolIndexById.isEmpty { return .toolUse }
        if lastStopReason == DevinProto.StopReason.maxTokens { return .length }
        return .stop
    }

    private func messageLocked(stopReason: StopReason) -> AssistantMessage {
        var u = usage
        u.cost = calculateCost(model: model, usage: u)
        return AssistantMessage(
            content: blocks,
            api: api,
            provider: model.provider,
            model: model.id,
            responseId: responseId,
            responseModel: responseModel,
            usage: u,
            stopReason: stopReason,
            timestamp: Timestamp.now()
        )
    }
}
