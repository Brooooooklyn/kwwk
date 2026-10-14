import Foundation
import Testing
@testable import KWWKAI

/// A tool call is never kept, or sent, with an empty id, and Gemini's own
/// call ids go back the way it gave them (magpie gateway/chat.go `call_<id>`,
/// codeassist.go `FunctionCall.ID`; follow-up to YEL-495).
@Suite("Tool-call ids: empty ids and Gemini's own")
struct ToolCallIdEmptyAndGeminiTests {
    // MARK: - Chat decoder

    /// llama.cpp / Ollama style: two parallel calls, neither with an id.
    static let chatNoIdsSSE = """
    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"type":"function","function":{"name":"read","arguments":"{\\"path\\":"}}]}}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"a.txt\\"}"}}]}}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"","type":"function","function":{"name":"read","arguments":"{\\"path\\":\\"b.txt\\"}"}}]}}]}

    data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """

    static let chatModel = Model(
        id: "qwen3-coder", name: "Qwen3 Coder", api: "openai-completions", provider: "llama-cpp",
        baseURL: "http://127.0.0.1:8080/v1", reasoning: false, input: [.text],
        contextWindow: 128_000, maxTokens: 1024)

    private static func calls(_ message: AssistantMessage) -> [ToolCall] {
        message.content.compactMap { if case .toolCall(let call) = $0 { return call }; return nil }
    }

    @Test("a Chat stream's calls with no id each get one of their own, the same in the end event and the message")
    func chatMintsIds() async throws {
        let provider = OpenAICompletionsProvider(client: StubSSEClient(body: Self.chatNoIdsSSE), defaultAPIKey: "k")
        let stream = provider.stream(model: Self.chatModel, context: Context(messages: [.user(UserMessage(text: "read both"))]), options: nil)
        var ended: [String] = []
        for await event in stream {
            if case .toolCallEnd(_, let call, _) = event { ended.append(call.id) }
        }
        let message = await stream.result()
        let ids = Self.calls(message).map(\.id)
        try #require(ids.count == 2)
        #expect(ids.allSatisfy { !$0.isEmpty && $0.hasPrefix("call_") })
        #expect(ids.allSatisfy { $0.wholeMatch(of: #/[a-zA-Z0-9_-]+/#) != nil })
        #expect(Set(ids).count == 2)
        #expect(ended == ids)
        #expect(Self.calls(message).map(\.arguments) == [.object(["path": "a.txt"]), .object(["path": "b.txt"])])
    }

