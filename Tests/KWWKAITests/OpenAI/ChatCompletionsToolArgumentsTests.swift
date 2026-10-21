import Foundation
import Testing
@testable import KWWKAI

/// Tool-call arguments a stream breaks up, recorded and made up.
///
/// The fixtures under `Fixtures/ChatCompletionsToolCalls` are OpenRouter
/// streams of `z-ai/glm-5.3-flash` asked to call a `bot_send_card`-shaped
/// tool (and, in the two-tool ones, a `bot_set_agent_status`-shaped one),
/// recorded 2026-10-21 with the request pinned to one upstream each, the
/// reasoning chunks after the first two dropped. Z.ai, Novita, Together and
/// AtlasCloud send one call per index, the id and name on its first
/// fragment; InferenceNet's tool-call parser breaks the model's call up into
/// several, one with unterminated JSON.
@Suite("Chat Completions tool-call arguments")
struct ChatCompletionsToolArgumentsTests {
    static let model = OpenAICompletionsTests.model

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ChatCompletionsToolCalls")

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent("glm-5.3-flash-\(name).sse"), encoding: .utf8)
    }

    static func decode(_ sse: String) async -> (message: AssistantMessage, ended: [ToolCall]) {
        let client = StubSSEClient(body: sse)
        let provider = OpenAICompletionsProvider(client: client, defaultAPIKey: "sk-test")
        let s = provider.stream(model: model,
            context: Context(messages: [.user(UserMessage(text: "x"))]), options: nil)
        var ended: [ToolCall] = []
        for await event in s {
            if case .toolCallEnd(_, let call, _) = event { ended.append(call) }
        }
        return (await s.result(), ended)
    }

    static func calls(_ message: AssistantMessage) -> [ToolCall] {
        message.content.compactMap { if case .toolCall(let call) = $0 { return call } else { return nil } }
    }

    static func keys(_ call: ToolCall) -> Set<String> {
        if case .object(let object) = call.arguments { return Set(object.keys) }
        return []
    }

    static let channel: JSONValue = "ch_8f3a9d2e-71b4-4c55-9e0a-2d6f1c3b7a90"

    // MARK: - Recorded streams

    @Test("well-formed upstreams give the whole card call",
          arguments: ["zai-whole-arguments", "novita-token-pieces", "together-empty-fragment", "atlascloud-mixed-pieces"])
    func wellFormedUpstreams(name: String) async throws {
        let (message, ended) = await Self.decode(try Self.fixture(name))
        let calls = Self.calls(message)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.name == "bot_send_card")
        #expect(call.unparsedArguments == nil)
        #expect(Self.keys(call) == ["action", "channel_id", "card"])
        guard case .object(let arguments) = call.arguments,
              case .object(let card)? = arguments["card"] else {
            Issue.record("no card object: \(call.arguments)")
            return
        }
        #expect(arguments["action"] == "send")
        #expect(arguments["channel_id"] == Self.channel)
        #expect(card["title"] == "Build 1.4.2 ready")
        #expect(ended == calls)
        #expect(message.stopReason == .toolUse)
    }

    @Test("Z.ai's two calls in one turn stay two calls")
    func zaiTwoTools() async throws {
        let calls = Self.calls(await Self.decode(try Self.fixture("zai-two-tools")).message)
        #expect(calls.map(\.name) == ["bot_send_card", "bot_set_agent_status"])
        #expect(calls.allSatisfy { $0.unparsedArguments == nil })
        #expect(Self.keys(calls[0]) == ["action", "channel_id", "card"])
        #expect(calls[1].arguments == .object(["emoji": "🚀", "target": "self", "text": "Shipping 1.4.2"]))
    }

    @Test("InferenceNet's broken-up card call is flagged, not run as a partial call")
    func inferenceNetSplitCall() async throws {
        let (message, ended) = await Self.decode(try Self.fixture("inferencenet-split-call"))
        let calls = Self.calls(message)
        #expect(calls.map(\.name) == ["bot_send_card", "bot_send_card"])
        #expect(calls.allSatisfy { $0.unparsedArguments != nil })
        #expect(calls[0].unparsedArguments?.hasPrefix(#"{"channel_id": "ch_8f3a9d2e"#) == true)
        #expect(calls[1].unparsedArguments?.hasPrefix(#"{"action": "send", "card": {"}"#) == true)
        #expect(ended.map(\.unparsedArguments) == calls.map(\.unparsedArguments))
    }

    @Test("InferenceNet's broken-up call beside a whole one: only the broken parts are flagged")
    func inferenceNetSplitTwoTools() async throws {
        let calls = Self.calls(await Self.decode(try Self.fixture("inferencenet-split-two-tools")).message)
        #expect(calls.map(\.name) == ["bot_send_card", "bot_set_agent_status", "bot_send_card"])
        #expect(calls.map { $0.unparsedArguments != nil } == [true, false, true])
        #expect(calls[1].arguments == .object(["emoji": "🚀", "target": "self", "text": "Shipping 1.4.2"]))
    }

    @Test("InferenceNet's runaway repeats are read as the calls they say they are")
    func inferenceNetRunawayCalls() async throws {
        let calls = Self.calls(await Self.decode(try Self.fixture("inferencenet-runaway-calls")).message)
        #expect(calls.count == 4)
        #expect(calls[0].unparsedArguments != nil)
        for call in calls.dropFirst() {
            #expect(call.unparsedArguments == nil)
            #expect(call.arguments == .object(["action": "send", "channel_id": Self.channel]))
        }
    }

    // MARK: - Shapes a relay could send

    private static func chunk(_ toolCall: String) -> String {
        #"data: {"id":"c","choices":[{"index":0,"delta":{"tool_calls":["# + toolCall + "]}}]}\n\n"
    }

    private static func stream(_ toolCalls: [String]) -> String {
        toolCalls.map(chunk).joined()
            + #"data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"# + "\n\n"
            + "data: [DONE]\n\n"
    }

    @Test("the rest of a call under a fresh id and no name continues it")
    func freshIdWithoutName() async throws {
        let calls = Self.calls(await Self.decode(Self.stream([
            #"{"index":0,"id":"call_a","type":"function","function":{"name":"bot_send_card","arguments":"{\"action\":\"send\""}}"#,
            #"{"index":0,"id":"call_b","type":"function","function":{"arguments":",\"channel_id\":\"ch_1\"}"}}"#,
        ])).message)
        #expect(calls.map(\.id) == ["call_a"])
        #expect(calls.first?.arguments == .object(["action": "send", "channel_id": "ch_1"]))
    }

    @Test("the rest of a call at a fresh index and no name continues it")
    func freshIndexWithoutName() async throws {
        let calls = Self.calls(await Self.decode(Self.stream([
            #"{"index":0,"id":"call_a","type":"function","function":{"name":"bot_send_card","arguments":"{\"action\":\"send\"}"}}"#,
            #"{"index":1,"function":{"arguments":"{\"channel_id\":\"ch_1\",\"card\":{\"title\":\"t\"}}"}}"#,
        ])).message)
        #expect(calls.map(\.id) == ["call_a"])
        #expect(calls.first?.arguments == .object([
            "action": "send", "channel_id": "ch_1", "card": .object(["title": "t"]),
        ]))
        #expect(calls.first?.unparsedArguments == nil)
    }

    @Test("a closed first object and the rest of its keys after it are merged")
    func closedObjectThenContinuation() async throws {
        let calls = Self.calls(await Self.decode(Self.stream([
            #"{"index":0,"id":"call_a","type":"function","function":{"name":"bot_send_card","arguments":"{\"action\":\"send\"}"}}"#,
            #"{"index":0,"function":{"arguments":",\"channel_id\":\"ch_1\"}"}}"#,
        ])).message)
        #expect(calls.first?.arguments == .object(["action": "send", "channel_id": "ch_1"]))
    }

    @Test("the whole arguments sent again after a first key are kept whole")
    func wholeArgumentsAfterFirstKey() async throws {
        let calls = Self.calls(await Self.decode(Self.stream([
            #"{"index":0,"id":"call_a","type":"function","function":{"name":"bot_send_card","arguments":"{\"action\":\"send\"}"}}"#,
            #"{"index":0,"function":{"arguments":"{\"action\":\"send\",\"channel_id\":\"ch_1\"}"}}"#,
        ])).message)
        #expect(calls.count == 1)
        #expect(calls.first?.arguments == .object(["action": "send", "channel_id": "ch_1"]))
    }

    @Test("another function named at the same index with no id is the next call")
    func otherNameSameIndex() async throws {
        let calls = Self.calls(await Self.decode(Self.stream([
            #"{"index":0,"type":"function","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}"#,
            #"{"index":0,"type":"function","function":{"name":"time","arguments":"{\"zone\":\"CET\"}"}}"#,
        ])).message)
        #expect(calls.map(\.name) == ["weather", "time"])
        #expect(calls.map(\.arguments) == [.object(["city": "Paris"]), .object(["zone": "CET"])])
    }

    @Test("the same name repeated on every fragment continues the call")
    func repeatedNameContinues() async throws {
        let calls = Self.calls(await Self.decode(Self.stream([
            #"{"index":0,"id":"call_a","type":"function","function":{"name":"calc","arguments":"{\"a\":1"}}"#,
            #"{"index":0,"id":"call_a","type":"function","function":{"name":"calc","arguments":",\"b\":2}"}}"#,
        ])).message)
        #expect(calls.count == 1)
        #expect(calls.first?.arguments == .object(["a": 1, "b": 2]))
    }

    @Test("arguments that never close are flagged with the text received")
    func unterminatedArguments() async throws {
        let calls = Self.calls(await Self.decode(Self.stream([
            #"{"index":0,"id":"call_a","type":"function","function":{"name":"calc","arguments":"{\"a\":\"x"}}"#,
        ])).message)
        #expect(calls.first?.arguments == .object([:]))
        #expect(calls.first?.unparsedArguments == #"{"a":"x"#)
    }
}

