import Foundation
import Testing
@testable import KWWKAI

/// DeepSeek refuses a request that replays a tool turn without its thinking
/// (magpie f4cc7459, #1462, #1611, #1822). The fixtures are magpie's
/// (internal/gateway/deepseek_anthropic_thinking_test.go and
/// chat_tool_reasoning_test.go).
@Suite("DeepSeek tool-turn reasoning")
struct DeepSeekToolTurnReasoningTests {
    // MARK: - Fixtures

    private static func json(_ text: String) -> [[String: Any]] {
        let data = Data(text.utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    private static func same(_ got: [String: Any], _ want: String) {
        let wantObject = (try? JSONSerialization.jsonObject(with: Data(want.utf8))) as? [String: Any] ?? [:]
        #expect(NSDictionary(dictionary: got).isEqual(to: wantObject), "\(got) is not \(want)")
    }

    /// magpie's `claudeTurnsForDeepSeek`: Claude's redacted thinking before
    /// one call, Claude's signed thinking before another, a step with none,
    /// and a reply with redacted and signed thinking.
    static let claudeTurns = #"""
    [
    {"role":"user","content":"fix the login bug"},
    {"role":"assistant","content":[{"type":"redacted_thinking","data":"EmwKAhgBEgy3va3pzix"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},
    {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"main.go"}]},
    {"role":"assistant","content":[{"type":"thinking","thinking":"Read main.go.","signature":"EqQBCkgIBxABGAIiQL"},{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"cat main.go"}}]},
    {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"package main"}]},
    {"role":"assistant","content":[{"type":"text","text":"Checking the test."},{"type":"tool_use","id":"toolu_3","name":"Bash","input":{"command":"go test"}}]},
    {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_3","content":"ok"}]},
    {"role":"assistant","content":[{"type":"redacted_thinking","data":"EmwKAhgBEgy3va3pzix"},{"type":"thinking","thinking":"Fine.","signature":"EqQBCkgIBxAB"},{"type":"text","text":"It passes."}]},
    {"role":"user","content":"thanks, now commit"}
    ]
    """#

    /// magpie's `toolTurnsNoReasoning`, less OpenRouter's `reasoning` field
    /// (kwwk never writes it on this route).
    static let chatTurns = #"""
    [
    {"role":"user","content":"hi"},
    {"role":"assistant","content":"Hello!"},
    {"role":"user","content":"what time is it? twice"},
    {"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_time","arguments":"{}"}}]},
    {"role":"tool","tool_call_id":"call_1","content":"12:00"},
    {"role":"assistant","content":null,"tool_calls":[{"id":"call_2","type":"function","function":{"name":"get_time","arguments":"{}"}}],"reasoning_content":"Once more."},
    {"role":"tool","tool_call_id":"call_2","content":"12:01"},
    {"role":"assistant","content":"It is 12:01."},
    {"role":"user","content":"thanks"},
    {"role":"assistant","content":"You're welcome."}
    ]
    """#

    private static func model(
        _ id: String, api: String, provider: String, baseURL: String, reasoning: Bool = true
    ) -> Model {
        Model(id: id, name: id, api: api, provider: provider, baseURL: baseURL,
              reasoning: reasoning, input: [.text], contextWindow: 128_000, maxTokens: 1024)
    }

    // MARK: - Which models

    @Test("the Messages rule holds for DeepSeek models on any host, never Anthropic's or Claude's", arguments: [
        ("deepseek-flash", "https://api.deepseek.com/anthropic", true),
        ("DeepSeek-V4-Pro", "https://relay.example", true),
        ("deepseek/deepseek-v4-pro", "https://openrouter.ai/api", true),
        ("some-model", "https://api.deepseek.com/anthropic", true),
        ("deepseek-flash", "https://api.anthropic.com", false),
        ("claude-sonnet-4-6", "https://api.deepseek.com/anthropic", false),
        ("anthropic/claude-sonnet-4-6", "https://deepseek.relay.example", false),
        ("kimi-k2", "https://api.moonshot.ai/anthropic", false),
        ("glm-5.2", "https://relay.example", false),
    ])
    func anthropicGate(id: String, baseURL: String, applies: Bool) {
        let m = Self.model(id, api: "anthropic-messages", provider: "x", baseURL: baseURL)
        #expect(DeepSeekToolTurnReasoning.appliesToAnthropic(m) == applies)
    }

    @Test("the Chat rule holds for DeepSeek models on any host", arguments: [
        ("deepseek-v4.1-flash", "https://opencode.ai/zen/go/v1", true),
        ("deepseek-chat", "https://api.deepseek.com", true),
        ("accounts/fireworks/models/deepseek-v4", "https://api.fireworks.ai/inference/v1", true),
        ("glm-5.2", "https://opencode.ai/zen/go/v1", false),
        ("mistral-medium-3.5", "https://api.mistral.ai/v1", false),
        ("gpt-x", "https://api.openai.com", false),
    ])
    func chatGate(id: String, baseURL: String, applies: Bool) {
        let m = Self.model(id, api: "openai-completions", provider: "x", baseURL: baseURL)
        #expect(DeepSeekToolTurnReasoning.appliesToChat(m) == applies)
    }

    // MARK: - Messages API

    @Test("each Messages tool turn, and a reply after tool results, gets thinking (magpie #1611, #1822)")
    func anthropicToolTurns() throws {
        let ms = DeepSeekToolTurnReasoning.anthropicMessages(Self.json(Self.claudeTurns))
        try #require(ms.count == 9)
        Self.same(ms[0], #"{"role":"user","content":"fix the login bug"}"#)
        Self.same(ms[1], #"{"role":"assistant","content":[{"type":"thinking","thinking":" "},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}"#)
        Self.same(ms[2], #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"main.go"}]}"#)
        Self.same(ms[3], #"{"role":"assistant","content":[{"type":"thinking","thinking":"Read main.go.","signature":"EqQBCkgIBxABGAIiQL"},{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"cat main.go"}}]}"#)
        Self.same(ms[5], #"{"role":"assistant","content":[{"type":"thinking","thinking":" "},{"type":"text","text":"Checking the test."},{"type":"tool_use","id":"toolu_3","name":"Bash","input":{"command":"go test"}}]}"#)
        Self.same(ms[7], #"{"role":"assistant","content":[{"type":"thinking","thinking":" "},{"type":"thinking","thinking":"Fine.","signature":"EqQBCkgIBxAB"},{"type":"text","text":"It passes."}]}"#)
        Self.same(ms[8], #"{"role":"user","content":"thanks, now commit"}"#)
    }

    @Test("a reply after tool results gets thinking; one after the user's words doesn't")
    func anthropicReplies() throws {
        let ms = DeepSeekToolTurnReasoning.anthropicMessages(Self.json(#"""
        [
        {"role":"user","content":"hi"},
        {"role":"assistant","content":[{"type":"text","text":"Hello!"}]},
        {"role":"user","content":[{"type":"text","text":"run ls"}]},
        {"role":"assistant","content":[{"type":"thinking","thinking":"ok","signature":"s"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]},
        {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a"},{"type":"text","text":"also b"}]},
        {"role":"assistant","content":[{"type":"text","text":"Done with b."}]},
        {"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"x"}]},
        {"role":"assistant","content":[{"type":"text","text":"Done."}]},
        {"role":"assistant","content":"plain"}
        ]
        """#))
        Self.same(ms[1], #"{"role":"assistant","content":[{"type":"text","text":"Hello!"}]}"#)
        Self.same(ms[3], #"{"role":"assistant","content":[{"type":"thinking","thinking":"ok","signature":"s"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}"#)
        // tool results beside the user's words: a new turn, as magpie has it
        Self.same(ms[5], #"{"role":"assistant","content":[{"type":"text","text":"Done with b."}]}"#)
        Self.same(ms[7], #"{"role":"assistant","content":[{"type":"thinking","thinking":" "},{"type":"text","text":"Done."}]}"#)
        Self.same(ms[8], #"{"role":"assistant","content":"plain"}"#)
    }

    @Test("Messages with nothing to change are left as they are")
    func anthropicUnchanged() {
        for text in [
            #"[{"role":"user","content":"hi"}]"#,
            #"[{"role":"assistant","content":[{"type":"thinking","thinking":"x"},{"type":"tool_use","id":"t","name":"n","input":{}}]}]"#,
            #"[{"role":"assistant","content":"plain"}]"#,
        ] {
            let before = Self.json(text)
            let after = DeepSeekToolTurnReasoning.anthropicMessages(before)
            #expect(NSArray(array: after).isEqual(to: before), "\(text) became \(after)")
        }
    }

    // MARK: - Chat API

    @Test("each Chat tool call, and a reply to a tool result, gets reasoning_content (magpie #1462, #1822)")
    func chatToolTurns() throws {
        let ms = DeepSeekToolTurnReasoning.chatMessages(Self.json(Self.chatTurns))
        try #require(ms.count == 10)
        Self.same(ms[1], #"{"role":"assistant","content":"Hello!"}"#)
        Self.same(ms[3], #"{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_time","arguments":"{}"}}],"reasoning_content":" "}"#)
        Self.same(ms[4], #"{"role":"tool","tool_call_id":"call_1","content":"12:00"}"#)
        Self.same(ms[5], #"{"role":"assistant","content":null,"tool_calls":[{"id":"call_2","type":"function","function":{"name":"get_time","arguments":"{}"}}],"reasoning_content":"Once more."}"#)
        Self.same(ms[7], #"{"role":"assistant","content":"It is 12:01.","reasoning_content":" "}"#)
        Self.same(ms[9], #"{"role":"assistant","content":"You're welcome."}"#)
    }

    @Test("an empty reasoning_content placeholder on a tool turn becomes a space")
    func chatEmptyPlaceholder() {
        let ms = DeepSeekToolTurnReasoning.chatMessages(Self.json(#"""
        [
        {"role":"user","content":"hi"},
        {"role":"assistant","content":"Hello!","reasoning_content":""},
        {"role":"assistant","content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"f","arguments":"{}"}}],"reasoning_content":""}
        ]
        """#))
        #expect(ms[1]["reasoning_content"] as? String == "")
        #expect(ms[2]["reasoning_content"] as? String == " ")
    }

    // MARK: - Through the providers

    private static let anthropicSSE = AnthropicToolChoiceTests.minimalSSE

    /// A conversation another model ran its tools in, then continued on `model`.
    private static func switchedConversation(from source: Model) -> [Message] {
        [
            .user(UserMessage(text: "what time is it?")),
            .assistant(AssistantMessage(
                content: [.toolCall(ToolCall(id: "call_1", name: "get_time", arguments: [:]))],
                api: source.api, provider: source.provider, model: source.id, stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(toolCallId: "call_1", toolName: "get_time",
                                          content: [.text(TextContent(text: "12:00"))])),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "It is 12:00."))],
                api: source.api, provider: source.provider, model: source.id, stopReason: .stop
            )),
            .user(UserMessage(text: "thanks")),
        ]
    }

    private func anthropicRequest(_ model: Model) async throws -> [[String: Any]] {
        let client = StubSSEClient(body: Self.anthropicSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test")
        _ = await provider.stream(
            model: model, context: Context(messages: Self.switchedConversation(from: model)), options: nil
        ).result()
        let data = try #require(client.lastRequest?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(body["messages"] as? [[String: Any]])
    }

    @Test("the Anthropic provider gives a DeepSeek model's tool turns thinking", arguments: [
        ("deepseek-v4-pro", "https://api.deepseek.com/anthropic"),
        ("deepseek-v4-flash", "https://opencode.ai/zen/go"),
    ])
    func anthropicProvider(id: String, baseURL: String) async throws {
        let model = Self.model(id, api: "anthropic-messages", provider: "deepseek", baseURL: baseURL)
        let ms = try await anthropicRequest(model)
        try #require(ms.count == 5)
        let call = try #require(ms[1]["content"] as? [[String: Any]])
        #expect(call.first?["type"] as? String == "thinking")
        #expect(call.first?["thinking"] as? String == " ")
        #expect(call.last?["type"] as? String == "tool_use")
        let reply = try #require(ms[3]["content"] as? [[String: Any]])
        #expect(reply.first?["type"] as? String == "thinking")
        #expect(reply.first?["thinking"] as? String == " ")
    }

    @Test("the Anthropic provider leaves Claude's and other models' tool turns alone", arguments: [
        ("claude-sonnet-4-6", "https://api.anthropic.com"),
        ("glm-5.2", "https://opencode.ai/zen/go"),
    ])
    func anthropicProviderOthers(id: String, baseURL: String) async throws {
        let model = Self.model(id, api: "anthropic-messages", provider: "x", baseURL: baseURL)
        let ms = try await anthropicRequest(model)
        for m in ms {
            for block in m["content"] as? [[String: Any]] ?? [] {
                #expect(block["type"] as? String != "thinking")
            }
        }
    }

    private func chatRequest(_ model: Model) throws -> [[String: Any]] {
        let body = try OpenAICompletionsProvider.encodeBodyDict(
            model: model, context: Context(messages: Self.switchedConversation(from: model)), options: nil
        )
        return try #require(body["messages"] as? [[String: Any]])
    }

    @Test("the Chat provider gives a DeepSeek model's tool turns reasoning_content on any host", arguments: [
        ("deepseek-v4-pro", "https://api.deepseek.com", true),
        ("deepseek-v4.1-flash", "https://opencode.ai/zen/go/v1", true),
        ("deepseek/deepseek-v4-pro", "https://openrouter.ai/api/v1", false),
    ])
    func chatProvider(id: String, baseURL: String, reasoning: Bool) throws {
        let model = Self.model(id, api: "openai-completions", provider: "x", baseURL: baseURL, reasoning: reasoning)
        let ms = try chatRequest(model)
        let assistants = ms.filter { $0["role"] as? String == "assistant" }
        try #require(assistants.count == 2)
        #expect(assistants[0]["tool_calls"] != nil)
        #expect(assistants[0]["reasoning_content"] as? String == " ")
        #expect(assistants[1]["reasoning_content"] as? String == " ")
    }

    @Test("the Chat provider gives other models none")
    func chatProviderOthers() throws {
        let model = Self.model("glm-5.2", api: "openai-completions", provider: "x", baseURL: "https://opencode.ai/zen/go/v1")
        let ms = try chatRequest(model)
        for m in ms where m["role"] as? String == "assistant" {
            #expect(m["reasoning_content"] as? String != " ")
        }
    }
}
