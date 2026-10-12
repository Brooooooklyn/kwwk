import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streaming provider for Qoder and Qoder CN subscriptions
/// (`api == "qoder-chat"`).
///
/// Qoder lists no public API, so this speaks the endpoint its desktop client
/// uses: `POST <api>/algo/api/v2/service/pro/sse/agent_chat_generation`.
/// One turn is:
///
/// 1. The account's model listing (fetched once and kept) gives the chosen
///    model's entry, which the request sends back whole as `model_config`.
/// 2. The JSON body goes through the client's own base64 codec
///    (`QoderCodec`) and is signed with the COSY envelope (`QoderCosy`).
/// 3. The reply is SSE: each `data:` line is an envelope whose `body` is an
///    OpenAI chat-completion chunk (text, `reasoning_content`, `tool_calls`,
///    usage), and whose `statusCodeValue` carries a failure.
///
/// Tools are ordinary client-side tool calls in OpenAI's shape. Ported from
/// magpie `internal/gateway/qoder.go`.
public final class QoderChatProvider: APIProvider, @unchecked Sendable {
    public let api = QoderModels.api
    private let client: HTTPClient
    private let listings = Listings()

    /// The query asks for the LLM result, names the common agent, and says
    /// `Encode=1` for the body codec.
    static let chatPath = "/algo/api/v2/service/pro/sse/agent_chat_generation?FetchKeys=llm_model_result&AgentId=agent_common&Encode=1"

    /// Qoder's own line, which the caller's system prompt follows.
    static let systemPreamble = "You are a Qoder agent. Use the instructions below and the tools available to you to assist the user."

    public init(client: HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached { [self] in
            await run(out: out, model: model, context: context, options: options)
        }
        return out
    }

    // MARK: - Run

