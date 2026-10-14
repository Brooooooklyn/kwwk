import Foundation

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

    private let lock = NSLock()
    private var blocks: [Int: Block] = [:]
    /// Bedrock's `contentBlockIndex` → our ordinal index in `order`.
    private var blockByIndex: [Int: Int] = [:]
    private var order: [Int] = []
    private var endedIndices: Set<Int> = []

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    func noteTextBlock(at blockIndex: Int) -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let existing = blockByIndex[blockIndex] { return (existing, false) }
            let idx = order.count
            blockByIndex[blockIndex] = idx
            order.append(idx)
            blocks[idx] = .text(TextContent(text: ""))
            return (idx, true)
        }
    }

    func noteThinkingBlock(at blockIndex: Int) -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let existing = blockByIndex[blockIndex] { return (existing, false) }
            let idx = order.count
            blockByIndex[blockIndex] = idx
            order.append(idx)
            blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return (idx, true)
        }
    }

    func noteToolUseBlock(at blockIndex: Int, id: String, name: String) -> Int {
        lock.withLock {
            if let existing = blockByIndex[blockIndex] { return existing }
            let idx = order.count
            blockByIndex[blockIndex] = idx
            order.append(idx)
            blocks[idx] = .toolUse(id: id, name: name, json: "")
            return idx
        }
    }

    func toolCallIndex(at blockIndex: Int) -> Int? {
        lock.withLock { blockByIndex[blockIndex] }
    }

    func appendText(index: Int, text: String) {
        lock.withLock {
            if case .text(var t) = blocks[index] { t.text += text; blocks[index] = .text(t) }
        }
    }
    func appendThinking(index: Int, text: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index] { th.thinking += text; blocks[index] = .thinking(th) }
        }
    }
    func appendSignature(index: Int, signature: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index] {
                th.thinkingSignature = (th.thinkingSignature ?? "") + signature
                blocks[index] = .thinking(th)
            }
        }
    }
    func appendToolCallArgs(index: Int, chunk: String) {
        lock.withLock {
            if case .toolUse(let id, let name, let json) = blocks[index] {
                blocks[index] = .toolUse(id: id, name: name, json: json + chunk)
            }
        }
    }

    func finishBlock(at blockIndex: Int, emit: (AssistantMessageEvent) -> Void) {
        let idx: Int? = lock.withLock { blockByIndex[blockIndex] }
        guard let idx, !endedIndices.contains(idx) else { return }
        let partial = snapshot()
        guard let block = lock.withLock({ blocks[idx] }) else { return }
        switch block {
        case .text(let t):
            emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
        case .thinking(let th):
            emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
        case .toolUse(let id, let name, let json):
            let call = ToolCall(id: id, name: name, arguments: parseJSONObject(json) ?? .object([:]))
            emit(.toolCallEnd(contentIndex: idx, toolCall: call, partial: partial))
        }
        _ = lock.withLock { endedIndices.insert(idx) }
    }

    func finalizePending(emit: (AssistantMessageEvent) -> Void) {
        let indices = lock.withLock { order }
        for idx in indices where !endedIndices.contains(idx) {
            let partial = snapshot()
            guard let block = lock.withLock({ blocks[idx] }) else { continue }
            switch block {
            case .text(let t):
                emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
            case .thinking(let th):
                emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
            case .toolUse(let id, let name, let json):
                let call = ToolCall(id: id, name: name, arguments: parseJSONObject(json) ?? .object([:]))
                emit(.toolCallEnd(contentIndex: idx, toolCall: call, partial: partial))
            }
            _ = lock.withLock { endedIndices.insert(idx) }
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
        lock.withLock {
            AssistantMessage(
                content: order.compactMap { idx -> AssistantBlock? in
                    switch blocks[idx] {
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
