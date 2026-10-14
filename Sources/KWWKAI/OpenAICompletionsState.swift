import Foundation

/// Mutable state for OpenAI Completions stream. Tracks content block order
/// and incremental tool-call JSON buffers.
final class OpenAICompletionsState: @unchecked Sendable {
    let api: String
    let provider: String
    let modelId: String
    let model: Model
    var signal: CancellationHandle?

    var responseId: String?
    var usage = Usage()
    var stopReason: StopReason = .stop
    var errorMessage: String?
    var failure: ProviderFailure?

    enum Block {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolUse(id: String, name: String, json: String, thoughtSignature: String?)
    }
    private let lock = NSLock()
    private var blocks: [Int: Block] = [:]
    private var order: [Int] = []
    private var textBlockIndex: Int?
    private var thinkingBlockIndex: Int?
    /// Map from OpenAI `tool_calls[i].index` → our content index.
    private var toolCallIndexMap: [Int: Int] = [:]
    /// Map from a settled tool-call `id` → our content index. Used to attach
    /// encrypted reasoning details, which arrive keyed by tool-call id.
    private var toolCallContentIndexById: [String: Int] = [:]
    /// Reasoning details that arrived before the matching tool-call id settled.
    private var pendingReasoningById: [String: String] = [:]
    private var endedIndices: Set<Int> = []

