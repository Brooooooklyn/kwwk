import Foundation
import Testing
import KWWKAuth

@Suite("Cursor plan usage")
struct CursorUsageTests {
    private func windows(_ json: String) throws -> [OAuthUsageWindow] {
        CursorUsageReader.windows(from: try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        ))
    }

    /// GetCurrentPeriodUsage as it answered a Free account, 2026-10-13
    /// (the bucket's model list cut short).
    @Test("the period's total and its two pools, reset at the cycle's end")
    func periodWindows() throws {
        let got = try windows(#"""
        {"billingCycleStart":"1791617241814","billingCycleEnd":"1794295641814",
         "planUsage":{"totalSpend":28,"bonusSpend":28,"remainingBonus":false,
                      "autoPercentUsed":28.000000000000004,"apiPercentUsed":0,"totalPercentUsed":14.000000000000002},
         "spendLimitUsage":{"pooledLimit":"0","pooledRemaining":"0","individualLimit":0,"limitType":"user"},
         "displayMessage":"You've used 0% of your included usage",
         "autoBucketModels":["default","composer-1.5","composer-2"]}
        """#)
        let month = 2_678_400
        #expect(got == [
            OAuthUsageWindow(window: .primary, usedPercent: 14.000000000000002, resetsAt: 1_794_295_641_814, windowSeconds: month),
            OAuthUsageWindow(window: .primary, usedPercent: 28.000000000000004, resetsAt: 1_794_295_641_814,
                             windowSeconds: month, limitID: "cursor:auto", limitName: "Cursor Models"),
            OAuthUsageWindow(window: .primary, usedPercent: 0, resetsAt: 1_794_295_641_814,
                             windowSeconds: month, limitID: "cursor:api", limitName: "Other Models"),
        ])
    }

    /// The plugin's usage.test.mjs "the period's three windows": no cycle
    /// start, and a pool left out of the reply is one not touched.
    @Test("a reply without the cycle's start or a pool still reads")
    func sparseReply() throws {
        let got = try windows(#"{"billingCycleEnd":"1792833042000","planUsage":{"autoPercentUsed":12.5,"totalPercentUsed":20}}"#)
        #expect(got.map(\.usedPercent) == [20, 12.5, 0])
        #expect(got.allSatisfy { $0.resetsAt == 1_792_833_042_000 && $0.windowSeconds == nil })
        #expect(try windows(#"{"planUsage":{"totalPercentUsed":130}}"#).first?.usedPercent == 100)
        #expect(try windows(#"{"planUsage":{"totalPercentUsed":3}}"#).first?.resetsAt == nil)
    }

    @Test("a plan that reports spend instead has no windows")
    func enterprise() throws {
        #expect(try windows(#"{"billingCycleEnd":"1792833042000","spendLimitUsage":{"limitType":"team"}}"#).isEmpty)
    }

    @Test("usage is asked as a Connect call with only the access token")
    func requestAndFailures() async throws {
        let credentials = OAuthCredentials(access: "access", refresh: "never-send", expires: .max)
        let client = QueuedHTTPClient([.response(status: 200, body: #"{"planUsage":{"totalPercentUsed":1}}"#)])
        let got = try await CursorUsageReader().usage(credentials, using: client)
        #expect(got.count == 3)
        let request = try #require(client.requests.first)
        #expect(request.method == "POST" && request.body == Data("{}".utf8))
        #expect(request.url.absoluteString == "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")
        #expect(client.header("Authorization", request: 0) == "Bearer access")
        #expect(client.header("Connect-Protocol-Version", request: 0) == "1")
        #expect(client.header("Content-Type", request: 0) == "application/json")

        let limited = QueuedHTTPClient([.response(status: 429, body: "", headers: ["Retry-After": "30"])])
        await #expect(throws: OAuthUsageError.rateLimited(retryAfterSeconds: 30)) {
            _ = try await CursorUsageReader().usage(credentials, using: limited)
        }
        let refused = QueuedHTTPClient([.response(status: 401, body: #"{"code":"unauthenticated"}"#)])
        await #expect(throws: OAuthUsageError.unavailable(
            providerId: "cursor", status: 401, detail: #"{"code":"unauthenticated"}"#
        )) {
            _ = try await CursorUsageReader().usage(credentials, using: refused)
        }
        let garbled = QueuedHTTPClient([.response(status: 200, body: "<html>")])
        await #expect(throws: OAuthUsageError.unavailable(providerId: "cursor", status: 200, detail: "undecodable body")) {
            _ = try await CursorUsageReader().usage(credentials, using: garbled)
        }
    }

    @Test("Cursor's reader is one of the subscriptions kwwk reads")
    func registered() {
        #expect(OAuthUsage.readers["cursor"] is CursorUsageReader)
    }
}
