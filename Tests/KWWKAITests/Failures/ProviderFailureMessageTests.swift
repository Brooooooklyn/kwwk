import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

/// A failure's message is what a host shows people, so an NSError with a
/// localized description of its own reaches it as that sentence, not as
/// `Error Domain=… UserInfo={…}`; one without falls back to its description,
/// as before. The category and retry decision stay what they were.
@Suite("Provider failure message")
struct ProviderFailureMessageTests {
    private static let url = URL(string: "http://127.0.0.1:3425/v1/messages")!

    /// The shape FoundationNetworking gives a refused connection on Linux:
    /// curl's sentence on the error and on its underlying error, beside the
    /// failing URL.
    private static func refusedConnection(description: String?) -> NSError {
        var info: [String: Any] = [:]
        if let description { info[NSLocalizedDescriptionKey] = description }
        let inner = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: info)
        info[NSUnderlyingErrorKey] = inner
        info[NSURLErrorFailingURLErrorKey] = url
        info[NSURLErrorFailingURLStringErrorKey] = url.absoluteString
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: info)
    }

    private static func expectNoDump(_ text: String) {
        #expect(!text.contains("Error Domain="))
        #expect(!text.contains("UserInfo="))
        #expect(!text.contains(url.absoluteString))
    }

    @Test func refusedConnectionCapturesItsLocalizedDescription() {
        let curl = "Failed to connect to 127.0.0.1 port 3425 after 0 ms: Couldn't connect to server"
        let error = Self.refusedConnection(description: curl)
        let failure = ProviderFailure.capture(error)
        #expect(failure.message == error.localizedDescription)
        #expect(failure.message == curl)
        Self.expectNoDump(failure.message)
        #expect(failure.transportDomain == NSURLErrorDomain)
        #expect(failure.transportCode == NSURLErrorCannotConnectToHost)
        #expect(failure.category == .transport)
        #expect(failure.isRetryable)
        #expect(failure.outcome == .network)
    }

    // Foundation's own placeholder, "The operation couldn't be completed.
    // (NSURLErrorDomain error -1004.)", would hide the code and the URL.
    @Test func undescribedURLErrorFallsBackToItsDescription() {
        let error = Self.refusedConnection(description: nil)
        let failure = ProviderFailure.capture(error)
        #expect(failure.message == String(describing: error))
        #expect(failure.message != error.localizedDescription)
        #expect(failure.category == .transport)
        #expect(failure.isRetryable)
    }

    @Test func foundationURLErrorCapturesItsLocalizedDescription() {
        let error = URLError(.cannotConnectToHost, userInfo: [
            NSLocalizedDescriptionKey: "Could not connect to the server.",
            NSURLErrorFailingURLStringErrorKey: Self.url.absoluteString,
        ])
        let failure = ProviderFailure.capture(error)
        #expect(failure.message == "Could not connect to the server.")
        Self.expectNoDump(failure.message)
        #expect(failure.isRetryable)
    }

    // Linux URLSession reports an unmapped curl failure as a bare -1 whose
    // only evidence is curl's text; it is kept once, and still decides.
    @Test func curlTextOfABareUnknownStaysOnceAndDecides() {
        let curl = "transfer closed with outstanding read data remaining"
        let inner = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown,
                            userInfo: [NSLocalizedDescriptionKey: curl])
        let described = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [
            NSUnderlyingErrorKey: inner,
            NSLocalizedDescriptionKey: curl,
            NSURLErrorFailingURLStringErrorKey: Self.url.absoluteString,
        ])
        let failure = ProviderFailure.capture(described)
        #expect(failure.message == curl)
        #expect(failure.isRetryable)

        // With no sentence of its own the outer error falls back to its
        // description, which already carries the underlying curl text, so it
        // is not appended again.
        let bare = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSUnderlyingErrorKey: inner])
        let fromUnderlying = ProviderFailure.capture(bare)
        #expect(fromUnderlying.message == String(describing: bare))
        #expect(fromUnderlying.message.contains(curl))
        #expect(fromUnderlying.category == .transport)
    }

    @Test func unknownWrapperGivesItsOwnSentenceAndTheCauseDecides() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let wrapper = NSError(domain: "Proxy", code: 1, userInfo: [
            NSUnderlyingErrorKey: timeout,
            NSLocalizedDescriptionKey: "the proxy gave up",
        ])
        let failure = ProviderFailure.capture(wrapper)
        #expect(failure.message == "the proxy gave up")
        #expect(failure.category == .timeout)
        #expect(failure.isRetryable)
    }

    // A plain Swift error has no localized text; its own description is what
    // tells a dropped connection apart, so it is kept.
    @Test func plainSwiftErrorKeepsItsDescription() {
        let error = WebSocketKeepaliveError(reason: "no pong within 30s")
        let failure = ProviderFailure.capture(error)
        #expect(failure.message == "WebSocket connection keepalive failed: no pong within 30s")
        #expect(failure.category == .transport)
        #expect(failure.isRetryable)
    }

    private final class RefusingClient: HTTPClient, @unchecked Sendable {
        let error: any Error
        init(_ error: any Error) { self.error = error }
        func stream(
            url: URL,
            method: String,
            headers: [String: String],
            body: Data?,
            cancellation: CancellationHandle?
        ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
            throw error
        }
    }

    @Test func providerErrorMessageIsNoDump() async {
        let error = Self.refusedConnection(description: "Failed to connect to 127.0.0.1 port 3425: Connection refused")
        let provider = AnthropicProvider(client: RefusingClient(error), defaultAPIKey: "k")
        let model = Model(
            id: "claude-test", name: "Claude Test", api: "anthropic-messages", provider: "anthropic",
            baseURL: "http://127.0.0.1:3425",
            reasoning: false, input: [.text], contextWindow: 128_000, maxTokens: 1024
        )
        let stream = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        for await _ in stream {}
        let result = await stream.result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "Failed to connect to 127.0.0.1 port 3425: Connection refused")
        #expect(result.failure?.message == result.errorMessage)
        #expect(result.failure?.category == .transport)
    }
}
