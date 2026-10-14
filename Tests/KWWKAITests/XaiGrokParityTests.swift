import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers every request with the same SSE body and keeps what was sent.
private final class RecordingSSEClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: String
    private var _requests: [(headers: [String: String], body: Data)] = []

    init(_ reply: String) { self.reply = reply }

    var requests: [(headers: [String: String], body: Data)] { lock.withLock { _requests } }

    func json(_ index: Int) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: requests[index].body) as? [String: Any])
    }

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?, cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        lock.withLock { _requests.append((headers, body ?? Data())) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "text/event-stream"])!
        let data = Data(reply.utf8)
        return (response, AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        })
    }
}

/// What xAI's API takes and refuses, as magpie's Grok plugin — the maintained
/// client of Grok's Responses backend — sends it (magpie-plugins
/// packages/grok index.mjs `rewrite` and `fetch`, with its tests).
@Suite("xAI Grok request rules")
struct XaiGrokParityTests {
    static let responses: Model = {
        var model = OpenAIResponsesTests.model
        model.id = "grok-4.7"
        model.provider = "xai"
        model.baseURL = "https://api.x.ai/v1"
        return model
    }()

    static let completions: Model = {
        var model = OpenAICompletionsTests.model
        model.id = "grok-4.3"
        model.provider = "xai"
        model.baseURL = "https://api.x.ai/v1"
        return model
    }()

