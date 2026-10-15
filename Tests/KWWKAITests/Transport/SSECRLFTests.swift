import Foundation
import Testing
@testable import KWWKAI

/// SSE framed with CRLF, as Gemini's `streamGenerateContent` sends it. In
/// Swift "\r\n" is one Character, so the parser must find line ends by
/// Unicode scalar.
@Suite("SSE with CRLF line ends")
struct SSECRLFTests {
    @Test("CRLF-framed events split like LF-framed ones")
    func crlfFraming() {
        let parser = SSEParser()
        parser.ingest("event: a\r\ndata: one\r\n\r\ndata: two\r\ndata: three\r\n\r\n")
        let messages = parser.drain()
        #expect(messages.map(\.event) == ["a", "message"])
        #expect(messages.map(\.data) == ["one", "two\nthree"])
    }

    @Test("a CRLF split between \\r and \\n across reads still ends the line once")
    func crlfAcrossChunks() {
        let parser = SSEParser()
        parser.ingest(bytes: Data("data: one\r".utf8))
        parser.ingest(bytes: Data("\n\r".utf8))
        parser.ingest(bytes: Data("\ndata: two\r\n\r\n".utf8))
        #expect(parser.drain().map(\.data) == ["one", "two"])
    }

    /// Trimmed from what gemini-3.8-flash streamed on 2026-10-14.
    static let geminiCRLF =
        "data: {\"candidates\": [{\"content\": {\"parts\": [{\"text\": \"ok\"}],\"role\": \"model\"},\"index\": 0}]," +
        "\"usageMetadata\": {\"promptTokenCount\": 3,\"candidatesTokenCount\": 1,\"totalTokenCount\": 75}}\r\n\r\n" +
        "data: {\"candidates\": [{\"content\": {\"parts\": [{\"text\": \"\",\"thoughtSignature\": \"Eq8DCqwD\"}],\"role\": \"model\"}," +
        "\"finishReason\": \"STOP\",\"index\": 0}],\"usageMetadata\": {\"promptTokenCount\": 3,\"candidatesTokenCount\": 1," +
        "\"totalTokenCount\": 75,\"thoughtsTokenCount\": 71}}\r\n\r\n"

    @Test("a CRLF Gemini reply reads to its text and STOP")
    func geminiReply() async {
        let model = Model(
            id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", api: "google-generative-ai", provider: "google",
            baseURL: "https://generativelanguage.googleapis.com", reasoning: true, input: [.text],
            contextWindow: 1_048_576, maxTokens: 65_536
        )
        let provider = GoogleGeminiProvider(client: StubSSEClient(body: Self.geminiCRLF), defaultAPIKey: "k")
        let result = await provider.stream(
            model: model, context: Context(messages: [.user(UserMessage(text: "say ok"))]), options: nil
        ).result()
        #expect(result.stopReason == .stop)
        #expect(result.content.contains { if case .text(let t) = $0 { return t.text == "ok" } else { return false } })
    }
}
