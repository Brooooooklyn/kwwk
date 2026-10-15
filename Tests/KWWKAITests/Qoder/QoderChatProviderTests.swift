import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Ported from magpie's `internal/gateway/qoder_test.go` and
// `qoder_cn_test.go`. The tool-call markers are spelled with escapes for
// their angle brackets, as magpie spells them.

/// Path-routed HTTP stub: each URL path answers its queued replies in order
/// (the last one repeats); every request is recorded.
final class QoderStubClient: HTTPClient, @unchecked Sendable {
    struct Reply {
        var status = 200
        var contentType = "text/event-stream"
        var chunks: [Data]
        /// Thrown after the chunks, in place of a clean end.
        var failure: (any Error)?

        init(status: Int = 200, contentType: String = "text/event-stream", body: String, failure: (any Error)? = nil) {
            self.status = status
            self.contentType = contentType
            self.chunks = body.isEmpty ? [] : [Data(body.utf8)]
            self.failure = failure
        }
    }

    private let lock = NSLock()
    private var replies: [String: [Reply]]
    private(set) var requests: [(url: URL, method: String, headers: [String: String], body: Data?)] = []

    init(_ replies: [String: [Reply]]) {
        self.replies = replies
    }

    func requests(to path: String) -> [(url: URL, method: String, headers: [String: String], body: Data?)] {
        lock.withLock { requests.filter { $0.url.path == path } }
    }

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?, cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let reply: Reply = lock.withLock {
            requests.append((url, method, headers, body))
            guard var queue = replies[url.path], !queue.isEmpty else { return Reply(status: 404, body: "") }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            replies[url.path] = queue
            return next
        }
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["content-type": reply.contentType]
        )!
        return (response, AsyncThrowingStream { continuation in
            for chunk in reply.chunks { continuation.yield(chunk) }
            continuation.finish(throwing: reply.failure)
        })
    }
}

// MARK: - Fixtures

private let listPath = "/algo/api/v2/model/list"
private let chatPath = "/algo/api/v2/service/pro/sse/agent_chat_generation"

private let callOpen = "\u{3C}tool_call\u{3E}"
private let callClose = "\u{3C}/tool_call\u{3E}"

