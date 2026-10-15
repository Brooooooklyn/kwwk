import Foundation
import Testing
@testable import KWWKAuth

/// The replies are the Grok Build backend's as magpie's Grok plugin tests
/// give them (magpie-plugins packages/grok usage.test.mjs, from magpie's
/// grok_usage_test.go).
@Suite("Subscription usage — xAI Grok")
struct XaiUsageTests {
    @Test("SuperGrok's week and its capped on-demand spending")
    func weekAndOnDemand() throws {
        let body = Data(#"""
        {"config": {
          "creditUsagePercent": 42.5,
          "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY",
                            "start": "2026-09-21T02:17:59.504011+00:00", "end": "2026-09-28T02:17:59.504011+00:00"},
          "onDemandCap": {"val": 2000},
          "onDemandUsed": {"val": 500},
          "billingPeriodEnd": "2026-09-28T02:17:59.504011+00:00"
        }}
        """#.utf8)
        #expect(try XaiUsageReader.windows(fromJSON: body) == [
            OAuthUsageWindow(window: .sevenDay, usedPercent: 42.5, resetsAt: 1_790_561_879_504, windowSeconds: 604_800),
            OAuthUsageWindow(
                window: .secondary, usedPercent: 25, resetsAt: 1_790_561_879_504, windowSeconds: nil,
                limitID: "on-demand", limitName: "On-demand"
            ),
        ])
    }

    @Test("a month with no on-demand cap is one window, and not the weekly one")
    func monthWithoutCap() throws {
        let body = Data(#"""
        {"config": {"currentPeriod": {"type": "USAGE_PERIOD_TYPE_MONTHLY", "end": "2026-10-01T00:00:00+00:00"},
                    "onDemandCap": {"val": 0}}}
        """#.utf8)
        #expect(try XaiUsageReader.windows(fromJSON: body) == [
            OAuthUsageWindow(window: .primary, usedPercent: 0, resetsAt: 1_790_812_800_000, windowSeconds: 2_592_000),
        ])
    }

    @Test("no current period reads the billing period; an unknown one has no length and no made-up reset")
    func billingPeriodAndUnknownPeriod() throws {
        let billing = Data(#"{"config":{"creditUsagePercent":7,"billingPeriodEnd":"2026-10-05T00:00:00Z"}}"#.utf8)
        #expect(try XaiUsageReader.windows(fromJSON: billing) == [
            OAuthUsageWindow(window: .primary, usedPercent: 7, resetsAt: 1_791_158_400_000, windowSeconds: nil),
        ])
        let hourly = Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_HOURLY","end":"soon"}}}"#.utf8)
        #expect(try XaiUsageReader.windows(fromJSON: hourly) == [
            OAuthUsageWindow(window: .primary, usedPercent: 0, resetsAt: nil, windowSeconds: nil),
        ])
        // Nothing about an allowance is not a 0%-used one.
        #expect(try XaiUsageReader.windows(fromJSON: Data("{}".utf8)).isEmpty)
    }

    @Test("asks the Grok Build backend with the Bearer token alone")
    func request() async throws {
        let client = QueuedHTTPClient([.response(status: 200, body: #"{"config":{"creditUsagePercent":1}}"#)])
        let windows = try await XaiUsageReader().usage(
            OAuthCredentials(access: "tok-2", refresh: "", expires: .max),
            using: client
        )
        #expect(windows.map(\.usedPercent) == [1])
        #expect(client.requests[0].url.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(client.requests[0].method == "GET")
        #expect(client.requests[0].headers == ["Authorization": "Bearer tok-2", "Accept": "application/json"])
        #expect(OAuthUsage.readers["xai"] is XaiUsageReader)
    }

    @Test("a refused token, a reply that is not JSON and a 429 are usage failures, never the login's")
    func failures() async throws {
        let creds = OAuthCredentials(access: "t", refresh: "", expires: .max)
        await #expect(throws: OAuthUsageError.unavailable(providerId: "xai", status: 401, detail: "")) {
            _ = try await XaiUsageReader().usage(creds, using: QueuedHTTPClient([.response(status: 401, body: "")]))
        }
        await #expect(throws: OAuthUsageError.unavailable(providerId: "xai", status: 200, detail: "undecodable body")) {
            _ = try await XaiUsageReader().usage(
                creds,
                using: QueuedHTTPClient([.response(status: 200, body: "<html>oops</html>")])
            )
        }
        await #expect(throws: OAuthUsageError.rateLimited(retryAfterSeconds: 120)) {
            _ = try await XaiUsageReader().usage(
                creds,
                using: QueuedHTTPClient([.response(status: 429, body: "", headers: ["Retry-After": "120"])])
            )
        }
    }
}
