import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

/// Replays every recorded provider error under `Fixtures/ProviderErrors`
/// through the parser that provider uses in production, and checks what the
/// failure is read as. See that directory's README for how a record captured
/// by `ProviderErrorCapture` becomes a fixture.
@Suite("Provider error fixtures")
struct ProviderErrorFixtureTests {
    struct Fixture: Decodable, CustomTestStringConvertible, Sendable {
        struct Expect: Decodable, Sendable {
            var category: String
            var credentialRejection: Bool
        }
        var name = ""
        var provider: String
        var parser: String
        var source: String
        var expect: Expect
        var request: ProviderErrorCapture.Record.Request
        var response: ProviderErrorCapture.Record.Response
        var testDescription: String { name }

        private enum CodingKeys: String, CodingKey { case provider, parser, source, expect, request, response }
    }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ProviderErrors")

    static func load() -> [Fixture] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  var fixture = try? JSONDecoder().decode(Fixture.self, from: data) else { return nil }
            fixture.name = name
            return fixture
        }
    }

    static func parse(_ fixture: Fixture) async throws -> ProviderFailure {
        let body = Data(fixture.response.body.utf8)
        let url = URL(string: fixture.request.url) ?? URL(fileURLWithPath: "/")
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: fixture.response.status, httpVersion: "HTTP/1.1",
            headerFields: fixture.response.headers
        ))
        switch fixture.parser {
        case "http":
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(body)
                continuation.finish()
            }
            return await ProviderFailure.http(response, body: stream)
        case "kiro":
            return KiroProvider.httpFailure(status: fixture.response.status, body: body)
        case "qoder":
            return QoderChatProvider.failure(status: fixture.response.status, body: body)
        case "cursor-http":
            return CursorConnectResponse.failureFromHTTP(status: fixture.response.status, body: fixture.response.body)
        case "cursor-end-stream":
            return try #require(CursorConnectResponse.failureFromEndStream(body))
        case let parser where parser.hasPrefix("devin:"):
            return DevinAgentProvider.unaryFailure(
                operation: String(parser.dropFirst("devin:".count)), response: response, body: body
            )
        default:
            Issue.record("unknown parser \(fixture.parser)")
            return ProviderFailure(message: "")
        }
    }

    @Test("the corpus is present and every file decodes")
    func corpusLoads() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path).filter { $0.hasSuffix(".json") }
        #expect(!files.isEmpty)
        #expect(Self.load().count == files.count)
    }

    @Test("each recorded error is read as recorded", arguments: Self.load())
    func replay(_ fixture: Fixture) async throws {
        #expect(!fixture.source.isEmpty)
        let failure = try await Self.parse(fixture)
        #expect(failure.category.rawValue == fixture.expect.category, "\(failure)")
        #expect(failure.isCredentialRejection == fixture.expect.credentialRejection, "\(failure)")
    }
}
