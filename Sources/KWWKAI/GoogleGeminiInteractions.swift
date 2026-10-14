import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gemini over the Interactions API — `POST /v1beta/interactions` — which is
/// the only wire AI Studio keys created since October 2026 can use (see
/// `GoogleGeminiProvider.Wire`).
///
/// kwwk keeps the transcript, so every request is stateless: `store: false`,
/// the whole history goes in `input` as steps, and `previous_interaction_id`
/// is never sent.
///
/// Wire, as measured against gemini-3.8-flash on 2026-10-14:
///  - Request steps: `user_input {content}`, `thought {signature, summary}`,
///    `model_output {content}`, `function_call {id, name, arguments,
///    signature}`, `function_result {call_id, name, result, is_error}`.
///  - The stream is `step.start` (carries the step, with `id`/`name`/
///    `signature` on a call) → `step.delta` (`text`, `thought_summary`,
///    `thought_signature`, `arguments_delta` with a JSON string) →
///    `step.stop`, per step `index`, then `interaction.completed` with the
///    final `status` and `usage`, then `data: [DONE]`.
///  - `status`: `completed`, `requires_action` (tool calls), `incomplete`
///    (output token limit), `failed`, `cancelled`, `budget_exceeded`.
///  - A step whose calls carry no valid signature is refused with 400
///    "Request contains an invalid argument." when it is part of the turn
///    being answered; so is a forged signature. Google's
///    `skip_thought_signature_validator` on the first call is accepted, and
///    so are foreign call ids (`toolu_…`).
///  - An error status comes back with an SSE-shaped body
///    (`event: error` / `data: {"error":{…}}`).
extension GoogleGeminiProvider {
    /// Signatures read from the Interactions wire are stored with this mark.
    /// A signature without it came from `generateContent` (sessions saved
    /// before the move); whether Interactions accepts those is unknown and a
    /// refused one fails the whole request, so they are not replayed here.
    /// The mark is not base64, so `generateContent` drops a marked one too.
    static let interactionsSignatureMark = "ix:"

    static func markInteractionsSignature(_ sig: String?) -> String? {
        guard let sig, !sig.isEmpty else { return nil }
        return interactionsSignatureMark + sig
    }

    static func interactionsSignature(_ stored: String?) -> String? {
        guard let stored, stored.hasPrefix(interactionsSignatureMark) else { return nil }
        let sig = String(stored.dropFirst(interactionsSignatureMark.count))
        return sig.isEmpty ? nil : sig
    }

    func runInteractions(
        out: AssistantMessageStream,
        model: Model,
        context: Context,
        options: StreamOptions?
    ) async {
        let url = URL(string: "\(interactionsBase(model))/v1beta/interactions?alt=sse")
            ?? URL(string: "https://\(Self.aiStudioHost)/v1beta/interactions?alt=sse")!

        let body: Data
        do {
            body = try Self.encodeInteractionsBody(model: model, context: context, options: options)
        } catch {
            let msg = Self.makeError(api: api, model: model, text: "Failed to encode request: \(error)")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
            return
        }

        var headers: [String: String] = [
            "content-type": "application/json",
            "accept": "text/event-stream",
        ]
        for (k, v) in extraHeaders { headers[k] = v }
        if let auth = options?.resolvedAuth {
            if let key = resolvedQueryKey(auth, expectedName: "key") {
                headers["x-goog-api-key"] = key
            }
            applyResolvedAuth(auth, to: &headers)
        } else if let key = options?.apiKey ?? defaultAPIKey, !key.isEmpty {
            headers["x-goog-api-key"] = key
        }
        for (k, v) in options?.headers ?? [:] { headers[k] = v }

        do {
            let (response, stream) = try await client.stream(
                url: url, method: "POST", headers: headers, body: body,
                cancellation: options?.cancellation
            )
            if response.statusCode >= 400 {
                let failure = await ProviderFailure.http(response, body: Self.unwrapSSEErrorBody(stream))
                let msg = Self.makeError(api: api, model: model, text: failure.message, failure: failure)
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
                return
            }
            let state = GeminiInteractionsState(api: api, provider: model.provider, modelId: model.id)
            state.signal = options?.cancellation
            let driveTask = Task {
                try await Self.driveInteractions(events: parseSSE(bytes: stream), out: out, state: state)
            }
            let cancelReg = options?.cancellation?.onCancel { _ in driveTask.cancel() }
            defer { cancelReg?.cancel() }
            try await driveTask.value
        } catch {
            if options?.cancellation?.isCancelled == true {
                let aborted = Self.makeAborted(api: api, model: model)
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
            } else {
                let msg = Self.makeError(api: api, model: model, text: "\(error)", failure: .capture(error))
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
            }
        }
    }