    /// The shape of Codex desktop's `automation_update` parameters (the
    /// plugin's testdata/codex_automation_update_schema.json, cut down): a
    /// union at the root whose second branch is a union itself, with fields
    /// behind local `$ref`s.
    static let rootUnion: JSONValue = [
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "anyOf": [
            [
                "type": "object",
                "properties": ["mode": ["type": "string", "const": "view"], "id": ["$ref": "#/$defs/id"]],
                "required": ["mode", "id"],
                "additionalProperties": false,
            ],
            [
                "anyOf": [
                    [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"], "prompt": ["type": "string"], "rrule": ["type": "string"],
                            "mode": ["$ref": "#/$defs/create"],
                        ],
                        "required": ["name", "prompt", "rrule", "mode"],
                    ],
                    [
                        "type": "object",
                        "properties": [
                            "id": ["$ref": "#/$defs/id"], "status": ["type": "string"],
                            "mode": ["type": "string", "const": "update"],
                        ],
                        "required": ["id", "mode"],
                    ],
                ],
            ],
            ["type": "string"],
        ],
        "$defs": [
            "id": ["type": "string"],
            "create": ["type": "string", "enum": ["create", "suggested_create"]],
        ],
    ]

    private static func send(
        _ client: RecordingSSEClient, model: Model, tools: [Tool]? = nil,
        messages: [Message] = [.user(UserMessage(text: "hi"))], options: StreamOptions? = nil
    ) async -> AssistantMessage {
        let stream: AssistantMessageStream
        let context = Context(messages: messages, tools: tools)
        if model.api == "openai-completions" {
            stream = OpenAICompletionsProvider(client: client, defaultAPIKey: "k")
                .stream(model: model, context: context, options: options)
        } else {
            stream = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "k")
                .stream(model: model, context: context, options: options)
        }
        for await _ in stream {}
        return await stream.result()
    }

    // MARK: Tool schema

    @Test("Responses: a tool's root union reaches xAI as an object, nested branches' fields kept")
    func responsesRootUnionFolded() async throws {
        // Sent as it came, Grok answers 400 "[invalid_client_tool_schema]
        // mcp__codex_app__automation_update: tool parameter root must be an
        // object type (root schema is an anyOf/oneOf union with a non-object
        // branch)" (plugin 0.1.10, schema.test.mjs).
        let plain: JSONValue = ["type": "object", "properties": ["cmd": ["type": "string"]]]
        let tools = [
            Tool(name: "exec_command", description: "d", parameters: plain),
            Tool(name: "automation_update", description: "d", parameters: Self.rootUnion),
        ]
        let client = RecordingSSEClient(OpenAIResponsesTests.textSSE)
        _ = await Self.send(client, model: Self.responses, tools: tools)
        let sent = try #require(try client.json(0)["tools"] as? [[String: Any]])
        let folded = try #require(sent[1]["parameters"] as? [String: Any])
        #expect(folded["type"] as? String == "object")
        #expect(folded["anyOf"] == nil)
        #expect(folded["oneOf"] == nil)
        #expect(Set((folded["properties"] as? [String: Any] ?? [:]).keys)
            == ["mode", "id", "name", "prompt", "rrule", "status"])
        #expect(folded["required"] as? [String] == ["mode"])
        // The plain tool goes as it came.
        #expect(sent[0]["parameters"] as? NSDictionary == anyFromJSONValue(plain) as? NSDictionary)

        // Another vendor's Responses API gets the schema as the tool wrote it.
        _ = await Self.send(client, model: OpenAIResponsesTests.model, tools: tools)
        let untouched = try #require(try client.json(1)["tools"] as? [[String: Any]])
        #expect((untouched[1]["parameters"] as? [String: Any])?["anyOf"] != nil)
    }

    @Test("Responses: a tool added mid-conversation is folded for xAI the same")
    func addedToolRootUnionFolded() throws {
        let system = SystemMessage(toolsAdded: [
            Tool(name: "automation_update", description: "d", parameters: Self.rootUnion)
        ])
        for (flag, key) in [(\ModelCompat.supportsAdditionalTools, "additional_tools"), (\.supportsToolSearch, "tool_search_output")] {
            for (base, folds) in [(Self.responses, true), (OpenAIResponsesTests.model, false)] {
                var model = base
                var compat = model.compat ?? ModelCompat()
                compat[keyPath: flag] = true
                model.compat = compat
                let items = OpenAIResponsesProvider.encodeToolAdditions(system, model: model, seed: "s")
                let item = try #require(items.compactMap { anyFromJSONValue($0) as? [String: Any] }
                    .first { $0["type"] as? String == key })
                let parameters = try #require((item["tools"] as? [[String: Any]])?.first?["parameters"] as? [String: Any])
                #expect((parameters["type"] as? String == "object") == folds)
                #expect((parameters["anyOf"] == nil) == folds)
            }
        }
    }

    // MARK: Prompt cache

    @Test("Responses: xAI is told the conversation in x-grok-conv-id, the body's prompt_cache_key")
    func responsesConversationHeader() async throws {
        let client = RecordingSSEClient(OpenAIResponsesTests.textSSE)
        _ = await Self.send(client, model: Self.responses, options: StreamOptions(sessionId: "conversation-1"))
        #expect(client.requests[0].headers["x-grok-conv-id"] == "conversation-1")
        #expect(try client.json(0)["prompt_cache_key"] as? String == "conversation-1")

        // No caching asked, no key in the body: no conversation named either.
        _ = await Self.send(client, model: Self.responses,
                            options: StreamOptions(cacheRetention: CacheRetention.none, sessionId: "conversation-1"))
        #expect(client.requests[1].headers["x-grok-conv-id"] == nil)

        // A caller's own header is the one sent.
        _ = await Self.send(client, model: Self.responses,
                            options: StreamOptions(sessionId: "conversation-1", headers: ["X-Grok-Conv-Id": "mine"]))
        #expect(client.requests[2].headers["X-Grok-Conv-Id"] == "mine")
        #expect(client.requests[2].headers["x-grok-conv-id"] == nil)

        // Grok's header goes to Grok only.
        _ = await Self.send(
            client,
            model: OpenAIResponsesTests.model,
            options: StreamOptions(sessionId: "conversation-1")
        )
        #expect(client.requests[3].headers["x-grok-conv-id"] == nil)
    }

    @Test("Chat Completions: xAI is told the conversation in x-grok-conv-id")
    func completionsConversationHeader() async throws {
        let client = RecordingSSEClient(OpenAICompletionsTests.textSSE)
        _ = await Self.send(client, model: Self.completions, options: StreamOptions(sessionId: "conversation-1"))
        #expect(client.requests[0].headers["x-grok-conv-id"] == "conversation-1")

        _ = await Self.send(client, model: Self.completions,
                            options: StreamOptions(cacheRetention: CacheRetention.none, sessionId: "conversation-1"))
        #expect(client.requests[1].headers["x-grok-conv-id"] == nil)

        _ = await Self.send(
            client,
            model: OpenAICompletionsTests.model,
            options: StreamOptions(sessionId: "conversation-1")
        )
        #expect(client.requests[2].headers["x-grok-conv-id"] == nil)
    }

    // MARK: Reasoning replay

    /// A reasoning item whose `content` is null beside its sealed reasoning.
    static let nullContentReasoningSSE = """
    data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}

    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1"}}

    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[],"content":null,"encrypted_content":"sealed"}}

    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","role":"assistant","content":[]}}

    data: {"type":"response.output_text.delta","output_index":1,"content_index":0,"delta":"answer"}

    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message"}}

    data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":2,"output_tokens":1}}}

    """

    @Test("Responses: a replayed reasoning item goes back to xAI without a null content")
    func reasoningNullContentDropped() async throws {
        // Beside `"content": null` Grok cannot read the sealed reasoning and
        // refuses the request (magpie grok.go grokBody, "Could not decode the
        // compaction blob"; the plugin's rewrite drops the field).
        for (model, keepsNull) in [(Self.responses, false), (OpenAIResponsesTests.model, true)] {
            let client = RecordingSSEClient(Self.nullContentReasoningSSE)
            let first = await Self.send(client, model: model, options: StreamOptions(reasoning: .high))
            _ = await Self.send(client, model: model, messages: [
                .user(UserMessage(text: "hi")), .assistant(first), .user(UserMessage(text: "again")),
            ], options: StreamOptions(reasoning: .high))
            let input = try #require(try client.json(1)["input"] as? [[String: Any]])
            let reasoning = try #require(input.first { $0["type"] as? String == "reasoning" })
            #expect(reasoning["encrypted_content"] as? String == "sealed")
            #expect(reasoning["id"] as? String == "rs_1")
            #expect((reasoning["content"] is NSNull) == keepsNull)
            #expect((reasoning["content"] == nil) == !keepsNull)
        }
    }
}
