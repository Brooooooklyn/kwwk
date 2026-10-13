import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streaming provider for Devin subscription models (`api == "devin-agent"`).
///
/// Devin's CLI talks to Codeium's Cascade backend over the Connect protocol
/// (HTTP/1.1, protobuf bodies). One turn is:
///
/// 1. `AuthService/GetUserJwt` exchanges the session token for a user JWT
///    (and optionally a per-account API server URL).
/// 2. Router models (`adaptive`) first call `AssignModel` to get the concrete
///    model uid plus an assignment JWT.
/// 3. `ApiServerService/GetChatMessage` takes a gzip-compressed Connect
///    request frame and server-streams `GetChatMessageResponse` deltas (text,
///    thinking, tool calls, usage) until an end-of-stream trailer.
///
/// Tools are ordinary client-side tool calls: the model emits them and the
/// agent loop runs them, like any other provider. Ported from oh-my-pi's
/// `streamDevin`.
public final class DevinAgentProvider: APIProvider, @unchecked Sendable {
    public let api = "devin-agent"
    public let defaultAPIKey: String?
    private let client: HTTPClient

    static let defaultStopPatterns = ["<|user|>", "<|bot|>", "<|context_request|>", "<|endoftext|>", "<|end_of_turn|>"]

    /// Connect frame flags: bit 0x01 = gzip payload, 0x02 = end-of-stream trailer.
    static let compressedFlag: UInt8 = 0x01
    static let endStreamFlag: UInt8 = 0x02
    /// Cap on a single Connect frame payload so a corrupt length prefix fails
    /// fast instead of buffering gigabytes.
    static let maxFramePayload = 16 * 1024 * 1024
    /// History size above which an opaque `invalid_argument` "internal error"
    /// trailer is treated as context overflow (triggers compaction).
    static let largeHistoryRecoveryBytes = 512 * 1024

    public init(client: HTTPClient = URLSessionHTTPClient(), defaultAPIKey: String? = nil) {
        self.client = client
        self.defaultAPIKey = defaultAPIKey
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached { [self] in
            await run(out: out, model: model, context: context, options: options)
        }
        return out
    }

    /// The model uid sent on the wire. Devin selects reasoning effort by model
    /// uid (`claude-opus-5-high`, …); the catalog's `thinkingLevelMap` routes
    /// each level of a collapsed family to its member uid.
    static func wireModelId(model: Model, reasoning: ReasoningLevel?) -> String {
        guard let map = model.thinkingLevelMap else { return model.id }
        let clamped = clampThinkingLevel(model, ModelThinkingLevel(reasoning: reasoning))
        if let entry = map[clamped.rawValue], let mapped = entry { return mapped }
        return model.id
    }

    // MARK: - Run