    init(api: String, provider: String, modelId: String, model: Model) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
        self.model = model
    }

    // MARK: Block book-keeping

    func noteTextBlock() -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let idx = textBlockIndex { return (idx, false) }
            let idx = order.count
            textBlockIndex = idx
            order.append(idx)
            blocks[idx] = .text(TextContent(text: ""))
            return (idx, true)
        }
    }

    func noteThinkingBlock() -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let idx = thinkingBlockIndex { return (idx, false) }
            let idx = order.count
            thinkingBlockIndex = idx
            order.append(idx)
            blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return (idx, true)
        }
    }

    /// The content block a tool-call fragment at `rawIndex` belongs to. A
    /// fragment naming an id other than the one the index's open call goes
    /// by is the next call, not more of this one; a fragment with no id, or
    /// repeating the open call's, continues it.
    func noteToolCallBlock(at rawIndex: Int, id: String? = nil) -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let idx = toolCallIndexMap[rawIndex] {
                guard let id, case .toolUse(let openID, _, _, _) = blocks[idx],
                      !openID.isEmpty, openID != id else { return (idx, false) }
            }
            let idx = order.count
            toolCallIndexMap[rawIndex] = idx
            order.append(idx)
            blocks[idx] = .toolUse(id: "", name: "", json: "", thoughtSignature: nil)
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

    func setThinkingSignature(index: Int, signature: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index], th.thinkingSignature == nil {
                th.thinkingSignature = signature
                blocks[index] = .thinking(th)
            }
        }
    }

    func updateToolCallID(rawIndex: Int, id: String) {
        lock.withLock {
            guard let contentIndex = toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(_, let name, let json, let sig) = blocks[contentIndex] {
                var newSig = sig
                if let pending = pendingReasoningById.removeValue(forKey: id) { newSig = pending }
                blocks[contentIndex] = .toolUse(id: id, name: name, json: json, thoughtSignature: newSig)
            }
            toolCallContentIndexById[id] = contentIndex
        }
    }

    func updateToolCallName(rawIndex: Int, name: String) {
        lock.withLock {
            guard let contentIndex = toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(let id, _, let json, let sig) = blocks[contentIndex] {
                blocks[contentIndex] = .toolUse(id: id, name: name, json: json, thoughtSignature: sig)
            }
        }
    }

    func appendToolCallArgs(rawIndex: Int, chunk: String) {
        lock.withLock {
            guard let contentIndex = toolCallIndexMap[rawIndex] else { return }
            if case .toolUse(let id, let name, let json, let sig) = blocks[contentIndex] {
                blocks[contentIndex] = .toolUse(id: id, name: name, json: json + chunk, thoughtSignature: sig)
            }
        }
    }

    /// Attach an encrypted reasoning detail (serialized JSON) to the tool call
    /// with the matching id, or stash it as pending if the id has not settled.
    func applyReasoningDetail(id: String, serialized: String) {
        lock.withLock {
            if let contentIndex = toolCallContentIndexById[id],
               case .toolUse(let cid, let name, let json, _) = blocks[contentIndex] {
                blocks[contentIndex] = .toolUse(id: cid, name: name, json: json, thoughtSignature: serialized)
            } else {
                pendingReasoningById[id] = serialized
            }
        }
    }

    // MARK: Stream events

    func applyUsage(_ obj: [String: JSONValue]) {
        func intOf(_ v: JSONValue?) -> Int? { if case .int(let n)? = v { return n }; return nil }
        let prompt = intOf(obj["prompt_tokens"]) ?? 0
        let promptDetails: [String: JSONValue] = {
            if case .object(let d)? = obj["prompt_tokens_details"] { return d }
            return [:]
        }()
        // DeepSeek exposes cache hits via `prompt_cache_hit_tokens` instead of
        // `prompt_tokens_details.cached_tokens`, Moonshot via a top-level
        // `cached_tokens`.
        let cacheRead = intOf(promptDetails["cached_tokens"]) ?? intOf(obj["prompt_cache_hit_tokens"])
            ?? intOf(obj["cached_tokens"]) ?? 0
        let cacheWrite = intOf(promptDetails["cache_write_tokens"]) ?? 0
        let output = intOf(obj["completion_tokens"]) ?? 0
        let completionDetails: [String: JSONValue] = {
            if case .object(let d)? = obj["completion_tokens_details"] { return d }
            return [:]
        }()
        let reasoning = intOf(completionDetails["reasoning_tokens"]) ?? 0
        let input = max(0, prompt - cacheRead - cacheWrite)
        usage.input = input
        usage.output = output
        usage.cacheRead = cacheRead
        usage.cacheWrite = cacheWrite
        usage.reasoning = reasoning
        usage.totalTokens = input + output + cacheRead + cacheWrite
        usage.cost = calculateCost(model: model, usage: usage)
    }

    /// Streaming snapshot. In-progress tool calls use an empty-object
    /// placeholder rather than re-parsing the growing JSON buffer on every
    /// delta (O(n^2)); full arguments are parsed once in
    /// `finalizeStreamingBlocks`/`finalize`.
    func snapshot() -> AssistantMessage { buildMessage(parseToolArgs: false) }

    /// Gives each tool call the stream never named an id for one of its
    /// own. llama.cpp, Ollama and some relays send none, and a call kept at
    /// `""` can't be told from another one, nor paired with its result, and
    /// Anthropic refuses it outright after a switch (magpie mints
    /// `call_<id>` the same way, gateway/chat.go). The id is minted once and
    /// kept, so the end event, the final message and the tool result agree.
    private func settleEmptyToolCallIds() {
        lock.withLock {
            for idx in order {
                guard case .toolUse(let id, let name, let json, let sig) = blocks[idx], id.isEmpty else { continue }
                let minted = "call_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
                blocks[idx] = .toolUse(id: minted, name: name, json: json, thoughtSignature: sig)
            }
        }
    }

    private func buildMessage(parseToolArgs: Bool) -> AssistantMessage {
        if parseToolArgs { settleEmptyToolCallIds() }
        return lock.withLock {
            AssistantMessage(
                content: order.compactMap { idx -> AssistantBlock? in
                    switch blocks[idx] {
                    case .text(let t): return .text(t)
                    case .thinking(let th): return .thinking(th)
                    case .toolUse(let id, let name, let json, let sig):
                        let args: JSONValue = parseToolArgs ? parseJSONObject(json) ?? .object([:]) : .object([:])
                        return .toolCall(ToolCall(id: id, name: name, arguments: args, thoughtSignature: sig))
                    case .none: return nil
                    }
                },
                api: api,
                provider: provider,
                model: modelId,
                responseId: responseId,
                usage: usage,
                stopReason: stopReason,
                timestamp: Timestamp.now()
            )
        }
    }

    /// Emit `text_end` / `thinking_end` / `toolcall_end` once per block when
    /// the stream reports a finish reason or runs out of events.
    func finalizeStreamingBlocks(emit: (AssistantMessageEvent) -> Void) {
        settleEmptyToolCallIds()
        let indices = lock.withLock { order }
        for idx in indices {
            if endedIndices.contains(idx) { continue }
            let partial = snapshot()
            guard let block = lock.withLock({ blocks[idx] }) else { continue }
            switch block {
            case .text(let t):
                emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
            case .thinking(let th):
                emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
            case .toolUse(let id, let name, let json, let sig):
                let call = ToolCall(id: id, name: name, arguments: parseJSONObject(json) ?? .object([:]), thoughtSignature: sig)
                emit(.toolCallEnd(contentIndex: idx, toolCall: call, partial: partial))
            }
            _ = lock.withLock { endedIndices.insert(idx) }
        }
    }

    func finalize() -> AssistantMessage {
        buildMessage(parseToolArgs: true)
    }

    func asAborted() -> AssistantMessage {
        stopReason = .aborted
        var m = buildMessage(parseToolArgs: true)
        m.errorMessage = "Request was aborted"
        return m
    }
}
