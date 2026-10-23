import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The streams and refusals below are the ones magpie's tests hold for
// WorkBuddy (`internal/gateway/workbuddy_blocks_test.go`, `chattidy_test.go`,
// `workbuddy_refused_test.go`, `prompt_refused_test.go`), verified there
// against copilot.tencent.com.

private func sse(_ lines: String...) -> String {
    lines.map { $0 + "\n\n" }.joined()
}

private func chunk(_ delta: String, finish: String = #""""#) -> String {
    #"data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish)}]}"#
}

/// A WorkBuddy reply as it streams: every delta, text too, carries
/// `"tool_calls": []` and, once the thinking is over, an empty
/// `reasoning_content`; every chunk that hasn't finished says
/// `"finish_reason": ""`.
private let textStream = sse(
    chunk(#"{"role":"assistant","content":"","reasoning_content":"Look first.","tool_calls":[]}"#),
    chunk(#"{"content":"我来","reasoning_content":"","tool_calls":[]}"#),
    chunk(#"{"content":"看","reasoning_content":"","tool_calls":[]}"#),
    chunk(#"{"content":"一下","reasoning_content":"","tool_calls":[]}"#),
    chunk(#"{"content":"。","reasoning_content":"","tool_calls":[]}"#),
    chunk(#"{"content":"","reasoning_content":"","tool_calls":[]}"#, finish: #""stop""#),
    "data: [DONE]"
)

/// A tool call as CodeBuddy CN streams it: every argument fragment after the
/// first repeats `"function": {"name": ""}`. (magpie's fixture splits
/// `{"pattern"}`; the arguments here are a whole object.)
private func toolStream(name: String) -> String {
    sse(
        chunk(#"{"content":"","reasoning_content":"The user","tool_calls":[]}"#),
        chunk(#"{"content":"","reasoning_content":"","tool_calls":[]}"#),
        chunk(#"{"content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"\#(name)","arguments":""},"index":0}]}"#),
        chunk(#"{"content":"","tool_calls":[{"function":{"name":"","arguments":"{\"pat"},"index":0}]}"#),
        chunk(#"{"content":"","tool_calls":[{"function":{"name":"","arguments":"tern\":\"TODO\"}"},"index":0}]}"#, finish: #""tool_calls""#),
        "data: [DONE]"
    )
}

private let auth = ResolvedProviderAuth(
    token: "own-access", scheme: .bearer,
    headers: ["X-User-Id": "u1", "X-Domain": "www.codebuddy.cn"]
)

private func run(
    _ site: WorkBuddySite = .china,
    modelId: String = "hy3",
    client: StubSSEClient,
    context: Context,
    options: StreamOptions = StreamOptions(resolvedAuth: auth)
) async -> (events: [AssistantMessageEvent], result: AssistantMessage) {
    let stream = WorkBuddyProvider(site: site, client: client)
        .stream(model: WorkBuddyModels.model(site: site, id: modelId), context: context, options: options)
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    return (events, await stream.result())
}

private func body(_ client: StubSSEClient) throws -> [String: Any] {
    let data = try #require(client.lastRequest?.body)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let hello = Context(systemPrompt: "You are kwwk.", messages: [.user(UserMessage(text: "hi"))])

@Suite("WorkBuddy provider")
struct WorkBuddyProviderTests {
    // MARK: - Request

    @Test("A chat goes to /v2/chat/completions with the account's and the client's headers")
    func requestHeaders() async throws {
        let client = StubSSEClient(body: textStream)
        _ = await run(client: client, context: hello, options: StreamOptions(sessionId: "s-1", resolvedAuth: auth))
        let request = try #require(client.lastRequest)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://copilot.tencent.com/v2/chat/completions")

        var headers = request.headers
        // The chat's ids: 32 hex digits each, the message's and the
        // request's the same one, the conversation's another.
        let ids = ["X-Conversation-ID", "X-Conversation-Request-ID", "X-Conversation-Message-ID", "X-Request-ID"]
            .map { headers.removeValue(forKey: $0) ?? "" }
        #expect(ids.allSatisfy { $0.count == 32 && $0.allSatisfy(\.isHexDigit) })
        #expect(ids[2] == ids[3])
        #expect(Set(ids).count == 3)
        #expect(headers == [
            "content-type": "application/json",
            "accept": "text/event-stream",
            "Authorization": "Bearer own-access",
            "X-User-Id": "u1",
            "X-Domain": "www.codebuddy.cn",
            "X-Product": "SaaS",
            "X-IDE-Type": "WorkBuddy",
            "User-Agent": "WorkBuddy/5.5.6",
            "X-Requested-With": "XMLHttpRequest",
            "X-Agent-Intent": "craft",
            "X-Agent-Purpose": "conversation",
            "X-IDE-Name": "WorkBuddy",
            "X-IDE-Version": "5.5.6",
        ])
    }

    @Test("WorkBuddy AI is asked at its own endpoint, with the agent's type too")
    func internationalBuild() async throws {
        let client = StubSSEClient(body: textStream)
        _ = await run(.international, modelId: "default-model", client: client, context: hello)
        let request = try #require(client.lastRequest)
        #expect(request.url.absoluteString == "https://www.workbuddy.ai/v2/chat/completions")
        #expect(request.headers["X-Agent-Type"] == "main")
        #expect(request.headers["X-IDE-Type"] == "WorkBuddy")
        #expect(try body(client)["model"] as? String == "default-model")
    }

    @Test("The body is a streamed chat: the system prompt under system, the level as reasoning_effort, none of OpenAI's own fields")
    func requestBody() async throws {
        let client = StubSSEClient(body: textStream)
        let tool = Tool(name: "grep", description: "Search", parameters: .object([
            "type": .string("object"), "properties": .object(["pattern": .object(["type": .string("string")])]),
        ]))
        _ = await run(
            client: client,
            context: Context(systemPrompt: "You are kwwk.", messages: [.user(UserMessage(text: "hi"))], tools: [tool]),
            options: StreamOptions(
                maxTokens: 1024,
                cacheRetention: .long,
                sessionId: "s-1",
                resolvedAuth: auth,
                reasoning: .medium
            )
        )
        let expected: [String: Any] = [
            "model": "hy3",
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": 1024,
            // hy3 takes low and high: medium is asked as high.
            "reasoning_effort": "high",
            "messages": [
                ["role": "system", "content": "You are kwwk."],
                ["role": "user", "content": "hi"],
            ],
            "tools": [[
                "type": "function",
                "function": [
                    "name": "grep", "description": "Search",
                    "parameters": ["type": "object", "properties": ["pattern": ["type": "string"]]],
                ],
            ]],
        ]
        #expect(try body(client) as NSDictionary == expected as NSDictionary)
    }

    @Test("A chat with no system prompt is sent with one first; a model with no levels is asked for none")
    func defaultSystemPrompt() async throws {
        let client = StubSSEClient(body: textStream)
        _ = await run(
            modelId: "auto", client: client,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(resolvedAuth: auth, reasoning: .high)
        )
        let sent = try body(client)
        #expect(sent["messages"] as? NSArray == [
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": "hi"],
        ] as NSArray)
        #expect(sent["reasoning_effort"] == nil)
        #expect(sent["max_tokens"] == nil)
        #expect(sent["max_completion_tokens"] == nil)
    }

    // MARK: - Stream

    @Test("A reply is its thinking and one text block, whatever empty fields ride on each delta")
    func textReply() async throws {
        let (events, result) = await run(client: StubSSEClient(body: textStream), context: hello)
        // One text block: a client that took each empty field for a block's
        // end read the reply a word to a line.
        let types = events.map(\.type)
        #expect(types.filter { $0 == "thinking_start" }.count == 1)
        #expect(types.filter { $0 == "text_start" }.count == 1)
        #expect(types.filter { $0 == "text_delta" }.count == 4)
        #expect(types.last == "done")
        #expect(result.content == [
            .thinking(ThinkingContent(thinking: "Look first.", thinkingSignature: "reasoning_content")),
            .text(TextContent(text: "我来看一下。")),
        ])
        #expect(result.stopReason == .stop)
        #expect(result.provider == "workbuddy")
        #expect(result.failure == nil)
    }

    @Test("A tool call keeps its name through the empty ones repeated on its argument fragments")
    func toolCall() async throws {
        let (events, result) = await run(client: StubSSEClient(body: toolStream(name: "grep")), context: hello)
        #expect(result.stopReason == .toolUse)
        #expect(result.content == [
            .thinking(ThinkingContent(thinking: "The user", thinkingSignature: "reasoning_content")),
            .toolCall(ToolCall(id: "call_1", name: "grep", arguments: .object(["pattern": .string("TODO")]))),
        ])
        #expect(events.filter { $0.type == "toolcall_start" }.count == 1)
    }

    @Test("Usage comes on the last chunk")
    func usage() async throws {
        let stream = sse(
            #"data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"The user said hi."}}]}"#,
            #"data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hi","reasoning_content":""}}]}"#,
            #"data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"!","reasoning_content":""}}]}"#,
            #"data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"reasoning_content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#,
            "data: [DONE]"
        )
        let (_, result) = await run(client: StubSSEClient(body: stream), context: hello)
        #expect(result.content.last == .text(TextContent(text: "Hi!")))
        #expect(result.usage.input == 3)
        #expect(result.usage.output == 2)
        #expect(result.usage.totalTokens == 5)
        #expect(result.responseId == "c1")
    }

    @Test("A stream cut before it finished is an error that keeps what was said")
    func truncated() async throws {
        let stream = sse(
            chunk(#"{"role":"assistant","content":"","reasoning_content":"Look first.","tool_calls":[]}"#),
            chunk(#"{"content":"我来","reasoning_content":"","tool_calls":[]}"#)
        )
        let (events, result) = await run(client: StubSSEClient(body: stream), context: hello)
        #expect(events.last?.type == "error")
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "Stream ended without finish_reason")
        #expect(result.content.last == .text(TextContent(text: "我来")))
        #expect(result.failure?.category == .transport)
    }

    // MARK: - Tools

    @Test("A tool WorkBuddy would refuse the name of is sent under a safe one, and the model's calls come back under its own")
    func toolNames() async throws {
        let client = StubSSEClient(body: toolStream(name: "fs_read"))
        let earlier = AssistantMessage(
            content: [.toolCall(ToolCall(id: "call_0", name: "fs.read", arguments: .object([:])))],
            api: "openai-completions", provider: "workbuddy", model: "hy3", stopReason: .toolUse
        )
        let context = Context(
            systemPrompt: "You are kwwk.",
            messages: [
                .user(UserMessage(text: "read it")),
                .assistant(earlier),
                .toolResult(ToolResultMessage(
                    toolCallId: "call_0",
                    toolName: "fs.read",
                    content: [.text(TextContent(text: "ok"))]
                )),
            ],
            tools: [
                Tool(name: "fs.read", description: "Read", parameters: .object(["type": .string("object")])),
                Tool(name: "fs_read", description: "Taken", parameters: .object(["type": .string("object")])),
                Tool(name: "读取", description: "CJK", parameters: .object(["type": .string("object")])),
            ]
        )
        let renamed = StubSSEClient(body: toolStream(name: "fs_read_2"))
        let (events, result) = await run(
            client: renamed, context: context,
            options: StreamOptions(resolvedAuth: auth, toolChoice: .tool(name: "fs.read"))
        )
        // The choice follows the tool to the name it was sent under, as the
        // string WorkBuddy takes (plugin request.test.mjs, "flattens
        // tool_choice after tool names are made safe").
        #expect(try body(renamed)["tool_choice"] as? String == "fs_read_2")
        // The call the model made of the renamed tool is the caller's.
        guard case .toolCall(let call)? = result.content.last else {
            Issue.record("no tool call in \(result.content)")
            return
        }
        #expect(call.name == "fs.read")
        for event in events {
            guard case .toolCallEnd(_, let ended, let partial) = event else { continue }
            #expect(ended.name == "fs.read")
            guard case .toolCall(let streamed)? = partial.content.last else { continue }
            #expect(streamed.name == "fs.read")
        }

        // A tool whose own name is the safe one keeps it: its calls aren't
        // named back.
        let (_, own) = await run(client: client, context: context)
        guard case .toolCall(let ownCall)? = own.content.last else {
            Issue.record("no tool call in \(own.content)")
            return
        }
        #expect(ownCall.name == "fs_read")

        let sent = try body(client)
        let names = (sent["tools"] as? [[String: Any]] ?? [])
            .compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names == ["fs_read_2", "fs_read", "__"])
        // The chat's history names the call as its tool now is.
        let messages = sent["messages"] as? [[String: Any]] ?? []
        let calls = messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.flatMap { $0 }
        #expect(calls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } == ["fs_read_2"])
    }

    @Test("The tool choice goes as WorkBuddy's string; a chat that may call no tool goes without its tools")
    func toolChoice() async throws {
        let context = Context(
            systemPrompt: "You are kwwk.",
            messages: [.user(UserMessage(text: "run it"))],
            tools: [Tool(name: "read", description: "Read", parameters: .object(["type": .string("object")]))]
        )
        func sent(_ choice: ToolChoice?) async throws -> [String: Any] {
            let client = StubSSEClient(body: textStream)
            _ = await run(
                client: client,
                context: context,
                options: StreamOptions(resolvedAuth: auth, toolChoice: choice)
            )
            return try body(client)
        }
        #expect(try await sent(.tool(name: "read"))["tool_choice"] as? String == "read")
        #expect(try await sent(.auto)["tool_choice"] as? String == "auto")
        #expect(try await sent(.required)["tool_choice"] as? String == "required")
        let unasked = try await sent(nil)
        #expect(unasked["tool_choice"] == nil)
        #expect((unasked["tools"] as? [[String: Any]])?.count == 1)
        // plugin request.test.mjs, "removes tools when tool_choice is none".
        let none = try await sent(ToolChoice.none)
        #expect(none["tool_choice"] == nil)
        #expect(none["tools"] == nil)
        // What only says how tools are called goes with them, and stays
        // with the tools that are sent.
        func serial(_ choice: ToolChoice) async throws -> [String: Any] {
            let client = StubSSEClient(body: textStream)
            _ = await run(
                client: client, context: context,
                options: StreamOptions(resolvedAuth: auth, toolChoice: choice, parallelToolCalls: false)
            )
            return try body(client)
        }
        #expect(try await serial(ToolChoice.none)["parallel_tool_calls"] == nil)
        #expect(try await serial(.auto)["parallel_tool_calls"] as? Bool == false)
    }

    @Test("A tool's parameters are given a shape every model takes")
    func toolSchemas() throws {
        // No type, or not an object at all: an object.
        #expect(WorkBuddyWire.fitParameters(.object([:])) == .object(["type": .string("object"), "properties": .object([:])]))
        #expect(WorkBuddyWire.fitParameters(.null) == .object(["type": .string("object"), "properties": .object([:])]))
        // A union at the root is folded.
        let union: JSONValue = .object(["anyOf": .array([
            .object([
                "type": .string("object"),
                "properties": .object(["a": .object(["type": .string("string")])]),
                "required": .array([.string("a")])
            ]),
            .object(["type": .string("object"), "properties": .object(["b": .object(["type": .string("string")])])]),
        ])])
        #expect(WorkBuddyWire.fitParameters(union) == .object([
            "type": .string("object"),
            "properties": .object(["a": .object(["type": .string("string")]), "b": .object(["type": .string("string")])]),
        ]))
        // A pattern's \0 is \u0000; a backslash before a 0, and an octal
        // escape, are left. A tuple's items become one schema.
        let deep: JSONValue = .object(["type": .string("object"), "properties": .object([
            "nul": .object(["type": .string("string"), "pattern": .string(#"^[^\0]+$"#)]),
            "kept": .object(["type": .string("string"), "pattern": .string(#"\\0|\01"#)]),
            "pair": .object(["type": .string("array"), "additionalItems": .bool(false), "items": .array([
                .object(["type": .string("string")]), .object(["type": .string("number")]),
            ])]),
            "one": .object(["type": .string("array"), "items": .array([.object(["type": .string("string")])])]),
            "none": .object(["type": .string("array"), "items": .array([])]),
        ])])
        #expect(WorkBuddyWire.fitParameters(deep) == .object(["type": .string("object"), "properties": .object([
            "nul": .object(["type": .string("string"), "pattern": .string(#"^[^\u0000]+$"#)]),
            "kept": .object(["type": .string("string"), "pattern": .string(#"\\0|\01"#)]),
            "pair": .object(["type": .string("array"), "items": .object(["anyOf": .array([
                .object(["type": .string("string")]), .object(["type": .string("number")]),
            ])])]),
            "one": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "none": .object(["type": .string("array"), "items": .object([:])]),
        ])]))
    }

    // MARK: - Refusals

    private func refusal(status: Int, _ body: String) async -> ProviderFailure? {
        await run(client: StubSSEClient(body: body, statusCode: status), context: hello).result.failure
    }

    @Test("The channel refusal is about the chat's words, not the account, and says what to do", arguments: [11101, 11128])
    func unapprovedChannel(code: Int) async throws {
        let (events, result) = await run(
            .international, modelId: "default-model",
            client: StubSSEClient(
                body: #"{"code":\#(code),"msg":"Illegal API invocation from an unapproved channel"}"#, statusCode: 400
            ),
            context: hello
        )
        let failure = try #require(result.failure)
        #expect(failure.message == "Illegal API invocation from an unapproved channel — \(WorkBuddyWire.refusedHint)")
        #expect(result.errorMessage == failure.message)
        #expect(failure.httpStatus == 400)
        #expect(failure.providerCode == String(code))
        // A problem with the request: never a sign-in to renew, a quota to
        // wait out or a failure to retry.
        #expect(failure.category == .invalidRequest)
        #expect(!failure.isRetryable)
        guard case .error(_, let message)? = events.last else {
            Issue.record("the stream didn't end in an error")
            return
        }
        #expect(message.failure == failure)
    }

    @Test("Another refusal is said in WorkBuddy's own words, with no hint")
    func otherRefusals() async throws {
        let first = try #require(await refusal(status: 400, #"{"code":1,"msg":"first message is not system prompt"}"#))
        #expect(first.message == "first message is not system prompt")
        #expect(first.providerCode == "1")
        #expect(first.category == .invalidRequest)

        // A User-Agent the gateway doesn't know, and tools a model can't take.
        #expect(await refusal(status: 400, #"{"code":10085,"msg":"请求不合法"}"#)?.message == "请求不合法")
        let tools = try #require(await refusal(status: 400, #"{"code":11133,"msg":"Invalid request parameters"}"#))
        #expect(tools.message == "Invalid request parameters")
        #expect(tools.providerCode == "11133")

        // A lapsed token is the account's.
        let lapsed = try #require(await refusal(status: 401, #"{"code":1,"msg":"token expired"}"#))
        #expect(lapsed.message == "token expired")
        #expect(lapsed.category == .authentication)

        // An error of OpenAI's shape, and one that isn't JSON, are as they came.
        #expect(await refusal(status: 429, #"{"error":{"message":"slow down","type":"rate_limit_error"}}"#)?.category == .rateLimit)
        #expect(await refusal(status: 502, "Bad Gateway")?.message == "Bad Gateway")
    }

    @Test("Credits used up say so and read as quota", arguments: [
        #"{"code":14018,"msg":"credits used up","data":null}"#,
        #"{"code":"14018","msg":"额度已用尽"}"#,
        #"{"error":{"message":"Credits exhausted for this cycle","code":14018}}"#,
        // The answer the plugin's refused.test.mjs holds, and one cut short.
        #"{"error":{"data":{"code":14018,"msg":"Credits exhausted. Please visit the link below to purchase add-on packs and get more credits: https://www.codebuddy.ai/profile/usage ","requestId":"test-req"}}}"#,
        #"{"error":{"data":{"code":14018,"msg":"Credits exh"#,
    ])
    func creditsExhausted(body: String) async throws {
        let failure = try #require(await refusal(status: 429, body))
        #expect(failure.message.hasSuffix(" — \(WorkBuddyWire.exhaustedHint)"))
        #expect(failure.providerCode == "insufficient_quota")
        #expect(failure.category == .quota)
        #expect(!failure.isRetryable)
    }

    @Test("Credits used up read as quota whatever status the refusal comes under", arguments: [400, 401, 403, 429])
    func creditsExhaustedStatus(status: Int) async throws {
        let failure = try #require(await refusal(status: status, #"{"code":14018,"msg":"额度已用尽"}"#))
        #expect(failure.message == "额度已用尽 — \(WorkBuddyWire.exhaustedHint)")
        #expect(failure.category == .quota)
        #expect(!failure.isRetryable)
    }

    @Test("A code that only begins with 14018 is another error")
    func otherCode() async throws {
        let failure = try #require(await refusal(status: 429, #"{"code":140185,"msg":"busy"}"#))
        #expect(failure.message == "busy")
        #expect(failure.providerCode == "140185")
        #expect(failure.category == .rateLimit)
    }
}

@Suite("WorkBuddy wire")
struct WorkBuddyWireTests {
    private func mended(_ json: String) throws -> [String: Any] {
        var root = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        WorkBuddyWire.mendMessages(&root)
        return root
    }

    private func roles(_ root: [String: Any]) -> [String] {
        (root["messages"] as? [[String: Any]] ?? []).compactMap { $0["role"] as? String }
    }

    // magpie's TestWorkBuddyBody.
    @Test("A chat that doesn't open with a system message is given one, the rest kept as it was")
    func systemFirst() throws {
        let none = try mended(
            #"{"model":"deepseek-v4.1-flash","stream":true,"max_tokens":1024,"messages":[{"role":"user","content":"<b>hi</b> & 1.50"}]}"#
        )
        #expect(roles(none) == ["system", "user"])
        #expect(none["model"] as? String == "deepseek-v4.1-flash")
        #expect(none["stream"] as? Bool == true)
        #expect(none["max_tokens"] as? Int == 1024)
        let messages = try #require(none["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "You are a helpful assistant.")
        #expect(messages[1]["content"] as? String == "<b>hi</b> & 1.50")

        // A system prompt later on still wants one first.
        let late = try mended(#"{"messages":[{"role":"user","content":"a"},{"role":"system","content":"s"}]}"#)
        #expect(roles(late) == ["system", "user", "system"])

        // Already first, or not a chat: as it was.
        for same in [
            #"{"messages":[{"role":"system","content":"own"},{"role":"user","content":"a"}]}"#,
            #"{"messages":[]}"#,
            #"{"prompt":"a cat"}"#,
        ] {
            let before = try #require(JSONSerialization.jsonObject(with: Data(same.utf8)) as? NSDictionary)
            #expect(try mended(same) as NSDictionary == before)
        }
    }

    @Test("An object tool choice of any spelling becomes a string, or goes")
    func mendToolChoice() {
        func mended(_ choice: Any) -> [String: Any] {
            var root: [String: Any] = ["tools": [["type": "function"]], "tool_choice": choice]
            WorkBuddyWire.mendToolChoice(&root)
            return root
        }
        #expect(mended(["type": "function", "function": ["name": " fs_read "]])["tool_choice"] as? String == "fs_read")
        // A named choice with no name leaves the model to choose.
        #expect(mended(["type": "function"])["tool_choice"] as? String == "auto")
        #expect(mended(["type": "Required"])["tool_choice"] as? String == "required")
        #expect(mended(["type": "auto"])["tool_choice"] as? String == "auto")
        for none: Any in ["none", ["type": "none"]] {
            #expect(mended(none)["tool_choice"] == nil)
            #expect(mended(none)["tools"] == nil)
        }
        // What isn't a choice WorkBuddy knows goes; the tools stay.
        for unknown: Any in [["type": "allowed_tools"], 3] {
            #expect(mended(unknown)["tool_choice"] == nil)
            #expect(mended(unknown)["tools"] != nil)
        }
        #expect(mended("required")["tool_choice"] as? String == "required")
    }

    @Test("The words WorkBuddy refuses a chat for are reworded, in every message and whatever their case")
    func flaggedWords() throws {
        #expect(WorkBuddyWire.unflagged("x-anthropic-billing-header: cc_version=2.1.280; cch=0;\nYou are Claude Code, Anthropic's official CLI for Claude.")
            == "You are Claude Code, Anthropic's CLI for Claude.")
        #expect(WorkBuddyWire.unflagged("you are claude code, anthropic’s OFFICIAL cli for claude")
            == "You are Claude Code, Anthropic's CLI for Claude")
        #expect(WorkBuddyWire.unflagged("Main branch (you will usually use this for PRs): main")
            == "Main branch (usually the base for PRs): main")
        #expect(WorkBuddyWire.unflagged("Codex CLI is an open source project led by OpenAI.")
            == "The Codex CLI is an open source project led by OpenAI.")
        #expect(WorkBuddyWire.unflagged("the Codex CLI is an open source project led by OpenAI.")
            == "the Codex CLI is an open source project led by OpenAI.")
        #expect(WorkBuddyWire.unflagged("You are kwwk. $1 \\0") == "You are kwwk. $1 \\0")

        // A system message that was the billing header alone goes; a user
        // message's text is reworded where it stands, its other parts kept.
        let root = try mended(#"""
        {"messages":[
          {"role":"system","content":"x-anthropic-billing-header: cc_version=2.1.280;"},
          {"role":"system","content":"You are Claude Code, Anthropic's official CLI for Claude."},
          {"role":"user","content":[
            {"type":"text","text":"x-anthropic-billing-header: a\n"},
            {"type":"text","text":"Main branch (you will usually use this for PRs): main"},
            {"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]}]}
        """#)
        #expect(roles(root) == ["system", "user"])
        let messages = try #require(root["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "You are Claude Code, Anthropic's CLI for Claude.")
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts[0]["text"] as? String == "Main branch (usually the base for PRs): main")
        #expect(parts[1]["type"] as? String == "image_url")
    }

    // MARK: - The chat's ids

    private func ids(_ messages: [Message], session: String? = nil) -> [String: String] {
        WorkBuddyWire.conversationHeaders(context: Context(messages: messages), sessionId: session)
    }

    private let call = AssistantMessage(
        content: [.toolCall(ToolCall(id: "call_1", name: "grep", arguments: .object([:])))],
        api: "openai-completions", provider: "workbuddy", model: "hy3", stopReason: .toolUse
    )
    private let result = ToolResultMessage(
        toolCallId: "call_1",
        toolName: "grep",
        content: [.text(TextContent(text: "ok"))]
    )
    private let answer = AssistantMessage(
        content: [.text(TextContent(text: "done"))], api: "openai-completions", provider: "workbuddy", model: "hy3"
    )

    @Test("Every step of one user send carries the same turn id, and the user's next message another")
    func turnIds() {
        let send: [Message] = [.user(UserMessage(text: "find it"))]
        let first = ids(send, session: "s-1")
        // A tool result sent back, the images it came with, and a note the
        // runtime wrote are steps of the same send.
        let step = ids(send + [
            .assistant(call), .toolResult(result),
            .user(UserMessage(content: [.image(ImageContent(data: "AA==", mimeType: "image/png"))])),
            .user(UserMessage(text: "a background task finished", source: .runtime)),
        ], session: "s-1")
        let next = ids(
            send + [.assistant(call), .toolResult(result), .assistant(answer), .user(UserMessage(text: "and now?"))],
            session: "s-1"
        )

        #expect(first["X-Conversation-Request-ID"] == step["X-Conversation-Request-ID"])
        #expect(first["X-Conversation-Request-ID"] != next["X-Conversation-Request-ID"])
        // The conversation is the session's throughout.
        #expect(first["X-Conversation-ID"] == step["X-Conversation-ID"])
        #expect(first["X-Conversation-ID"] == next["X-Conversation-ID"])
        // The message's id and the request's are the same one, new each time.
        #expect(first["X-Request-ID"] == first["X-Conversation-Message-ID"])
        #expect(first["X-Request-ID"] != step["X-Request-ID"])
        #expect(first.values.allSatisfy { $0.count == 32 })
    }

    @Test("A conversation is its session, else its first user message; two conversations' same words are two sends")
    func conversationIds() {
        let send: [Message] = [.user(UserMessage(text: "find it"))]
        let later = send + [.assistant(answer), .user(UserMessage(text: "and now?"))]
        #expect(ids(send)["X-Conversation-ID"] == ids(later)["X-Conversation-ID"])
        #expect(ids(send)["X-Conversation-ID"] != ids([.user(UserMessage(text: "another"))])["X-Conversation-ID"])
        #expect(ids(send, session: "s-1")["X-Conversation-ID"] != ids(send, session: "s-2")["X-Conversation-ID"])
        #expect(ids(send, session: "s-1")["X-Conversation-Request-ID"] != ids(send, session: "s-2")["X-Conversation-Request-ID"])

        // Nothing names the conversation: no id is made up for it, and the
        // turn's is the request's own.
        let nameless = ids([.assistant(answer)])
        #expect(nameless["X-Conversation-ID"] == nil)
        #expect(nameless["X-Conversation-Request-ID"]?.count == 32)
        #expect(nameless["X-Conversation-Request-ID"] != ids([.assistant(answer)])["X-Conversation-Request-ID"])

        // After a compaction the summary is the only user message there is.
        let compacted: [Message] = [
            .user(UserMessage(text: "summary so far", source: .compaction)),
            .assistant(call),
            .toolResult(result)
        ]
        #expect(ids(compacted, session: "s-1")["X-Conversation-Request-ID"] == ids(compacted + [.assistant(call), .toolResult(result)], session: "s-1")["X-Conversation-Request-ID"])
    }
}

@Suite("WorkBuddy models")
struct WorkBuddyModelsTests {
    @Test("The bundled lists are magpie's, each build's its own")
    func bundled() throws {
        let china = ModelsCatalog.byProvider["workbuddy"] ?? [:]
        let international = ModelsCatalog.byProvider["workbuddy-ai"] ?? [:]
        #expect(china.count == 15)
        #expect(international.count == 16)
        #expect(china[WorkBuddyModels.defaultModelId(for: .china)]?.name == "Auto")
        #expect(international[WorkBuddyModels.defaultModelId(for: .international)]?.name == "Default")
        #expect(china["gpt-5.5"] == nil)
        #expect(international["kimi-k3"]?.contextWindow == 1_000_000)

        for (site, rows) in [(WorkBuddySite.china, china), (.international, international)] {
            for row in rows.values {
                // A bundled row is the row a live listing of the same model makes.
                #expect(row.api == "openai-completions")
                #expect(row.provider == site.id)
                #expect(row.baseURL == site.chatBaseURL)
                #expect(row.compat == WorkBuddyModels.compat)
                #expect(row.maxTokens == 0)
            }
        }
    }

    @Test("A model takes the reasoning levels WorkBuddy offers it, and off only where it offers that")
    func levels() throws {
        let hy3 = try #require(ModelsCatalog.model(provider: "workbuddy", id: "hy3"))
        #expect(supportedThinkingLevels(hy3) == [.low, .high])
        #expect(clampThinkingLevel(hy3, .medium) == .high)
        #expect(clampThinkingLevel(hy3, .max) == .high)
        let pro = try #require(ModelsCatalog.model(provider: "workbuddy", id: "deepseek-v4-pro"))
        #expect(supportedThinkingLevels(pro) == [.off, .high, .xhigh])
        #expect(pro.thinkingLevelMap?["off"] == "none")
        let glm = try #require(ModelsCatalog.model(provider: "workbuddy-ai", id: "glm-5.3"))
        #expect(supportedThinkingLevels(glm) == [.low, .high, .max])
        #expect(ModelsCatalog.model(provider: "workbuddy", id: "auto")?.reasoning == false)

        // An id the bundled list doesn't carry is still a usable row.
        let unknown = WorkBuddyModels.model(site: .international, id: "new-model")
        #expect(unknown.provider == "workbuddy-ai")
        #expect(unknown.baseURL == "https://www.workbuddy.ai/v2")
        #expect(unknown.compat == WorkBuddyModels.compat)
    }

    // magpie's TestWorkBuddyFetchModels.
    private static let config = #"""
    {"code":0,"msg":"OK","data":{
      "agents":[{"name":"craft","models":["gpt"]},{"name":"cli","models":["auto","kimi-k2.8-preview","deepseek-v4-pro","bare"]}],
      "models":[{"id":"gpt","name":"GPT"},
       {"id":"auto","name":"Auto","maxInputTokens":256000,"maxOutputTokens":32000,"supportsImages":true,"onlyReasoning":true,"reasoning":{"effort":"high"}},
       {"id":"kimi-k2.8-preview","name":"Kimi-K2.8-Preview","maxInputTokens":1000000,"maxOutputTokens":64000,"supportsImages":false,
        "onlyReasoning":true,"reasoning":{"canDisableThinking":true,"defaultEffort":"high","supportedEfforts":["low","high","max"]}},
       {"id":"deepseek-v4-pro","name":"Deepseek-V4-Pro","onlyReasoning":false,"reasoning":{"canDisableThinking":true,"supportedEfforts":["high","xhigh"]}}]}}
    """#

    private let credentials = OAuthCredentials(
        access: "tok", refresh: "r", expires: .max,
        extras: ["uid": .string("u1"), "domain": .string("www.codebuddy.cn"), "enterpriseId": .string("ent-1")]
    )

    @Test("The account's own list is the product config's CLI agent's, asked as WorkBuddy's CLI asks")
    func fetch() async throws {
        let client = StubSSEClient(body: Self.config)
        let listings = try await WorkBuddyModels.fetch(site: .china, credentials: credentials, client: client)

        let request = try #require(client.lastRequest)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://copilot.tencent.com/v3/config")
        #expect(request.body == nil)
        #expect(request.headers == [
            "Authorization": "Bearer tok",
            "X-User-Id": "u1",
            "X-Domain": "www.codebuddy.cn",
            // An enterprise account is listed the enterprise's models.
            "X-Enterprise-Id": "ent-1",
            "X-Tenant-Id": "ent-1",
            "X-Product": "SaaS",
            "X-IDE-Type": "WorkBuddy",
            // A bare WorkBuddy/<version> gets CodeBuddy IDE's config.
            "User-Agent": "CLI/2.0.0 WorkBuddy/5.5.6",
            "X-Requested-With": "XMLHttpRequest",
            "X-Agent-Intent": "craft",
            "X-Agent-Purpose": "conversation",
            "X-IDE-Name": "WorkBuddy",
            "X-IDE-Version": "5.5.6",
            "Accept": "application/json",
        ])

        let models = listings.map(\.model)
        #expect(models.map(\.id) == ["auto", "kimi-k2.8-preview", "deepseek-v4-pro", "bare"])
        #expect(models.map(\.name) == ["Auto", "Kimi-K2.8-Preview", "Deepseek-V4-Pro", "bare"])
        #expect(models.map(\.contextWindow) == [256_000, 1_000_000, 1_000_000, 200_000])
        #expect(models.map(\.maxTokens) == [32_000, 64_000, 0, 0])
        #expect(models.map(\.input) == [[.text, .image], [.text], [.text], [.text]])
        // The levels offered, and off where the model can think off; a model
        // with none is asked for none.
        #expect(models.map(supportedThinkingLevels) == [[.off], [.low, .high, .max], [.off, .high, .xhigh], [.off]])
        #expect(listings.allSatisfy { $0.creditRate == nil })
        #expect(models.allSatisfy { $0.provider == "workbuddy" && $0.compat == WorkBuddyModels.compat })
    }

    @Test("A config that can't be used says why")
    func fetchFailures() async throws {
        func failure(_ body: String, status: Int = 200) async -> ProviderFailure? {
            do {
                _ = try await WorkBuddyModels.fetch(
                    site: .international,
                    credentials: credentials,
                    client: StubSSEClient(body: body, statusCode: status)
                )
                return nil
            } catch {
                return error as? ProviderFailure
            }
        }
        let lapsed = try #require(await failure(#"{"code":1,"msg":"token expired"}"#, status: 401))
        #expect(lapsed.message == "WorkBuddy AI's config: token expired")
        #expect(lapsed.category == .authentication)
        #expect(await failure("", status: 502)?.message == "WorkBuddy AI's config: HTTP 502")
        #expect(await failure(#"{"code":10085,"msg":"请求不合法"}"#)?.message == "WorkBuddy AI's config: 请求不合法 (10085)")
        // CodeBuddy IDE's config: no cli agent.
        #expect(await failure(#"{"code":0,"data":{"agents":[{"name":"craft","models":["gpt"]}],"models":[{"id":"gpt"}]}}"#)?.message
            == "WorkBuddy AI's config lists no models for its CLI agent")
    }

    // magpie's TestWBFreeCredits and TestWBCreditsRate.
    @Test("Each model carries the credits WorkBuddy's picker shows by it")
    func creditRates() throws {
        let config = try #require(JSONSerialization.jsonObject(with: Data(#"""
        {"agents":[{"name":"cli","models":["deepseek-v4.1-flash","deepseek-v4.1-flash-sg","gpt-5.5","kimi-k3","glm-5.3","hy3","odd","inf"]}],
         "models":[{"id":"deepseek-v4.1-flash","name":"Deepseek-V4.1-Flash","credits":"x0.00"},
          {"id":"deepseek-v4.1-flash-sg","name":"Deepseek-V4.1-Flash","credits":"x0.03"},
          {"id":"gpt-5.5","credits":"X1.00"},
          {"id":"kimi-k3","credits":1.5},
          {"id":"glm-5.3","credits":0},
          {"id":"hy3"},
          {"id":"odd","credits":"lots"},
          {"id":"inf","credits":"x+Inf"}]}
        """#.utf8)) as? [String: Any])
        let listings = WorkBuddyModels.listings(fromConfig: config, site: .international)
        #expect(listings.map(\.creditRate) == [0, 0.03, 1, 1.5, 0, nil, nil, nil])
        // Two models WorkBuddy names alike are told apart.
        #expect(listings.prefix(2).map(\.model.name) == ["Deepseek-V4.1-Flash", "Deepseek-V4.1-Flash (SG)"])
    }

    // The plugin's efforts.test.mjs (plugins#255): WorkBuddy AI's own
    // config of 2026-10-20, cut to the models it names.
    @Test("A model that says only supportsReasoning and a default takes low, high, max and its default")
    func defaultEffortOnly() throws {
        let config = try #require(JSONSerialization.jsonObject(with: Data(#"""
        {"agents":[{"name":"cli","models":["default-model","fast-model","primary-model","deepseek-v4.1-flash-sg","hy3","gpt-5.6-sol","glm-5.2","kimi-k3"]}],
         "models":[{"id":"default-model","name":"Default"},
          {"id":"fast-model","supportsReasoning":true,"onlyReasoning":true,"reasoning":{"effort":"medium","summary":"auto"}},
          {"id":"primary-model","supportsReasoning":true,"onlyReasoning":true,"reasoning":{"effort":"high","summary":"auto"}},
          {"id":"deepseek-v4.1-flash-sg","supportsReasoning":true,"onlyReasoning":true,"reasoning":{"effort":"high","summary":"auto"}},
          {"id":"hy3","supportsReasoning":true,"onlyReasoning":true,"reasoning":{"canDisableThinking":false,"defaultEffort":"high","supportedEfforts":["low","high"]}},
          {"id":"gpt-5.6-sol","supportsReasoning":true,"onlyReasoning":false,"reasoning":{"canDisableThinking":true,"defaultEffort":"high","supportedEfforts":["low","medium","high","xhigh","max"]}},
          {"id":"glm-5.2","supportsReasoning":true,"onlyReasoning":false,"reasoning":{"canDisableThinking":true,"defaultEffort":"high","supportedEfforts":["high","xhigh"]}},
          {"id":"kimi-k3","supportsReasoning":true,"onlyReasoning":true,"reasoning":{"effort":"medium","summary":"auto"}}]}
        """#.utf8)) as? [String: Any])
        let models = Dictionary(
            uniqueKeysWithValues: WorkBuddyModels.listings(fromConfig: config, site: .international).map { ($0.model.id, $0.model) }
        )
        func levels(_ id: String) throws -> [ModelThinkingLevel] { supportedThinkingLevels(try #require(models[id])) }
        #expect(try levels("fast-model") == [.low, .medium, .high, .max])
        #expect(try levels("kimi-k3") == [.low, .medium, .high, .max])
        #expect(try levels("primary-model") == [.low, .high, .max])
        #expect(try levels("deepseek-v4.1-flash-sg") == [.low, .high, .max])
        #expect(models["fast-model"]?.reasoning == true)
        // Listed levels are kept as they are; a model that doesn't reason
        // gets none.
        #expect(try levels("hy3") == [.low, .high])
        #expect(try levels("gpt-5.6-sol") == [.off, .low, .medium, .high, .xhigh, .max])
        #expect(try levels("glm-5.2") == [.off, .high, .xhigh])
        #expect(models["default-model"]?.reasoning == false)
    }

    // The plugin's usage.test.mjs, "WorkBuddy AI's GLM models are text-only"
    // (0.1.16, cb90931).
    @Test("WorkBuddy AI's GLM models are text-only; its others and China's GLM keep images")
    func glmTextOnly() throws {
        let ids = ["glm-5.3-flash", "glm-5.3", "glm-5.2", "glm-6", "deepseek-v4.1-flash", "kimi-k3", "gemini-3.5-flash", "gpt-5.5", "hy3"]
        let config: [String: Any] = [
            "agents": [["name": "cli", "models": ids + ["said-nothing"]]],
            "models": ids.map { ["id": $0, "name": $0, "supportsImages": $0 != "hy3"] } + [["id": "said-nothing"]],
        ]
        func images(_ site: WorkBuddySite) -> [String: Bool] {
            Dictionary(uniqueKeysWithValues: WorkBuddyModels.listings(fromConfig: config, site: site).map {
                ($0.model.id, $0.model.input.contains(.image))
            })
        }
        #expect(images(.international) == [
            "glm-5.3-flash": false, "glm-5.3": false, "glm-5.2": false, "glm-6": false,
            "deepseek-v4.1-flash": true, "kimi-k3": true, "gemini-3.5-flash": true, "gpt-5.5": true,
            "hy3": false, "said-nothing": false,
        ])
        #expect(images(.china) == [
            "glm-5.3-flash": true, "glm-5.3": true, "glm-5.2": true, "glm-6": true,
            "deepseek-v4.1-flash": true, "kimi-k3": true, "gemini-3.5-flash": true, "gpt-5.5": true,
            "hy3": false, "said-nothing": false,
        ])
        // The family, by its id's start: not a model whose id only has glm in it.
        #expect(!WorkBuddyModels.textOnly(site: .international, id: "my-glm-5"))
    }

    // magpie's TestWorkBuddyDistinctNames.
    @Test("A later model of the same name is named for what its id adds, or else its id")
    func distinctNames() {
        func listing(_ id: String, _ name: String) -> WorkBuddyModels.Listing {
            WorkBuddyModels.Listing(
                model: Model(id: id, name: name, api: "openai-completions", provider: "workbuddy"),
                creditRate: nil
            )
        }
        let named = WorkBuddyModels.distinctNames([
            listing("deepseek-v4.1-flash", "Deepseek-V4.1-Flash"),
            listing("deepseek-v4.1-flash-sg", "Deepseek-V4.1-Flash"),
            listing("glm-5.3", "GLM-5.3"),
            listing("glm-x", "GLM-5.3"),
        ])
        #expect(named.map(\.model.name) == ["Deepseek-V4.1-Flash", "Deepseek-V4.1-Flash (SG)", "GLM-5.3", "GLM-5.3 (glm-x)"])
    }
}
