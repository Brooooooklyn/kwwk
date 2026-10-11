import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers each request with the next scripted reply and keeps what was sent.
private final class ScriptedResponsesClient: HTTPClient, @unchecked Sendable {
    struct Reply {
        var status = 200
        var contentType = "text/event-stream"
        var body: String
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var _requests: [(headers: [String: String], body: Data)] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var requests: [(headers: [String: String], body: Data)] { lock.withLock { _requests } }

    func input(_ index: Int) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: requests[index].body) as? [String: Any]
        return object?["input"] as? [[String: Any]] ?? []
    }

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?, cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let reply = lock.withLock { () -> Reply in
            _requests.append((headers, body ?? Data()))
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": reply.contentType])!
        return (response, AsyncThrowingStream { continuation in
            continuation.yield(Data(reply.body.utf8))
            continuation.finish()
        })
    }
}

@Suite("OpenAI Responses vendor behaviour")
struct OpenAIResponsesParityTests {
    static let codex: Model = {
        var model = OpenAIResponsesTests.model
        model.api = "chatgpt-codex"
        model.provider = "openai-codex"
        return model
    }()

    private static func run(
        _ client: ScriptedResponsesClient, model: Model = codex, messages: [Message] = [.user(UserMessage(text: "hi"))],
        options: StreamOptions? = nil, provider: OpenAIResponsesProvider? = nil
    ) async -> AssistantMessage {
        let provider = provider ?? OpenAIResponsesProvider(
            api: model.api, client: client, webSocketClient: nil, defaultAPIKey: "k")
        let stream = provider.stream(model: model, context: Context(messages: messages), options: options)
        for await _ in stream {}
        return await stream.result()
    }

    // MARK: Prompt cache

    @Test("ChatGPT Codex names the conversation in session-id and thread-id, where its prompt cache is looked up")
    func codexSessionHeaders() async throws {
        let client = ScriptedResponsesClient([.init(body: OpenAIResponsesTests.textSSE)])
        _ = await Self.run(client, options: StreamOptions(sessionId: "conversation-1"))
        #expect(client.requests[0].headers["session-id"] == "conversation-1")
        #expect(client.requests[0].headers["thread-id"] == "conversation-1")

        // No caching asked, no key in the body: no session named either.
        _ = await Self.run(client, options: StreamOptions(cacheRetention: CacheRetention.none, sessionId: "conversation-1"))
        #expect(client.requests[1].headers["session-id"] == nil)

        // The public API keys its cache by the body's prompt_cache_key.
        _ = await Self.run(client, model: OpenAIResponsesTests.model, options: StreamOptions(sessionId: "conversation-1"))
        #expect(client.requests[2].headers["session-id"] == nil)
        #expect(client.requests[2].headers["thread-id"] == nil)
    }

    // MARK: Usage

    @Test("usage separates cache writes from input and reads reasoning tokens")
    func usageCacheWriteAndReasoning() async throws {
        // The usage object of a ChatGPT backend reply (2026-10-11), with figures set.
        let sse = """
        data: {"type":"response.completed","response":{"id":"r","status":"completed","usage":{"input_tokens":5399,"input_tokens_details":{"cached_tokens":4608,"cache_write_tokens":500},"output_tokens":24,"output_tokens_details":{"reasoning_tokens":17},"total_tokens":5423}}}

        """
        let result = await Self.run(ScriptedResponsesClient([.init(body: sse)]))
        #expect(result.usage.cacheRead == 4608)
        #expect(result.usage.cacheWrite == 500)
        #expect(result.usage.input == 291)
        #expect(result.usage.output == 24)
        #expect(result.usage.reasoning == 17)
        #expect(result.usage.totalTokens == 5423)
    }

    // MARK: Error text

    @Test("an error event's sentence is shown from either shape")
    func errorEventShapes() async throws {
        let topLevel = """
        data: {"type":"error","code":"server_error","message":"The server had an error processing your request."}

        """
        let flat = await Self.run(ScriptedResponsesClient([.init(body: topLevel)]))
        #expect(flat.errorMessage == "The server had an error processing your request.")
        #expect(flat.failure?.providerCode == "server_error")

        let nested = """
        data: {"type":"error","error":{"message":"response protection is unavailable","type":"internal_error"}}

        """
        let wrapped = await Self.run(ScriptedResponsesClient([.init(body: nested)]))
        #expect(wrapped.errorMessage == "response protection is unavailable")

        let bare = await Self.run(ScriptedResponsesClient([.init(body: "data: {\"type\":\"error\"}\n\n")]))
        #expect(bare.errorMessage == "OpenAI Responses error")
    }