    private func run(out: AssistantMessageStream, model: Model, context: Context, options: StreamOptions?) async {
        let state = DevinStreamState(api: api, model: model)
        guard let apiKey = options?.resolvedAuth?.token ?? options?.apiKey ?? defaultAPIKey, !apiKey.isEmpty else {
            let msg = state.failed(ProviderFailure(message: "Devin session token is required (run /login devin)"))
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
            return
        }
        let cancellation = options?.cancellation
        do {
            let baseURL = Self.baseURL(model)
            let auth = try await fetchAuth(apiKey: apiKey, baseURL: baseURL, cancellation: cancellation)
            let chatBaseURL = auth.baseURL ?? baseURL
            let cascadeId = options?.sessionId.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            let messages = TransformMessages.normalize(context.messages, model: model)

            var assignment: DevinProto.ModelAssignment?
            if model.compat?.modelRouter == true {
                let assigned = try await assignModel(
                    model: model, apiKey: auth.apiKey, cascadeId: cascadeId,
                    messages: messages, baseURL: chatBaseURL, cancellation: cancellation
                )
                assignment = assigned
                state.setResponseModel(assigned.modelUid)
            }

            let request = Self.buildChatRequest(
                model: model, context: context, messages: messages, options: options,
                apiKey: auth.apiKey, userJwt: auth.userJwt, cascadeId: cascadeId, assignment: assignment
            )
            let requestBytes = request.encode()
            let compressed = try Gzip.compress(requestBytes)
            var frame = Data([Self.compressedFlag])
            frame.append(Self.bigEndian(UInt32(compressed.count)))
            frame.append(compressed)

            var headers: [String: String] = [
                "content-type": "application/connect+proto",
                "connect-protocol-version": "1",
                "connect-content-encoding": "gzip",
                "connect-accept-encoding": "gzip",
                "accept-encoding": "identity",
                "user-agent": DevinWire.connectUserAgent,
            ]
            for (k, v) in options?.headers ?? [:] { headers[k] = v }

            let url = URL(string: chatBaseURL + DevinWire.getChatMessagePath)!
            let (response, body) = try await client.stream(
                url: url, method: "POST", headers: headers, body: frame, cancellation: cancellation
            )
            if response.statusCode >= 400 {
                throw await Self.httpFailure(operation: "API", response: response, body: body)
            }

            out.push(.start(partial: state.snapshot()))
            let driveTask = Task {
                try await self.drive(
                    body: body, state: state, out: out, cancellation: cancellation,
                    historyBytes: { Self.shrinkableHistoryBytes(request: request, context: context) }
                )
            }
            let cancelReg = cancellation?.onCancel { _ in driveTask.cancel() }
            defer { cancelReg?.cancel() }
            try await driveTask.value

            if cancellation?.isCancelled == true {
                let aborted = state.aborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            state.closeOpenBlocks(emit: { out.push($0) })
            let final = state.finalize()
            out.push(.done(reason: final.stopReason, message: final))
            out.end(final)
        } catch {
            if cancellation?.isCancelled == true {
                let aborted = state.aborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
            } else {
                let msg = state.failed(.capture(error))
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
            }
        }
    }

    /// Read Connect frames off the response body and feed each decoded delta
    /// into `state`.
    ///
    /// Every reply Devin sends ends with an end-of-stream frame (flags 0x03,
    /// `{}` or the error), after at least its id and usage frames (measured
    /// 2026-10-11 on SWE-1.6, Sonnet 5 and Opus 5, failed turns included). A
    /// body that stops short of that frame was cut off, and one that holds
    /// nothing else is no reply; both fail the turn as retryable transport
    /// errors, as magpie's `decodeDevin` and `askDevin` do, instead of
    /// passing for a finished answer whose half-received tool arguments
    /// would decode to `{}`.
    private func drive(
        body: AsyncThrowingStream<Data, Error>,
        state: DevinStreamState,
        out: AssistantMessageStream,
        cancellation: CancellationHandle?,
        historyBytes: @escaping @Sendable () -> Int
    ) async throws {
        var parser = ConnectFrameParser(maxPayload: Self.maxFramePayload)
        var messageFrames = 0
        var sawEndStream = false
        for try await chunk in body {
            if cancellation?.isCancelled == true { return }
            for frame in try parser.append(chunk) {
                let payload = frame.flags & Self.compressedFlag != 0
                    ? try Gzip.decompress(frame.payload)
                    : frame.payload
                if frame.flags & Self.endStreamFlag != 0 {
                    if let failure = Self.trailerFailure(payload, historyBytes: historyBytes) { throw failure }
                    if messageFrames == 0 {
                        throw ProviderFailure(message: "Devin stream ended before any reply frame (empty reply)")
                    }
                    sawEndStream = true
                    continue
                }
                messageFrames += 1
                state.apply(DevinProto.GetChatMessageResponse.decode(payload), emit: { out.push($0) })
            }
        }
        if cancellation?.isCancelled == true { return }
        if !sawEndStream {
            throw ProviderFailure(message: "Devin stream ended before its end-of-stream frame")
        }
    }

    // MARK: - Auth

    struct Auth {
        var userJwt: String
        var apiKey: String
        var baseURL: String?
    }

    /// `GetUserJwt` with the prefixed session token; on 401 retry once with the
    /// raw credential (a bare Windsurf API key rather than a session token).
    func fetchAuth(apiKey: String, baseURL: String, cancellation: CancellationHandle?) async throws -> Auth {
        let sessionKey = DevinWire.normalizeSessionToken(apiKey)
        var wireKey = sessionKey
        var (response, body) = try await unary(
            baseURL + DevinWire.getUserJwtPath,
            body: DevinProto.encodeGetUserJwtRequest(metadata: DevinWire.cliMetadata(apiKey: sessionKey)),
            cancellation: cancellation
        )
        if response.statusCode == 401, apiKey != sessionKey {
            wireKey = apiKey
            (response, body) = try await unary(
                baseURL + DevinWire.getUserJwtPath,
                body: DevinProto.encodeGetUserJwtRequest(metadata: DevinWire.cliMetadata(apiKey: apiKey)),
                cancellation: cancellation
            )
        }
        guard response.statusCode < 400 else {
            throw Self.unaryFailure(operation: "auth", response: response, body: body)
        }
        let decoded = DevinProto.GetUserJwtResponse.decode(DevinProto.unaryPayload(body))
        guard !decoded.userJwt.isEmpty else {
            throw ProviderFailure(message: "Devin auth error: GetUserJwt returned an empty user JWT", httpStatus: 401)
        }
        let custom = decoded.customApiServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return Auth(
            userJwt: decoded.userJwt,
            apiKey: wireKey,
            baseURL: custom.isEmpty ? nil : Self.trimSlashes(custom)
        )
    }

    /// Resolve a router slot into a concrete model uid plus the JWT that
    /// authorizes it. A router uid is never a legal `chatModelUid`, so a failed
    /// assignment fails the turn.
    private func assignModel(
        model: Model, apiKey: String, cascadeId: String, messages: [Message],
        baseURL: String, cancellation: CancellationHandle?
    ) async throws -> DevinProto.ModelAssignment {
        let lastUser = messages.last(where: { if case .user = $0 { return true }; return false })
        var prompt: DevinProto.ChatMessagePrompt?
        if case .user(let user)? = lastUser { prompt = Self.userPrompt(user, messageId: "") }
        let (response, body) = try await unary(
            baseURL + DevinWire.assignModelPath,
            body: DevinProto.encodeAssignModelRequest(
                metadata: DevinWire.cliMetadata(apiKey: apiKey),
                modelRouterUid: model.id, cascadeId: cascadeId, prompt: prompt
            ),
            cancellation: cancellation
        )
        guard response.statusCode < 400 else {
            throw Self.unaryFailure(operation: "AssignModel", response: response, body: body)
        }
        guard let assignment = DevinProto.decodeAssignModelResponse(DevinProto.unaryPayload(body)),
              !assignment.assignmentJwt.isEmpty, !assignment.modelUid.isEmpty else {
            throw ProviderFailure(message: "Devin AssignModel error: response carried no assignment JWT and model uid")
        }
        return assignment
    }

    private func unary(
        _ urlString: String, body: Data, cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, Data) {
        try await client.request(
            url: URL(string: urlString)!, method: "POST",
            headers: DevinWire.unaryHeaders, body: body, cancellation: cancellation
        )
    }

    // MARK: - Request building

    static func buildChatRequest(
        model: Model,
        context: Context,
        messages: [Message],
        options: StreamOptions?,
        apiKey: String,
        userJwt: String,
        cascadeId: String,
        assignment: DevinProto.ModelAssignment?
    ) -> DevinProto.GetChatMessageRequest {
        let chatModelUid = assignment?.modelUid ?? wireModelId(model: model, reasoning: options?.reasoning)
        // Devin's Gemini backend applies Google's tool-schema constraints and
        // rejects JSON-Schema type arrays with an opaque `invalid_argument`.
        let googleSchema = isGeminiUid(model.id) || isGeminiUid(chatModelUid)
        let offered = context.tools ?? []
        let tools = offered.map { tool -> DevinProto.ChatToolDefinition in
            // Devin's Claude models answer 502 to a union at a schema's root.
            let parameters = ToolSchemaRoot.objectRoot(tool.parameters)
            let schema = googleSchema ? normalizeSchemaForGoogle(parameters) : parameters
            // The tool's own words go in the instructions (see
            // `instructions`); the definition only points at them.
            let described = !tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return DevinProto.ChatToolDefinition(
                name: tool.name,
                description: described ? toolDescriptionPointer(tool.name) : tool.name,
                jsonSchemaString: jsonString(schema)
            )
        }
        let instructions = instructions(systemPrompt: context.systemPrompt, tools: offered)
        var prompts = chatMessagePrompts(messages, cascadeId: cascadeId, model: model)
        if !instructions.isEmpty {
            if let first = prompts.firstIndex(where: { $0.source == .user }) {
                prompts[first].prompt = joinNonEmpty(instructions, prompts[first].prompt)
            } else {
                prompts.insert(DevinProto.ChatMessagePrompt(
                    messageId: deterministicUUID("\(cascadeId)\0instructions"), source: .user, prompt: instructions
                ), at: 0)
            }
        }
        // Devin answers 400 "an internal error occurred" to a temperature
        // of exactly 0 on every model; 1e-6 is as near greedy as it takes.
        let requested = options?.temperature ?? 0.4
        let temperature = requested == 0 ? 1e-6 : requested
        let maxTokens = options?.maxTokens ?? (model.maxTokens > 0 ? model.maxTokens : 64_000)
        // ChatToolChoice "required" forces a call (measured 2026-10-11 on
        // Sonnet 5 and Opus 5). A tool's name there is refused with
        // `invalid_argument`, so a named tool is forced only when it is the
        // one tool offered; "none" ends the turn with no content at all, so
        // it stays "auto".
        var toolChoice = "auto"
        switch options?.toolChoice {
        case .required? where !tools.isEmpty:
            toolChoice = "required"
        case .tool(let name)? where tools.count == 1 && tools[0].name == name:
            toolChoice = "required"
        default:
            break
        }
        return DevinProto.GetChatMessageRequest(
            metadata: DevinWire.cliMetadata(apiKey: apiKey, userJwt: userJwt),
            prompt: "",
            chatMessagePrompts: prompts,
            instructions: instructions,
            chatModelUid: chatModelUid,
            configuration: DevinProto.CompletionConfiguration(
                maxTokens: UInt64(max(1, maxTokens)),
                temperature: temperature,
                firstTemperature: temperature,
                topP: 1,
                stopPatterns: defaultStopPatterns
            ),
            tools: tools,
            toolChoice: toolChoice,
            disableParallelToolCalls: !(model.compat?.supportsParallelToolCalls ?? false)
                || options?.parallelToolCalls == false,
            cascadeId: cascadeId,
            executionId: UUID().uuidString.lowercased(),
            modelAssignmentJwt: assignment?.assignmentJwt
        )
    }

    /// What goes at the head of the first user message: the system prompt,
    /// then each tool's description in a `<tool_descriptions>` block, as
    /// magpie's Devin plugin sends them (`build`, `toolDescriptions`).
    ///
    /// Devin screens the request's system field and each tool's own
    /// description, and refuses the whole turn over words it takes in a
    /// message. Measured 2026-10-12 on SWE-1.6 through this builder: the
    /// system prompt "You are a Claude agent, built on Anthropic's Claude
    /// Agent SDK." ends the stream with `permission_denied` "Your request was
    /// blocked by our content policy", and a tool described as "Reads a file
    /// from the local filesystem. You can access any file directly by using
    /// this tool." (WorkBuddy's Read, magpie 85fa42c1) with
    /// `permission_denied` "Unable to process request due to an MCP
    /// configuration issue"; the same words at the head of the user message
    /// are both answered.
    static func instructions(systemPrompt: String?, tools: [Tool]) -> String {
        joinNonEmpty(systemPrompt ?? "", toolDescriptions(tools))
    }

    static func toolDescriptions(_ tools: [Tool]) -> String {
        var out = ""
        for tool in tools {
            let description = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else { continue }
            out += "<tool name=\"\(tool.name)\">\n\(description)\n</tool>\n"
        }
        return out.isEmpty ? "" : "<tool_descriptions>\n\(out)</tool_descriptions>"
    }

    static func toolDescriptionPointer(_ name: String) -> String {
        "Described under <tool name=\"\(name)\"> in <tool_descriptions>, in the instructions."
    }

    static func joinNonEmpty(_ parts: String...) -> String {
        joinNonEmpty(parts)
    }

    static func joinNonEmpty(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func isGeminiUid(_ uid: String) -> Bool {
        let lower = uid.lowercased()
        return lower.contains("gemini") || uid.hasPrefix("MODEL_GOOGLE_GEMINI_")
    }

    /// Flatten one user turn into a Cascade USER prompt with inline images.
    /// A Cascade message holds one text: several text blocks are set apart
    /// by a blank line, as magpie's Devin plugin joins them (`build`), so
    /// the end of one never runs into the start of the next.
    static func userPrompt(_ msg: UserMessage, messageId: String) -> DevinProto.ChatMessagePrompt {
        var prompt = DevinProto.ChatMessagePrompt(messageId: messageId, source: .user)
        var texts: [String] = []
        for block in msg.content {
            switch block {
            case .text(let t): texts.append(t.text)
            case .image(let i): prompt.images.append(.init(base64Data: i.data, mimeType: i.mimeType))
            }
        }
        prompt.prompt = joinNonEmpty(texts)
        return prompt
    }

    /// Map kwwk history onto Cascade `ChatMessagePrompt`s (USER / SYSTEM / TOOL
    /// channels). Message ids are deterministic in (cascade, index, role) so
    /// they stay stable across history rebuilds.
    static func chatMessagePrompts(
        _ messages: [Message], cascadeId: String, model: Model
    ) -> [DevinProto.ChatMessagePrompt] {
        var prompts: [DevinProto.ChatMessagePrompt] = []
        for (index, message) in messages.enumerated() {
            switch message {
            case .system:
                // Cascade has no mid-conversation tool changes; the request's
                // top-level tool list already holds every current tool.
                continue
            case .user(let user):
                prompts.append(userPrompt(user, messageId: deterministicUUID("\(cascadeId)\0\(index)\0user")))
            case .assistant(let assistant):
                let native = assistant.api == "devin-agent"
                    && assistant.provider == model.provider && assistant.model == model.id
                var prompt = DevinProto.ChatMessagePrompt(source: .system)
                // A Cascade message holds one thinking text and one signature,
                // and Devin's Claude models check the pair: a signature that
                // doesn't match its text fails the turn with `invalid_argument`
                // "There is an issue with this request" (measured 2026-10-11 on
                // Opus 5). Several blocks joined into one text therefore go
                // unsigned, which Devin takes, dropping the thinking.
                let thinkingBlocks = assistant.content.reduce(0) { count, block in
                    if case .thinking = block { return count + 1 }
                    return count
                }
                var texts: [String] = []
                for block in assistant.content {
                    switch block {
                    case .text(let t):
                        texts.append(t.text)
                    case .thinking(let th):
                        prompt.thinking += th.thinking
                        if native, thinkingBlocks == 1, let sig = th.thinkingSignature { prompt.signature = sig }
                    case .toolCall(let call):
                        prompt.toolCalls.append(.init(id: call.id, name: call.name, argumentsJson: jsonString(call.arguments)))
                    case .fallback:
                        break
                    }
                }
                prompt.prompt = joinNonEmpty(texts)
                if prompt.prompt.isEmpty && prompt.thinking.isEmpty && prompt.signature.isEmpty && prompt.toolCalls.isEmpty {
                    continue
                }
                if native, let responseId = assistant.responseId, !responseId.isEmpty {
                    prompt.messageId = responseId
                } else {
                    prompt.messageId = "bot-" + deterministicUUID("\(cascadeId)\0\(index)\0assistant")
                }
                prompts.append(prompt)
            case .toolResult(let result):
                var prompt = DevinProto.ChatMessagePrompt(
                    messageId: deterministicUUID("\(cascadeId)\0\(index)\0tool\0\(result.toolCallId)"),
                    source: .tool,
                    toolCallId: result.toolCallId,
                    toolResultIsError: result.isError
                )
                for block in result.content {
                    switch block {
                    case .text(let t): prompt.prompt += t.text
                    case .image(let i): prompt.images.append(.init(base64Data: i.data, mimeType: i.mimeType))
                    }
                }
                prompts.append(prompt)
            }
        }
        return prompts
    }

    /// History bytes context maintenance could shrink: every prompt except the
    /// trailing user turn(s) being answered, less the instructions the first
    /// user prompt carries (compaction keeps those).
    static func shrinkableHistoryBytes(request: DevinProto.GetChatMessageRequest, context: Context) -> Int {
        var tail = 0
        if case .user? = context.messages.last { tail = 1 }
        let prompts = request.chatMessagePrompts
        let shrinkable = tail > 0 ? Array(prompts.dropLast(tail)) : prompts
        var bytes = DevinProto.GetChatMessageRequest.historyByteCount(shrinkable)
        if !request.instructions.isEmpty, shrinkable.contains(where: { $0.source == .user }) {
            bytes -= request.instructions.utf8.count
        }
        return max(0, bytes)
    }

    /// RFC-4122-shaped UUID derived from SHA-256 of `seed`.
    static func deterministicUUID(_ seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    static func jsonString(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Minimal Gemini-compatible schema rewrite: JSON-Schema `type` arrays
    /// (`["string", "null"]`) become a single type plus `nullable: true`,
    /// applied recursively.
    static func normalizeSchemaForGoogle(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map(normalizeSchemaForGoogle))
        case .object(var obj):
            if case .array(let types)? = obj["type"] {
                let names = types.compactMap { item -> String? in
                    if case .string(let s) = item { return s }
                    return nil
                }
                let nonNull = names.filter { $0 != "null" }
                if names.contains("null") { obj["nullable"] = .bool(true) }
                if let first = nonNull.first { obj["type"] = .string(first) } else { obj.removeValue(forKey: "type") }
            }
            for (key, child) in obj where key != "type" && key != "enum" && key != "const" && key != "default" {
                obj[key] = normalizeSchemaForGoogle(child)
            }
            return .object(obj)
        default:
            return value
        }
    }

    // MARK: - Errors

    /// Connect end-of-stream trailer: `{"error": {"code", "message", "details"}}`.
    static func trailerFailure(_ payload: Data, historyBytes: () -> Int) -> ProviderFailure? {
        guard !payload.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let error = obj["error"] as? [String: Any] else { return nil }
        let code = error["code"] as? String ?? ""
        let message = error["message"] as? String ?? ""
        guard !code.isEmpty || !message.isEmpty else { return nil }
        var text = "Devin stream error\(code.isEmpty ? "" : " \(code)"): \(message)"
        if let details = error["details"],
           let data = try? JSONSerialization.data(withJSONObject: details),
           let detailText = String(data: data, encoding: .utf8), detailText != "[]" {
            text += " [details: \(detailText.prefix(2000))]"
        }
        var failure = ProviderFailure(message: text, providerCode: code.isEmpty ? nil : code.lowercased())
        let lower = message.lowercased()
        let isLimit = code.lowercased() == "resource_exhausted" || lower.contains("quota") || lower.contains("rate limit")
        if !isLimit, lower.contains("content policy") {
            // Devin refuses a prompt it screens out as `permission_denied`
            // "Your request was blocked by our content policy" (measured
            // 2026-10-12). Sent again it is refused again, and signing in
            // again changes nothing: a bad request, as magpie's Devin plugin
            // answers it (`failure`: 400).
            failure.httpStatus = 400
        }
        // Devin's own outage wears the same code: `permission_denied`
        // "internal server error: error number 13" answered every chat of a
        // healthy Pro account on 2026-10-13, from the devin CLI too, which
        // marks it `cognition.ai/errorKind: internal`, `retryable: true`.
        // A server fault to ask again, not a sign-in to redo — only
        // `unauthenticated` means that (magpie's Devin plugin, `failure`).
        if code.lowercased() == "permission_denied", lower.contains("internal server error") {
            failure.providerCode = "internal"
        }
        // Opaque `invalid_argument: internal error` with a large history is far
        // more likely a size rejection; classify it as context overflow so the
        // agent compacts instead of failing the turn outright.
        if code.lowercased() == "invalid_argument",
           message.range(of: #"\binternal error\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
           historyBytes() >= largeHistoryRecoveryBytes {
            failure.providerCode = "context_length_exceeded"
        }
        return failure
    }

    static func httpFailure(
        operation: String, response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>
    ) async -> ProviderFailure {
        var bytes = Data()
        do {
            for try await chunk in body {
                bytes.append(contentsOf: chunk.prefix(max(0, 4096 - bytes.count)))
                if bytes.count >= 4096 { break }
            }
        } catch {}
        return unaryFailure(operation: operation, response: response, body: bytes)
    }

    /// Bounded, human-readable error from a failed Connect call. Binary
    /// protobuf and proxy HTML bodies are suppressed to the status line.
    static func unaryFailure(operation: String, response: HTTPURLResponse, body: Data) -> ProviderFailure {
        let status = "\(response.statusCode)"
        var detail: String?
        var code: String?
        let isHTML = response.value(forHTTPHeaderField: "content-type")?.lowercased().contains("text/html") == true
        if !isHTML, let text = String(data: DevinProto.unaryPayload(body).prefix(4096), encoding: .utf8) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                if let error = obj["error"] as? [String: Any] {
                    detail = error["message"] as? String
                    code = error["code"] as? String
                } else {
                    detail = obj["message"] as? String ?? obj["error"] as? String
                    code = obj["code"] as? String
                }
            } else {
                let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let printable = collapsed.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
                if printable, !collapsed.lowercased().hasPrefix("<html"), !collapsed.lowercased().hasPrefix("<!doctype") {
                    detail = collapsed
                }
            }
        }
        var message = "Devin \(operation) error \(status)"
        if let detail, !detail.isEmpty { message += ": \(detail)" }
        var failure = ProviderFailure(message: message, httpStatus: response.statusCode, providerCode: code)
        failure.retryAfterMs = ProviderFailure.retryDelay(headers: response.allHeaderFields.reduce(into: [:]) { result, entry in
            if let key = entry.key as? String { result[key.lowercased()] = String(describing: entry.value) }
        })
        return failure
    }

    // MARK: - Helpers

    static func baseURL(_ model: Model) -> String {
        trimSlashes(model.baseURL.isEmpty ? DevinWire.defaultBaseURL : model.baseURL)
    }

    static func trimSlashes(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}

// MARK: - Connect frame parser

/// Incremental parser for Connect streaming frames: 1 flag byte, 4-byte
/// big-endian length, payload.
struct ConnectFrameParser {
    struct Frame {
        let flags: UInt8
        let payload: Data
    }

    enum ParseError: Error, LocalizedError {
        case frameTooLarge(Int, limit: Int)
        var errorDescription: String? {
            switch self {
            case .frameTooLarge(let len, let limit): return "Devin Connect frame length \(len) exceeds \(limit)-byte cap"
            }
        }
    }

    let maxPayload: Int
    private var buffer = Data()

    init(maxPayload: Int) {
        self.maxPayload = maxPayload
    }

    mutating func append(_ chunk: Data) throws -> [Frame] {
        buffer.append(chunk)
        var frames: [Frame] = []
        while buffer.count >= 5 {
            let start = buffer.startIndex
            let flags = buffer[start]
            let length = Int(buffer[start + 1]) << 24 | Int(buffer[start + 2]) << 16
                | Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
            if length > maxPayload { throw ParseError.frameTooLarge(length, limit: maxPayload) }
            guard buffer.count >= 5 + length else { break }
            let payload = Data(buffer[(start + 5)..<(start + 5 + length)])
            buffer = Data(buffer[(start + 5 + length)...])
            frames.append(Frame(flags: flags, payload: payload))
        }
        return frames
    }
}

// MARK: - Stream state

/// Accumulates the assistant message from `GetChatMessageResponse` deltas and
/// emits the matching `AssistantMessageEvent`s.
final class DevinStreamState: @unchecked Sendable {
    private let api: String
    private let model: Model
    private let lock = NSLock()

    private var blocks: [AssistantBlock] = []
    private var textIndex: Int?
    private var thinkingIndex: Int?
    /// Tool-call block index + accumulated JSON args, keyed by call id.
    private var toolIndexById: [String: Int] = [:]
    private var toolArgs: [String: String] = [:]
    private var toolOrder: [String] = []
    private var activeToolCallId: String?
    /// Ids given here to calls Devin opened without one.
    private var mintedToolCallIds: Set<String> = []
    private var responseId: String?
    private var responseModel: String?
    private var lastStopReason: UInt64 = DevinProto.StopReason.unspecified
    private var usage = Usage()
    private var stopReasonOverride: StopReason?

    init(api: String, model: Model) {
        self.api = api
        self.model = model
    }

    func setResponseModel(_ uid: String) {
        lock.withLock { responseModel = uid }
    }

    func apply(_ msg: DevinProto.GetChatMessageResponse, emit: (AssistantMessageEvent) -> Void) {
        lock.withLock {
            if !msg.messageId.isEmpty, responseId == nil { responseId = msg.messageId }
            if let actual = msg.actualModelUid, !actual.isEmpty { responseModel = actual }
            if msg.stopReason != DevinProto.StopReason.unspecified { lastStopReason = msg.stopReason }
            if let u = msg.usage {
                usage.input = Int(u.inputTokens)
                usage.output = Int(u.outputTokens)
                usage.cacheRead = Int(u.cacheReadTokens)
                usage.cacheWrite = Int(u.cacheWriteTokens)
                usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
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
            lock.withLock {
                let index = thinkingIndex ?? blocks.lastIndex { if case .thinking = $0 { return true }; return false }
                if let index, case .thinking(var t) = blocks[index] {
                    t.thinkingSignature = msg.deltaSignature
                    blocks[index] = .thinking(t)
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
        let (index, isNew): (Int, Bool) = lock.withLock {
            if let idx = textIndex { return (idx, false) }
            blocks.append(.text(TextContent(text: "")))
            textIndex = blocks.count - 1
            return (blocks.count - 1, true)
        }
        if isNew { emit(.textStart(contentIndex: index, partial: snapshot())) }
        lock.withLock {
            if case .text(var t) = blocks[index] { t.text += delta; blocks[index] = .text(t) }
        }
        emit(.textDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    private func appendThinking(_ delta: String, signature: String, emit: (AssistantMessageEvent) -> Void) {
        let (index, isNew): (Int, Bool) = lock.withLock {
            if let idx = thinkingIndex { return (idx, false) }
            blocks.append(.thinking(ThinkingContent(thinking: "")))
            thinkingIndex = blocks.count - 1
            return (blocks.count - 1, true)
        }
        if isNew { emit(.thinkingStart(contentIndex: index, partial: snapshot())) }
        lock.withLock {
            if case .thinking(var t) = blocks[index] {
                t.thinking += delta
                if !signature.isEmpty { t.thinkingSignature = signature }
                blocks[index] = .thinking(t)
            }
        }
        emit(.thinkingDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    private func endText(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = lock.withLock {
            guard let idx = textIndex, case .text(let t) = blocks[idx] else { return nil }
            textIndex = nil
            return (idx, t.text)
        }
        if let (index, content) = closed { emit(.textEnd(contentIndex: index, content: content, partial: snapshot())) }
    }

    private func endThinking(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = lock.withLock {
            guard let idx = thinkingIndex, case .thinking(let t) = blocks[idx] else { return nil }
            thinkingIndex = nil
            return (idx, t.thinking)
        }
        if let (index, content) = closed { emit(.thinkingEnd(contentIndex: index, content: content, partial: snapshot())) }
    }

    /// Tool-call deltas carry the call id on the first frame (later frames may
    /// omit it) and either cumulative or incremental argument JSON.
    private func applyToolDelta(_ call: DevinProto.ChatToolCall, emit: (AssistantMessageEvent) -> Void) {
        enum Step { case skip, started(Int), existing(Int) }
        let step: Step = lock.withLock {
            var named = call.id.isEmpty ? activeToolCallId : call.id
            // A call that opens with a name and no id still runs: it gets an
            // id of ours, as magpie's Devin plugin gives one (`events`). A
            // name is what opens a call there, so a second name with no id
            // after such a call is the next call, not more of the first:
            // taken as one, their arguments would run together and decode
            // to `{}`.
            if call.id.isEmpty, !call.name.isEmpty,
               activeToolCallId.map(mintedToolCallIds.contains) ?? true {
                let minted = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                mintedToolCallIds.insert(minted)
                named = minted
            }
            guard let id = named else { return .skip }
            activeToolCallId = id
            if let idx = toolIndexById[id] {
                if !call.name.isEmpty, case .toolCall(var tc) = blocks[idx] { tc.name = call.name; blocks[idx] = .toolCall(tc) }
                return .existing(idx)
            }
            blocks.append(.toolCall(ToolCall(id: id, name: call.name, arguments: .object([:]))))
            let idx = blocks.count - 1
            toolIndexById[id] = idx
            toolArgs[id] = ""
            toolOrder.append(id)
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
        let delta: String = lock.withLock {
            let id = activeToolCallId ?? ""
            let previous = toolArgs[id] ?? ""
            let accumulated = call.argumentsJson.hasPrefix(previous) ? call.argumentsJson : previous + call.argumentsJson
            toolArgs[id] = accumulated
            return String(accumulated.dropFirst(previous.count))
        }
        if !delta.isEmpty { emit(.toolCallDelta(contentIndex: index, delta: delta, partial: snapshot())) }
    }

    func closeOpenBlocks(emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        endThinking(emit: emit)
        let completed: [(Int, ToolCall)] = lock.withLock {
            var out: [(Int, ToolCall)] = []
            for id in toolOrder {
                guard let idx = toolIndexById[id], case .toolCall(var tc) = blocks[idx] else { continue }
                let json = toolArgs[id] ?? ""
                tc.arguments = json.isEmpty
                    ? .object([:])
                    : (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:])
                blocks[idx] = .toolCall(tc)
                out.append((idx, tc))
            }
            toolOrder.removeAll()
            return out
        }
        for (index, call) in completed {
            emit(.toolCallEnd(contentIndex: index, toolCall: call, partial: snapshot()))
        }
    }

    func snapshot() -> AssistantMessage {
        lock.withLock { messageLocked(stopReason: stopReasonOverride ?? derivedStopReasonLocked()) }
    }

    func finalize() -> AssistantMessage { snapshot() }

    func aborted() -> AssistantMessage {
        lock.withLock { stopReasonOverride = .aborted }
        var m = snapshot()
        m.errorMessage = "Request was aborted"
        return m
    }

    func failed(_ failure: ProviderFailure) -> AssistantMessage {
        lock.withLock { stopReasonOverride = .error }
        var m = snapshot()
        m.errorMessage = failure.message
        m.failure = failure
        return m
    }

    private func derivedStopReasonLocked() -> StopReason {
        if !toolIndexById.isEmpty { return .toolUse }
        if lastStopReason == DevinProto.StopReason.maxTokens { return .length }
        return .stop
    }

    private func messageLocked(stopReason: StopReason) -> AssistantMessage {
        var u = usage
        u.cost = calculateCost(model: model, usage: u)
        return AssistantMessage(
            content: blocks, api: api, provider: model.provider, model: model.id,
            responseId: responseId, responseModel: responseModel,
            usage: u, stopReason: stopReason, timestamp: Timestamp.now()
        )
    }
}