@Suite("Streamed tool arguments")
struct StreamedToolArgumentsTests {
    @Test("shapes that read as one object", arguments: [
        (#"{"a":1,"b":2}"#, ["a": 1, "b": 2] as [String: JSONValue]),
        ("", [:]),
        ("  ", [:]),
        (#"{"a":1}{"b":2}"#, ["a": 1, "b": 2]),
        (#"{"a":1}{"a":1,"b":2}"#, ["a": 1, "b": 2]),
        (#"{"a":1},"b":2}"#, ["a": 1, "b": 2]),
        (#"{"a":1}"b":2}"#, ["a": 1, "b": 2]),
        (#"{"a":"}{"}{"b":"x\"}"}"#, ["a": "}{", "b": "x\"}"]),
        (#"{"a":{"n":[1,{"m":2}]}} {"b":3}"#, ["a": .object(["n": .array([1, .object(["m": 2])])]), "b": 3]),
        (#"{"a":1}{"b":2}{"c":3}"#, ["a": 1, "b": 2, "c": 3]),
        (#"{}"#, [:]),
    ])
    func readable(text: String, expected: [String: JSONValue]) {
        #expect(StreamedToolArguments.object(text) == expected)
    }

    @Test("shapes that do not", arguments: [
        #"{"a":"x"#,
        #"{"a":1}garbage"#,
        #"[1,2]"#,
        #""text""#,
        #"{"action": "send", "card": {"}\n, "action": "send"}"#,
    ])
    func unreadable(text: String) {
        #expect(StreamedToolArguments.object(text) == nil)
        let decoded = StreamedToolArguments.decode(text)
        #expect(decoded.arguments == .object([:]))
        #expect(decoded.unparsed == text)
    }
}

@Suite("Responses function-call arguments at output_item.done")
struct ResponsesDoneArgumentsTests {
    @Test("an empty or shorter done keeps every streamed key; a readable done fixes an unreadable stream",
          arguments: [
              (#"{"a":1,"b":2}"#, "", #"{"a":1,"b":2}"#),
              (#"{"a":1,"b":2}"#, nil, #"{"a":1,"b":2}"#),
              (#"{"a":1,"b":2}"#, #"{"a":1}"#, #"{"a":1,"b":2}"#),
              (#"{"a":1,"b":2}"#, #"{"a":"#, #"{"a":1,"b":2}"#),
              (#"{"a":"#, #"{"a":1,"b":2}"#, #"{"a":1,"b":2}"#),
              ("", #"{"a":1}"#, #"{"a":1}"#),
          ] as [(String, String?, String)])
    func settled(streamed: String, done: String?, expected: String) {
        let settled = OpenAIResponsesState.settledArguments(streamed: streamed, done: done)
        #expect(StreamedToolArguments.object(settled) == StreamedToolArguments.object(expected))
    }

    @Test("a done item with empty arguments leaves the streamed ones")
    func emptyDoneThroughProvider() async throws {
        let sse = """
        data: {"type":"response.created","response":{"id":"r","status":"in_progress"}}

        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"bot_send_card","arguments":""}}

        data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\"action\\":\\"send\\""}

        data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":",\\"channel_id\\":\\"ch_1\\"}"}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"","arguments":""}}

        data: {"type":"response.completed","response":{"id":"r","status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}

        """
        let client = StubSSEClient(body: sse)
        let provider = OpenAIResponsesProvider(client: client, webSocketClient: nil, defaultAPIKey: "k")
        let s = provider.stream(model: OpenAIResponsesTests.model,
            context: Context(messages: [.user(UserMessage(text: "go"))]), options: nil)
        var ended: [ToolCall] = []
        for await event in s {
            if case .toolCallEnd(_, let call, _) = event { ended.append(call) }
        }
        let expected: JSONValue = .object(["action": "send", "channel_id": "ch_1"])
        #expect(ended.map(\.arguments) == [expected])
        #expect(ended.map(\.name) == ["bot_send_card"])
        let result = await s.result()
        let calls = result.content.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
        #expect(calls.map(\.arguments) == [expected])
    }
}
