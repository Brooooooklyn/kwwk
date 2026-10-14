import Foundation

// MARK: - Mutable state

final class OpenAIResponsesState: @unchecked Sendable {
    let api: String
    let provider: String
    let modelId: String
    var signal: CancellationHandle?

    var responseId: String?
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
    private var order: [Int] = []
    /// Output-index → content-index for each kind of item. Kept separate so
    /// that a reasoning + message + function_call under the same output_index
    /// can coexist (rare, but legal).
    private var textByOutput: [Int: Int] = [:]
    private var reasoningByOutput: [Int: Int] = [:]
    private var toolCallByOutput: [Int: Int] = [:]

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    func noteMessageItem(outputIndex: Int) {
        // Text content parts arrive separately; nothing to do here.
        _ = outputIndex
    }

    func noteTextPart(outputIndex: Int) -> Int {
        lock.withLock {
            if let existing = textByOutput[outputIndex] { return existing }
            let idx = order.count
            textByOutput[outputIndex] = idx
            order.append(idx)
            blocks[idx] = .text(TextContent(text: ""))
            return idx
        }
    }

    func noteReasoningItem(outputIndex: Int) -> Int {
        lock.withLock {
            if let existing = reasoningByOutput[outputIndex] { return existing }
            let idx = order.count
            reasoningByOutput[outputIndex] = idx
            order.append(idx)
            blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return idx
        }
    }

    func noteFunctionCallItem(outputIndex: Int, callId: String, name: String, arguments: String = "") -> Int {
        lock.withLock {
            if let existing = toolCallByOutput[outputIndex] { return existing }
            let idx = order.count
            toolCallByOutput[outputIndex] = idx
            order.append(idx)
            blocks[idx] = .toolUse(id: callId, name: name, json: arguments)
            return idx
        }
    }

    func updateFunctionCallItem(outputIndex: Int, callId: String?, name: String?, arguments: String?) {
        lock.withLock {
            guard let index = toolCallByOutput[outputIndex],
                  case .toolUse(let currentId, let currentName, let currentJSON) = blocks[index]
            else { return }
            blocks[index] = .toolUse(
                id: callId ?? currentId,
                name: name ?? currentName,
                json: arguments ?? currentJSON
            )
        }
    }

    func textIndex(for outputIndex: Int) -> Int? {
        lock.withLock { textByOutput[outputIndex] }
    }
    func reasoningIndex(for outputIndex: Int) -> Int? {
        lock.withLock { reasoningByOutput[outputIndex] }
    }
    func toolCallIndex(for outputIndex: Int) -> Int? {
        lock.withLock { toolCallByOutput[outputIndex] }
    }

    func appendText(at index: Int, text: String) {
        lock.withLock {
            if case .text(var t) = blocks[index] {
                t.text += text
                blocks[index] = .text(t)
            }
        }
    }

    func appendThinking(at index: Int, text: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index] {
                th.thinking += text
                blocks[index] = .thinking(th)
            }
        }
    }

    func setThinkingSignature(at index: Int, signature: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index] {
                th.thinkingSignature = signature
                blocks[index] = .thinking(th)
            }
        }
    }

    func thinkingSignature(at index: Int) -> String? {
        lock.withLock {
            if case .thinking(let th) = blocks[index] { return th.thinkingSignature }
            return nil
        }
    }

    func appendToolCallArgs(at index: Int, chunk: String) {
        lock.withLock {
            if case .toolUse(let id, let name, let json) = blocks[index] {
                blocks[index] = .toolUse(id: id, name: name, json: json + chunk)
            }
        }
    }

    func textValue(at index: Int) -> String {
        lock.withLock {
            if case .text(let t) = blocks[index] { return t.text } else { return "" }
        }
    }

    func thinkingValue(at index: Int) -> String {
        lock.withLock {
            if case .thinking(let th) = blocks[index] { return th.thinking } else { return "" }
        }
    }

    func toolCallValue(at index: Int) -> ToolCall? {
        lock.withLock {
            guard case .toolUse(let id, let name, let json) = blocks[index] else { return nil }
            return ToolCall(id: id, name: name, arguments: parseJSONObject(json) ?? .object([:]))
        }
    }

    func hasToolCalls() -> Bool {
        lock.withLock { !toolCallByOutput.isEmpty }
    }

    func applyUsage(_ obj: [String: JSONValue]) {
        if case .int(let v) = obj["input_tokens"] ?? .null { usage.input = v }
        if case .int(let v) = obj["output_tokens"] ?? .null { usage.output = v }
        // `input_tokens` is the whole prompt: both cache figures are part of
        // it. The ChatGPT backend reports `cache_write_tokens` beside
        // `cached_tokens` and `reasoning_tokens` under the output details
        // (measured 2026-10-11); reasoning stays inside `output`.
        if case .object(let details) = obj["input_tokens_details"] ?? .null {
            if case .int(let v) = details["cached_tokens"] ?? .null { usage.cacheRead = v }
            if case .int(let v) = details["cache_write_tokens"] ?? .null { usage.cacheWrite = v }
            usage.input = max(0, usage.input - usage.cacheRead - usage.cacheWrite)
        }
        if case .object(let details) = obj["output_tokens_details"] ?? .null,
           case .int(let v) = details["reasoning_tokens"] ?? .null {
            usage.reasoning = v
        }
        usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
    }

    /// Streaming snapshot. In-progress tool calls use an empty-object
    /// placeholder rather than re-parsing the growing JSON buffer on every
    /// delta (O(n^2)); full arguments are parsed once in `finalize`
    /// (and in `toolCallValue` for the `toolCallEnd` event).
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
                responseId: responseId,
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