    @Test("the ChatGPT backend's {detail} refusal is shown as its sentence")
    func detailBody() async throws {
        // Both bodies as the backend sent them on 2026-10-11.
        let stream = await Self.run(ScriptedResponsesClient([
            .init(status: 400, contentType: "application/json", body: #"{"detail":"Stream must be set to true"}"#),
        ]))
        #expect(stream.errorMessage == "Stream must be set to true")
        #expect(stream.failure?.httpStatus == 400)
        #expect(stream.failure?.category == .invalidRequest)

        let model = await Self.run(ScriptedResponsesClient([
            .init(status: 400, contentType: "application/json",
                  body: #"{"detail":"The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account."}"#),
        ]))
        #expect(model.errorMessage == "The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account.")

        let object = OpenAIResponsesProvider.readingDetail(ProviderFailure(
            message: #"{"detail":{"message":"Workspace is deactivated","code":"deactivated_workspace"}}"#, httpStatus: 402))
        #expect(object.message == "Workspace is deactivated")
        #expect(object.providerCode == "deactivated_workspace")

        // A body that already gave its message is left alone.
        let plain = ProviderFailure(message: "Bad request", httpStatus: 400, providerCode: "invalid_request_error")
        #expect(OpenAIResponsesProvider.readingDetail(plain) == plain)
    }

    // MARK: A 200 that is not a stream

    @Test("a 200 web page is named as one, not reported as a dropped stream")
    func webPageReply() async throws {
        let page = "<!DOCTYPE html><html><head><title>Just a moment...</title></head><body></body></html>"
        let result = await Self.run(ScriptedResponsesClient([.init(contentType: "text/html; charset=UTF-8", body: page)]))
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "The server answered HTTP 200 with a web page, not an event stream: Just a moment...")
        // A challenge can pass: still asked again, as the dropped stream was.
        #expect(result.failure?.isRetryable == true)
    }

    @Test("a 200 JSON error body keeps the vendor's message and is not replayed as a dropped stream")
    func jsonReply() async throws {
        let refused = await Self.run(ScriptedResponsesClient([.init(
            contentType: "application/json",
            body: #"{"error":{"message":"The model `gpt-9` does not exist","type":"invalid_request_error","code":"model_not_found"}}"#)]))
        #expect(refused.errorMessage == "The model `gpt-9` does not exist")
        #expect(refused.failure?.providerCode == "model_not_found")
        #expect(refused.failure?.isRetryable == false)

        let whole = await Self.run(ScriptedResponsesClient([.init(
            contentType: "application/json", body: #"{"id":"resp_1","object":"response","status":"completed"}"#)]))
        #expect(whole.errorMessage == "The server answered HTTP 200 with JSON, not an event stream")
        #expect(whole.failure?.isRetryable == false)
    }

    @Test("an event stream under a JSON or HTML content type is still read")
    func mislabelledStream() async throws {
        for type in ["application/json", "text/html"] {
            let result = await Self.run(ScriptedResponsesClient([.init(contentType: type, body: OpenAIResponsesTests.textSSE)]))
            #expect(result.stopReason == .stop)
            #expect(result.responseId == "resp_1")
            #expect(result.content == [.text(TextContent(text: "Hello, world"))])
        }
    }

    // MARK: Refused seals

    /// The 400 the ChatGPT backend gave a reasoning item with one character
    /// of its encrypted_content changed (2026-10-11).
    static let sealRefusal = #"""
    {
      "error": {
        "message": "The encrypted content for item rs_072826f4f25f1ba0016acaf835f5e881918001ad5f83b0bd3a could not be verified. Reason: Encrypted content could not be decrypted or parsed.",
        "type": "invalid_request_error",
        "param": null,
        "code": "invalid_encrypted_content"
      }
    }
    """#

    static func reasoningTurn(_ sealed: String, answer: String) -> Message {
        let item = #"{"type":"reasoning","id":"rs_\#(sealed)","summary":[],"encrypted_content":"\#(sealed)"}"#
        return .assistant(AssistantMessage(
            content: [.thinking(ThinkingContent(thinking: "", thinkingSignature: item)), .text(TextContent(text: answer))],
            api: codex.api, provider: codex.provider, model: codex.id))
    }

    static let sealedHistory: [Message] = [
        .user(UserMessage(text: "first")),
        reasoningTurn("sealed-by-the-other-account", answer: "one"),
        .user(UserMessage(text: "second")),
    ]

    private static func types(_ input: [[String: Any]]) -> [String] {
        input.compactMap { $0["type"] as? String }
    }

    @Test("a refusal of replayed reasoning is asked again without it, and later turns leave it out")
    func sealRefusedOverHTTP() async throws {
        let client = ScriptedResponsesClient([
            .init(status: 400, contentType: "application/json", body: Self.sealRefusal),
            .init(body: OpenAIResponsesTests.textSSE),
        ])
        let provider = OpenAIResponsesProvider(api: Self.codex.api, client: client, webSocketClient: nil, defaultAPIKey: "k")
        let options = StreamOptions(sessionId: "moved")
        let result = await Self.run(client, messages: Self.sealedHistory, options: options, provider: provider)
        #expect(result.stopReason == .stop)
        #expect(result.content == [.text(TextContent(text: "Hello, world"))])
        #expect(client.requests.count == 2)
        #expect(Self.types(try client.input(0)) == ["message", "reasoning", "message", "message"])
        #expect(Self.types(try client.input(1)) == ["message", "message", "message"])

        // Next turn of the conversation: the refused seal stays out, what
        // this account sealed since goes along.
        let later = Self.sealedHistory + [Self.reasoningTurn("sealed-here", answer: "two"), .user(UserMessage(text: "third"))]
        _ = await Self.run(client, messages: later, options: options, provider: provider)
        #expect(client.requests.count == 3)
        let reasoning = try client.input(2).filter { $0["type"] as? String == "reasoning" }
        #expect(reasoning.compactMap { $0["encrypted_content"] as? String } == ["sealed-here"])
    }

    @Test("a seal refusal is shown when the retry is refused too, or when the request held no seal")
    func sealRefusalSurfaces() async throws {
        let twice = ScriptedResponsesClient([.init(status: 400, contentType: "application/json", body: Self.sealRefusal)])
        let result = await Self.run(twice, messages: Self.sealedHistory)
        #expect(twice.requests.count == 2)
        #expect(result.stopReason == .error)
        #expect(result.failure?.providerCode == "invalid_encrypted_content")

        let unsealed = ScriptedResponsesClient([.init(status: 400, contentType: "application/json", body: Self.sealRefusal)])
        let plain = await Self.run(unsealed)
        #expect(unsealed.requests.count == 1)
        #expect(plain.stopReason == .error)
    }

    @Test("a refused compaction gives way to the messages it was made from")
    func refusedCompactionFallsBack() async throws {
        var recap = UserMessage(text: "recap")
        recap.nativeCompaction = NativeCompactionPayload(
            model: Self.codex,
            items: [.object(["type": .string("compaction"), "encrypted_content": .string("sealed-compaction")])],
            fallbackMessages: [.user(UserMessage(text: "before compaction"))])
        let client = ScriptedResponsesClient([
            .init(status: 400, contentType: "application/json", body: Self.sealRefusal),
            .init(body: OpenAIResponsesTests.textSSE),
        ])
        let result = await Self.run(client, messages: [.user(recap), .user(UserMessage(text: "next"))])
        #expect(result.stopReason == .stop)
        #expect(Self.types(try client.input(0)).contains("compaction"))
        let retried = try client.input(1)
        #expect(!Self.types(retried).contains("compaction"))
        let texts = retried.compactMap { ($0["content"] as? [[String: Any]])?.first?["text"] as? String }
        #expect(texts == ["before compaction", "next"])
    }

    @Test("a seal refusal over WebSocket is asked again on a fresh connection")
    func sealRefusedOverWebSocket() async throws {
        // The event as the ChatGPT backend sent it over WebSocket (2026-10-11).
        let refusal = #"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_encrypted_content","message":"The encrypted content for item rs_1 could not be verified. Reason: Encrypted content could not be decrypted or parsed.","param":null},"status":400}"#
        let first = StubWebSocketConnection(batches: [[#"{"type":"codex.rate_limits"}"#, refusal]])
        let answer = OpenAIResponsesTests.textSSE.split(separator: "\n")
            .filter { $0.hasPrefix("data: ") }.map { String($0.dropFirst(6)) }
        let second = StubWebSocketConnection(batches: [answer])
        let ws = StubWebSocketClient(connections: [first, second])
        let http = ScriptedResponsesClient([.init(body: OpenAIResponsesTests.textSSE)])
        let provider = OpenAIResponsesProvider(api: Self.codex.api, client: http, webSocketClient: ws, defaultAPIKey: "k")
        let result = await Self.run(http, messages: Self.sealedHistory,
                                    options: StreamOptions(sessionId: "moved-ws"), provider: provider)
        #expect(result.stopReason == .stop)
        #expect(result.content == [.text(TextContent(text: "Hello, world"))])
        #expect(http.requests.isEmpty)
        #expect(ws.connectCount == 2)
        #expect(first.closed)
        #expect(first.sentTexts[0].contains("sealed-by-the-other-account"))
        #expect(!second.sentTexts[0].contains("sealed-by-the-other-account"))
        #expect(ws.lastHeaders["session-id"] == "moved-ws")
    }

    @Test("only the vendors' seal refusals are read as one")
    func foreignSealWordings() {
        #expect(OpenAIResponsesProvider.isForeignSeal(ProviderFailure(
            message: "Could not decrypt the provided encrypted_content. Ensure the value is the unmodified encrypted_content from a previous response.",
            httpStatus: 400)))
        #expect(OpenAIResponsesProvider.isForeignSeal(ProviderFailure(message: "refused", providerCode: "invalid_encrypted_content")))
        #expect(!OpenAIResponsesProvider.isForeignSeal(ProviderFailure(
            message: "Invalid 'input[2].encrypted_content': string too long.", httpStatus: 400)))
        #expect(!OpenAIResponsesProvider.isForeignSeal(ProviderFailure(
            message: "The encrypted content could not be verified.", httpStatus: 500)))
    }
}
