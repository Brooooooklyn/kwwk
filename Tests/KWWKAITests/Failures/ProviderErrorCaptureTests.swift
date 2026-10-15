import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI
@testable import KWWKAuth

@Suite("Provider error capture", .serialized)
struct ProviderErrorCaptureTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-capture-\(UUID().uuidString)")
    }

    /// Records under `directory`, optionally only those for `url`: capture is
    /// process-wide, so another suite's 4xx may land here while one runs.
    private func records(in directory: URL, for url: String? = nil) throws -> [ProviderErrorCapture.Record] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted().map {
            try JSONDecoder().decode(ProviderErrorCapture.Record.self,
                                     from: Data(contentsOf: directory.appendingPathComponent($0)))
        }.filter { url == nil || $0.request.url == url }
    }

    private func stream(_ chunks: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
            continuation.finish()
        }
    }

    @Test("a record keeps the body verbatim and nothing that authenticates")
    func recordRedacts() throws {
        let url = try #require(URL(string: "https://user:pw@example.com/v1/models/x:generate?key=SECRET&alt=sse#frag"))
        let record = ProviderErrorCapture.record(
            method: "POST", url: url, status: 401,
            headers: ["Authorization": "Bearer SECRET", "Set-Cookie": "s=SECRET", "Content-Type": "application/json",
                      "WWW-Authenticate": #"Bearer error="invalid_token""#, "x-request-id": "req-1"],
            body: Data(#"{"error":"bad token"}"#.utf8)
        )
        #expect(record.request.url == "https://example.com/v1/models/x:generate?key=REDACTED&alt=REDACTED")
        #expect(record.response.headers == [
            "content-type": "application/json", "www-authenticate": #"Bearer error="invalid_token""#, "x-request-id": "req-1",
        ])
        #expect(record.response.body == #"{"error":"bad token"}"#)
        #expect(!record.response.bodyTruncated)
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(!encoded.contains("SECRET"))
    }

    @Test("an error response is saved and its body still reaches the caller intact")
    func teeSavesAndReplays() async throws {
        let directory = tempDirectory()
        ProviderErrorCapture.enable(directory: directory)
        defer { ProviderErrorCapture.disable() }
        let url = try #require(URL(string: "https://api.x.ai/v1/chat/completions"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil,
                                                    headerFields: ["Content-Type": "application/json"]))
        let body = #"{"code":"unauthenticated:bad-credentials","error":"The OAuth2 access token could not be validated."}"#

        let replay = await ProviderErrorCapture.tee(method: "POST", url: url, response: response,
                                                    body: stream([String(body.prefix(20)), String(body.dropFirst(20))]))
        var received = Data()
        for try await chunk in replay { received.append(chunk) }

        #expect(String(decoding: received, as: UTF8.self) == body)
        let saved = try records(in: directory, for: url.absoluteString)
        #expect(saved.count == 1)
        #expect(saved.first?.response.status == 403)
        #expect(saved.first?.response.body == body)
        #expect(saved.first?.request.url == "https://api.x.ai/v1/chat/completions")
    }

    @Test("success responses pass through and nothing is written")
    func successIsUntouched() async throws {
        let directory = tempDirectory()
        ProviderErrorCapture.enable(directory: directory)
        defer { ProviderErrorCapture.disable() }
        let url = try #require(URL(string: "https://example.com/ok"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))

        let passed = await ProviderErrorCapture.tee(method: "POST", url: url, response: response, body: stream(["data: 1\n\n"]))
        var received = Data()
        for try await chunk in passed { received.append(chunk) }

        #expect(String(decoding: received, as: UTF8.self) == "data: 1\n\n")
        #expect(try records(in: directory, for: url.absoluteString).isEmpty)
    }

    @Test("a body past the bound is cut in the record but not for the caller")
    func longBodyIsBoundedInRecordOnly() async throws {
        let directory = tempDirectory()
        ProviderErrorCapture.enable(directory: directory)
        defer { ProviderErrorCapture.disable() }
        let url = try #require(URL(string: "https://example.com/page"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 502, httpVersion: nil, headerFields: nil))
        let chunk = String(repeating: "x", count: 16 * 1024)
        let chunks = Array(repeating: chunk, count: 6)

        let replay = await ProviderErrorCapture.tee(method: "GET", url: url, response: response, body: stream(chunks))
        var received = 0
        for try await part in replay { received += part.count }

        #expect(received == 6 * 16 * 1024)
        let saved = try #require(try records(in: directory, for: url.absoluteString).first)
        #expect(saved.response.body.utf8.count == ProviderErrorCapture.maxBodyBytes)
        #expect(saved.response.bodyTruncated)
    }

    @Test("only the newest records are kept")
    func retentionKeepsNewest() throws {
        let directory = tempDirectory()
        let url = try #require(URL(string: "https://example.com/x"))
        for second in 0..<5 {
            let record = ProviderErrorCapture.record(
                method: "POST", url: url, status: 500, headers: [:], body: Data("\(second)".utf8),
                now: Date(timeIntervalSince1970: 1_800_000_000 + Double(second))
            )
            ProviderErrorCapture.write(record, to: directory, retain: 3)
        }
        #expect(try records(in: directory).map(\.response.body) == ["2", "3", "4"])
    }

    @Test("off unless enabled")
    func offByDefault() {
        ProviderErrorCapture.disable()
        #expect(ProviderErrorCapture.directory == nil)
    }
}
