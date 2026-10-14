import Foundation
import Testing
@testable import KWWKAI

/// Gemini over the Interactions API. The SSE fixtures are trimmed copies of
/// what gemini-3.8-flash streamed on 2026-10-14 (signatures shortened).
@Suite("Google Gemini Interactions")
struct GoogleGeminiInteractionsTests {
    static let model = Model(
        id: "gemini-3.8-flash",
        name: "Gemini 3.8 Flash",
        api: "google-generative-ai",
        provider: "google",
        baseURL: "https://generativelanguage.googleapis.com",
        reasoning: true,
        input: [.text, .image],
        contextWindow: 1_048_576,
        maxTokens: 65_536
    )

    /// Two parallel calls: a signed thought, then calls whose arguments
    /// stream as JSON strings; ends `requires_action`.
    static let parallelCallsSSE = """
    data: {"interaction": {"object": "interaction", "model": "gemini-3.8-flash"}, "event_type": "interaction.created"}

    data: {"status": "in_progress", "event_type": "interaction.status_update"}

    data: {"index": 0, "step": {"type": "thought"}, "event_type": "step.start"}

    data: {"index": 0, "delta": {"signature": "EmkKZwFpFH0T", "type": "thought_signature"}, "event_type": "step.delta"}

    data: {"index": 0, "event_type": "step.stop"}

    data: {"index": 1, "step": {"id": "call_842506", "signature": "AWkUfRMKx2Yn", "type": "function_call", "name": "read", "arguments": {}}, "event_type": "step.start"}

    data: {"index": 1, "delta": {"arguments": "{\\"path\\":\\"a.txt\\"}", "type": "arguments_delta"}, "event_type": "step.delta"}

    data: {"index": 1, "event_type": "step.stop"}

    data: {"index": 2, "step": {"id": "call_842512", "type": "function_call", "name": "read", "arguments": {}}, "event_type": "step.start"}

    data: {"index": 2, "delta": {"arguments": "{\\"path\\":\\"b.txt\\"}", "type": "arguments_delta"}, "event_type": "step.delta"}

    data: {"index": 2, "event_type": "step.stop"}

    data: {"interaction": {"status": "requires_action", "usage": {"total_tokens": 98, "total_input_tokens": 66, "total_cached_tokens": 0, "total_output_tokens": 32, "total_thought_tokens": 0}, "object": "interaction", "model": "gemini-3.8-flash"}, "event_type": "interaction.completed"}

    data: [DONE]

    """

    /// A thought summary, then the answer; ends `completed`.
    static let textSSE = """
    data: {"interaction": {"object": "interaction", "model": "gemini-3.8-flash"}, "event_type": "interaction.created"}

    data: {"index": 0, "step": {"type": "thought"}, "event_type": "step.start"}

    data: {"index": 0, "delta": {"content": {"text": "Counting the r's."}, "type": "thought_summary"}, "event_type": "step.delta"}

    data: {"index": 0, "delta": {"signature": "Et0ICtoIAWkU", "type": "thought_signature"}, "event_type": "step.delta"}

    data: {"index": 0, "event_type": "step.stop"}

    data: {"index": 1, "step": {"type": "model_output"}, "event_type": "step.start"}

    data: {"index": 1, "delta": {"text": "There are 3 ", "type": "text"}, "event_type": "step.delta"}

    data: {"index": 1, "delta": {"text": "r's.", "type": "text"}, "event_type": "step.delta"}

    data: {"index": 1, "event_type": "step.stop"}

    data: {"interaction": {"status": "completed", "usage": {"total_tokens": 314, "total_input_tokens": 18, "total_cached_tokens": 8, "total_output_tokens": 11, "total_thought_tokens": 285}, "object": "interaction"}, "event_type": "interaction.completed"}

    data: [DONE]

    """