    /// An error body sent as SSE (`event: error` / `data: {…}`) reduced to
    /// its JSON, so `ProviderFailure.http` reads Google's message and code.
    static func unwrapSSEErrorBody(_ body: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var bytes = Data()
                do {
                    for try await chunk in body {
                        bytes.append(chunk)
                        if bytes.count >= 16_384 { break }
                    }
                } catch {}
                let text = String(decoding: bytes, as: UTF8.self)
                let data = text.split(whereSeparator: \.isNewline)
                    .first { $0.hasPrefix("data:") }
                    .map { String($0.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces) }
                continuation.yield(data.flatMap { $0.data(using: .utf8) } ?? bytes)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Stream

    static func driveInteractions(
        events: AsyncThrowingStream<SSEMessage, Error>,
        out: AssistantMessageStream,
        state: GeminiInteractionsState
    ) async throws {
        var emittedStart = false
        func ensureStart() {
            if !emittedStart {
                out.push(.start(partial: state.snapshot()))
                emittedStart = true
            }
        }
        var status: String?
        for try await sse in events {
            if state.signal?.isCancelled == true {
                let aborted = state.asAborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            guard case .object(let obj)? = parseJSONObject(sse.data) else { continue }
            let eventType = obj["event_type"]?.ixString ?? sse.event
            switch eventType {
            case "error":
                let failure = ProviderFailure.payload(.object(obj))
                var message = state.snapshot()
                message.stopReason = .error
                message.errorMessage = failure.message
                message.failure = failure
                out.push(.error(reason: .error, error: message))
                out.end(message)
                return

            case "step.start":
                guard let index = obj["index"]?.ixInt,
                      case .object(let step)? = obj["step"] else { continue }
                switch step["type"]?.ixString {
                case "thought":
                    ensureStart()
                    let content = state.openThinking(step: index, signature: step["signature"]?.ixString)
                    out.push(.thinkingStart(contentIndex: content, partial: state.snapshot()))
                    for text in summaryTexts(step["summary"]) where !text.isEmpty {
                        state.appendThinking(step: index, text: text)
                        out.push(.thinkingDelta(contentIndex: content, delta: text, partial: state.snapshot()))
                    }
                case "model_output":
                    ensureStart()
                    let content = state.openText(step: index)
                    out.push(.textStart(contentIndex: content, partial: state.snapshot()))
                    for text in summaryTexts(step["content"]) where !text.isEmpty {
                        state.appendText(step: index, text: text)
                        out.push(.textDelta(contentIndex: content, delta: text, partial: state.snapshot()))
                    }
                case "function_call":
                    ensureStart()
                    let content = state.openToolCall(
                        step: index,
                        id: step["id"]?.ixString,
                        name: step["name"]?.ixString ?? "",
                        arguments: step["arguments"],
                        signature: step["signature"]?.ixString
                    )
                    out.push(.toolCallStart(contentIndex: content, partial: state.snapshot()))
                default:
                    // Server-side tools (search, code execution, …) are not
                    // offered, so nothing else is expected; skip it.
                    continue
                }

            case "step.delta":
                guard let index = obj["index"]?.ixInt,
                      case .object(let delta)? = obj["delta"],
                      let content = state.contentIndex(step: index) else { continue }
                switch delta["type"]?.ixString {
                case "text":
                    guard let text = delta["text"]?.ixString, !text.isEmpty else { continue }
                    state.appendText(step: index, text: text)
                    out.push(.textDelta(contentIndex: content, delta: text, partial: state.snapshot()))
                case "thought_summary":
                    for text in summaryTexts(delta["content"]) where !text.isEmpty {
                        state.appendThinking(step: index, text: text)
                        out.push(.thinkingDelta(contentIndex: content, delta: text, partial: state.snapshot()))
                    }
                case "thought_signature":
                    state.setSignature(step: index, signature: delta["signature"]?.ixString)
                case "arguments_delta":
                    guard let text = delta["arguments"]?.ixString, !text.isEmpty else { continue }
                    state.appendArguments(step: index, text: text)
                    out.push(.toolCallDelta(contentIndex: content, delta: text, partial: state.snapshot()))
                default:
                    continue
                }

            case "step.stop":
                guard let index = obj["index"]?.ixInt else { continue }
                if let ended = state.close(step: index) { out.push(ended) }

            case "interaction.status_update":
                if case .object(let usage)? = obj["usage"] { state.applyUsage(usage) }

            case "interaction.completed":
                guard case .object(let interaction)? = obj["interaction"] else { continue }
                if case .object(let usage)? = interaction["usage"] { state.applyUsage(usage) }
                if let id = interaction["id"]?.ixString, !id.isEmpty { state.responseId = id }
                status = interaction["status"]?.ixString ?? "completed"
                if let failure = completionFailure(status: status, interaction: interaction) {
                    state.failure = failure
                }

            default:
                continue
            }
        }

        if state.signal?.isCancelled == true {
            let aborted = state.asAborted()
            out.push(.error(reason: .aborted, error: aborted))
            out.end(aborted)
            return
        }
        for ended in state.closeAll() { out.push(ended) }
        var final = state.snapshot()
        switch status {
        case nil:
            // Same wording as generateContent's, which the retry policy replays.
            final.stopReason = .error
            final.errorMessage = "Gemini stream ended without a finish reason"
            final.failure = ProviderFailure(message: final.errorMessage ?? "")
        case "incomplete":
            final.stopReason = .length
        case "completed", "requires_action":
            if state.failure != nil {
                final.stopReason = .error
            } else if state.hasToolCalls() {
                final.stopReason = .toolUse
            } else if !final.hasReplayUnsafeContent {
                // A completed reply with no answer at all (see the
                // generateContent path, magpie #667): a failed reply.
                let failure = ProviderFailure(message: "Gemini stream ended without content", rawStopReason: status)
                final.stopReason = .error
                final.errorMessage = failure.message
                final.failure = failure
            } else {
                final.stopReason = .stop
            }
        default:
            final.stopReason = .error
            if final.failure == nil {
                let failure = ProviderFailure(message: "Gemini interaction \(status ?? "")", rawStopReason: status)
                final.errorMessage = failure.message
                final.failure = failure
            }
        }
        if final.stopReason == .error { out.push(.error(reason: .error, error: final)) }
        else { out.push(.done(reason: final.stopReason, message: final)) }
        out.end(final)
    }

    /// The texts in a `thought_summary`/`model_output` content value: one
    /// content object or an array of them.
    static func summaryTexts(_ value: JSONValue?) -> [String] {
        switch value {
        case .object(let obj)?:
            return obj["text"]?.ixString.map { [$0] } ?? []
        case .array(let items)?:
            return items.flatMap { summaryTexts($0) }
        default:
            return []
        }
    }

    static func completionFailure(status: String?, interaction: [String: JSONValue]) -> ProviderFailure? {
        switch status {
        case "failed", "cancelled", "budget_exceeded":
            var message = "Gemini interaction \(status ?? "")"
            if case .array(let errors)? = interaction["errors"],
               case .object(let first)? = errors.first,
               let detail = first["message"]?.ixString, !detail.isEmpty {
                message += ": \(detail)"
            }
            return ProviderFailure(message: message, rawStopReason: status)
        default:
            return nil
        }
    }

    // MARK: - Encoding

    static func encodeInteractionsBody(
        model: Model, context: Context, options: StreamOptions?
    ) throws -> Data {
        var context = context
        context.messages = TransformMessages.normalize(context.messages, model: model)
        var root: [String: Any] = [
            "model": model.id,
            "input": encodeInteractionsInput(context: context, model: model),
            "store": false,
            "stream": true,
        ]
        if let sys = context.systemPrompt, !sys.isEmpty {
            root["system_instruction"] = sys
        }
        var generationConfig: [String: Any] = [:]
        if let tools = context.tools, !tools.isEmpty {
            root["tools"] = tools.map { tool -> [String: Any] in
                var entry: [String: Any] = [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                ]
                if let params = anyFromJSONValue(tool.parameters) {
                    entry["parameters"] = params
                }
                return entry
            }
            if let choice = interactionsToolChoice(options?.toolChoice) {
                generationConfig["tool_choice"] = choice
            }
        }
        if let temp = options?.temperature { generationConfig["temperature"] = temp }
        if let maxTokens = OutputTokenPolicy.effectiveLimit(for: model, requested: options?.maxTokens) {
            generationConfig["max_output_tokens"] = maxTokens
        }
        let id = model.id.lowercased()
        if let reasoning = options?.reasoning {
            if usesThinkingLevel(id) {
                generationConfig["thinking_level"] = catalogThinkingLevel(
                    geminiThinkingLevel(reasoning, modelId: id), model: model).lowercased()
            }
            // Interactions has no integer budget; Gemini 2.x thinks dynamically.
            generationConfig["thinking_summaries"] = "auto"
        } else if model.reasoning {
            // Reasoning off on a model that can't stop thinking: its least
            // level (same table as generateContent's disabled config).
            if isGemini3Pro(id) {
                generationConfig["thinking_level"] = catalogThinkingLevel("LOW", model: model).lowercased()
            } else if isGemini3Flash(id) || isGemma4(id) {
                generationConfig["thinking_level"] = catalogThinkingLevel("MINIMAL", model: model).lowercased()
            }
            generationConfig["thinking_summaries"] = "none"
        }
        if !generationConfig.isEmpty {
            root["generation_config"] = generationConfig
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func interactionsToolChoice(_ choice: ToolChoice?) -> Any? {
        guard let choice else { return nil }
        switch choice {
        case .auto: return "auto"
        case .none: return "none"
        case .required: return "any"
        case .tool(let name): return ["allowed_tools": ["mode": "any", "tools": [name]]]
        }
    }

    static func interactionsImage(_ image: ImageContent) -> [String: Any] {
        ["type": "image", "data": image.data, "mime_type": image.mimeType]
    }

    static func encodeInteractionsInput(context: Context, model: Model) -> [[String: Any]] {
        var steps: [[String: Any]] = []
        let acceptsImages = model.input.contains(.image)
        for message in context.messages {
            switch message {
            case .system:
                continue

            case .user(let u):
                let content: [[String: Any]] = u.content.compactMap { block in
                    switch block {
                    case .text(let t): return ["type": "text", "text": t.text]
                    case .image(let i): return acceptsImages ? interactionsImage(i) : nil
                    }
                }
                if !content.isEmpty {
                    steps.append(["type": "user_input", "content": content])
                }

            case .assistant(let a):
                // Cross-model thinking is already text, and foreign call
                // signatures are already gone (TransformMessages); a
                // signature goes back only to the model that wrote it.
                let isSameModel = a.provider == model.provider
                    && a.api == model.api && a.model == model.id
                func signature(_ stored: String?) -> String? {
                    isSameModel ? interactionsSignature(stored) : nil
                }
                var turn: [[String: Any]] = []
                for block in a.content {
                    switch block {
                    case .fallback:
                        break
                    case .thinking(let th):
                        var step: [String: Any] = ["type": "thought"]
                        if let sig = signature(th.thinkingSignature) { step["signature"] = sig }
                        if !th.thinking.isEmpty {
                            step["summary"] = [["type": "text", "text": th.thinking]]
                        }
                        if step.count > 1 { turn.append(step) }
                    case .text(let t):
                        guard !t.text.isEmpty else { break }
                        turn.append(["type": "model_output", "content": [["type": "text", "text": t.text]]])
                    case .toolCall(let tc):
                        var step: [String: Any] = [
                            "type": "function_call",
                            "id": tc.id,
                            "name": tc.name,
                            "arguments": anyFromJSONValue(tc.arguments) ?? [:] as Any,
                        ]
                        if let sig = signature(tc.thoughtSignature) { step["signature"] = sig }
                        turn.append(step)
                    }
                }
                // Gemini 3 refuses a step of calls that carries no signature
                // (another model's, or one saved off generateContent): the
                // first call goes with the value Google documents for
                // history it did not write. Text ahead of such calls is
                // refused even then (Claude's thinking, downgraded to text,
                // sits there), unless the turn opens with a thought signed
                // the same way; one leads every such turn, which is
                // accepted with or without text (measured 2026-10-14).
                if (geminiMajorVersion(model.id) ?? 0) >= 3,
                   !turn.contains(where: { $0["type"] as? String == "function_call" && $0["signature"] != nil }),
                   let first = turn.firstIndex(where: { $0["type"] as? String == "function_call" }) {
                    turn[first]["signature"] = skipThoughtSignature
                    if !turn.contains(where: { $0["type"] as? String == "thought" && $0["signature"] != nil }) {
                        turn.insert(["type": "thought", "signature": skipThoughtSignature], at: 0)
                    }
                }
                steps.append(contentsOf: turn)

            case .toolResult(let tr):
                let text = tr.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text } else { return nil }
                }.joined(separator: "\n")
                let images: [ImageContent] = acceptsImages
                    ? tr.content.compactMap { if case .image(let i) = $0 { return i } else { return nil } }
                    : []
                var step: [String: Any] = [
                    "type": "function_result",
                    "call_id": tr.toolCallId,
                    "name": tr.toolName,
                ]
                if images.isEmpty {
                    step["result"] = text
                } else {
                    var parts: [[String: Any]] = []
                    if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                    parts.append(contentsOf: images.map(interactionsImage))
                    step["result"] = parts
                }
                if tr.isError { step["is_error"] = true }
                steps.append(step)
            }
        }
        return steps
    }
}

// MARK: - Mutable state

/// One reply read off the Interactions stream. Content is ordered as the
/// steps arrive; each step `index` maps to one content block.
final class GeminiInteractionsState: @unchecked Sendable {
    let api: String
    let provider: String
    let modelId: String
    var signal: CancellationHandle?

    var responseId: String?
    var usage = Usage()
    var failure: ProviderFailure?

    private enum Block {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolCall(ToolCall, rawArguments: String)
    }

    private let lock = NSLock()
    private var blocks: [Block] = []
    private var stepToContent: [Int: Int] = [:]
    private var open: Set<Int> = []

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    private func add(_ block: Block, step: Int) -> Int {
        lock.withLock {
            let index = blocks.count
            blocks.append(block)
            stepToContent[step] = index
            open.insert(index)
            return index
        }
    }

    func contentIndex(step: Int) -> Int? {
        lock.withLock { stepToContent[step] }
    }

    func openThinking(step: Int, signature: String?) -> Int {
        add(.thinking(ThinkingContent(
            thinking: "",
            thinkingSignature: GoogleGeminiProvider.markInteractionsSignature(signature)
        )), step: step)
    }

    func openText(step: Int) -> Int {
        add(.text(TextContent(text: "")), step: step)
    }

    func openToolCall(step: Int, id: String?, name: String, arguments: JSONValue?, signature: String?) -> Int {
        let callId: String = {
            if let id, !id.isEmpty { return id }
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            return "\(GoogleGeminiProvider.mintedIdPrefix)\(step)-\(stamp)"
        }()
        let call = ToolCall(
            id: callId, name: name, arguments: arguments ?? .object([:]),
            thoughtSignature: GoogleGeminiProvider.markInteractionsSignature(signature)
        )
        return add(.toolCall(call, rawArguments: ""), step: step)
    }

    private func update(step: Int, _ body: (inout Block) -> Void) {
        lock.withLock {
            guard let index = stepToContent[step] else { return }
            body(&blocks[index])
        }
    }

    func appendText(step: Int, text: String) {
        update(step: step) { if case .text(var t) = $0 { t.text += text; $0 = .text(t) } }
    }

    func appendThinking(step: Int, text: String) {
        update(step: step) { if case .thinking(var th) = $0 { th.thinking += text; $0 = .thinking(th) } }
    }

    func setSignature(step: Int, signature: String?) {
        guard let marked = GoogleGeminiProvider.markInteractionsSignature(signature) else { return }
        update(step: step) {
            switch $0 {
            case .thinking(var th): th.thinkingSignature = marked; $0 = .thinking(th)
            case .toolCall(var call, let raw): call.thoughtSignature = marked; $0 = .toolCall(call, rawArguments: raw)
            case .text: break
            }
        }
    }

    func appendArguments(step: Int, text: String) {
        update(step: step) {
            if case .toolCall(let call, let raw) = $0 { $0 = .toolCall(call, rawArguments: raw + text) }
        }
    }

    /// Ends the step's block, returning the event that says so.
    func close(step: Int) -> AssistantMessageEvent? {
        guard let index = contentIndex(step: step) else { return nil }
        return close(index: index)
    }

    func closeAll() -> [AssistantMessageEvent] {
        let indices = lock.withLock { open.sorted() }
        return indices.compactMap { close(index: $0) }
    }

    private func close(index: Int) -> AssistantMessageEvent? {
        let block: Block? = lock.withLock {
            guard open.remove(index) != nil else { return nil }
            if case .toolCall(var call, let raw) = blocks[index] {
                // The arguments stream as a JSON string; the step's own
                // `arguments` stand when none streamed.
                if !raw.isEmpty, let parsed = parseJSONObject(raw) { call.arguments = parsed }
                blocks[index] = .toolCall(call, rawArguments: raw)
            }
            return blocks[index]
        }
        guard let block else { return nil }
        let partial = snapshot()
        switch block {
        case .text(let t): return .textEnd(contentIndex: index, content: t.text, partial: partial)
        case .thinking(let th): return .thinkingEnd(contentIndex: index, content: th.thinking, partial: partial)
        case .toolCall(let call, _): return .toolCallEnd(contentIndex: index, toolCall: call, partial: partial)
        }
    }

    func hasToolCalls() -> Bool {
        lock.withLock { blocks.contains { if case .toolCall = $0 { return true } else { return false } } }
    }

    func applyUsage(_ obj: [String: JSONValue]) {
        func int(_ key: String) -> Int { obj[key]?.ixInt ?? 0 }
        let input = int("total_input_tokens")
        let cached = int("total_cached_tokens")
        let thoughts = int("total_thought_tokens")
        lock.withLock {
            usage.input = max(0, input - cached)
            usage.output = int("total_output_tokens") + thoughts
            usage.cacheRead = cached
            usage.reasoning = thoughts
            usage.totalTokens = int("total_tokens")
        }
    }

    func snapshot() -> AssistantMessage {
        lock.withLock {
            AssistantMessage(
                content: blocks.map { block -> AssistantBlock in
                    switch block {
                    case .text(let t): return .text(t)
                    case .thinking(let th): return .thinking(th)
                    case .toolCall(let call, _): return .toolCall(call)
                    }
                },
                api: api,
                provider: provider,
                model: modelId,
                responseId: responseId,
                usage: usage,
                stopReason: .stop,
                errorMessage: failure?.message,
                failure: failure,
                timestamp: Timestamp.now()
            )
        }
    }

    func asAborted() -> AssistantMessage {
        var m = snapshot()
        m.stopReason = .aborted
        m.errorMessage = "Request was aborted"
        return m
    }
}

private extension JSONValue {
    var ixString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var ixInt: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }
}
