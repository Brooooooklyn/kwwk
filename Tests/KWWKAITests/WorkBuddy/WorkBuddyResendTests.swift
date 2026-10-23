import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The plugin's aftertools.test.mjs and systemasuser.test.mjs
// (`@magpie-community/opencode-workbuddy-auth` 0.1.20, 0.1.29): a WorkBuddy
// that refuses a chat as the real one did, and what kwwk sends it again.

/// A WorkBuddy that answers each request by what it holds, recording each.
private final class ScriptedWorkBuddy: HTTPClient, @unchecked Sendable {
    struct Answer {
        var status = 200
        var body = served
        var headers: [String: String] = [:]
    }

    struct Sent {
        var url: URL
        var headers: [String: String]
        var body: Data?
        var json: [String: Any] { (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
        var messages: [[String: Any]] { json["messages"] as? [[String: Any]] ?? [] }
        var roles: [String] { messages.compactMap { $0["role"] as? String } }
    }

    private let lock = NSLock()
    /// What this WorkBuddy answers a request, without recording it.
    let answer: @Sendable (Sent) throws -> Answer
    private var recorded: [Sent] = []

    init(_ answer: @escaping @Sendable (Sent) throws -> Answer) {
        self.answer = answer
    }

    var sent: [Sent] { lock.withLock { recorded } }
    var chats: [Sent] { sent.filter { $0.url.path.hasSuffix("/chat/completions") } }
    func forget() { lock.withLock { recorded.removeAll() } }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let request = Sent(url: url, headers: headers, body: body)
        lock.withLock { recorded.append(request) }
        let said = try answer(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: said.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": said.status == 200 ? "text/event-stream" : "application/json"]
                .merging(said.headers) { _, own in own }
        )!
        let data = Data(said.body.utf8)
        return (response, AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        })
    }
}

/// A reply WorkBuddy streams when it serves a chat.
private let served = [
    #"data: {"id":"c1","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":""}]}"#,
    #"data: {"id":"c1","choices":[{"index":0,"delta":{"content":""},"finish_reason":"stop"}]}"#,
    "data: [DONE]",
].map { $0 + "\n\n" }.joined()

private let auth = ResolvedProviderAuth(
    token: "own-access", scheme: .bearer,
    headers: ["X-User-Id": "u1", "X-Domain": "www.workbuddy.ai"]
)

private func run(
    _ provider: WorkBuddyProvider,
    model: String,
    _ context: Context,
    cancellation: CancellationHandle? = nil
) async -> AssistantMessage {
    let stream = provider.stream(
        model: WorkBuddyModels.model(site: provider.site, id: model),
        context: context,
        options: StreamOptions(resolvedAuth: auth, cancellation: cancellation)
    )
    for await _ in stream {}
    return await stream.result()
}

private func text(_ content: Any?) -> String {
    if let text = content as? String { return text }
    return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
}

private let call = AssistantMessage(
    content: [.toolCall(ToolCall(id: "call_1", name: "bash", arguments: .object(["command": .string("ls")])))],
    api: "openai-completions", provider: "workbuddy-ai", model: "gemini-3.8-flash", stopReason: .toolUse
)
private let result = ToolResultMessage(toolCallId: "call_1", toolName: "bash", content: [.text(TextContent(text: "a.txt"))])
private let ask = UserMessage(text: "List the files.")
private let reminder = UserMessage(text: "<system-reminder>note</system-reminder>")
private let bash = Tool(name: "bash", description: "Runs a command.", parameters: .object([
    "type": .string("object"), "properties": .object(["command": .object(["type": .string("string")])]),
]))

// MARK: - Tool results, then the user's message

/// The body www.workbuddy.ai sent on 2026-10-14 for tool results followed
/// by a user message, to gemini-3.8-flash.
private let afterTools = #"""
{"code":11153,"msg":"the conversation must end with a user message","requestId":"555fb7db0fb1ef01abc76992cbfcad0e",
 "extError":{"code":"400001","message":"the conversation must end with a user message","param":"","type":"invalid_request_error","StatusCode":400},
 "displayMsg":{"en":"This conversation must end with a user message. Please add your input and retry."}}
