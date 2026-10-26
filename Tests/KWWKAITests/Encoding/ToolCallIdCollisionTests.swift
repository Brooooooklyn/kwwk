import Foundation
import Testing
@testable import KWWKAI

/// Foreign tool-call ids are rewritten so the target takes them, and two
/// distinct ids never go as one (magpie `safeCallID`, 577a0e43 / 6c099edd,
/// #1304; follow-up to PR #179).
@Suite("Tool-call id normalization is collision-free")
struct ToolCallIdCollisionTests {
    private static let claude: Model = {
        var model = AnthropicProviderTests.sampleModel
        model.id = "claude-sonnet-5-5"
        return model
    }()

    private static let openai = Model(
        id: "gpt-x", name: "GPT X", api: "openai-completions", provider: "openai",
        baseURL: "https://api.openai.com", reasoning: true, input: [.text],
        contextWindow: 128_000, maxTokens: 1024)

    private static func isClaudeSafe(_ id: String) -> Bool {
        id.wholeMatch(of: #/[a-zA-Z0-9_-]+/#) != nil
    }

    /// One foreign assistant turn calling each id, then each call's result.
    private static func history(_ ids: [String]) -> [Message] {
        var messages: [Message] = [.user(UserMessage(text: "go"))]
        messages.append(.assistant(AssistantMessage(
            content: ids.map { .toolCall(ToolCall(id: $0, name: "bash", arguments: [:])) },
            api: "devin-agent", provider: "devin", model: "swe-2", stopReason: .toolUse
        )))
        for id in ids {
            messages.append(.toolResult(ToolResultMessage(
                toolCallId: id, toolName: "bash", content: [.text(TextContent(text: "out of \(id)"))])))
        }
        return messages
    }

    private static func pairs(_ messages: [Message]) -> (calls: [String], results: [String: String]) {
        var calls: [String] = []
        var results: [String: String] = [:]
        for message in messages {
            switch message {
            case .assistant(let a):
                for case .toolCall(let call) in a.content { calls.append(call.id) }
            case .toolResult(let r):
                if case .text(let t)? = r.content.first { results[r.toolCallId] = t.text }
            default: break
            }
        }
        return (calls, results)
    }

    @Test("ids that differ only in characters Claude refuses stay distinct, each paired with its own result")
    func distinctIdsStayDistinct() throws {
        let ids = [
            "Bash:0#ab",
            "Bash.0#ab",
            "Bash_0_ab",
            "Bash 0#ab",
            "functions.read:0",
            "functions:read.0",
            "调用-1",
            "调用-2"
        ]
        let out = TransformMessages.normalizeToolCallIds(Self.history(ids), model: Self.claude)
        let (calls, results) = Self.pairs(out)
        try #require(calls.count == ids.count)
        #expect(Set(calls).count == ids.count, "collapsed: \(calls)")
        for (original, sent) in zip(ids, calls) {
            #expect(Self.isClaudeSafe(sent), "\(sent)")
            #expect(sent.count <= 64)
            #expect(results[sent] == "out of \(original)", "\(original) → \(sent)")
        }
    }

    @Test("a safe id goes as it is; an unsafe one is the mark and its base64url", arguments: [
        ("toolu_01ABCdef", "toolu_01ABCdef"),
        ("call_abc-123", "call_abc-123"),
        ("Bash:0#ab", "kw_QmFzaDowI2Fi"),
        ("Bash.0#ab", "kw_QmFzaC4wI2Fi"),
        ("Bash_0_ab", "Bash_0_ab"),
        ("functions.read:0", "kw_ZnVuY3Rpb25zLnJlYWQ6MA"),
        // a safe id that looks like a rewrite is rewritten itself
        ("kw_QmFzaDowI2Fi", "kw_a3dfUW1GemFEb3dJMkZp"),
        ("call_abc123|fc_0e9d8c7b6a", "call_abc123"),
    ])
    func mapping(id: String, expected: String) {
        #expect(TransformMessages.normalizeId(id, model: Self.claude) == expected)
    }

    @Test("an id that looks like another's rewrite never takes its place")
    func markedIdsDoNotCollide() {
        let unsafe = "Bash:0#ab"
        let lookalike = TransformMessages.normalizeId(unsafe, model: Self.claude)
        #expect(TransformMessages.normalizeId(lookalike, model: Self.claude) != lookalike)
        let out = TransformMessages.normalizeToolCallIds(Self.history([unsafe, lookalike]), model: Self.claude)
        let (calls, results) = Self.pairs(out)
        #expect(Set(calls).count == 2)
        #expect(results[calls[0]] == "out of \(unsafe)")
        #expect(results[calls[1]] == "out of \(lookalike)")
    }

    @Test("long ids that share a prefix stay distinct within OpenAI's 40 and Claude's 64")
    func longIdsHashedNotCut() {
        let base = String(repeating: "x", count: 70)
        let ids = [base + "_a", base + "_b", "dv:" + base + "a", "dv:" + base + "b"]
        for model in [Self.claude, Self.openai] {
            let limit = model.provider == "openai" ? 40 : 64
            let out = TransformMessages.normalizeToolCallIds(Self.history(ids), model: model)
            let (calls, results) = Self.pairs(out)
            #expect(Set(calls).count == ids.count, "\(model.provider): \(calls)")
            for (original, sent) in zip(ids, calls) {
                #expect(Self.isClaudeSafe(sent))
                #expect(sent.count <= limit, "\(sent)")
                #expect(sent.hasPrefix(TransformMessages.hashMark))
                #expect(results[sent] == "out of \(original)")
            }
        }
    }

    @Test("the mapping is stable across requests")
    func stable() {
        let id = "Bash:0#a65b6a5e02194b87bbc796c4428c946d"
        let a = TransformMessages.normalizeId(id, model: Self.claude)
        let b = TransformMessages.normalizeId(id, model: Self.claude)
        #expect(a == b)
        #expect(a.count <= 64)
        #expect(Self.isClaudeSafe(a))
    }

    @Test("ids Claude would refuse reach the Anthropic request distinct and paired")
    func throughAnthropicProvider() async throws {
        let client = StubSSEClient(body: AnthropicToolChoiceTests.minimalSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test")
        let ids = ["Bash:0#ab", "Bash.0#ab", "Bash_0_ab"]
        _ = await provider.stream(
            model: Self.claude,
            context: Context(messages: Self.history(ids)),
            options: nil
        ).result()
        let data = try #require(client.lastRequest?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        var uses: [String] = []
        var results: [String: String] = [:]
        for message in messages {
            for block in message["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String { uses.append(id) }
                if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                    let content = block["content"]
                    let text = (content as? String)
                        ?? ((content as? [[String: Any]])?.first?["text"] as? String) ?? ""
                    results[id] = text
                }
            }
        }
        #expect(uses == ["kw_QmFzaDowI2Fi", "kw_QmFzaC4wI2Fi", "Bash_0_ab"])
        for (original, sent) in zip(ids, uses) {
            #expect(results[sent] == "out of \(original)")
        }
    }

    // MARK: - Repeated ids

    private static func cursorTurn(_ calls: [(String, String)], results: [(String, String, String)]) -> [Message] {
        var messages: [Message] = [.user(UserMessage(text: "go"))]
        messages.append(.assistant(AssistantMessage(
            content: calls.map { .toolCall(ToolCall(id: $0.0, name: $0.1, arguments: [:])) },
            api: "cursor-agent", provider: "cursor", model: "claude-opus-5-5-high", stopReason: .stop
        )))
        for (id, name, text) in results {
            messages.append(.toolResult(ToolResultMessage(
                toolCallId: id, toolName: name, content: [.text(TextContent(text: text))])))
        }
        return messages
    }

    @Test("a Cursor edit's read and write under one id go as two ids, each with its own result")
    func repeatedIdInOneTurn() {
        let messages = Self.cursorTurn(
            [("toolu_1", "read"), ("toolu_1", "write"), ("toolu_2", "bash")],
            results: [("toolu_1", "read", "read out"), ("toolu_1", "write", "write out"), ("toolu_2", "bash", "bash out")]
        )
        let out = TransformMessages.uniquifyToolCallIds(messages, model: Self.claude)
        let (calls, results) = Self.pairs(out)
        #expect(calls == ["toolu_1", "toolu_1_2", "toolu_2"])
        #expect(results == ["toolu_1": "read out", "toolu_1_2": "write out", "toolu_2": "bash out"])
    }

    @Test("results go to the call of the same tool, whatever order they come in")
    func repeatedIdResultsByName() {
        let messages = Self.cursorTurn(
            [("toolu_1", "read"), ("toolu_1", "write")],
            results: [("toolu_1", "write", "write out"), ("toolu_1", "read", "read out")]
        )
        let (_, results) = Self.pairs(TransformMessages.uniquifyToolCallIds(messages, model: Self.claude))
        #expect(results == ["toolu_1": "read out", "toolu_1_2": "write out"])
    }

    @Test("an id reused in a later turn is renamed there, with that turn's result")
    func repeatedIdAcrossTurns() {
        var messages = Self.cursorTurn([("call_0", "bash")], results: [("call_0", "bash", "one")])
        messages += Self.cursorTurn([("call_0", "bash")], results: [("call_0", "bash", "two")])
        let (calls, results) = Self.pairs(TransformMessages.uniquifyToolCallIds(messages, model: Self.claude))
        #expect(calls == ["call_0", "call_0_2"])
        #expect(results == ["call_0": "one", "call_0_2": "two"])
    }

    @Test("a renamed id never takes an id already in the transcript")
    func renameSkipsTakenIds() {
        let messages = Self.cursorTurn(
            [("a", "f"), ("a", "f"), ("a_2", "f")],
            results: [("a", "f", "1"), ("a", "f", "2"), ("a_2", "f", "3")]
        )
        let (calls, results) = Self.pairs(TransformMessages.uniquifyToolCallIds(messages, model: Self.claude))
        #expect(calls == ["a", "a_3", "a_2"])
        #expect(results == ["a": "1", "a_3": "2", "a_2": "3"])
    }

    @Test("an errored turn's ids do not make a later call's id a repeat")
    func erroredTurnClaimsNothing() {
        let messages: [Message] = [
            .assistant(AssistantMessage(
                content: [.toolCall(ToolCall(id: "a", name: "f", arguments: [:]))],
                api: "a", provider: "p", model: "m", stopReason: .error
            )),
        ] + Self.cursorTurn([("a", "f")], results: [("a", "f", "ok")])
        let (calls, _) = Self.pairs(TransformMessages.uniquifyToolCallIds(messages, model: Self.claude))
        #expect(calls == ["a", "a"])
    }

    @Test("a transcript with no repeated id is returned as it is")
    func noRepeatsUnchanged() {
        let messages = Self.history(["x", "y"])
        let out = TransformMessages.uniquifyToolCallIds(messages, model: Self.claude)
        #expect(Self.pairs(out).calls == ["x", "y"])
        #expect(Self.pairs(out).results == Self.pairs(messages).results)
    }

    @Test("a renamed id over the length limit is hashed to fit")
    func longRepeatHashed() {
        let long = String(repeating: "a", count: 40)
        let messages = Self.cursorTurn([(long, "f"), (long, "f")], results: [(long, "f", "1"), (long, "f", "2")])
        let (calls, results) = Self.pairs(TransformMessages.uniquifyToolCallIds(messages, model: Self.openai))
        #expect(calls[0] == long)
        #expect(calls[1].hasPrefix(TransformMessages.hashMark) && calls[1].count == 40)
        #expect(results[calls[1]] == "2")
    }

    @Test("a Cursor turn with a repeated id reaches the Anthropic request with unique tool_use ids")
    func repeatedIdThroughAnthropicProvider() async throws {
        let client = StubSSEClient(body: AnthropicToolChoiceTests.minimalSSE)
        let provider = AnthropicProvider(client: client, defaultAPIKey: "test")
        let messages = Self.cursorTurn(
            [("toolu_1", "read"), ("toolu_1", "write")],
            results: [("toolu_1", "read", "read out"), ("toolu_1", "write", "write out")]
        )
        _ = await provider.stream(model: Self.claude, context: Context(messages: messages), options: nil).result()
        let data = try #require(client.lastRequest?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sent = try #require(body["messages"] as? [[String: Any]])
        var uses: [String] = []
        var resultIds: [String] = []
        for message in sent {
            for block in message["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String { uses.append(id) }
                if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String { resultIds.append(id) }
            }
        }
        #expect(uses == ["toolu_1", "toolu_1_2"])
        #expect(resultIds == ["toolu_1", "toolu_1_2"])
    }
}