private func jsonText(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

/// An OpenAI chat.completion.chunk wrapped as Qoder's SSE envelope.
private func envelope(_ inner: String) -> String {
    jsonText([
        "headers": ["Content-Type": ["application/json"]],
        "body": inner, "statusCodeValue": 200, "statusCode": "OK",
    ] as [String: Any])
}

/// A chunk whose delta carries `content`.
private func content(_ text: String) -> String {
    envelope(jsonText(["choices": [["delta": ["content": text]]], "object": "chat.completion.chunk"]))
}

/// A failed envelope: Qoder reports a refusal inside a 200 stream.
private func failedEnvelope(_ status: Int, _ body: String) -> String {
    jsonText(["statusCodeValue": status, "body": body] as [String: Any])
}

private func sse(_ lines: [String]) -> String {
    lines.map { "data: \($0)\n\n" }.joined()
}

private func auth(token: String = "jt-test", uid: String = "uid-test") -> ResolvedProviderAuth {
    ResolvedProviderAuth(
        token: token, scheme: .bearer,
        metadata: ["uid": .string(uid), "machineId": "machine-test", "name": "Test", "email": "t@x"]
    )
}

private func collect(
    _ stream: AssistantMessageStream
) async -> (events: [AssistantMessageEvent], final: AssistantMessage) {
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    return (events, await stream.result())
}

/// Runs one turn against a stub Qoder that lists `listing` and streams
/// `reply`.
private func turn(
    reply: QoderStubClient.Reply,
    listing: String = qoderFlashListing,
    model: Model = qoderModel(id: "qfmodel", site: .global),
    context: Context = Context(messages: [.user(UserMessage(text: "hi"))]),
    options: StreamOptions = StreamOptions(resolvedAuth: auth())
) async -> (events: [AssistantMessageEvent], final: AssistantMessage, client: QoderStubClient) {
    let client = QoderStubClient([listPath: [.init(body: listing)], chatPath: [reply]])
    let (events, final) = await collect(QoderChatProvider(client: client).stream(
        model: model,
        context: context,
        options: options
    ))
    return (events, final, client)
}

private func body(
    _ listing: String = qoderFlashListing, context: Context = Context(), options: StreamOptions? = nil
) throws -> [String: Any] {
    let data = try QoderChatProvider.chatBody(
        model: try qoderListed(listing), context: context, messages: context.messages, options: options
    )
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func parameters(
    _ level: ReasoningLevel?, _ listing: String = qoderFlashListing
) throws -> [String: Any] {
    try #require(try body(listing, options: StreamOptions(reasoning: level))["parameters"] as? [String: Any])
}

private func texts(_ message: AssistantMessage) -> String {
    message.content.compactMap { block -> String? in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined()
}

private func toolCalls(_ message: AssistantMessage) -> [ToolCall] {
    message.content.compactMap { block -> ToolCall? in
        if case .toolCall(let call) = block { return call }
        return nil
    }
}

private let readTool = Tool(
    name: "read", description: "Read a file",
    parameters: ["type": "object", "properties": ["path": ["type": "string"]]]
)

// MARK: - Request

@Suite("Qoder chat request")
struct QoderChatRequestTests {
    @Test("The body names the common agent, carries the system prompt twice and the model's own listing entry")
    func chatBody() throws {
        let context = Context(
            systemPrompt: "Be terse.",
            messages: [
                .user(UserMessage(text: "hi")),
                .assistant(AssistantMessage(
                    content: [.toolCall(ToolCall(id: "c1", name: "read", arguments: ["path": "x"]))],
                    api: "qoder-chat",
                    provider: "qoder",
                    model: "qfmodel"
                )),
                .toolResult(ToolResultMessage(
                    toolCallId: "c1",
                    toolName: "read",
                    content: [.text(TextContent(text: "the file"))]
                )),
            ],
            tools: [readTool]
        )
        let body = try body(context: context)
        #expect(body["agent_id"] as? String == "agent_common")
        #expect(body["task_id"] as? String == "common")
        #expect(body["session_type"] as? String == "app")
        let business = try #require(body["business"] as? [String: Any])
        #expect(business["product"] as? String == "app")
        #expect(business["version"] as? String == "1.1.49")
        #expect(business["type"] as? String == "agent")
        #expect(business["stage"] as? String == "start")
        #expect((business["id"] as? String)?.count == 32)
        #expect((business["begin_at"] as? Int64 ?? 0) > 1_700_000_000_000)

        let config = try #require(body["model_config"] as? [String: Any])
        #expect(config["key"] as? String == "qfmodel")
        #expect(config["format"] as? String == "openai")

        // The caller's tools go as Qoder's own function tools, not in the prompt.
        let systemText = "You are a Qoder agent. Use the instructions below and the tools available to you to assist the user.\n\nBe terse."
        let system = try #require(body["system"] as? [[String: String]])
        #expect(system == [["type": "text", "text": systemText]])
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "read")
        #expect(function["description"] as? String == "Read a file")
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(messages[0]["content"] as? [[String: String]] == system)
        // The assistant's call and its result are tool turns named by id.
        let call = try #require((messages[2]["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "c1")
        #expect(messages[3]["tool_call_id"] as? String == "c1")
        #expect(messages[3]["content"] as? String == "the file")
    }

    @Test("The listing entry goes back whole, with fields kwwk never read")
    func selectedModelConfig() throws {
        let listing = #"{"chat":[{"key":"other-model","enable":true,"display_name":"Other","format":"custom","source":"system","is_vl":false,"is_reasoning":false,"max_input_tokens":64000,"custom_field":17}]}"#
        let listed = try qoderListed(listing)
        let data = try QoderChatProvider.chatBody(
            model: listed, context: Context(), messages: [], options: StreamOptions(reasoning: .high)
        )
        // Spliced in as listed, not rebuilt.
        #expect(String(decoding: data, as: UTF8.self).contains("\"model_config\":" + listed.config))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((body["model_config"] as? [String: Any])?["custom_field"] as? Int == 17)
        let parameters = try #require(body["parameters"] as? [String: Any])
        #expect(parameters["context_length"] as? Int == 64000)
        // A model that does not think is not asked to, whatever the level.
        #expect(parameters["enable_thinking"] as? Bool == false)
        #expect(parameters["reasoning_effort"] == nil)
        #expect(parameters["max_tokens"] as? Int == 32000)
        #expect(body["tools"] == nil)
    }

    @Test("The caller's output limit replaces the default")
    func maxTokens() throws {
        let parameters = try #require(try body(options: StreamOptions(maxTokens: 4096))["parameters"] as? [String: Any])
        #expect(parameters["max_tokens"] as? Int == 4096)
    }

    @Test("A level the model names is sent as it is; one it doesn't goes to the nearest, the stronger on a tie")
    func reasoning() throws {
        for (level, effort) in [
            (ReasoningLevel.xhigh, "xhigh"), (.max, "xhigh"), (.medium, "medium"), (.low, "low"),
            (.minimal, "low"), (.high, "xhigh"),
        ] {
            let parameters = try parameters(level)
            #expect(parameters["reasoning_effort"] as? String == effort, "\(level)")
            #expect(parameters["enable_thinking"] as? Bool == true)
        }
        #expect(try parameters(.medium, qoderAlwaysThinkingListing)["reasoning_effort"] as? String == "high")
    }

    @Test("Thinking turned off reaches a model that can stop as off; one that can't thinks at its lowest")
    func thinkingOff() throws {
        let off = try parameters(nil)
        #expect(off["enable_thinking"] as? Bool == false)
        #expect(off["reasoning_effort"] == nil)

        let always = try parameters(nil, qoderAlwaysThinkingListing)
        #expect(always["enable_thinking"] as? Bool == true)
        #expect(always["reasoning_effort"] as? String == "low")
    }

    @Test("A thinking model that names no efforts is sent none")
    func noEfforts() throws {
        let parameters = try parameters(.high, #"{"chat":[{"key":"bare","enable":true,"is_reasoning":true}]}"#)
        #expect(parameters["enable_thinking"] as? Bool == true)
        #expect(parameters["reasoning_effort"] == nil)
    }

    // magpie-plugins qoder `context.test.mjs`.
    @Test("A request is sent the default window while it fits, a larger one only when it needs it")
    func contextLength() throws {
        func sent(_ characters: Int, maxTokens: Int? = nil, ceiling: Int? = nil) throws -> Int? {
            let context = Context(messages: [.user(UserMessage(text: String(repeating: "a", count: characters)))])
            let data = try QoderChatProvider.chatBody(
                model: try qoderListed(qoderWindowedFlashListing), context: context, messages: context.messages,
                options: StreamOptions(maxTokens: maxTokens), windowCeiling: ceiling
            )
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (body["parameters"] as? [String: Any])?["context_length"] as? Int
        }
        #expect(try sent(10) == 200_000)
        #expect(try sent(300_000 * 3) == 400_000)
        #expect(try sent(700_000 * 3) == 1_000_000)
        #expect(try sent(1_200_000 * 3) == 1_000_000)

        // A window holds the reply too: a prompt that fits 200K alone but
        // not with the max_tokens asked for the reply is sent the next one
        // (yetone/magpie#700). None asked: the 32000 Qoder is sent counts.
        #expect(try sent(180_000 * 3, maxTokens: 1000) == 200_000)
        #expect(try sent(180_000 * 3, maxTokens: 32_000) == 400_000)
        #expect(try sent(180_000 * 3) == 400_000)

        // The catalog row's context window is the most that is asked for: a
        // caller that lowers it stays in the smaller windows.
        #expect(try sent(700_000 * 3, ceiling: 400_000) == 400_000)
        #expect(try sent(700_000 * 3, ceiling: 200_000) == 200_000)
        #expect(try sent(700_000 * 3, ceiling: 100_000) == 200_000)

        // A model with no windows is sent its max_input_tokens, and one
        // with neither is sent none.
        #expect(try parameters(nil)["context_length"] as? Int == 200_000)
        #expect(try parameters(nil, #"{"chat":[{"key":"y","enable":true}]}"#)["context_length"] == nil)
    }

    @Test("Tools are withheld for tool choice none; a required call is asked for in the system prompt")
    func toolChoice() throws {
        let context = Context(messages: [], tools: [Tool(name: "read", description: "", parameters: .null)])
        #expect(try body(context: context, options: StreamOptions(toolChoice: ToolChoice.none))["tools"] == nil)

        let required = try body(context: context, options: StreamOptions(toolChoice: .required))
        let system = try #require((required["system"] as? [[String: String]])?.first?["text"])
        #expect(system.hasSuffix("\nYou must call an available function in this response."))
        // A tool with no schema takes an empty object one.
        let function = try #require((required["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        #expect(function["parameters"] as? [String: [String: String]] == nil)
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")
        #expect(((function["parameters"] as? [String: Any])?["properties"] as? [String: Any])?.isEmpty == true)

        // With no tools there is nothing to require.
        let bare = try body(options: StreamOptions(toolChoice: .required))
        #expect((bare["system"] as? [[String: String]])?.first?["text"] == QoderChatProvider.systemPreamble)
    }

    @Test("A tool call and its result are OpenAI tool turns, paired by id and not by order")
    func toolTurns() throws {
        let messages = QoderChatProvider.chatMessages([
            .user(UserMessage(text: "read it")),
            .assistant(AssistantMessage(
                content: [
                    .thinking(ThinkingContent(thinking: "which file?")),
                    .text(TextContent(text: "Reading both.")),
                    .toolCall(ToolCall(id: "call_A", name: "read", arguments: ["path": "/tmp/x & y"])),
                    .toolCall(ToolCall(id: "call_B", name: "bash", arguments: ["command": "ls"])),
                ],
                api: "qoder-chat",
                provider: "qoder",
                model: "qfmodel"
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "call_B",
                toolName: "bash",
                content: [.text(TextContent(text: "second result"))]
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "call_A",
                toolName: "read",
                content: [.text(TextContent(text: "first result"))],
                isError: true
            )),
        ])
        #expect(messages.count == 4)
        #expect(messages[1]["content"] as? String == "Reading both.")
        let calls = try #require(messages[1]["tool_calls"] as? [[String: Any]])
        #expect(calls.map { $0["id"] as? String } == ["call_A", "call_B"])
        #expect(calls.allSatisfy { $0["type"] as? String == "function" })
        // Arguments reach Qoder as they stand, not HTML-escaped.
        let function = try #require(calls[0]["function"] as? [String: String])
        #expect(function == ["name": "read", "arguments": #"{"path":"/tmp/x & y"}"#])
        #expect(messages[2]["role"] as? String == "tool")
        #expect(messages[2]["tool_call_id"] as? String == "call_B")
        #expect(messages[2]["content"] as? String == "second result")
        #expect(messages[3]["tool_call_id"] as? String == "call_A")
        #expect(messages[3]["content"] as? String == "Error: first result")

        // Every text block of a turn that calls tools goes beside the calls.
        let spoken = QoderChatProvider.chatMessages([.assistant(AssistantMessage(
            content: [
                .text(TextContent(text: "First. ")),
                .toolCall(ToolCall(id: "call_C", name: "read", arguments: [:])),
                .text(TextContent(text: "Then this.")),
            ],
            api: "qoder-chat",
            provider: "qoder",
            model: "qfmodel"
        ))])
        #expect(spoken[0]["content"] as? String == "First. Then this.")
    }

    @Test("A turn of plain text keeps its blocks; one with nothing to say is not sent")
    func plainTurns() throws {
        let png = ImageContent(data: "iVBOR", mimeType: "image/png")
        let messages = QoderChatProvider.chatMessages([
            .user(UserMessage(content: [.text(TextContent(text: "look")), .image(png)])),
            .assistant(AssistantMessage(
                content: [.thinking(ThinkingContent(thinking: "hm"))],
                api: "qoder-chat",
                provider: "qoder",
                model: "qfmodel"
            )),
            .system(SystemMessage(toolsAdded: [readTool])),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "A cat."))],
                api: "qoder-chat",
                provider: "qoder",
                model: "qfmodel"
            )),
        ])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant"])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(blocks[0] as? [String: String] == ["type": "text", "text": "look"])
        #expect(blocks[1]["type"] as? String == "image_url")
        #expect((blocks[1]["image_url"] as? [String: String])?["url"] == "data:image/png;base64,iVBOR")
        #expect(messages[1]["content"] as? [[String: String]] == [["type": "text", "text": "A cat."]])
    }

    @Test("A tool turn holds text only, so a tool's images follow in a user turn, joined to the user's own next turn")
    func toolResultImages() throws {
        let png = ToolResultBlock.image(ImageContent(data: "iVBOR", mimeType: "image/png"))
        func screenshot(_ id: String) -> Message {
            .assistant(AssistantMessage(
                content: [.toolCall(ToolCall(id: id, name: "screenshot", arguments: [:]))],
                api: "qoder-chat",
                provider: "qoder",
                model: "qfmodel"
            ))
        }
        let messages = QoderChatProvider.chatMessages([
            .user(UserMessage(text: "look")),
            screenshot("call_A"),
            .toolResult(ToolResultMessage(
                toolCallId: "call_A", toolName: "screenshot", content: [.text(TextContent(text: "shot taken")), png]
            )),
            .user(UserMessage(text: "what do you see?")),
            screenshot("call_B"),
            .toolResult(ToolResultMessage(toolCallId: "call_B", toolName: "screenshot", content: [png, png])),
        ])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "tool", "user", "assistant", "tool", "user"])
        #expect(messages[2]["content"] as? String
            == "shot taken\n\n[The tool returned an image; it follows in the next message.]")
        let joined = try #require(messages[3]["content"] as? [[String: Any]])
        #expect(joined.count == 3)
        #expect(joined[0]["text"] as? String == "[From the result of screenshot (tool call call_A):]")
        #expect((joined[1]["image_url"] as? [String: String])?["url"] == "data:image/png;base64,iVBOR")
        #expect(joined[2]["text"] as? String == "what do you see?")
        #expect(messages[5]["content"] as? String == "[The tool returned 2 images; they follow in the next message.]")
        let trailing = try #require(messages[6]["content"] as? [[String: Any]])
        #expect(trailing.map { $0["type"] as? String } == ["text", "image_url", "image_url"])
    }

    @Test("The request is the encoded body, signed, with the model's key and source beside the envelope")
    func wire() async throws {
        let (_, final, client) = await turn(
            reply: .init(body: sse([content("ok")])),
            context: Context(systemPrompt: "Be terse.", messages: [.user(UserMessage(text: "hi"))], tools: [readTool]),
            options: StreamOptions(resolvedAuth: auth(), reasoning: .xhigh)
        )
        #expect(texts(final) == "ok")
        #expect(client.requests.map(\.url.absoluteString) == [
            "https://api3.qoder.sh/algo/api/v2/model/list?Encode=1",
            "https://api3.qoder.sh/algo/api/v2/service/pro/sse/agent_chat_generation?FetchKeys=llm_model_result&AgentId=agent_common&Encode=1",
        ])
        let request = try #require(client.requests(to: chatPath).first)
        #expect(request.method == "POST")
        #expect(request.headers["Accept"] == "text/event-stream")
        #expect(request.headers["Cache-Control"] == "no-cache")
        #expect(request.headers["Accept-Encoding"] == "identity")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["X-Model-Key"] == "qfmodel")
        #expect(request.headers["X-Model-Source"] == "system")
        #expect(request.headers["Cosy-User"] == "uid-test")
        #expect(request.headers["Cosy-MachineId"] == "machine-test")
        #expect(request.headers["Login-Version"] == "v2")

        // The signature covers the wire body, not the plaintext.
        let wire = String(decoding: try #require(request.body), as: UTF8.self)
        let authorization = try #require(request.headers["Authorization"])
        #expect(authorization.hasPrefix("Bearer COSY."))
        let parts = authorization.dropFirst("Bearer COSY.".count).split(separator: ".").map(String.init)
        #expect(parts.last == QoderCosy.signature(
            payload: parts[0], key: request.headers["Cosy-Key"] ?? "",
            timestamp: Int64(request.headers["Cosy-Date"] ?? "") ?? 0,
            body: wire, path: chatPath.replacingOccurrences(of: "/algo", with: "")
        ))

        let plain = try #require(JSONSerialization.jsonObject(with: qoderDecodeRequestBody(wire)) as? [String: Any])
        #expect(plain["agent_id"] as? String == "agent_common")
        #expect((plain["model_config"] as? [String: Any])?["key"] as? String == "qfmodel")
        #expect((plain["messages"] as? [[String: Any]])?.count == 2)
        #expect((plain["parameters"] as? [String: Any])?["reasoning_effort"] as? String == "xhigh")
        #expect((plain["tools"] as? [[String: Any]])?.count == 1)
    }

    @Test("A Qoder CN account's listing and chat go to Qoder CN's inference host")
    func cnHost() async throws {
        let (_, final, client) = await turn(
            reply: .init(body: sse([content("ok")])), model: qoderModel(id: "qfmodel", site: .cn)
        )
        #expect(texts(final) == "ok")
        #expect(final.provider == "qoder-cn")
        #expect(client.requests.map { $0.url.host } == ["gateway.qoder.com.cn", "gateway.qoder.com.cn"])
        #expect(client.requests.map(\.url.path) == [listPath, chatPath])
    }

    @Test("The listing is read once per account and again only for a model it doesn't name")
    func listingIsKept() async throws {
        let other = #"{"chat":[{"key":"other-model","enable":true,"source":"custom"}]}"#
        let client = QoderStubClient([
            listPath: [.init(body: qoderFlashListing), .init(body: other)],
            chatPath: [.init(body: sse([content("ok")]))],
        ])
        let provider = QoderChatProvider(client: client)
        let context = Context(messages: [.user(UserMessage(text: "hi"))])
        let options = StreamOptions(resolvedAuth: auth())
        for _ in 0..<2 {
            let (_, final) = await collect(provider.stream(
                model: qoderModel(id: "qfmodel", site: .global),
                context: context,
                options: options
            ))
            #expect(final.stopReason == .stop)
        }
        #expect(client.requests(to: listPath).count == 1)

        // A new model on the roster is found by a fresh read…
        let (_, found) = await collect(provider.stream(
            model: qoderModel(id: "other-model", site: .global),
            context: context,
            options: options
        ))
        #expect(found.stopReason == .stop)
        #expect(client.requests(to: listPath).count == 2)
        #expect(client.requests(to: chatPath).last?.headers["X-Model-Source"] == "custom")

        // …and one the account isn't offered is refused before any chat.
        let (_, refused) = await collect(provider.stream(
            model: qoderModel(id: "unknown", site: .global),
            context: context,
            options: options
        ))
        #expect(refused.stopReason == .error)
        #expect(refused.errorMessage == "Qoder: unknown or disabled model \"unknown\"")
        #expect(refused.failure?.category == .invalidRequest)
        #expect(client.requests(to: chatPath).count == 3)

        // Another account has its own listing.
        _ = await collect(provider.stream(
            model: qoderModel(id: "other-model", site: .global), context: context,
            options: StreamOptions(resolvedAuth: auth(uid: "uid-two"))
        ))
        #expect(client.requests(to: listPath).count == 4)
    }

    @Test("Without a signed-in account nothing is sent")
    func missingSignIn() async throws {
        for options in [StreamOptions(), StreamOptions(resolvedAuth: ResolvedProviderAuth(token: "jt", scheme: .bearer))] {
            let client = QoderStubClient([:])
            let (_, final) = await collect(QoderChatProvider(client: client).stream(
                model: qoderModel(id: "qfmodel", site: .cn), context: Context(), options: options
            ))
            #expect(final.stopReason == .error)
            #expect(final.errorMessage == "Qoder CN sign-in is required (run /login qoder-cn)")
            #expect(final.failure?.category == .authentication)
            #expect(client.requests.isEmpty)
        }
    }
}