"""#

/// gemini-3.8-flash: tool results then a user message are refused, and a
/// chat that doesn't end with a user message; anything else is served.
private func geminiAfterTools() -> ScriptedWorkBuddy {
    ScriptedWorkBuddy { sent in
        let roles = sent.roles
        var index = roles.count - 1
        while index >= 0, roles[index] == "user" { index -= 1 }
        if roles.last != "user" || (index < roles.count - 1 && index >= 0 && roles[index] == "tool") {
            return .init(status: 400, body: afterTools)
        }
        return .init()
    }
}

@Suite("WorkBuddy chats sent again")
struct WorkBuddyResendTests {
    @Test("Tool results then the user's message go again with an empty reply between them")
    func replyAfterTools() async throws {
        let service = geminiAfterTools()
        let provider = WorkBuddyProvider(site: .international, client: service)
        let reply = await run(provider, model: "gemini-after-tools-a", Context(
            systemPrompt: "You are kwwk.",
            messages: [.user(ask), .assistant(call), .toolResult(result), .user(reminder)],
            tools: [bash]
        ))
        #expect(reply.stopReason == .stop)
        #expect(service.chats.count == 2)
        let again = try #require(service.chats.last)
        #expect(again.roles == ["system", "user", "assistant", "tool", "assistant", "user"])
        #expect(again.messages[4]["content"] as? String == "")
        #expect(again.messages[4].count == 2)
        // What the user said is still the user's, last.
        #expect(text(again.messages[5]["content"]) == "<system-reminder>note</system-reminder>")
        // The same request, sent again: the chat's ids are the same.
        #expect(again.headers == service.chats[0].headers)
    }

    @Test("A model that refused it gets the empty reply up front on its next chat; another model is asked as it was")
    func upFront() async throws {
        let service = geminiAfterTools()
        let provider = WorkBuddyProvider(site: .international, client: service)
        let context = Context(
            systemPrompt: "You are kwwk.",
            messages: [.user(ask), .assistant(call), .toolResult(result), .user(reminder)],
            tools: [bash]
        )
        _ = await run(provider, model: "gemini-after-tools-b", context)
        service.forget()
        let reply = await run(provider, model: "gemini-after-tools-b", context)
        #expect(reply.stopReason == .stop)
        #expect(service.chats.count == 1)
        #expect(service.chats.first?.roles == ["system", "user", "assistant", "tool", "assistant", "user"])

        let answered = AssistantMessage(
            content: [.text(TextContent(text: "Two."))],
            api: "openai-completions", provider: "workbuddy-ai", model: "deepseek-after-tools-b"
        )
        _ = await run(provider, model: "deepseek-after-tools-b", Context(
            systemPrompt: "You are kwwk.",
            messages: [.user(ask), .assistant(call), .toolResult(result), .assistant(answered), .user(ask)],
            tools: [bash]
        ))
        #expect(service.chats.count == 2)
        #expect(service.chats.last?.messages.contains { $0["role"] as? String == "assistant" && $0["content"] as? String == "" } == false)
    }

    @Test("A chat ending with the assistant's message is a prefill, refused as it was")
    func prefill() async throws {
        let service = geminiAfterTools()
        let provider = WorkBuddyProvider(site: .international, client: service)
        let prefill = AssistantMessage(
            content: [.text(TextContent(text: "There are"))],
            api: "openai-completions", provider: "workbuddy-ai", model: "gemini-after-tools-c"
        )
        let reply = await run(provider, model: "gemini-after-tools-c", Context(
            systemPrompt: "You are kwwk.",
            messages: [.user(ask), .assistant(call), .toolResult(result), .assistant(prefill)]
        ))
        #expect(service.chats.count == 1)
        #expect(reply.failure?.message == "the conversation must end with a user message")
        #expect(reply.failure?.providerCode == "11153")
        #expect(reply.failure?.httpStatus == 400)
    }

    @Test("replyAfterTools changes only tool results followed by user messages")
    func replyAfterToolsShapes() {
        let ask: [String: Any] = ["role": "user", "content": "List the files."]
        let call: [String: Any] = ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call_1"]]]
        let result: [String: Any] = ["role": "tool", "tool_call_id": "call_1", "content": "a.txt"]
        func roles(_ messages: [[String: Any]]) -> [String]? {
            (WorkBuddyWire.replyAfterTools(["model": "m", "messages": messages])?["messages"] as? [[String: Any]])?
                .compactMap { $0["role"] as? String }
        }
        #expect(roles([ask, call, result, ask, ask]) == ["user", "assistant", "tool", "assistant", "user", "user"])
        #expect(roles([ask]) == nil)
        #expect(roles([ask, call, result]) == nil)
        #expect(roles([ask, call, result, ["role": "assistant", "content": "ok"], ask]) == nil)
        #expect(roles([ask, ["role": "assistant", "content": "hi"]]) == nil)
        #expect(WorkBuddyWire.replyAfterTools(["prompt": "a cat"]) == nil)
    }

    @Test("Another 400, and a 11153 code a body only begins with, are not sent again")
    func otherRefusals() async throws {
        for body in [#"{"code":11133,"msg":"Invalid request parameters"}"#, #"{"code":111530,"msg":"x"}"#, "Bad Request"] {
            let service = ScriptedWorkBuddy { _ in .init(status: 400, body: body) }
            let provider = WorkBuddyProvider(site: .international, client: service)
            let reply = await run(provider, model: "gemini-3.8-flash", Context(
                systemPrompt: "You are kwwk.",
                messages: [.user(ask), .assistant(call), .toolResult(result), .user(reminder)],
                tools: [bash]
            ))
            #expect(service.chats.count == 1)
            #expect(reply.failure?.httpStatus == 400)
        }
    }

    // MARK: - A system prompt refused as an unapproved channel

    /// The body copilot.tencent.com and www.workbuddy.ai both sent on
    /// 2026-10-21 for a system prompt opening with Claude Code's identity
    /// line.
    private static let channel = #"""
    {"code":11128,"msg":"Illegal API invocation from an unapproved channel","requestId":"77e85b2840d5e111705b54090bc89318",
     "displayMsg":{"en":"Request blocked. Please send it again","zh":"请求被拦截，请重新发送"},
     "displayTips":{"en":"This call failed channel verification, possibly because it was not sent from an official client."},
     "actions":["EDIT_INPUT","SUBMIT_FEEDBACK"]}
    """#
    private static let notFirst = #"{"code":11128,"msg":"first message is not system prompt","requestId":"e83a1453"}"#

    /// Lines `flagged` doesn't know, refused as WorkBuddy refuses known
    /// ones: an agent's opening line at the start of a system or assistant
    /// message, a fingerprint anywhere in one.
    private static let opening = "You are Example Agent, the official CLI of Example Inc."
    private static let anywhere = "Example fingerprint (you will usually see this)"

    private static func channelCheck() -> ScriptedWorkBuddy {
        ScriptedWorkBuddy { sent in
            let refused = sent.messages.contains { message in
                let role = message["role"] as? String
                let words = text(message["content"])
                return (role == "system" || role == "assistant")
                    && (words.lowercased().hasPrefix(opening.lowercased()) || words.contains(anywhere))
            }
            return refused ? .init(status: 400, body: channel) : .init()
        }
    }

    private static let systemCounter = NSLock()
    nonisolated(unsafe) private static var systems = 0
    /// A system prompt of its own per test: what was refused stays
    /// remembered for as long as the provider lives.
    private static func system() -> String {
        systemCounter.withLock {
            systems += 1
            return opening + "\nUse the tools to answer. (\(systems))"
        }
    }

    @Test("A refused system prompt goes again as the user's instructions, tools and all", arguments: WorkBuddySite.all)
    func systemAsUser(site: WorkBuddySite) async throws {
        let service = Self.channelCheck()
        let provider = WorkBuddyProvider(site: site, client: service)
        let system = Self.system()
        let reply = await run(provider, model: "glm-5.3", Context(
            systemPrompt: system, messages: [.user(UserMessage(text: "Read calc.py."))], tools: [bash]
        ))
        #expect(reply.stopReason == .stop)
        #expect(service.chats.count == 2)
        let again = try #require(service.chats.last)
        #expect(again.roles == ["system", "user"])
        #expect(again.messages[0]["content"] as? String == WorkBuddyWire.defaultSystemPrompt)
        #expect(text(again.messages[1]["content"]) == "<instructions>\n\(system)\n</instructions>\n\nRead calc.py.")
        #expect((again.json["tools"] as? [[String: Any]])?.count == 1)
    }

    @Test("The same system prompt's next chat goes moved at once, and another's is tried as it is")
    func movedUpFront() async throws {
        let service = Self.channelCheck()
        let provider = WorkBuddyProvider(site: .china, client: service)
        let system = Self.system()
        let read = UserMessage(text: "Read calc.py.")
        _ = await run(provider, model: "glm-5.3", Context(systemPrompt: system, messages: [.user(read)], tools: [bash]))
        let reply = await run(provider, model: "glm-5.3", Context(
            systemPrompt: system, messages: [.user(read), .assistant(call), .toolResult(result)], tools: [bash]
        ))
        #expect(reply.stopReason == .stop)
        #expect(service.chats.count == 3)
        let moved = service.chats[2]
        #expect(moved.roles == ["system", "user", "assistant", "tool"])
        #expect(text(moved.messages[1]["content"]).hasPrefix("<instructions>\n" + Self.opening))
        // What the tool said and what the assistant called stay as they were.
        #expect(moved.messages[3]["content"] as? String == "a.txt")

        _ = await run(provider, model: "glm-5.3", Context(systemPrompt: "You are a coding agent.", messages: [.user(read)]))
        #expect(service.chats.count == 4)
        #expect(service.chats[3].messages.first?["content"] as? String == "You are a coding agent.")
    }

    @Test("A line refused anywhere in the system prompt is moved too")
    func movedAnywhere() async throws {
        let service = Self.channelCheck()
        let provider = WorkBuddyProvider(site: .international, client: service)
        let reply = await run(provider, model: "glm-5.3", Context(
            systemPrompt: "You are a coding agent.\n\nGit status:\n" + Self.anywhere,
            messages: [.user(UserMessage(text: "Read calc.py."))]
        ))
        #expect(reply.stopReason == .stop)
        #expect(service.chats.count == 2)
        #expect(text(service.chats[1].messages[1]["content"]).contains(Self.anywhere))
    }

    @Test("A refusal that stands after the move is the user's, with the hint, tried once")
    func standsAfterMove() async throws {
        let service = Self.channelCheck()
        let provider = WorkBuddyProvider(site: .china, client: service)
        // An assistant message WorkBuddy refuses too, which nothing moves.
        let quoted = AssistantMessage(
            content: [.text(TextContent(text: Self.opening))], api: "openai-completions", provider: "workbuddy", model: "glm-5.3"
        )
        let reply = await run(provider, model: "glm-5.3", Context(
            systemPrompt: Self.system(),
            messages: [.user(UserMessage(text: "Read calc.py.")), .assistant(quoted), .user(UserMessage(text: "go on"))]
        ))
        #expect(service.chats.count == 2)
        let failure = try #require(reply.failure)
        #expect(failure.message == "Illegal API invocation from an unapproved channel — \(WorkBuddyWire.refusedHint)")
        #expect(failure.providerCode == "11128")
        #expect(!failure.isCredentialRejection)
    }

    @Test("A chat with nothing to move isn't sent again")
    func nothingToMove() async throws {
        let service = Self.channelCheck()
        let provider = WorkBuddyProvider(site: .china, client: service)
        let quoted = AssistantMessage(
            content: [.text(TextContent(text: Self.opening))], api: "openai-completions", provider: "workbuddy", model: "glm-5.3"
        )
        let reply = await run(provider, model: "glm-5.3", Context(
            messages: [.user(UserMessage(text: "hi")), .assistant(quoted), .user(UserMessage(text: "Read calc.py."))]
        ))
        #expect(reply.stopReason == .error)
        #expect(service.chats.count == 1)
    }

    @Test("11128 for another reason moves nothing")
    func notFirstMovesNothing() async throws {
        let service = ScriptedWorkBuddy { _ in .init(status: 400, body: Self.notFirst) }
        let provider = WorkBuddyProvider(site: .international, client: service)
        let reply = await run(provider, model: "glm-5.3", Context(
            systemPrompt: "You are a coding agent.", messages: [.user(UserMessage(text: "Read calc.py."))]
        ))
        #expect(reply.failure?.message == "first message is not system prompt")
        #expect(service.chats.count == 1)
    }

    @Test("A model that refuses both is moved, then given the empty reply")
    func bothRefusals() async throws {
        let check = Self.channelCheck()
        let gemini = geminiAfterTools()
        let service = ScriptedWorkBuddy { sent in
            let channel = try check.answer(sent)
            return channel.status == 400 ? channel : try gemini.answer(sent)
        }
        let provider = WorkBuddyProvider(site: .international, client: service)
        let reply = await run(provider, model: "gemini-both", Context(
            systemPrompt: Self.system(),
            messages: [.user(ask), .assistant(call), .toolResult(result), .user(reminder)],
            tools: [bash]
        ))
        #expect(reply.stopReason == .stop)
        #expect(service.chats.count == 3)
        #expect(service.chats[2].roles == ["system", "user", "assistant", "tool", "assistant", "user"])
        #expect(text(service.chats[2].messages[1]["content"]).hasPrefix("<instructions>\n"))
    }

    @Test("systemAsUser: parts, a later system message, no user message")
    func systemAsUserShapes() throws {
        let opening = Self.opening
        let parts = try #require(WorkBuddyWire.systemAsUser(["messages": [
            ["role": "system", "content": [["type": "text", "text": opening], ["type": "text", "text": "Be brief."]]],
            ["role": "user", "content": [
                ["type": "text", "text": "look"], ["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]],
            ]],
            ["role": "assistant", "content": "ok"],
            ["role": "system", "content": "Reminder: be brief."],
            ["role": "user", "content": "next"],
        ] as [[String: Any]]])?["messages"] as? [[String: Any]])
        #expect(parts[0]["role"] as? String == "system")
        #expect(parts[0]["content"] as? String == WorkBuddyWire.defaultSystemPrompt)
        let first = try #require(parts[1]["content"] as? [[String: Any]])
        #expect(first[0]["text"] as? String == "<instructions>\n\(opening)\nBe brief.\n</instructions>")
        #expect(first.dropFirst().compactMap { $0["type"] as? String } == ["text", "image_url"])
        #expect(parts[3]["role"] as? String == "user")
        #expect(parts[3]["content"] as? String == "Reminder: be brief.")

        let alone = try #require(WorkBuddyWire.systemAsUser(["messages": [["role": "system", "content": opening]]])?["messages"]
            as? [[String: Any]])
        #expect(alone.compactMap { $0["role"] as? String } == ["system", "user"])
        #expect(alone[1]["content"] as? String == "<instructions>\n\(opening)\n</instructions>")

        #expect(WorkBuddyWire.systemAsUser(["messages": [
            ["role": "system", "content": WorkBuddyWire.defaultSystemPrompt], ["role": "user", "content": "hi"],
        ]]) == nil)
        #expect(WorkBuddyWire.systemKey(["messages": [["role": "system", "content": WorkBuddyWire.defaultSystemPrompt]]]) == "")
    }

    @Test("The words the move adds name no one")
    func namesNoOne() throws {
        let moved = try #require(WorkBuddyWire.systemAsUser(["messages": [
            ["role": "system", "content": "x"], ["role": "user", "content": "Read calc.py."],
        ]]))
        let data = try JSONSerialization.data(withJSONObject: moved)
        let added = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "Read calc.py.", with: "")
            .replacingOccurrences(of: WorkBuddyWire.defaultSystemPrompt, with: "")
        #expect(added.range(of: "magpie|workbuddy|codebuddy|opencode|claude|codex|kwwk", options: [.regularExpression, .caseInsensitive]) == nil)
    }
}
