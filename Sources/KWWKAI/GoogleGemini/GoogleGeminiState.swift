import Foundation

// MARK: - Mutable state

final class GoogleGeminiState: @unchecked Sendable {
    let api: String
    let provider: String
    let modelId: String
    var signal: CancellationHandle?

    var responseId: String?
    var usage = Usage()
    var stopReason: StopReason = .stop
    var failure: ProviderFailure?

    enum Block {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolUse(id: String, call: ToolCall)
    }

    private let lock = NSLock()
    private var blocks: [Int: Block] = [:]
    private var order: [Int] = []
    private var textIndex: Int?
    private var thinkingIndex: Int?
    private var endedIndices: Set<Int> = []

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    func noteTextBlock() -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let idx = textIndex { return (idx, false) }
            let idx = order.count
            textIndex = idx
            order.append(idx)
            blocks[idx] = .text(TextContent(text: ""))
            return (idx, true)
        }
    }

    func noteThinkingBlock() -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let idx = thinkingIndex { return (idx, false) }
            let idx = order.count
            thinkingIndex = idx
            order.append(idx)
            blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return (idx, true)
        }
    }

    func appendText(index: Int, text: String) {
        lock.withLock {
            if case .text(var t) = blocks[index] {
                t.text += text
                blocks[index] = .text(t)
            }
        }
    }

    func appendThinking(index: Int, text: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index] {
                th.thinking += text
                blocks[index] = .thinking(th)
            }
        }
    }

    private static func retainSignature(_ existing: String?, _ incoming: String?) -> String? {
        if let incoming, !incoming.isEmpty { return incoming }
        return existing
    }

    func setTextSignature(index: Int, sig: String?) {
        lock.withLock {
            if case .text(var t) = blocks[index] {
                t.textSignature = Self.retainSignature(t.textSignature, sig)
                blocks[index] = .text(t)
            }
        }
    }

    func setThinkingSignature(index: Int, sig: String?) {
        lock.withLock {
            if case .thinking(var th) = blocks[index] {
                th.thinkingSignature = Self.retainSignature(th.thinkingSignature, sig)
                blocks[index] = .thinking(th)
            }
        }
    }

    func appendToolCall(id given: String? = nil, name: String, args: JSONValue, signature: String?) -> Int {
        lock.withLock {
            let idx = order.count
            let id = given ?? "\(GoogleGeminiProvider.mintedIdPrefix)\(idx)-\(Int(Date().timeIntervalSince1970 * 1000))"
            let call = ToolCall(id: id, name: name, arguments: args, thoughtSignature: signature)
            order.append(idx)
            blocks[idx] = .toolUse(id: id, call: call)
            endedIndices.insert(idx)   // Gemini delivers calls atomically.
            return idx
        }
    }

    func toolCallId(at index: Int) -> String {
        lock.withLock {
            if case .toolUse(let id, _) = blocks[index] { return id } else { return "" }
        }
    }

    func hasToolCalls() -> Bool {
        lock.withLock {
            blocks.values.contains { if case .toolUse = $0 { return true } else { return false } }
        }
    }

    func applyUsage(_ obj: [String: JSONValue]) {
        func intVal(_ key: String) -> Int {
            switch obj[key] ?? .null {
            case .int(let v): return v
            case .double(let v): return Int(v)
            default: return 0
            }
        }
        let prompt = intVal("promptTokenCount")
        let cached = intVal("cachedContentTokenCount")
        let candidates = intVal("candidatesTokenCount")
        let thoughts = intVal("thoughtsTokenCount")
        usage.input = prompt - cached
        usage.output = candidates + thoughts
        usage.cacheRead = cached
        usage.reasoning = thoughts
        usage.totalTokens = intVal("totalTokenCount")
    }

    func snapshot() -> AssistantMessage {
        lock.withLock {
            AssistantMessage(
                content: order.compactMap { idx -> AssistantBlock? in
                    switch blocks[idx] {
                    case .text(let t): return .text(t)
                    case .thinking(let th): return .thinking(th)
                    case .toolUse(_, let call): return .toolCall(call)
                    case .none: return nil
                    }
                },
                api: api,
                provider: provider,
                model: modelId,
                responseId: responseId,
                usage: usage,
                stopReason: stopReason,
                errorMessage: failure?.message,
                failure: failure,
                timestamp: Timestamp.now()
            )
        }
    }

    func finalize() -> AssistantMessage { snapshot() }

    func asAborted() -> AssistantMessage {
        stopReason = .aborted
        var m = snapshot()
        m.errorMessage = "Request was aborted"
        return m
    }

    func finalizeStreamingBlocks(emit: (AssistantMessageEvent) -> Void) {
        let indices = lock.withLock { order }
        for idx in indices {
            if endedIndices.contains(idx) { continue }
            guard let block = lock.withLock({ blocks[idx] }) else { continue }
            let partial = snapshot()
            switch block {
            case .text(let t):
                emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
            case .thinking(let th):
                emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
            case .toolUse: break
            }
            _ = lock.withLock { endedIndices.insert(idx) }
        }
    }
}