    @Test("a Chat stream's own ids are kept")
    func chatKeepsIds() async throws {
        let sse = Self.chatNoIdsSSE
            .replacingOccurrences(of: #"{"index":0,"type":"function""#, with: #"{"index":0,"id":"call_A","type":"function""#)
            .replacingOccurrences(of: #""id":"","#, with: #""id":"call_B","#)
        let provider = OpenAICompletionsProvider(client: StubSSEClient(body: sse), defaultAPIKey: "k")
        let message = await provider.stream(model: Self.chatModel, context: Context(messages: [.user(UserMessage(text: "x"))]), options: nil).result()
        #expect(Self.calls(message).map(\.id) == ["call_A", "call_B"])
    }

    // MARK: - Stored history with empty ids

    private static func emptyIdHistory(provider: String = "llama-cpp", model: String = "qwen3-coder") -> [Message] {
        [
            .user(UserMessage(text: "read both")),
            .assistant(AssistantMessage(content: [
                .toolCall(ToolCall(id: "", name: "read", arguments: ["path": "a.txt"])),
                .toolCall(ToolCall(id: "", name: "grep", arguments: ["q": "x"])),
            ], api: "openai-completions", provider: provider, model: model, stopReason: .toolUse)),
            // answered out of order: paired by tool name
            .toolResult(ToolResultMessage(toolCallId: "", toolName: "grep", content: [.text(TextContent(text: "grep out"))])),
            .toolResult(ToolResultMessage(toolCallId: "", toolName: "read", content: [.text(TextContent(text: "read out"))])),
            .user(UserMessage(text: "now summarize")),
        ]
    }

    @Test("stored calls with empty ids get stable distinct ids, each result the id of its own call")
    func historyFilled() throws {
        let out = TransformMessages.fillEmptyToolCallIds(Self.emptyIdHistory())
        guard case .assistant(let a) = out[1], case .toolResult(let r1) = out[2], case .toolResult(let r2) = out[3]
        else { Issue.record("shape"); return }
        let ids = Self.calls(a).map(\.id)
        #expect(ids == ["call_unnamed_1_0", "call_unnamed_1_1"])
        #expect(r1.toolCallId == ids[1])   // grep
        #expect(r2.toolCallId == ids[0])   // read
        // the same on the next request
        let again = TransformMessages.fillEmptyToolCallIds(Self.emptyIdHistory())
        guard case .assistant(let b) = again[1] else { Issue.record("shape"); return }
        #expect(Self.calls(b).map(\.id) == ids)
    }

    @Test("a history with empty ids reaches Claude with ids it takes, every tool_use paired")
    func historyToAnthropic() async throws {
        let client = StubSSEClient(body: AnthropicToolChoiceTests.minimalSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test")
        _ = await provider.stream(model: AnthropicProviderTests.sampleModel,
                                  context: Context(messages: Self.emptyIdHistory()), options: nil).result()
        let data = try #require(client.lastRequest?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var uses: [String: String] = [:]
        var results: [String: String] = [:]
        for message in body["messages"] as? [[String: Any]] ?? [] {
            for block in message["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "tool_use" { uses[block["id"] as? String ?? ""] = block["name"] as? String }
                if block["type"] as? String == "tool_result" {
                    let content = block["content"]
                    results[block["tool_use_id"] as? String ?? ""] = (content as? String)
                        ?? ((content as? [[String: Any]])?.first?["text"] as? String)
                }
            }
        }
        #expect(uses.count == 2)
        #expect(!uses.keys.contains(""))
        for (id, name) in uses {
            #expect(id.wholeMatch(of: #/[a-zA-Z0-9_-]+/#) != nil)
            #expect(results[id] == "\(name) out")
        }
    }

    // MARK: - Gemini

    static let geminiIdSSE = """
    data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"id":"fc_9f1c2e","name":"calc","args":{"a":1}}},{"functionCall":{"name":"calc","args":{"a":2}}}]},"finishReason":"STOP","index":0}]}

    """

    @Test("Gemini's functionCall.id is the call's id; a call without one gets one made up")
    func geminiReadsId() async {
        let provider = GoogleGeminiProvider(client: StubSSEClient(body: Self.geminiIdSSE), defaultAPIKey: "k", wire: .generateContent)
        let message = await provider.stream(model: GoogleGeminiTests.model,
                                            context: Context(messages: [.user(UserMessage(text: "calc"))]), options: nil).result()
        let ids = Self.calls(message).map(\.id)
        #expect(ids.count == 2)
        #expect(ids.first == "fc_9f1c2e")
        #expect(ids.last?.hasPrefix(GoogleGeminiProvider.mintedIdPrefix) == true)
    }

    private static func geminiTurn(_ model: Model, ids: [String], api: String? = nil, provider: String? = nil, from: String? = nil) -> [Message] {
        var messages: [Message] = [.user(UserMessage(text: "calc"))]
        messages.append(.assistant(AssistantMessage(
            content: ids.map { .toolCall(ToolCall(id: $0, name: "calc", arguments: ["a": 1])) },
            api: api ?? model.api, provider: provider ?? model.provider, model: from ?? model.id, stopReason: .toolUse)))
        for id in ids {
            messages.append(.toolResult(ToolResultMessage(toolCallId: id, toolName: "calc", content: [.text(TextContent(text: "1"))])))
        }
        return messages
    }

    private static func wire(_ body: [String: Any]) -> (calls: [Any?], responses: [Any?]) {
        var calls: [Any?] = [], responses: [Any?] = []
        for content in body["contents"] as? [[String: Any]] ?? [] {
            for part in content["parts"] as? [[String: Any]] ?? [] {
                if let call = part["functionCall"] as? [String: Any] { calls.append(call["id"]) }
                if let response = part["functionResponse"] as? [String: Any] { responses.append(response["id"]) }
            }
        }
        return (calls, responses)
    }

    @Test("Gemini's own call id goes back on the functionCall and its functionResponse alike; a made-up one on neither")
    func geminiSendsOwnId() async throws {
        let model = GoogleGeminiTests.model
        let minted = GoogleGeminiProvider.mintedIdPrefix + "1-1760000000000"
        let body = try await GoogleGeminiTests.encodedBody(
            model: model, context: Context(messages: Self.geminiTurn(model, ids: ["fc_9f1c2e", minted])), options: nil)
        let (calls, responses) = Self.wire(body)
        #expect(calls.count == 2 && responses.count == 2)
        #expect(calls[0] as? String == "fc_9f1c2e")
        #expect(responses[0] as? String == "fc_9f1c2e")
        #expect(calls[1] == nil)
        #expect(responses[1] == nil)
    }

    @Test("another model's call ids are not sent to Gemini")
    func geminiForeignIds() async throws {
        let model = GoogleGeminiTests.model
        let body = try await GoogleGeminiTests.encodedBody(
            model: model,
            context: Context(messages: Self.geminiTurn(model, ids: ["toolu_01A"], api: "anthropic-messages", provider: "anthropic", from: "claude-x")),
            options: nil)
        let (calls, responses) = Self.wire(body)
        #expect(calls.count == 1 && calls[0] == nil)
        #expect(responses.count == 1 && responses[0] == nil)
    }

    @Test("a model that requires ids gets the call's id on the functionCall too, not only on its response", arguments: [
        "claude-sonnet-4-6", "gpt-oss-120b",
    ])
    func geminiRequiredIdsPaired(id: String) async throws {
        var model = GoogleGeminiTests.model
        model.id = id
        let minted = GoogleGeminiProvider.mintedIdPrefix + "0-1760000000000"
        let body = try await GoogleGeminiTests.encodedBody(
            model: model, context: Context(messages: Self.geminiTurn(model, ids: [minted])), options: nil)
        let (calls, responses) = Self.wire(body)
        #expect(calls.count == 1 && responses.count == 1)
        #expect(calls[0] as? String == minted)
        #expect(responses[0] as? String == minted)
    }
}