// MARK: - Stream

@Suite("Qoder chat stream")
struct QoderChatStreamTests {
    @Test("Thinking, text, a tool call written into the text and usage all reach the message")
    func fullTurn() async throws {
        let call = "\(callOpen)\n\u{3C}function=read\u{3E}\n\u{3C}parameter=path\u{3E}x\u{3C}/parameter\u{3E}\n\u{3C}/function\u{3E}\n\(callClose)"
        let (events, final, _) = await turn(reply: .init(body: sse([
            envelope(#"{"choices":[{"delta":{"role":"assistant","reasoning_content":"thinking"}}],"object":"chat.completion.chunk"}"#),
            envelope(#"{"choices":[{"delta":{"content":"Hi there"}}],"object":"chat.completion.chunk"}"#),
            content(call),
            envelope(#"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#),
            #"{"firstTokenDuration":50,"totalDuration":200}"#,
        ])))
        #expect(events.map(\.type) == [
            "start", "thinking_start", "thinking_delta", "thinking_end", "text_start", "text_delta", "text_end",
            "toolcall_start", "toolcall_delta", "toolcall_end", "done",
        ])
        #expect(final.content.count == 3)
        guard case .thinking(let thinking) = final.content[0] else {
            Issue.record("no thinking block")
            return
        }
        #expect(thinking.thinking == "thinking")
        #expect(texts(final) == "Hi there")
        let calls = toolCalls(final)
        #expect(calls.count == 1)
        #expect(calls[0].name == "read")
        #expect(calls[0].arguments == ["path": "x"])
        #expect(calls[0].id.hasPrefix("call_"))
        #expect(calls[0].id.count == 37)
        #expect(final.stopReason == .toolUse)
        #expect(final.usage.input == 10)
        #expect(final.usage.output == 5)
        #expect(final.usage.totalTokens == 15)
        #expect(final.api == "qoder-chat")
        #expect(final.provider == "qoder")
        #expect(final.model == "qfmodel")
    }

    @Test("A chunk sent as an object, not as JSON text, reads the same")
    func objectBody() async throws {
        let (_, final, _) = await turn(reply: .init(body: sse([
            jsonText(["body": ["choices": [["delta": ["content": "ok"]]]], "statusCodeValue": 200] as [String: Any]),
            jsonText([
                "body": ["choices": [["delta": [String: Any](), "finish_reason": "stop"]], "usage": ["prompt_tokens": 3, "completion_tokens": 1]],
                "statusCodeValue": "200",
            ] as [String: Any]),
        ])))
        #expect(texts(final) == "ok")
        #expect(final.stopReason == .stop)
        #expect(final.usage.input == 3)
    }

    @Test("Qoder's own tool_calls keep the ids their results are answered with")
    func nativeToolCalls() async throws {
        let (events, final, _) = await turn(reply: .init(body: sse([
            content("Reading."),
            envelope(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_up1","type":"function","function":{"name":"read","arguments":""}}]}}]}"#),
            envelope(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\": \"/tmp/x"}}]}}]}"#),
            envelope(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" \\u0026 y\"}"}}]}}]}"#),
            envelope(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_up2","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]}}]}"#),
            envelope(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#),
        ])))
        let calls = toolCalls(final)
        #expect(calls.map(\.id) == ["call_up1", "call_up2"])
        #expect(calls.map(\.name) == ["read", "bash"])
        // Arguments are handed on as they arrive: nothing is unescaped twice.
        let deltas = events.compactMap { event -> String? in
            if case .toolCallDelta(_, let delta, _) = event { return delta }
            return nil
        }
        #expect(deltas.joined() == #"{"path": "/tmp/x \u0026 y"}{"command":"ls"}"#)
        #expect(calls[0].arguments == ["path": "/tmp/x & y"])
        #expect(calls[1].arguments == ["command": "ls"])
        #expect(texts(final) == "Reading.")
        #expect(final.stopReason == .toolUse)
    }

    @Test("A native call with no id gets one, and text held back is let go before it")
    func nativeCallWithoutId() async throws {
        let (_, final, _) = await turn(reply: .init(body: sse([
            content("a <"),
            envelope(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"read","arguments":"{}"}}]}}]}"#),
            envelope(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#),
        ])))
        #expect(texts(final) == "a <")
        #expect(toolCalls(final).first?.id.hasPrefix("call_") == true)
        #expect(final.content.count == 2)
    }

    @Test("At the end of the stream held text goes out and there is one stop", arguments: [
        ("a < b and x <", "a < b and x <", StopReason.stop, 0),
        ("\(callOpen){\"name\":\"read\",\"arguments\":{\"path\":\"x\"}}\(callClose)tail <", "tail <", .toolUse, 1),
        ("before \(callOpen)incomplete", "before \(callOpen)incomplete", .stop, 0),
        ("", "", .stop, 0),
    ])
    func endOfStream(input: String, text: String, stop: StopReason, calls: Int) async throws {
        let (events, final, _) = await turn(reply: .init(body: sse([content(input), "[DONE]"])))
        #expect(texts(final) == text)
        #expect(final.stopReason == stop)
        #expect(toolCalls(final).count == calls)
        #expect(events.filter { $0.type == "done" }.count == 1)
        #expect(events.last?.type == "done")
    }

    @Test("Chunks split anywhere and lines with no blank between them read the same")
    func chunking() async throws {
        let lines = [
            content("Hel"),
            content("lo, 世界"),
            envelope(#"{"choices":[{"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#)
        ]
        let wire = Data(lines.map { "data: \($0)\n" }.joined().utf8)
        var reply = QoderStubClient.Reply(body: "")
        reply.chunks = stride(from: 0, to: wire.count, by: 7).map { wire[$0..<min($0 + 7, wire.count)] }
        let (_, final, _) = await turn(reply: reply)
        #expect(texts(final) == "Hello, 世界")
        #expect(final.stopReason == .length)
        #expect(final.usage.output == 2)
    }

    // magpie-plugins qoder `stream.test.mjs`, a reply shaped as a real
    // qmodel one: the usage comes after the finish, in a chunk with no
    // choices, then `[DONE]` and the timing line.
    @Test("The usage Qoder sends after the finish is read, cached and reasoning tokens with it")
    func usageAfterFinish() async throws {
        let (_, final, _) = await turn(reply: .init(body: [
            envelope(#"{"choices":[{"delta":{"content":"Hi","reasoning_content":""},"index":0}],"object":"chat.completion.chunk"}"#),
            envelope(#"{"choices":[{"delta":{"content":""},"finish_reason":"stop","index":0}],"object":"chat.completion.chunk"}"#),
            envelope(#"{"choices":[],"object":"chat.completion.chunk","usage":{"completion_tokens":106,"completion_tokens_details":{"reasoning_tokens":94},"prompt_tokens":40,"prompt_tokens_details":{"cached_tokens":32},"total_tokens":146}}"#),
            envelope("[DONE]"),
            #"{"firstTokenDuration":821,"totalDuration":1982}"#,
        ].map { "data:\($0)\n\n" }.joined()))
        #expect(texts(final) == "Hi")
        #expect(final.stopReason == .stop)
        #expect(final.content.count == 1)
        // The prompt's 40 are 32 read from the cache and 8 that were not.
        #expect(final.usage.input == 8)
        #expect(final.usage.cacheRead == 32)
        #expect(final.usage.output == 106)
        #expect(final.usage.reasoning == 94)
        #expect(final.usage.totalTokens == 146)
    }

    @Test("The reply is read to Qoder's [DONE], and nothing after it")
    func stopsAtDone() async throws {
        let (_, final, _) = await turn(reply: .init(body: sse([
            content("done"),
            envelope(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#),
            content(" and more"),
            envelope("[DONE]"),
            content(" and never this"),
            failedEnvelope(500, #"{"message":"late"}"#),
        ])))
        #expect(texts(final) == "done and more")
        #expect(final.stopReason == .length)
        #expect(final.usage.totalTokens == 0)
    }

    @Test("A refusal inside the stream fails the turn with its status", arguments: [
        (401, #"{"message":"device not trusted"}"#, "Qoder: the sign-in lapsed — sign in again (Qoder said 401: device not trusted)", 401, ProviderFailure.Category.authentication),
        (403, #"{"message":"upstream failure"}"#, "Qoder: the sign-in lapsed — sign in again (Qoder said 403: upstream failure)", 401, .authentication),
        (429, #"{"message":"额度已耗尽"}"#, "usage limit reached: 额度已耗尽", 429, .quota),
        (500, #"{"message":"upstream failure"}"#, "Qoder: upstream failure", 500, .server),
        (400, #"{"message":"Your quota is used up"}"#, "usage limit reached: Your quota is used up", 429, .quota),
        (400, #"{"message":"bad request","details":"{\"error\":{\"message\":\"该模型始终思考，不支持关闭思考\"}}"}"#,
         "Qoder: bad request: 该模型始终思考，不支持关闭思考", 400, .invalidRequest),
        (200_000, "", "Qoder: {\"body\":\"\",\"statusCodeValue\":200000}", 502, .server),
    ])
    func envelopeErrors(
        status: Int, body: String, message: String, mapped: Int, category: ProviderFailure.Category
    ) async throws {
        for partial in [false, true] {
            let lines = (partial ? [content("some text")] : []) + [failedEnvelope(status, body)]
            let (events, final, _) = await turn(reply: .init(body: sse(lines)))
            #expect(final.stopReason == .error)
            #expect(final.errorMessage == message)
            #expect(final.failure?.httpStatus == mapped)
            #expect(final.failure?.category == category)
            #expect(events.last?.type == "error")
            // What had already streamed stays on the failed message.
            #expect(texts(final) == (partial ? "some text" : ""))
        }
    }

    @Test("A refused request fails with Qoder's reason, its status and a retry hint", arguments: [
        (401, #"{"message":"token expired"}"#, "Qoder: the sign-in lapsed — sign in again (Qoder said 401: token expired)", ProviderFailure.Category.authentication),
        // Qoder gave no reason: none is made up.
        (403, "", "Qoder: the sign-in lapsed — sign in again", .authentication),
        (429, "slow down", "usage limit reached: slow down", .quota),
        (503, "", "Qoder: service unavailable", .server),
        (400, #"{"message":"prompt is too long: 250000 tokens > 200000 maximum"}"#,
         "Qoder: prompt is too long: 250000 tokens > 200000 maximum", .contextOverflow),
    ])
    func httpErrors(status: Int, body: String, message: String, category: ProviderFailure.Category) async throws {
        let (events, final, client) = await turn(
            reply: .init(status: status, contentType: "application/json", body: body)
        )
        #expect(final.stopReason == .error)
        #expect(final.errorMessage?.lowercased() == message.lowercased())
        #expect(final.failure?.category == category)
        #expect(events.map(\.type) == ["error"])
        #expect(client.requests(to: chatPath).count == 1)
    }

    // magpie-plugins qoder `busy.test.mjs` (#98). The body is the one Qoder
    // gave a real trial account on 2026-10-12, byte for byte
    // (`testdata/queued-10605.json`).
    private static let queued = #"{"code":"10605","message":"{\"isQueued\":false,\"modelKey\":\"efficient\",\"queueCount\":0,\"queueType\":\"p3\",\"retryAfterSeconds\":30,\"serviceAvailable\":false,\"waitTime\":0}"}"#

    @Test("A 403 with Qoder's queue code 10605 is a busy model to ask again after its 30s, not a lapsed sign-in", arguments: [false, true])
    func queueIsBusy(inStream: Bool) async throws {
        let reply: QoderStubClient.Reply = inStream
            ? .init(body: sse([failedEnvelope(403, Self.queued)]))
            : .init(status: 403, contentType: "application/json", body: Self.queued)
        let (_, final, _) = await turn(reply: reply)
        #expect(final.errorMessage == "Qoder is busy for efficient (this plan's queue: p3); try again in 30s")
        #expect(final.failure?.httpStatus == 503)
        #expect(final.failure?.retryAfterMs == 30_000)
        #expect(final.failure?.category == .server)
        #expect(final.failure?.isRetryable == true)
    }

    @Test("The queue's own wait is used, a queued request says so, and with no wait it is 30s")
    func queueWait() throws {
        func queue(_ state: [String: Any], code: String = "10605", status: Int = 403) -> ProviderFailure {
            QoderChatProvider.failure(
                status: status,
                body: Data(jsonText(["code": code, "message": jsonText(state)]).utf8)
            )
        }
        let queued = queue(["isQueued": true, "modelKey": "ultimate", "retryAfterSeconds": 12.2])
        #expect(queued.httpStatus == 503)
        #expect(queued.retryAfterMs == 13_000)
        #expect(queued.message == "Qoder queued the request for ultimate; try again in 13s")
        let unavailable = queue(["serviceAvailable": false])
        #expect(unavailable.httpStatus == 503)
        #expect(unavailable.retryAfterMs == 30_000)
        // The code alone, as a number or text, the message plain text.
        for body in [#"{"code":"10605","message":"busy"}"#, #"{"code":10605,"message":"busy"}"#] {
            let plain = QoderChatProvider.failure(status: 403, body: Data(body.utf8))
            #expect(plain.httpStatus == 503)
            #expect(plain.retryAfterMs == 30_000)
        }
        // A queue state under another status (429) is the same wait.
        let limited = queue(["serviceAvailable": false, "retryAfterSeconds": 5], code: "", status: 429)
        #expect(limited.httpStatus == 503)
        #expect(limited.retryAfterMs == 5000)
        #expect(limited.category == .server)
    }

    @Test("Qoder's other codes on a 403 aren't a lapsed sign-in either; 105 and no code are")
    func codes() throws {
        func failure(_ code: String, _ message: String) -> ProviderFailure {
            QoderChatProvider.failure(status: 403, body: Data(jsonText(["code": code, "message": message]).utf8))
        }
        for code in ["110", "112", "113", "114", "115", "116", "117", "118", "119", "122"] {
            let spent = failure(code, "credits used up")
            #expect(spent.message == "usage limit reached: credits used up")
            #expect(spent.httpStatus == 429)
            #expect(spent.category == .quota)
        }
        for code in ["406", "416", "430", "80411", "80412", "100400", "100401", "100403"] {
            let refused = failure(code, "no")
            #expect(refused.message == "Qoder refused the request (\(code)): no")
            #expect(refused.httpStatus == 400)
            #expect(refused.category == .invalidRequest)
        }
        let expired = failure("105", "login expired")
        #expect(expired.message == "Qoder: the sign-in lapsed — sign in again (Qoder said 403: login expired)")
        #expect(expired.httpStatus == 401)
        #expect(expired.category == .authentication)
        #expect(QoderChatProvider.failure(status: 403, body: Data()).message == "Qoder: the sign-in lapsed — sign in again")
    }

    @Test("A refused listing fails the turn before any chat")
    func listingRefused() async throws {
        let client = QoderStubClient([listPath: [.init(status: 403, contentType: "application/json", body: "{}")]])
        let (_, final) = await collect(QoderChatProvider(client: client).stream(
            model: qoderModel(id: "qfmodel", site: .global),
            context: Context(),
            options: StreamOptions(resolvedAuth: auth())
        ))
        #expect(final.failure?.category == .authentication)
        #expect(client.requests(to: chatPath).isEmpty)
    }

    @Test("A connection lost mid-stream is a transport failure that keeps what arrived")
    func brokenStream() async throws {
        let (events, final, _) = await turn(reply: .init(
            body: sse([content("partial")]), failure: URLError(.networkConnectionLost)
        ))
        #expect(final.stopReason == .error)
        #expect(final.errorMessage?.hasPrefix("Qoder: reading stream: ") == true)
        #expect(final.failure?.category == .transport)
        #expect(final.failure?.isRetryable == true)
        #expect(texts(final) == "partial")
        #expect(events.last?.type == "error")
    }

    @Test("A stream that ends inside a tool call's arguments is not run as a call")
    func truncatedToolCall() async throws {
        let (_, final, _) = await turn(reply: .init(body: sse([
            envelope(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_up1","function":{"name":"write","arguments":"{\"path\": \"/tmp/x"}}]}}]}"#),
        ])))
        #expect(final.stopReason == .error)
        #expect(final.errorMessage == "Qoder: stream ended before its tool call was complete")
        #expect(final.failure?.category == .transport)
    }

    @Test("A web page or nothing at all under a 200 is no reply")
    func notAnAPIReply() async throws {
        let (_, page, _) = await turn(
            reply: .init(contentType: "text/html; charset=utf-8", body: "<html>Just a moment...</html>")
        )
        #expect(page.stopReason == .error)
        #expect(page.errorMessage == "Qoder: answered 200 with a web page, not an API reply")
        #expect(page.failure?.category == .server)

        let (_, empty, _) = await turn(reply: .init(body: ""))
        #expect(empty.stopReason == .error)
        #expect(empty.errorMessage == "Qoder: answered 200 with nothing in it, not an API reply")
        #expect(empty.failure?.isRetryable == true)
    }

    @Test("A cancelled turn ends aborted")
    func cancelled() async throws {
        let cancellation = CancellationHandle()
        cancellation.cancel()
        let (events, final, _) = await turn(
            reply: .init(body: sse([content("ok")])),
            options: StreamOptions(resolvedAuth: auth(), cancellation: cancellation)
        )
        #expect(final.stopReason == .aborted)
        #expect(events.last?.type == "error")
    }
}

@Suite("Qoder tool calls written into the text")
struct QoderToolCallSplitterTests {
    private func run(_ pieces: [String]) -> (fragments: [QoderToolCallSplitter.Fragment], held: String) {
        var splitter = QoderToolCallSplitter()
        let fragments = pieces.flatMap { splitter.feed($0) }
        return (fragments, splitter.flush())
    }

    @Test("A block split across chunks is one call, with the text around it")
    func splitAcrossChunks() {
        let (fragments, held) = run([
            "before \u{3C}tool", "_call\u{3E}{\"name\":\"read\",", "\"arguments\":{\"path\":\"x\"}}\u{3C}/tool", "_call\u{3E} after",
        ])
        #expect(fragments == [.text("before "), .call(name: "read", arguments: #"{"path":"x"}"#), .text(" after")])
        #expect(held == "")
    }

    @Test("Text that only might open a block is held, then let go")
    func heldPrefix() {
        let (fragments, held) = run(["a \u{3C}", "b \u{3C}tool_ca", "t"])
        #expect(fragments == [.text("a "), .text("\u{3C}b "), .text("\u{3C}tool_cat")])
        #expect(held == "")
        #expect(run(["x \u{3C}tool_call"]).held == "\u{3C}tool_call")
    }

    @Test("The XML form reads each parameter as JSON when it is JSON and as it stands otherwise")
    func xmlForm() throws {
        let block = "\n\u{3C}function=write\u{3E}\n\u{3C}parameter=path\u{3E}/tmp/a b\u{3C}/parameter\u{3E}\n"
            + "\u{3C}parameter=lines\u{3E}[1, 2]\u{3C}/parameter\u{3E}\n\u{3C}parameter=text\u{3E}a \u{3C} b &&\nc\u{3C}/parameter\u{3E}\n"
            + "\u{3C}parameter=force\u{3E}true\u{3C}/parameter\u{3E}\n\u{3C}/function\u{3E}\n"
        let call = try #require(QoderToolCallSplitter.parseCall(block))
        #expect(call.name == "write")
        let arguments = try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))
        #expect(arguments == ["path": "/tmp/a b", "lines": [1, 2], "text": "a \u{3C} b &&\nc", "force": true])
    }

    @Test("A block that is neither form stays the text it was")
    func unreadableBlock() {
        #expect(QoderToolCallSplitter.parseCall("just words") == nil)
        #expect(QoderToolCallSplitter.parseCall(#"{"name":"read","arguments":"not an object"}"#) == nil)
        #expect(QoderToolCallSplitter.parseCall(#"{"name":" ","arguments":{}}"#) == nil)
        let (fragments, _) = run(["\(callOpen)just words\(callClose)"])
        #expect(fragments == [.text("\(callOpen)just words\(callClose)")])
    }
}

// MARK: - Registration

@Suite("Qoder registration", .serialized)
struct QoderRegistrationTests {
    private func credentials() -> OAuthCredentials {
        OAuthCredentials(
            access: "jt-one", refresh: "rt-one", expires: .max,
            extras: [
                "uid": "uid-one", "machineId": "machine-one", "email": "one@x", "name": "One",
                "deviceToken": "dt-one", "deviceRefresh": "drt-one",
            ]
        )
    }

    @Test("A stored login registers its site's provider and resolves the account beside the token", arguments: [
        ("qoder", "Qoder", "https://api3.qoder.sh"), ("qoder-cn", "Qoder CN", "https://gateway.qoder.com.cn"),
    ])
    func registerStoredLogin(storeId: String, name: String, host: String) async throws {
        let store = OAuthStore()
        try await store.set(credentials(), for: storeId)
        let resolved = try #require(try await registerStored(storeId: storeId, store: store))
        #expect(resolved.model.id == "qfmodel")
        #expect(resolved.model.api == "qoder-chat")
        #expect(resolved.model.provider == storeId)
        #expect(resolved.model.baseURL == host)
        #expect(resolved.modelLabel == "qfmodel · \(name)")
        #expect(await APIRegistry.shared.provider(scope: storeId, api: "qoder-chat") is QoderChatProvider)

        // The envelope's fields ride as metadata; the account-page tokens do not.
        let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
        #expect(auth.token == "jt-one")
        #expect(auth.metadata == ["uid": "uid-one", "machineId": "machine-one", "email": "one@x", "name": "One"])

        let override = try #require(try await registerStored(
            storeId: storeId,
            store: store,
            modelOverride: "kmodel_latest"
        ))
        #expect(override.model.name == "Kimi-K3")
    }

    @Test("Both sites are in the directory, the refresh providers and the display names")
    func directory() {
        #expect(modelProviderScope(forStoreId: "qoder-cn") == "qoder-cn")
        #expect(catalogProvider(forStoreId: "qoder") == "qoder")
        #expect(providerDisplayName(forStoreId: "qoder-cn") == "Qoder CN")
        #expect(ProviderAttribution.getProviderDisplayName("qoder") == "Qoder")
        #expect(ProviderAttribution.getProviderDisplayName("qoder-cn") == "Qoder CN")
        let providers = OAuthManager.defaultProviders().map(\.id)
        #expect(providers.contains("qoder") && providers.contains("qoder-cn"))
    }
}
