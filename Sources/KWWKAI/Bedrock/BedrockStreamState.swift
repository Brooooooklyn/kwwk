import Foundation
import NIOConcurrencyHelpers

// MARK: - Mutable state

final class BedrockStreamState: @unchecked Sendable {
    let api: String
    let provider: String
    let modelId: String
    var signal: CancellationHandle?
    var usage = Usage()
    var stopReason: StopReason = .stop
    var errorMessage: String?

    enum Block {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolUse(id: String, name: String, json: String)
    }

    private struct State {
        var blocks: [Int: Block] = [:]
        /// Bedrock's `contentBlockIndex` → our ordinal index in `order`.
        var blockByIndex: [Int: Int] = [:]
        var order: [Int] = []
        var endedIndices: Set<Int> = []
    }
    private let state = NIOLockedValueBox(State())

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    func noteTextBlock(at blockIndex: Int) -> (index: Int, firstSeen: Bool) {
        state.withLockedValue { state in
            if let existing = state.blockByIndex[blockIndex] { return (existing, false) }
            let idx = state.order.count
            state.blockByIndex[blockIndex] = idx
            state.order.append(idx)
            state.blocks[idx] = .text(TextContent(text: ""))
            return (idx, true)
        }
    }

    func noteThinkingBlock(at blockIndex: Int) -> (index: Int, firstSeen: Bool) {
        state.withLockedValue { state in
            if let existing = state.blockByIndex[blockIndex] { return (existing, false) }
            let idx = state.order.count
            state.blockByIndex[blockIndex] = idx
            state.order.append(idx)
            state.blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return (idx, true)
        }
    }

    func noteToolUseBlock(at blockIndex: Int, id: String, name: String) -> Int {
        state.withLockedValue { state in
            if let existing = state.blockByIndex[blockIndex] { return existing }
            let idx = state.order.count
            state.blockByIndex[blockIndex] = idx
            state.order.append(idx)
            state.blocks[idx] = .toolUse(id: id, name: name, json: "")
            return idx
        }
    }

    func toolCallIndex(at blockIndex: Int) -> Int? {
        state.withLockedValue { $0.blockByIndex[blockIndex] }
    }

    func appendText(index: Int, text: String) {
        state.withLockedValue { state in
            if case .text(var t) = state.blocks[index] { t.text += text; state.blocks[index] = .text(t) }
        }
    }
    func appendThinking(index: Int, text: String) {
        state.withLockedValue { state in
            if case .thinking(var th) = state.blocks[index] { th.thinking += text; state.blocks[index] = .thinking(th) }
        }
    }
    func appendSignature(index: Int, signature: String) {
        state.withLockedValue { state in
            if case .thinking(var th) = state.blocks[index] {
                th.thinkingSignature = (th.thinkingSignature ?? "") + signature
                state.blocks[index] = .thinking(th)
            }
        }
    }
    func appendToolCallArgs(index: Int, chunk: String) {
        state.withLockedValue { state in
            if case .toolUse(let id, let name, let json) = state.blocks[index] {
                state.blocks[index] = .toolUse(id: id, name: name, json: json + chunk)
            }
        }
    }

    func finishBlock(at blockIndex: Int, emit: (AssistantMessageEvent) -> Void) {
        let idx: Int? = state.withLockedValue { $0.blockByIndex[blockIndex] }
        guard let idx, !state.withLockedValue({ $0.endedIndices.contains(idx) }) else { return }
        let partial = snapshot()
        guard let block = state.withLockedValue({ $0.blocks[idx] }) else { return }
        switch block {
        case .text(let t):
            emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
        case .thinking(let th):
            emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
        case .toolUse(let id, let name, let json):
            let call = ToolCall(id: id, name: name, arguments: parseJSONObject(json) ?? .object([:]))
            emit(.toolCallEnd(contentIndex: idx, toolCall: call, partial: partial))
        }
        _ = state.withLockedValue { $0.endedIndices.insert(idx) }
    }

    func finalizePending(emit: (AssistantMessageEvent) -> Void) {
        let indices = state.withLockedValue { $0.order }
        for idx in indices where !state.withLockedValue({ $0.endedIndices.contains(idx) }) {
            let partial = snapshot()
            guard let block = state.withLockedValue({ $0.blocks[idx] }) else { continue }
            switch block {
            case .text(let t):
                emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
            case .thinking(let th):
                emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
            case .toolUse(let id, let name, let json):
                let call = ToolCall(id: id, name: name, arguments: parseJSONObject(json) ?? .object([:]))
                emit(.toolCallEnd(contentIndex: idx, toolCall: call, partial: partial))
            }
            _ = state.withLockedValue { $0.endedIndices.insert(idx) }
        }
    }

    func applyUsage(_ obj: [String: JSONValue]) {
        if case .int(let v) = obj["inputTokens"] ?? .null { usage.input = v }
        if case .int(let v) = obj["outputTokens"] ?? .null { usage.output = v }
        if case .int(let v) = obj["cacheReadInputTokens"] ?? .null { usage.cacheRead = v }
        if case .int(let v) = obj["cacheWriteInputTokens"] ?? .null { usage.cacheWrite = v }
        // pi: prefer the upstream totalTokens (truthy ⇒ > 0); else input+output,
        // and do NOT sum cacheRead/cacheWrite into the total.
        if case .int(let v) = obj["totalTokens"] ?? .null, v > 0 {
            usage.totalTokens = v
        } else {
            usage.totalTokens = usage.input + usage.output
        }
    }

    /// Streaming snapshot. In-progress tool calls use an empty-object
    /// placeholder rather than re-parsing the growing JSON buffer on every
    /// delta (O(n^2)); full arguments are parsed once in `finishBlock`/`finalize`.
    func snapshot() -> AssistantMessage { buildMessage(parseToolArgs: false) }

    private func buildMessage(parseToolArgs: Bool) -> AssistantMessage {
        state.withLockedValue { state in
            AssistantMessage(
                content: state.order.compactMap { idx -> AssistantBlock? in
                    switch state.blocks[idx] {
                    case .text(let t): return .text(t)
                    case .thinking(let th): return .thinking(th)
                    case .toolUse(let id, let name, let json):
                        let args: JSONValue = parseToolArgs ? parseJSONObject(json) ?? .object([:]) : .object([:])
                        return .toolCall(ToolCall(id: id, name: name, arguments: args))
                    case .none: return nil
                    }
                },
                api: api,
                provider: provider,
                model: modelId,
                usage: usage,
                stopReason: stopReason,
                errorMessage: errorMessage,
                timestamp: Timestamp.now()
            )
        }
    }

    func finalize() -> AssistantMessage { buildMessage(parseToolArgs: true) }

    func asAborted() -> AssistantMessage {
        stopReason = .aborted
        errorMessage = "Request was aborted"
        return snapshot()
    }

    func asError(text: String) -> AssistantMessage {
        stopReason = .error
        errorMessage = text
        return snapshot()
    }
}
