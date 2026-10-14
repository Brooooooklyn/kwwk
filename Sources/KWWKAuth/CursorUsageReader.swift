import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`,
/// the Connect call (in JSON, with an empty message) behind cursor-agent's
/// usage view and magpie's Cursor card (its cursor plugin's `usage`).
///
/// A plan's included usage is counted over the billing period in two pools:
/// Cursor's own models (Auto, Composer, Grok — `autoPercentUsed`) and every
/// other model (`apiPercentUsed`), with `totalPercentUsed` over both. The
/// total is the subscription's window; the pools are its model buckets, each
/// under a `limitID` of its own. All three reset when the billing cycle ends.
///
/// An enterprise plan reports spend, not `planUsage`, and has no windows.
/// On-demand spend past the included usage (`spendLimitUsage`,
/// `GetHardLimit`) and the Grok Bot allowance are money and a separate
/// product; neither is a rate window, and neither is read.
public struct CursorUsageReader: OAuthUsageReader {
    public let providerId = "cursor"
    public let url: URL

    public init(
        url: URL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    ) {
        self.url = url
    }

    public func usage(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> [OAuthUsageWindow] {
        let (response, body) = try await OAuthUsage.get(
            url,
            headers: [
                "Authorization": "Bearer \(credentials.access)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
            ],
            method: "POST",
            body: Data("{}".utf8),
            provider: providerId,
            client: client
        )
        guard let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw OAuthUsageError.unavailable(
                providerId: providerId, status: response.statusCode, detail: "undecodable body"
            )
        }
        return Self.windows(from: payload)
    }

    /// The normalization, separate from the wire for tests.
    public static func windows(from payload: [String: Any]) -> [OAuthUsageWindow] {
        guard let plan = payload["planUsage"] as? [String: Any] else { return [] }
        // int64 milliseconds, which Connect's JSON writes as strings.
        func millis(_ key: String) -> Int64? {
            let value = (payload[key] as? String).flatMap(Int64.init) ?? (payload[key] as? NSNumber)?.int64Value
            return value.flatMap { $0 > 0 ? $0 : nil }
        }
        let resetsAt = millis("billingCycleEnd")
        let seconds: Int? = {
            guard let start = millis("billingCycleStart"), let end = resetsAt, end > start else { return nil }
            return Int((end - start) / 1000)
        }()
        // A percentage that is zero may be left out of the reply.
        func window(_ key: String, limitID: String? = nil, limitName: String? = nil) -> OAuthUsageWindow {
            OAuthUsageWindow(
                window: .primary,
                usedPercent: (plan[key] as? NSNumber)?.doubleValue ?? 0,
                resetsAt: resetsAt,
                windowSeconds: seconds,
                limitID: limitID,
                limitName: limitName
            )
        }
        return [
            window("totalPercentUsed"),
            window("autoPercentUsed", limitID: "cursor:auto", limitName: "Cursor Models"),
            window("apiPercentUsed", limitID: "cursor:api", limitName: "Other Models"),
        ]
    }
}
