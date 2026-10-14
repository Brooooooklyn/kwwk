import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`, the
/// endpoint the Grok Build CLI's `/usage` reads with nothing but the Bearer
/// token (magpie-plugins packages/grok index.mjs `usage`, usage.test.mjs;
/// magpie grok_usage.go before it).
///
/// `config.creditUsagePercent` is how much of the current period's credits
/// is spent: `currentPeriod` names the period (weekly for SuperGrok) and
/// when it ends; without one the billing period's end stands in. On-demand
/// spending is a second window when the account has a cap for it.
///
/// It says nothing of a plan's rate limit: a free account reads 0% used
/// while its requests are answered 429 (plugin 0.1.7).
public struct XaiUsageReader: OAuthUsageReader {
    public let providerId = "xai"
    public let url: URL

    public init(url: URL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!) {
        self.url = url
    }

    public func usage(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> [OAuthUsageWindow] {
        let (response, body) = try await OAuthUsage.get(
            url,
            headers: [
                "Authorization": "Bearer \(credentials.access)",
                "Accept": "application/json",
            ],
            provider: providerId,
            client: client
        )
        guard let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw OAuthUsageError.unavailable(
                providerId: providerId,
                status: response.statusCode,
                detail: "undecodable body"
            )
        }
        return Self.windows(from: payload)
    }

    /// The normalization, separate from the wire for tests.
    public static func windows(fromJSON body: Data) throws -> [OAuthUsageWindow] {
        guard let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an object"))
        }
        return windows(from: payload)
    }

    /// The period's credits, then on-demand spending when it is capped. Only
    /// a weekly period takes the weekly name; a day, a month and a period
    /// Grok does not name stay `primary`, with the length when it is known.
    /// A reply with no `config` describes no allowance at all.
    static func windows(from payload: [String: Any]) -> [OAuthUsageWindow] {
        guard let config = payload["config"] as? [String: Any] else { return [] }
        var kind = OAuthUsageWindowKind.primary
        var seconds: Int?
        var end = config["billingPeriodEnd"] as? String
        if let period = config["currentPeriod"] as? [String: Any] {
            let type = (period["type"] as? String ?? "")
            switch type.hasPrefix(periodPrefix) ? String(type.dropFirst(periodPrefix.count)) : type {
            case "DAILY": seconds = 24 * 60 * 60
            case "WEEKLY": (kind, seconds) = (.sevenDay, 7 * 24 * 60 * 60)
            case "MONTHLY": seconds = 30 * 24 * 60 * 60
            default: break
            }
            end = period["end"] as? String
        }
        let resetsAt = end.flatMap(millis(fromRFC3339:))
        var windows = [OAuthUsageWindow(
            window: kind,
            usedPercent: number(config["creditUsagePercent"]),
            resetsAt: resetsAt,
            windowSeconds: seconds
        )]
        let cap = number((config["onDemandCap"] as? [String: Any])?["val"])
        if cap > 0 {
            let used = number((config["onDemandUsed"] as? [String: Any])?["val"])
            windows.append(OAuthUsageWindow(
                window: .secondary,
                usedPercent: 100 * used / cap,
                resetsAt: resetsAt,
                windowSeconds: nil,
                limitID: "on-demand",
                limitName: "On-demand"
            ))
        }
        return windows
    }

    private static let periodPrefix = "USAGE_PERIOD_TYPE_"

    /// A JSON number, 0 for anything else: the plugin counts no string.
    private static func number(_ value: Any?) -> Double {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return 0 }
        return number
    }

    /// Grok stamps microseconds and a numeric offset
    /// (`2026-09-28T02:17:59.504011+00:00`), which no `ISO8601DateFormatter`
    /// option reads whole: the fraction is parsed apart from the rest.
    /// Anything that is not a timestamp is no reset.
    private static func millis(fromRFC3339 text: String) -> Int64? {
        var whole = text
        var fraction = 0.0
        if let dot = whole.firstIndex(of: "."),
           let zone = whole[dot...].firstIndex(where: { "Zz+-".contains($0) }) {
            let digits = whole[whole.index(after: dot)..<zone]
            guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }), let parsed = Double("0.\(digits)") else {
                return nil
            }
            fraction = parsed
            whole.removeSubrange(dot..<zone)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: whole) else { return nil }
        return Int64(date.timeIntervalSince1970) * 1000 + Int64((fraction * 1000).rounded(.down))
    }
}
