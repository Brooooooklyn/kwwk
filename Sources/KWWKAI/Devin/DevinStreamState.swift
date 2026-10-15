import Foundation
import NIOConcurrencyHelpers

// MARK: - Stream state

/// Accumulates the assistant message from `GetChatMessageResponse` deltas and
/// emits the matching `AssistantMessageEvent`s.
final class DevinStreamState: Sendable {
    private let api: String
    private let model: Model
    private struct State {
        var blocks: [AssistantBlock] = []
        var textIndex: Int?
        var thinkingIndex: Int?
        /// Tool-call block index + accumulated JSON args, keyed by call id.
        var toolIndexById: [String: Int] = [:]
        var toolArgs: [String: String] = [:]
        var toolOrder: [String] = []
        var activeToolCallId: String?
        /// Ids given here to calls Devin opened without one.
        var mintedToolCallIds: Set<String> = []
        var responseId: String?
        var responseModel: String?
        var lastStopReason: UInt64 = DevinProto.StopReason.unspecified
        var usage = Usage()
        var stopReasonOverride: StopReason?
    }
    private let state = NIOLockedValueBox(State())

    init(api: String, model: Model) {
        self.api = api
        self.model = model
    }

    func setResponseModel(_ uid: String) {
        state.withLockedValue { $0.responseModel = uid }
    }