    static func run(_ sse: String, status: Int = 200, context: Context? = nil, options: StreamOptions? = nil)
        async -> (AssistantMessage, StubSSEClient) {
        let client = StubSSEClient(body: sse, statusCode: status)
        let provider = GoogleGeminiProvider(client: client, defaultAPIKey: "AQ.test")
        let result = await provider.stream(
            model: model,
            context: context ?? Context(messages: [.user(UserMessage(text: "hi"))]),
            options: options
        ).result()
        return (result, client)
    }

    static func body(_ client: StubSSEClient) throws -> [String: Any] {
        let data = try #require(client.lastRequest?.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func input(_ messages: [Message], model: Model = model) throws -> [[String: Any]] {
        let data = try GoogleGeminiProvider.encodeInteractionsBody(
            model: model, context: Context(messages: messages), options: nil)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["input"] as? [[String: Any]])
    }

    // MARK: - Which wire

    @Test("Google's own host goes over Interactions; Vertex, relays and a pinned wire do not")
    func routing() {
        let provider = GoogleGeminiProvider(defaultAPIKey: "k")
        #expect(provider.usesInteractions(Self.model))
        var versioned = Self.model
        versioned.baseURL = "https://generativelanguage.googleapis.com/v1beta"
        #expect(provider.usesInteractions(versioned))
        var relay = Self.model
        relay.baseURL = "https://gemini-relay.example.com"
        #expect(!provider.usesInteractions(relay))
        #expect(!GoogleGeminiProvider(defaultAPIKey: "k", wire: .generateContent).usesInteractions(Self.model))
        #expect(GoogleGeminiProvider(defaultAPIKey: "k", wire: .interactions).usesInteractions(relay))
        #expect(!ProviderVariants.vertexAI(project: "p", accessToken: "t").usesInteractions(Self.model))
    }

    // MARK: - Request

    @Test("posts a stateless interaction with the key in a header, never the URL")
    func request() async throws {
        let tool = Tool(name: "read", description: "Read a file", parameters: .object([
            "type": .string("object"),
            "properties": .object(["path": .object(["type": .string("string")])]),
        ]))
        var options = StreamOptions()
        options.reasoning = .high
        options.maxTokens = 4000
        let (_, client) = await Self.run(Self.textSSE, context: Context(
            systemPrompt: "Be terse.", messages: [.user(UserMessage(text: "hi"))], tools: [tool]), options: options)
        let request = try #require(client.lastRequest)
        #expect(request.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions?alt=sse")
        #expect(request.headers["x-goog-api-key"] == "AQ.test")
        let body = try Self.body(client)
        #expect(body["model"] as? String == "gemini-3.8-flash")
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["previous_interaction_id"] == nil)
        #expect(body["system_instruction"] as? String == "Be terse.")
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "function")
        #expect(tools.first?["name"] as? String == "read")
        #expect(tools.first?["parameters"] != nil)
        let config = try #require(body["generation_config"] as? [String: Any])
        #expect(config["thinking_level"] as? String == "high")
        #expect(config["thinking_summaries"] as? String == "auto")
        #expect(config["max_output_tokens"] as? Int == 4000)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.first?["type"] as? String == "user_input")
    }

    // MARK: - Stream

    @Test("parallel calls: ids kept, streamed arguments parsed, signatures marked, toolUse")
    func parallelCalls() async throws {
        let (result, _) = await Self.run(Self.parallelCallsSSE)
        #expect(result.stopReason == .toolUse)
        #expect(result.content.count == 3)
        guard case .thinking(let thought) = result.content[0],
              case .toolCall(let a) = result.content[1],
              case .toolCall(let b) = result.content[2] else {
            Issue.record("unexpected content: \(result.content)")
            return
        }
        #expect(thought.thinkingSignature == "ix:EmkKZwFpFH0T")
        #expect(a.id == "call_842506" && a.name == "read")
        #expect(a.arguments == .object(["path": .string("a.txt")]))
        #expect(a.thoughtSignature == "ix:AWkUfRMKx2Yn")
        #expect(b.id == "call_842512")
        #expect(b.arguments == .object(["path": .string("b.txt")]))
        #expect(b.thoughtSignature == nil)
        #expect(result.usage.input == 66)
        #expect(result.usage.output == 32)
    }

    @Test("text with a thought summary streams deltas and reports usage")
    func text() async throws {
        let client = StubSSEClient(body: Self.textSSE)
        let s = GoogleGeminiProvider(client: client, defaultAPIKey: "k").stream(
            model: Self.model, context: Context(messages: [.user(UserMessage(text: "hi"))]), options: nil)
        var text = "", thinking = ""
        for await event in s {
            if case .textDelta(_, let d, _) = event { text += d }
            if case .thinkingDelta(_, let d, _) = event { thinking += d }
        }
        let result = await s.result()
        #expect(text == "There are 3 r's.")
        #expect(thinking == "Counting the r's.")
        #expect(result.stopReason == .stop)
        #expect(result.usage.input == 10)
        #expect(result.usage.cacheRead == 8)
        #expect(result.usage.output == 296)
        #expect(result.usage.reasoning == 285)
    }

    @Test("incomplete is a length stop")
    func incomplete() async throws {
        let sse = Self.textSSE.replacingOccurrences(of: #""status": "completed""#, with: #""status": "incomplete""#)
        let (result, _) = await Self.run(sse)
        #expect(result.stopReason == .length)
    }

    @Test("a stream that never completes is the replayable no-finish error")
    func noCompletion() async throws {
        let sse = Self.textSSE.components(separatedBy: "data: {\"interaction\": {\"status\"").first ?? ""
        let (result, _) = await Self.run(sse)
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "Gemini stream ended without a finish reason")
    }

    @Test("a completed reply with nothing in it is an error, not an answer")
    func emptyCompletion() async throws {
        let sse = """
        data: {"interaction": {"status": "completed", "usage": {"total_tokens": 122, "total_input_tokens": 122, "total_output_tokens": 0}}, "event_type": "interaction.completed"}

        data: [DONE]

        """
        let (result, _) = await Self.run(sse)
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "Gemini stream ended without content")
    }

    @Test("an SSE-shaped error body reads as Google's message and status")
    func httpError() async throws {
        let sse = """
        event: error
        data: {"error":{"message":"Request contains an invalid argument.","code":"invalid_request"},"event_type":"error"}

        """
        let (result, _) = await Self.run(sse, status: 400)
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("Request contains an invalid argument.") == true)
        #expect(result.failure?.httpStatus == 400)
    }

    @Test("an error event mid-stream ends the reply with its message")
    func errorEvent() async throws {
        let sse = """
        data: {"index": 0, "step": {"type": "model_output"}, "event_type": "step.start"}

        data: {"error":{"message":"Internal error","code":"internal"},"event_type":"error"}

        """
        let (result, _) = await Self.run(sse)
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("Internal error") == true)
    }

    // MARK: - Replay

    static func ownTurn(thinkingSignature: String?, callSignature: String?) -> [Message] {
        [
            .user(UserMessage(text: "Read a.txt")),
            .assistant(AssistantMessage(
                content: [
                    .thinking(ThinkingContent(thinking: "Reading.", thinkingSignature: thinkingSignature)),
                    .toolCall(ToolCall(id: "call_1", name: "read", arguments: .object(["path": .string("a.txt")]),
                                       thoughtSignature: callSignature)),
                ],
                api: model.api, provider: model.provider, model: model.id, stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(toolCallId: "call_1", toolName: "read",
                                          content: [.text(TextContent(text: "apple"))])),
        ]
    }

    @Test("its own signatures go back unmarked, on the thought and the call")
    func ownSignatures() throws {
        let steps = try Self.input(Self.ownTurn(thinkingSignature: "ix:SIG1", callSignature: "ix:SIG2"))
        #expect(steps.map { $0["type"] as? String } == ["user_input", "thought", "function_call", "function_result"])
        #expect(steps[1]["signature"] as? String == "SIG1")
        #expect((steps[1]["summary"] as? [[String: Any]])?.first?["text"] as? String == "Reading.")
        #expect(steps[2]["signature"] as? String == "SIG2")
        #expect(steps[2]["id"] as? String == "call_1")
        #expect(steps[3]["call_id"] as? String == "call_1")
        #expect(steps[3]["result"] as? String == "apple")
    }

    @Test("a generateContent-era signature is not replayed; the step goes with Google's placeholder")
    func legacySignatures() throws {
        let steps = try Self.input(Self.ownTurn(thinkingSignature: "AAAA", callSignature: "BBBB"))
        #expect(steps.map { $0["type"] as? String } == ["user_input", "thought", "thought", "function_call", "function_result"])
        #expect(steps[1]["signature"] as? String == GoogleGeminiProvider.skipThoughtSignature)
        #expect(steps[2]["signature"] == nil)
        #expect(steps[3]["signature"] as? String == GoogleGeminiProvider.skipThoughtSignature)
    }

    @Test("Claude's turn — text ahead of calls — opens with a placeholder thought and keeps its ids")
    func foreignTurn() throws {
        let steps = try Self.input([
            .user(UserMessage(text: "Read both")),
            .assistant(AssistantMessage(
                content: [
                    .thinking(ThinkingContent(thinking: "I will read both.", thinkingSignature: "c2ln")),
                    .toolCall(ToolCall(id: "toolu_01A", name: "read", arguments: .object([:]))),
                    .toolCall(ToolCall(id: "toolu_01B", name: "read", arguments: .object([:]))),
                ],
                api: "anthropic-messages", provider: "anthropic", model: "claude-opus-5-5", stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(toolCallId: "toolu_01A", toolName: "read", content: [.text(TextContent(text: "apple"))])),
            .toolResult(ToolResultMessage(toolCallId: "toolu_01B", toolName: "read", content: [.text(TextContent(text: "banana"))])),
        ])
        #expect(steps.map { $0["type"] as? String }
            == ["user_input", "thought", "model_output", "function_call", "function_call", "function_result", "function_result"])
        #expect(steps[1]["signature"] as? String == GoogleGeminiProvider.skipThoughtSignature)
        #expect(steps[3]["signature"] as? String == GoogleGeminiProvider.skipThoughtSignature)
        #expect(steps[4]["signature"] == nil)
        #expect(steps[3]["id"] as? String == "toolu_01A")
        #expect(steps[6]["call_id"] as? String == "toolu_01B")
    }

    @Test("a turn with no calls needs no placeholder")
    func plainTurn() throws {
        let steps = try Self.input([
            .user(UserMessage(text: "hi")),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "hello"))],
                api: "anthropic-messages", provider: "anthropic", model: "claude-opus-5-5", stopReason: .stop
            )),
            .user(UserMessage(text: "again")),
        ])
        #expect(steps.map { $0["type"] as? String } == ["user_input", "model_output", "user_input"])
    }

    @Test("a result with an image goes as content parts, and an error is marked")
    func imageResult() throws {
        let steps = try Self.input([
            .user(UserMessage(text: "shot")),
            .assistant(AssistantMessage(
                content: [.toolCall(ToolCall(id: "call_1", name: "screenshot", arguments: .object([:])))],
                api: Self.model.api, provider: Self.model.provider, model: Self.model.id, stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "call_1", toolName: "screenshot",
                content: [.text(TextContent(text: "done")), .image(ImageContent(data: "aGk=", mimeType: "image/png"))],
                isError: true
            )),
        ])
        let result = try #require(steps.last)
        #expect(result["is_error"] as? Bool == true)
        let parts = try #require(result["result"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text", "image"])
        #expect(parts[1]["mime_type"] as? String == "image/png")
        #expect(parts[1]["data"] as? String == "aGk=")
    }

    @Test("a forced tool choice names the tool")
    func toolChoice() {
        #expect(GoogleGeminiProvider.interactionsToolChoice(.required) as? String == "any")
        let named = GoogleGeminiProvider.interactionsToolChoice(.tool(name: "read")) as? [String: Any]
        let allowed = named?["allowed_tools"] as? [String: Any]
        #expect(allowed?["mode"] as? String == "any")
        #expect(allowed?["tools"] as? [String] == ["read"])
    }
}
