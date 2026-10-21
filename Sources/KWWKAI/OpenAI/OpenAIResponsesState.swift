import Foundation
import NIOConcurrencyHelpers

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
    private struct State {
        var blocks: [Int: Block] = [:]
        var order: [Int] = []
        /// Output-index → content-index for each kind of item. Kept separate so
        /// that a reasoning + message + function_call under the same output_index
        /// can coexist (rare, but legal).
        var textByOutput: [Int: Int] = [:]
        var reasoningByOutput: [Int: Int] = [:]
        var toolCallByOutput: [Int: Int] = [:]
    }
    private let state = NIOLockedValueBox(State())

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
        state.withLockedValue { state in
            if let existing = state.textByOutput[outputIndex] { return existing }
            let idx = state.order.count
            state.textByOutput[outputIndex] = idx
            state.order.append(idx)
            state.blocks[idx] = .text(TextContent(text: ""))
            return idx
        }
    }

    func noteReasoningItem(outputIndex: Int) -> Int {
        state.withLockedValue { state in
            if let existing = state.reasoningByOutput[outputIndex] { return existing }
            let idx = state.order.count
            state.reasoningByOutput[outputIndex] = idx
            state.order.append(idx)
            state.blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return idx
        }
    }

    func noteFunctionCallItem(outputIndex: Int, callId: String, name: String, arguments: String = "") -> Int {
        state.withLockedValue { state in
            if let existing = state.toolCallByOutput[outputIndex] { return existing }
            let idx = state.order.count
            state.toolCallByOutput[outputIndex] = idx
            state.order.append(idx)
            state.blocks[idx] = .toolUse(id: callId, name: name, json: arguments)
            return idx
        }
    }

    func updateFunctionCallItem(outputIndex: Int, callId: String?, name: String?, arguments: String?) {
        state.withLockedValue { state in
            guard let index = state.toolCallByOutput[outputIndex],
                  case .toolUse(let currentId, let currentName, let currentJSON) = state.blocks[index]
            else { return }
            state.blocks[index] = .toolUse(
                id: callId.flatMap { $0.isEmpty ? nil : $0 } ?? currentId,
                name: name.flatMap { $0.isEmpty ? nil : $0 } ?? currentName,
                json: Self.settledArguments(streamed: currentJSON, done: arguments)
            )
        }
    }

    /// The arguments a finished function call keeps. `output_item.done`
    /// normally repeats the streamed arguments whole; a relay's can carry
    /// nothing, only some of them, or the rest. An empty or unreadable one
    /// leaves what was streamed, one where the stream was unreadable
    /// replaces it, and with both readable the done keys are laid over the
    /// streamed ones so neither loses a key.
    static func settledArguments(streamed: String, done: String?) -> String {
        guard let done, !done.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let doneObject = StreamedToolArguments.object(done) else { return streamed }
        guard let streamedObject = StreamedToolArguments.object(streamed), !streamedObject.isEmpty else {
            return done
        }
        let merged = streamedObject.merging(doneObject) { _, new in new }
        guard let data = try? JSONEncoder().encode(JSONValue.object(merged)) else { return done }
        return String(decoding: data, as: UTF8.self)
    }

    func textIndex(for outputIndex: Int) -> Int? {
        state.withLockedValue { $0.textByOutput[outputIndex] }
    }
    func reasoningIndex(for outputIndex: Int) -> Int? {
        state.withLockedValue { $0.reasoningByOutput[outputIndex] }
    }
    func toolCallIndex(for outputIndex: Int) -> Int? {
        state.withLockedValue { $0.toolCallByOutput[outputIndex] }
    }

    func appendText(at index: Int, text: String) {
        state.withLockedValue { state in
            if case .text(var t) = state.blocks[index] {
                t.text += text
                state.blocks[index] = .text(t)
            }
        }
    }

    func appendThinking(at index: Int, text: String) {
        state.withLockedValue { state in
            if case .thinking(var th) = state.blocks[index] {
                th.thinking += text
                state.blocks[index] = .thinking(th)
            }
        }
    }

    func setThinkingSignature(at index: Int, signature: String) {
        state.withLockedValue { state in
            if case .thinking(var th) = state.blocks[index] {
                th.thinkingSignature = signature
                state.blocks[index] = .thinking(th)
            }
        }
    }

    func thinkingSignature(at index: Int) -> String? {
        state.withLockedValue { state in
            if case .thinking(let th) = state.blocks[index] { return th.thinkingSignature }
            return nil
        }
    }

    func appendToolCallArgs(at index: Int, chunk: String) {
        state.withLockedValue { state in
            if case .toolUse(let id, let name, let json) = state.blocks[index] {
                state.blocks[index] = .toolUse(id: id, name: name, json: json + chunk)
            }
        }
    }

    func textValue(at index: Int) -> String {
        state.withLockedValue { state in
            if case .text(let t) = state.blocks[index] { return t.text } else { return "" }
        }
    }

    func thinkingValue(at index: Int) -> String {
        state.withLockedValue { state in
            if case .thinking(let th) = state.blocks[index] { return th.thinking } else { return "" }
        }
    }

    func toolCallValue(at index: Int) -> ToolCall? {
        state.withLockedValue { state in
            guard case .toolUse(let id, let name, let json) = state.blocks[index] else { return nil }
            let decoded = StreamedToolArguments.decode(json)
            return ToolCall(id: id, name: name, arguments: decoded.arguments, unparsedArguments: decoded.unparsed)
        }
    }

    func hasToolCalls() -> Bool {
        state.withLockedValue { !$0.toolCallByOutput.isEmpty }
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
        state.withLockedValue { state in
            AssistantMessage(
                content: state.order.compactMap { idx -> AssistantBlock? in
                    switch state.blocks[idx] {
                    case .text(let t): return .text(t)
                    case .thinking(let th): return .thinking(th)
                    case .toolUse(let id, let name, let json):
                        let decoded: (arguments: JSONValue, unparsed: String?) = parseToolArgs
                            ? StreamedToolArguments.decode(json)
                            : (.object([:]), nil)
                        return .toolCall(ToolCall(
                            id: id,
                            name: name,
                            arguments: decoded.arguments,
                            unparsedArguments: decoded.unparsed
                        ))
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
