import Foundation
import NIOConcurrencyHelpers

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

    private struct State {
        var blocks: [Int: Block] = [:]
        var order: [Int] = []
        var textIndex: Int?
        var thinkingIndex: Int?
        var endedIndices: Set<Int> = []
    }
    private let state = NIOLockedValueBox(State())

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    func noteTextBlock() -> (index: Int, firstSeen: Bool) {
        state.withLockedValue { state in
            if let idx = state.textIndex { return (idx, false) }
            let idx = state.order.count
            state.textIndex = idx
            state.order.append(idx)
            state.blocks[idx] = .text(TextContent(text: ""))
            return (idx, true)
        }
    }

    func noteThinkingBlock() -> (index: Int, firstSeen: Bool) {
        state.withLockedValue { state in
            if let idx = state.thinkingIndex { return (idx, false) }
            let idx = state.order.count
            state.thinkingIndex = idx
            state.order.append(idx)
            state.blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return (idx, true)
        }
    }

    func appendText(index: Int, text: String) {
        state.withLockedValue { state in
            if case .text(var t) = state.blocks[index] {
                t.text += text
                state.blocks[index] = .text(t)
            }
        }
    }

    func appendThinking(index: Int, text: String) {
        state.withLockedValue { state in
            if case .thinking(var th) = state.blocks[index] {
                th.thinking += text
                state.blocks[index] = .thinking(th)
            }
        }
    }

    private static func retainSignature(_ existing: String?, _ incoming: String?) -> String? {
        if let incoming, !incoming.isEmpty { return incoming }
        return existing
    }

    func setTextSignature(index: Int, sig: String?) {
        state.withLockedValue { state in
            if case .text(var t) = state.blocks[index] {
                t.textSignature = Self.retainSignature(t.textSignature, sig)
                state.blocks[index] = .text(t)
            }
        }
    }

    func setThinkingSignature(index: Int, sig: String?) {
        state.withLockedValue { state in
            if case .thinking(var th) = state.blocks[index] {
                th.thinkingSignature = Self.retainSignature(th.thinkingSignature, sig)
                state.blocks[index] = .thinking(th)
            }
        }
    }

    func appendToolCall(id given: String? = nil, name: String, args: JSONValue, signature: String?) -> Int {
        state.withLockedValue { state in
            let idx = state.order.count
            let id = given ?? "\(GoogleGeminiProvider.mintedIdPrefix)\(idx)-\(Int(Date().timeIntervalSince1970 * 1000))"
            let call = ToolCall(id: id, name: name, arguments: args, thoughtSignature: signature)
            state.order.append(idx)
            state.blocks[idx] = .toolUse(id: id, call: call)
            state.endedIndices.insert(idx)   // Gemini delivers calls atomically.
            return idx
        }
    }

    func toolCallId(at index: Int) -> String {
        state.withLockedValue { state in
            if case .toolUse(let id, _) = state.blocks[index] { return id } else { return "" }
        }
    }

    func hasToolCalls() -> Bool {
        state.withLockedValue { state in
            state.blocks.values.contains { if case .toolUse = $0 { return true } else { return false } }
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
        state.withLockedValue { state in
            AssistantMessage(
                content: state.order.compactMap { idx -> AssistantBlock? in
                    switch state.blocks[idx] {
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
        let indices = state.withLockedValue { $0.order }
        for idx in indices {
            if state.withLockedValue({ $0.endedIndices.contains(idx) }) { continue }
            guard let block = state.withLockedValue({ $0.blocks[idx] }) else { continue }
            let partial = snapshot()
            switch block {
            case .text(let t):
                emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
            case .thinking(let th):
                emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
            case .toolUse: break
            }
            _ = state.withLockedValue { $0.endedIndices.insert(idx) }
        }
    }
}