    func apply(_ msg: DevinProto.GetChatMessageResponse, emit: (AssistantMessageEvent) -> Void) {
        state.withLockedValue { state in
            if !msg.messageId.isEmpty, state.responseId == nil { state.responseId = msg.messageId }
            if let actual = msg.actualModelUid, !actual.isEmpty { state.responseModel = actual }
            if msg.stopReason != DevinProto.StopReason.unspecified { state.lastStopReason = msg.stopReason }
            if let u = msg.usage {
                state.usage.input = Int(u.inputTokens)
                state.usage.output = Int(u.outputTokens)
                state.usage.cacheRead = Int(u.cacheReadTokens)
                state.usage.cacheWrite = Int(u.cacheWriteTokens)
                state.usage.totalTokens = state.usage.input + state.usage.output
                    + state.usage.cacheRead + state.usage.cacheWrite
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
            state.withLockedValue { state in
                let index = state.thinkingIndex
                    ?? state.blocks.lastIndex { if case .thinking = $0 { return true }; return false }
                if let index, case .thinking(var t) = state.blocks[index] {
                    t.thinkingSignature = msg.deltaSignature
                    state.blocks[index] = .thinking(t)
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
        let (index, isNew): (Int, Bool) = state.withLockedValue { state in
            if let idx = state.textIndex { return (idx, false) }
            state.blocks.append(.text(TextContent(text: "")))
            state.textIndex = state.blocks.count - 1
            return (state.blocks.count - 1, true)
        }
        if isNew { emit(.textStart(contentIndex: index, partial: snapshot())) }
        state.withLockedValue { state in
            if case .text(var t) = state.blocks[index] { t.text += delta; state.blocks[index] = .text(t) }
        }
        emit(.textDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    private func appendThinking(_ delta: String, signature: String, emit: (AssistantMessageEvent) -> Void) {
        let (index, isNew): (Int, Bool) = state.withLockedValue { state in
            if let idx = state.thinkingIndex { return (idx, false) }
            state.blocks.append(.thinking(ThinkingContent(thinking: "")))
            state.thinkingIndex = state.blocks.count - 1
            return (state.blocks.count - 1, true)
        }
        if isNew { emit(.thinkingStart(contentIndex: index, partial: snapshot())) }
        state.withLockedValue { state in
            if case .thinking(var t) = state.blocks[index] {
                t.thinking += delta
                if !signature.isEmpty { t.thinkingSignature = signature }
                state.blocks[index] = .thinking(t)
            }
        }
        emit(.thinkingDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    private func endText(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = state.withLockedValue { state in
            guard let idx = state.textIndex, case .text(let t) = state.blocks[idx] else { return nil }
            state.textIndex = nil
            return (idx, t.text)
        }
        if let (index, content) = closed { emit(.textEnd(contentIndex: index, content: content, partial: snapshot())) }
    }

    private func endThinking(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = state.withLockedValue { state in
            guard let idx = state.thinkingIndex, case .thinking(let t) = state.blocks[idx] else { return nil }
            state.thinkingIndex = nil
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
        let step: Step = state.withLockedValue { state in
            var named = call.id.isEmpty ? state.activeToolCallId : call.id
            // A call that opens with a name and no id still runs: it gets an
            // id of ours, as magpie's Devin plugin gives one (`events`). A
            // name is what opens a call there, so a second name with no id
            // after such a call is the next call, not more of the first:
            // taken as one, their arguments would run together and decode
            // to `{}`.
            if call.id.isEmpty, !call.name.isEmpty,
               state.activeToolCallId.map({ state.mintedToolCallIds.contains($0) }) ?? true {
                let minted = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                state.mintedToolCallIds.insert(minted)
                named = minted
            }
            guard let id = named else { return .skip }
            state.activeToolCallId = id
            if let idx = state.toolIndexById[id] {
                if !call.name.isEmpty, case .toolCall(var tc) = state.blocks[idx] {
                    tc.name = call.name; state.blocks[idx] = .toolCall(tc)
                }
                return .existing(idx)
            }
            state.blocks.append(.toolCall(ToolCall(id: id, name: call.name, arguments: .object([:]))))
            let idx = state.blocks.count - 1
            state.toolIndexById[id] = idx
            state.toolArgs[id] = ""
            state.toolOrder.append(id)
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
        let delta: String = state.withLockedValue { state in
            let id = state.activeToolCallId ?? ""
            let previous = state.toolArgs[id] ?? ""
            let accumulated = call.argumentsJson.hasPrefix(previous)
                ? call.argumentsJson
                : previous + call.argumentsJson
            state.toolArgs[id] = accumulated
            return String(accumulated.dropFirst(previous.count))
        }
        if !delta.isEmpty { emit(.toolCallDelta(contentIndex: index, delta: delta, partial: snapshot())) }
    }

    func closeOpenBlocks(emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        endThinking(emit: emit)
        let completed: [(Int, ToolCall)] = state.withLockedValue { state in
            var out: [(Int, ToolCall)] = []
            for id in state.toolOrder {
                guard let idx = state.toolIndexById[id], case .toolCall(var tc) = state.blocks[idx] else { continue }
                let json = state.toolArgs[id] ?? ""
                tc.arguments = json.isEmpty
                    ? .object([:])
                    : (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:])
                state.blocks[idx] = .toolCall(tc)
                out.append((idx, tc))
            }
            state.toolOrder.removeAll()
            return out
        }
        for (index, call) in completed {
            emit(.toolCallEnd(contentIndex: index, toolCall: call, partial: snapshot()))
        }
    }

    func snapshot() -> AssistantMessage {
        state.withLockedValue { state in
            messageLocked(state, stopReason: state.stopReasonOverride ?? derivedStopReasonLocked(state))
        }
    }

    func finalize() -> AssistantMessage { snapshot() }

    func aborted() -> AssistantMessage {
        state.withLockedValue { $0.stopReasonOverride = .aborted }
        var m = snapshot()
        m.errorMessage = "Request was aborted"
        return m
    }

    func failed(_ failure: ProviderFailure) -> AssistantMessage {
        state.withLockedValue { $0.stopReasonOverride = .error }
        var m = snapshot()
        m.errorMessage = failure.message
        m.failure = failure
        return m
    }

    private func derivedStopReasonLocked(_ state: State) -> StopReason {
        if !state.toolIndexById.isEmpty { return .toolUse }
        if state.lastStopReason == DevinProto.StopReason.maxTokens { return .length }
        return .stop
    }

    private func messageLocked(_ state: State, stopReason: StopReason) -> AssistantMessage {
        var u = state.usage
        u.cost = calculateCost(model: model, usage: u)
        return AssistantMessage(
            content: state.blocks,
            api: api,
            provider: model.provider,
            model: model.id,
            responseId: state.responseId,
            responseModel: state.responseModel,
            usage: u,
            stopReason: stopReason,
            timestamp: Timestamp.now()
        )
    }
}