    private func run(out: AssistantMessageStream, model: Model, context: Context, options: StreamOptions?) async {
        let state = QoderStreamState(api: api, model: model)
        let site = QoderSite.of(model.provider)
        guard let auth = options?.resolvedAuth, let token = auth.token, !token.isEmpty,
              let account = QoderAccount(token: token, fields: auth.metadata) else {
            let message = state.failed(ProviderFailure(
                message: "\(site.name) sign-in is required (run /login \(site.id))", httpStatus: 401
            ))
            out.push(.error(reason: .error, error: message))
            out.end(message)
            return
        }
        let cancellation = options?.cancellation
        do {
            let baseURL = model.baseURL.isEmpty ? site.api : model.baseURL
            let listed = try await listings.model(
                model.id, baseURL: baseURL, account: account, site: site, client: client, cancellation: cancellation
            )
            let messages = TransformMessages.normalize(context.messages, model: model)
            let wire = QoderCodec.encodeRequestBody(
                try Self.chatBody(model: listed, context: context, messages: messages, options: options)
            )
            let url = baseURL + Self.chatPath
            var headers = try QoderCosy.headers(
                url: url, account: account, body: wire, timestamp: Int64(Date().timeIntervalSince1970)
            )
            headers["Accept"] = "text/event-stream"
            headers["Cache-Control"] = "no-cache"
            headers["X-Model-Key"] = listed.key
            headers["X-Model-Source"] = listed.source
            for (name, value) in options?.headers ?? [:] { headers[name] = value }

            let (response, body) = try await client.stream(
                url: URL(string: url)!, method: "POST", headers: headers, body: Data(wire.utf8),
                cancellation: cancellation
            )
            guard (200..<300).contains(response.statusCode) else {
                throw await Self.httpFailure(response: response, body: body)
            }
            // A web page served 200 is a gateway's, not Qoder's answer
            // (magpie #1012).
            if response.value(forHTTPHeaderField: "content-type")?.lowercased().hasPrefix("text/html") == true {
                throw ProviderFailure(
                    message: "Qoder: answered \(response.statusCode) with a web page, not an API reply", httpStatus: 502
                )
            }

            out.push(.start(partial: state.snapshot()))
            let driveTask = Task {
                try await Self.drive(body: body, state: state, out: out, cancellation: cancellation)
            }
            let cancelRegistration = cancellation?.onCancel { _ in driveTask.cancel() }
            defer { cancelRegistration?.cancel() }
            try await driveTask.value

            if cancellation?.isCancelled == true {
                let aborted = state.aborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            state.closeOpenBlocks(emit: { out.push($0) })
            let final = state.snapshot()
            out.push(.done(reason: final.stopReason, message: final))
            out.end(final)
        } catch {
            if cancellation?.isCancelled == true {
                let aborted = state.aborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
            } else {
                let message = state.failed(.capture(error))
                out.push(.error(reason: .error, error: message))
                out.end(message)
            }
        }
    }

    /// Reads the reply line by line. Qoder's chunks are single `data:` lines;
    /// anything else (blanks, the timing line that closes the stream) is
    /// skipped. The turn ends at the envelope whose body is `[DONE]`, not at
    /// the chunk that names a `finish_reason`: Qoder sends the token usage in
    /// a chunk of its own after the finish, with no choices, so reading only
    /// up to the finish counted every reply as 0 tokens (measured on a real
    /// account, magpie-plugins qoder 0.2.4, `stream.test.mjs`). A stream that
    /// ends without a finish is taken as it stands, unless it stopped inside
    /// a tool call's arguments — those would run as `{}`.
    static func drive(
        body: AsyncThrowingStream<Data, Error>,
        state: QoderStreamState,
        out: AssistantMessageStream,
        cancellation: CancellationHandle?
    ) async throws {
        var splitter = QoderToolCallSplitter()
        var nativeToolIndex = -1
        var buffer = Data()
        let emit: (AssistantMessageEvent) -> Void = { out.push($0) }

        func flushText() {
            let held = splitter.flush()
            if !held.isEmpty { state.appendText(held, emit: emit) }
        }

        /// False once Qoder has said the reply is done.
        func handle(_ line: Data) throws -> Bool {
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("data:") else { return true }
            let payload = text.dropFirst("data:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let envelope = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
                return true
            }
            // The chunk rides as JSON text; one sent as an object reads the
            // same (magpie reads either).
            var inner = envelope["body"] as? String ?? ""
            if let object = envelope["body"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: object) {
                inner = String(decoding: data, as: UTF8.self)
            }
            if let status = Self.int(envelope["statusCodeValue"]), status != 200 {
                throw Self.failure(status: status, body: Data((inner.isEmpty ? payload : inner).utf8))
            }
            if inner.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return false }
            guard let chunk = (try? JSONSerialization.jsonObject(with: Data(inner.utf8))) as? [String: Any] else {
                return true
            }
            let choice = (chunk["choices"] as? [Any])?.first as? [String: Any]
            let delta = choice?["delta"] as? [String: Any] ?? [:]
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                state.appendThinking(reasoning, emit: emit)
            }
            if let content = delta["content"] as? String {
                for fragment in splitter.feed(content) {
                    switch fragment {
                    case .text(let text):
                        state.appendText(text, emit: emit)
                    case .call(let name, let arguments):
                        state.startToolCall(id: "call_" + QoderCosy.compactUUID(), name: name, emit: emit)
                        state.appendToolArguments(arguments, emit: emit)
                    }
                }
            }
            // Qoder also serves tool calls in OpenAI's way. The id it sends
            // is the one the result is answered with, so it is kept; a new
            // `index` opens the next call.
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let function = call["function"] as? [String: Any] ?? [:]
                let index = Self.int(call["index"]) ?? 0
                if index != nativeToolIndex {
                    nativeToolIndex = index
                    flushText()
                    let id = call["id"] as? String ?? ""
                    state.startToolCall(
                        id: id.isEmpty ? "call_" + QoderCosy.compactUUID() : id,
                        name: function["name"] as? String ?? "", emit: emit
                    )
                }
                if let arguments = function["arguments"] as? String, !arguments.isEmpty {
                    state.appendToolArguments(arguments, emit: emit)
                }
            }
            if let finish = choice?["finish_reason"] as? String, !finish.isEmpty {
                state.setFinishReason(finish)
            }
            // Whichever chunk carries the usage: the finishing one, or the
            // one of its own that follows it.
            if let usage = chunk["usage"] as? [String: Any] {
                state.setUsage(
                    prompt: Self.int(usage["prompt_tokens"]) ?? 0,
                    completion: Self.int(usage["completion_tokens"]) ?? 0,
                    cached: Self.int((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]) ?? 0,
                    reasoning: Self.int((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"]) ?? 0
                )
            }
            return true
        }

        var received = false
        var done = false
        do {
            reading: for try await chunk in body {
                if cancellation?.isCancelled == true { return }
                received = received || !chunk.isEmpty
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    if try !handle(Data(line)) {
                        done = true
                        break reading
                    }
                }
            }
        } catch let failure as ProviderFailure {
            throw failure
        } catch {
            if cancellation?.isCancelled == true || error is CancellationError { throw error }
            var failure = ProviderFailure.capture(error)
            failure.message = "Qoder: reading stream: \(failure.message)"
            throw failure
        }
        if cancellation?.isCancelled == true { return }
        if !done {
            if !buffer.isEmpty { _ = try handle(buffer) }
            // Nothing at all under a 200 is no API reply (magpie #1012).
            if !received {
                throw ProviderFailure(message: "Qoder: answered 200 with nothing in it, not an API reply", httpStatus: 502)
            }
            if !state.sawFinishReason, state.hasIncompleteToolArguments {
                throw ProviderFailure(message: "Qoder: stream ended before its tool call was complete")
            }
        }
        flushText()
    }

    // MARK: - Models

    /// Each account's listing, fetched on first use. A model the kept
    /// listing doesn't name gets one fresh read before it is refused: the
    /// roster changes under a long-lived process.
    private actor Listings {
        private var byAccount: [String: [QoderModelInfo]] = [:]

        func model(
            _ key: String, baseURL: String, account: QoderAccount, site: QoderSite,
            client: HTTPClient, cancellation: CancellationHandle?
        ) async throws -> QoderModelInfo {
            let cacheKey = "\(baseURL)\n\(account.uid)"
            if let found = byAccount[cacheKey]?.first(where: { $0.key == key }) { return found }
            let fresh = try await QoderModels.fetchListing(
                baseURL: baseURL, account: account, client: client, cancellation: cancellation
            )
            byAccount[cacheKey] = fresh
            guard let found = fresh.first(where: { $0.key == key }) else {
                throw ProviderFailure(message: "\(site.name): unknown or disabled model \"\(key)\"", httpStatus: 400)
            }
            return found
        }
    }

    // MARK: - Request building

    /// The plaintext JSON `agent_chat_generation` takes: the system prompt
    /// (twice — as `system` and as the first message), the turns as OpenAI
    /// turns, the caller's tools as native function tools, and the model's
    /// own listing entry.
    static func chatBody(
        model: QoderModelInfo, context: Context, messages: [Message], options: StreamOptions?
    ) throws -> Data {
        let tools = context.tools ?? []
        var systemText = systemPreamble
        if let prompt = context.systemPrompt, !prompt.isEmpty { systemText += "\n\n" + prompt }
        if case .required? = options?.toolChoice, !tools.isEmpty {
            systemText += "\nYou must call an available function in this response."
        }
        let system: [String: Any] = ["type": "text", "text": systemText]

        let thinking = thinking(options?.reasoning, model: model)
        var parameters: [String: Any] = [
            "enable_thinking": thinking.enabled,
            "max_tokens": options?.maxTokens.flatMap { $0 > 0 ? $0 : nil } ?? QoderModels.defaultMaxTokens,
        ]
        if let effort = thinking.effort { parameters["reasoning_effort"] = effort }
        if model.maxInputTokens > 0 { parameters["context_length"] = model.maxInputTokens }

        let configPlaceholder = "model_config:" + UUID().uuidString
        var body: [String: Any] = [
            "parameters": parameters,
            "business": [
                "product": "app", "version": QoderCosy.clientVersion, "type": "agent",
                "id": QoderCosy.compactUUID(), "name": "kwwk session",
                "begin_at": Int64(Date().timeIntervalSince1970 * 1000), "stage": "start",
            ] as [String: Any],
            "agent_id": "agent_common",
            "task_id": "common",
            "session_type": "app",
            "model_config": configPlaceholder,
            "system": [system],
            "messages": [["role": "system", "content": [system]] as [String: Any]] + chatMessages(messages),
        ]
        var sendsTools = !tools.isEmpty
        if case .none? = options?.toolChoice { sendsTools = false }
        if sendsTools { body["tools"] = try tools.map(chatTool) }

        // The listing entry goes back exactly as Qoder listed it, so it is
        // spliced in as text rather than rebuilt.
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let text = String(decoding: encoded, as: UTF8.self)
        guard let slot = text.range(of: "\"\(configPlaceholder)\"") else {
            throw ProviderFailure(message: "Qoder: missing model configuration")
        }
        return Data(text.replacingCharacters(in: slot, with: model.config).utf8)
    }

    /// The turns as OpenAI turns, the format Qoder's chat endpoint takes: an
    /// assistant's tool calls as `tool_calls` and their results as `tool`
    /// turns named by `tool_call_id`, so a result is paired with its call by
    /// id and not by order. A tool turn holds text only, so the images a
    /// tool returned go after the tool turns in a user turn — as the start
    /// of the user's own turn when one comes next.
    static func chatMessages(_ messages: [Message]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var toolNames: [String: String] = [:]
        var pendingImages: [[String: Any]] = []

        func image(_ image: ImageContent) -> [String: Any]? {
            guard !image.data.isEmpty else { return nil }
            return ["type": "image_url", "image_url": ["url": "data:\(image.mimeType);base64,\(image.data)"]]
        }
        func showPendingImages() {
            guard !pendingImages.isEmpty else { return }
            out.append(["role": "user", "content": pendingImages])
            pendingImages = []
        }

        for message in messages {
            switch message {
            case .system:
                // Qoder has no mid-conversation tool changes; the request's
                // tool list already holds every current tool.
                continue
            case .user(let user):
                let blocks: [[String: Any]] = user.content.compactMap { block in
                    switch block {
                    case .text(let text): ["type": "text", "text": text.text]
                    case .image(let content): image(content)
                    }
                }
                guard !blocks.isEmpty else { continue }
                out.append(["role": "user", "content": pendingImages + blocks])
                pendingImages = []
            case .assistant(let assistant):
                showPendingImages()
                var blocks: [[String: Any]] = []
                var calls: [[String: Any]] = []
                for block in assistant.content {
                    switch block {
                    case .text(let text):
                        blocks.append(["type": "text", "text": text.text])
                    case .toolCall(let call):
                        let id = call.id.isEmpty ? "call_" + QoderCosy.compactUUID() : call.id
                        toolNames[id] = call.name
                        calls.append([
                            "id": id, "type": "function",
                            "function": ["name": call.name, "arguments": json(call.arguments)],
                        ])
                    case .thinking, .fallback:
                        break
                    }
                }
                if !calls.isEmpty {
                    // A turn that calls tools carries its first text as a
                    // plain string beside them, as magpie sends it.
                    let text = blocks.lazy.compactMap { $0["text"] as? String }.first { !$0.isEmpty } ?? ""
                    out.append(["role": "assistant", "content": text, "tool_calls": calls])
                } else if !blocks.isEmpty {
                    out.append(["role": "assistant", "content": blocks])
                }
            case .toolResult(let result):
                var text = result.content.compactMap { block -> String? in
                    if case .text(let text) = block { return text.text }
                    return nil
                }.joined()
                if result.isError { text = "Error: " + text }
                let images = result.content.compactMap { block -> [String: Any]? in
                    if case .image(let content) = block { return image(content) }
                    return nil
                }
                if !images.isEmpty {
                    var origin = "tool call \(result.toolCallId)"
                    let name = toolNames[result.toolCallId] ?? result.toolName
                    if !name.isEmpty { origin = "\(name) (\(origin))" }
                    pendingImages.append(["type": "text", "text": "[From the result of \(origin):]"])
                    pendingImages += images
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "\n\n" }
                    text += images.count == 1
                        ? "[The tool returned an image; it follows in the next message.]"
                        : "[The tool returned \(images.count) images; they follow in the next message.]"
                }
                out.append(["role": "tool", "tool_call_id": result.toolCallId, "content": text])
            }
        }
        showPendingImages()
        return out
    }

    private static func chatTool(_ tool: Tool) throws -> [String: Any] {
        var parameters = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.parameters), options: [.fragmentsAllowed])
        if parameters is NSNull { parameters = ["type": "object", "properties": [String: Any]()] as [String: Any] }
        return [
            "type": "function",
            "function": ["name": tool.name, "description": tool.description, "parameters": parameters],
        ]
    }

    private static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The reasoning levels agents and vendors name, weakest first.
    private static let effortRank = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// Whether to think and at which of the model's own efforts (nil to send
    /// none). Thinking turned off reaches a model that can stop as off; one
    /// that always thinks then thinks at its lowest (asked for less, Qoder
    /// refuses with "该模型始终思考，不支持关闭思考"). A level the model
    /// doesn't name goes to the nearest one it does, the stronger on a tie.
    static func thinking(_ level: ReasoningLevel?, model: QoderModelInfo) -> (enabled: Bool, effort: String?) {
        guard model.thinks, level != nil || model.alwaysThinks else { return (false, nil) }
        guard let lowest = model.efforts.first else { return (true, nil) }
        guard let level else { return (true, lowest) }
        if model.efforts.contains(level.rawValue) { return (true, level.rawValue) }
        let wanted = effortRank.firstIndex(of: level.rawValue) ?? 0
        var best = level.rawValue
        var distance = effortRank.count
        for effort in model.efforts {
            guard effort != "none", let rank = effortRank.firstIndex(of: effort) else { continue }
            if abs(rank - wanted) < distance || abs(rank - wanted) == distance && rank > wanted {
                best = effort
                distance = abs(rank - wanted)
            }
        }
        return (true, best)
    }

    // MARK: - Errors

    /// A refused request as kwwk's failure. Qoder says why in `message`, and
    /// the model vendor's own reason (an effort the model refuses, say) rides
    /// as JSON text in `details`. A refused sign-in and a spent plan get
    /// magpie's wording, which the failure classifier reads as authentication
    /// and quota.
    static func failure(status: Int, body: Data) -> ProviderFailure {
        let status = (400...599).contains(status) ? status : 502
        var message = String(decoding: body.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            if let said = object["message"] as? String, !said.isEmpty { message = said }
            let details = (object["details"] as? String).flatMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            } ?? object["details"] as? [String: Any]
            if let reason = (details?["error"] as? [String: Any])?["message"] as? String, !reason.isEmpty {
                message += ": " + reason
            }
        }
        if message.isEmpty { message = HTTPURLResponse.localizedString(forStatusCode: status) }
        if status == 401 || status == 403 {
            return ProviderFailure(message: "Qoder: the sign-in lapsed — sign in again", httpStatus: 401)
        }
        if status == 429 || message.lowercased().contains("quota") {
            return ProviderFailure(message: "usage limit reached: " + message, httpStatus: 429)
        }
        return ProviderFailure(message: "Qoder: " + message, httpStatus: status)
    }

    private static func httpFailure(
        response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>
    ) async -> ProviderFailure {
        var bytes = Data()
        // A broken error body must not erase a status already received.
        do {
            for try await chunk in body {
                bytes.append(chunk)
                if bytes.count >= 1 << 20 { break }
            }
        } catch {}
        var failure = failure(status: response.statusCode, body: bytes)
        failure.retryAfterMs = ProviderFailure.retryDelay(headers: response.allHeaderFields.reduce(into: [:]) { result, entry in
            if let key = entry.key as? String { result[key.lowercased()] = String(describing: entry.value) }
        })
        return failure
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }
}
