import Foundation
import Testing
@testable import KWWKAI

/// What Anthropic (measured against api.anthropic.com, 2026-10-11) and
/// Anthropic-shaped relays (magpie c5b57b90) refuse or send differently.
@Suite("Anthropic vendor quirks")
struct AnthropicVendorQuirkTests {
    private func model(_ id: String) -> Model {
        var model = AnthropicProviderTests.sampleModel
        model.id = id
        model.input = [.text, .image]
        return model
    }

    private func request(
        _ messages: [Message],
        model: Model,
        options: StreamOptions? = nil
    ) async throws -> [String: Any] {
        let client = StubSSEClient(body: AnthropicToolChoiceTests.minimalSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test")
        _ = await provider.stream(model: model, context: Context(messages: messages), options: options).result()
        let data = try #require(client.lastRequest?.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func reply(_ sse: String) async -> AssistantMessage {
        let provider = AnthropicProvider(client: StubSSEClient(body: sse), defaultAPIKey: "test")
        return await provider.stream(
            model: model("grok-behind-a-relay"),
            context: Context(messages: [.user(UserMessage(text: "run date"))]),
            options: nil
        ).result()
    }

    private func toolCalls(_ message: AssistantMessage) -> [ToolCall] {
        message.content.compactMap { if case .toolCall(let call) = $0 { return call }; return nil }
    }

    @Test("an image's media_type goes in the one spelling Anthropic takes", arguments: [
        ("image/jpg", "image/jpeg"),
        ("IMAGE/JPEG", "image/jpeg"),
        ("image/png; charset=binary", "image/png"),
        ("image/webp", "image/webp"),
    ])
    func imageMediaType(sent: String, expected: String) async throws {
        let image = ImageContent(data: "aW1hZ2U=", mimeType: sent)
        let model = model("claude-test")
        let json = try await request([
            .user(UserMessage(content: [.text(TextContent(text: "look")), .image(image)])),
            .assistant(AssistantMessage(
                content: [.toolCall(ToolCall(id: "call-1", name: "screenshot", arguments: [:]))],
                api: model.api, provider: model.provider, model: model.id, stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(toolCallId: "call-1", toolName: "screenshot", content: [.image(image)])),
        ], model: model)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let user = try #require(messages[0]["content"] as? [[String: Any]])
        let result = try #require((messages[2]["content"] as? [[String: Any]])?.first)
        let inner = try #require(result["content"] as? [[String: Any]])
        for block in [user[1], inner[0]] {
            let source = try #require(block["source"] as? [String: Any])
            #expect(source["media_type"] as? String == expected)
            #expect(source["data"] as? String == image.data)
        }
    }

    @Test("temperature is left out for the Claudes that refuse it", arguments: [
        ("claude-sonnet-5", false),
        ("claude-sonnet-5-5", false),
        ("claude-fable-5", false),
        ("claude-fable-5-1", false),
        ("claude-mythos-5", false),
        ("claude-opus-4-7", false),
        ("claude-opus-5.5", false),
        ("claude-haiku-5-5", false),
        ("us.anthropic.claude-sonnet-5-20260301-v1:0", false),
        ("claude-haiku-4-5-20251001", true),
        ("claude-sonnet-4-5-20250929", true),
        ("claude-sonnet-4-6", true),
        ("claude-sonnet-4-20250514", true),
        ("claude-opus-4-6", true),
        ("claude-3-7-sonnet-20250219", true),
        ("kimi-for-coding", true),
    ])
    func temperature(modelId: String, kept: Bool) async throws {
        let json = try await request([.user(UserMessage(text: "hi"))], model: model(modelId),
                                     options: StreamOptions(temperature: 0))
        #expect((json["temperature"] != nil) == kept)
    }

    @Test("a relay's OpenAI-style stop reason ends the turn as what it means", arguments: [
        ("tool_calls", StopReason.toolUse),
        ("function_call", StopReason.toolUse),
        ("stop", StopReason.stop),
        ("length", StopReason.length),
        ("some_new_reason", StopReason.error),
    ])
    func relayStopReason(raw: String, expected: StopReason) async {
        let message = await reply("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg","role":"assistant","content":[],"model":"grok","usage":{"input_tokens":1,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"bash","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\\"command\\\":\\\"date\\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"\(raw)"},"usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}

        """)
        #expect(message.stopReason == expected)
        #expect((message.errorMessage == nil) == (expected != .error))
        #expect(toolCalls(message).first?.arguments == ["command": "date"])
    }

    @Test("a tool_use whose start carries its whole input keeps it", arguments: [false, true])
    func inputCarriedByBlockStart(repeatedAsDelta: Bool) async {
        // The relay in the report sends no delta at all. One that sends the
        // input again as a delta must not have it appended to JSON that is
        // already complete.
        let delta = repeatedAsDelta ? """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\\"command\\\":\\\"date\\\"}"}}


        """ : ""
        let message = await reply("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg","role":"assistant","content":[],"model":"grok","usage":{"input_tokens":1,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"bash","input":{"command":"date"}}}

        \(delta)event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}

        """)
        #expect(message.stopReason == .toolUse)
        #expect(toolCalls(message).map(\.name) == ["bash"])
        #expect(toolCalls(message).first?.arguments == ["command": "date"])
    }
    /// A relay that puts only the first keys on the block start and streams
    /// the rest. Seen in production as `bot_send_card` receiving only `action`.
    @Test("a tool_use whose start carries part of its input keeps the streamed rest", arguments: [
        // The whole input streamed again.
        #"{\"action\":\"send\",\"channel_id\":\"proj.x\",\"card\":{\"type\":\"task\"}}"#,
        // Only the remaining keys, as an object.
        #"{\"channel_id\":\"proj.x\",\"card\":{\"type\":\"task\"}}"#,
        // The start's object continued.
        #",\"channel_id\":\"proj.x\",\"card\":{\"type\":\"task\"}}"#,
    ])
    func partialInputOnBlockStart(streamed: String) async {
        let message = await reply("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg","role":"assistant","content":[],"model":"kimi","usage":{"input_tokens":1,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"bot_send_card","input":{"action":"send"}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\(streamed)"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}

        """)
        #expect(toolCalls(message).first?.arguments == [
            "action": "send", "channel_id": "proj.x", "card": ["type": "task"],
        ])
    }
}
