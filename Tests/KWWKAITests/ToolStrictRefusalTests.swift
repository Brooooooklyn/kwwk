import Foundation
import Testing
@testable import KWWKAI

/// An upstream that answers 400 `refusal` to a request whose tools carry
/// `strict`, and streams a reply to any other. It records every request body.
final class StrictRefusingClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let refusal: String?
    private var _bodies: [[String: Any]] = []
    var bodies: [[String: Any]] { lock.withLock { _bodies } }

    /// `refusal` nil takes strict like any lax upstream.
    init(refusal: String?) { self.refusal = refusal }

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let json = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        lock.withLock { _bodies.append(json) }
        let refused = refusal != nil && ToolStrictRefusalTests.toolsHaveStrict(json)
        let response = HTTPURLResponse(
            url: url, statusCode: refused ? 400 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["content-type": refused ? "application/json" : "text/event-stream"]
        )!
        let data = Data((refused ? refusal! : ToolStrictRefusalTests.replySSE).utf8)
        return (response, AsyncThrowingStream { cont in
            cont.yield(data)
            cont.finish()
        })
    }
}

@Suite("Tool strict refused by an OpenAI-compatible endpoint")
struct ToolStrictRefusalTests {
    /// magpie #1980's refusal, in OpenAI's error shape.
    static let strictRefusal = #"{"error":{"message":"Unsupported Chat Completions API field: tools[0].function.strict","type":"invalid_request_error"}}"#

    static let replySSE = """
    data: {"id":"c","choices":[{"index":0,"delta":{"role":"assistant","content":"ok"}}]}

    data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

    static func toolsHaveStrict(_ body: [String: Any]) -> Bool {
        (body["tools"] as? [[String: Any]] ?? []).contains {
            ($0["function"] as? [String: Any])?["strict"] != nil
        }
    }

    static func model(provider: String) -> Model {
        Model(
            id: "m1", name: "M1", api: "openai-completions", provider: provider,
            baseURL: "https://relay.example.test/v1", reasoning: false, input: [.text],
            contextWindow: 128_000, maxTokens: 4096
        )
    }

    static let context = Context(
        messages: [.user(UserMessage(text: "hi"))],
        tools: [
            Tool(name: "read", description: "r", parameters: ["type": "object"]),
            Tool(name: "write", description: "w", parameters: ["type": "object"]),
        ]
    )

    static func ask(_ client: StrictRefusingClient, provider: String) async -> AssistantMessage {
        let s = OpenAICompletionsProvider(client: client, defaultAPIKey: "k")
            .stream(model: model(provider: provider), context: context, options: nil)
        for await _ in s {}
        return await s.result()
    }

    // Wordings from magpie's TestToolStrictRefusalWordings: a refusal of a
    // tool's strict is known however the path is written; a 400 over
    // strict's value or over a schema strict mode can't take is not.
    @Test("a refusal of a tool's strict is known however its path is written", arguments: [
        strictRefusal,
        "Unsupported Chat Completions API field: tools[0].***.strict",
        #"{"error":{"message":"Unknown parameter: 'tools[3].function.strict'.","type":"invalid_request_error","param":"tools[3].function.strict","code":"unknown_parameter"}}"#,
        #"{"error":{"message":"tools.0.function.strict: Extra inputs are not permitted"}}"#,
        #"{"detail":[{"type":"extra_forbidden","loc":["body","tools",0,"function","strict"],"msg":"Extra inputs are not permitted","input":false}]}"#,
        #"{"error":{"message":"Unrecognized request argument supplied: tools[0].strict"}}"#,
    ])
    func refusalWordings(body: String) {
        #expect(ToolStrictRefusal.isRefusal(body))
    }

    @Test("an invalid schema, an invalid strict value or another unsupported field is not a strict refusal", arguments: [
        #"{"error":{"message":"Invalid schema for function 'read': In context=(), 'additionalProperties' is required to be supplied and to be false.","type":"invalid_request_error","param":"tools[0].function.parameters","code":"invalid_function_parameters"}}"#,
        #"{"error":{"message":"Invalid type for 'tools[0].function.strict': expected a boolean, but got a string instead.","type":"invalid_request_error","param":"tools[0].function.strict","code":"invalid_type"}}"#,
        #"{"error":{"message":"Unsupported parameter: 'store'.","type":"invalid_request_error"}}"#,
    ])
    func notRefusalWordings(body: String) {
        #expect(!ToolStrictRefusal.isRefusal(body))
    }

    @Test("a refusing endpoint is asked again without strict, and the next turn goes without it at once; another still gets it")
    func retriedAndRemembered() async {
        let provider = "custom-provider-\(UUID().uuidString)"
        let refusing = StrictRefusingClient(refusal: Self.strictRefusal)

        let first = await Self.ask(refusing, provider: provider)
        #expect(first.stopReason == .stop)
        #expect(first.content == [.text(TextContent(text: "ok"))])
        #expect(refusing.bodies.count == 2)
        #expect(Self.toolsHaveStrict(refusing.bodies[0]))
        #expect(!Self.toolsHaveStrict(refusing.bodies[1]))
        #expect((refusing.bodies[1]["tools"] as? [[String: Any]])?.count == 2)

        let next = await Self.ask(refusing, provider: provider)
        #expect(next.stopReason == .stop)
        #expect(refusing.bodies.count == 3)
        #expect(!Self.toolsHaveStrict(refusing.bodies[2]))

        let lax = StrictRefusingClient(refusal: nil)
        let other = await Self.ask(lax, provider: "lax-\(UUID().uuidString)")
        #expect(other.stopReason == .stop)
        #expect(lax.bodies.count == 1)
        #expect(Self.toolsHaveStrict(lax.bodies[0]))
    }

    @Test("another 400 is reported as it came, with no retry and nothing remembered")
    func otherFailureNotRetried() async {
        let provider = "custom-provider-\(UUID().uuidString)"
        let refusal = #"{"error":{"message":"Invalid type for 'tools[0].function.strict': expected a boolean, but got a string instead.","type":"invalid_request_error","code":"invalid_type"}}"#
        let client = StrictRefusingClient(refusal: refusal)

        let result = await Self.ask(client, provider: provider)
        #expect(result.stopReason == .error)
        #expect(result.failure?.httpStatus == 400)
        #expect(result.failure?.message.hasPrefix("Invalid type for 'tools[0].function.strict'") == true)
        #expect(client.bodies.count == 1)

        _ = await Self.ask(client, provider: provider)
        #expect(client.bodies.count == 2)
        #expect(Self.toolsHaveStrict(client.bodies[1]))
    }
}
