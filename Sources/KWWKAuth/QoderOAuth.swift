import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Qoder (qoder.com) and Qoder CN (qoder.cn) subscriptions: the sign-in, the
// token refresh and the usage read, ported from magpie's `internal/qoder`
// (itself ported from CLIProxyAPI, which reverse-engineered the desktop
// client and checked it against live captures) and `internal/provider/
// qoder.go`. The chat wire lives in KWWKAI (`Sources/KWWKAI/Qoder`).
//
// A sign-in yields two independent token pairs. The `dt-` device token
// answers the account pages (user info, usage); it is traded once for the
// `jt-` job token that signs the model calls. Both rotate from their own
// refresh token. They are stored as:
//
//   access / refresh / expires   the pair that signs chat (job, or device
//                                when `deviceChat`)
//   extras.uid                   the account id every COSY envelope names
//   extras.machineId             generated at sign-in, kept with the account
//   extras.name / extras.email   from /api/v1/userinfo, either may be absent
//   extras.deviceToken / .deviceRefresh   the account-page pair
//   extras.deviceChat            true when the device token is the chat token

// MARK: - Sites

/// One Qoder deployment: the sign-in page, the account API and the inference
/// gateway, and the client id the sign-in names. The two sites share every
/// path and differ only in hosts and client id (magpie `endpoints.go`).
public struct QoderSite: Sendable, Hashable {
    /// The provider id its logins are stored under.
    public let id: String
    public let name: String
    /// Device-flow authorization page host.
    public let web: String
    /// Token poll, job token, refresh, user info and usage.
    public let openAPI: String
    /// Model list and chat.
    public let api: String
    public let clientID: String
    /// Goes on the authorization page; Qoder CN's CLI sends none.
    public let redirectURI: String?

    public init(
        id: String, name: String, web: String, openAPI: String, api: String,
        clientID: String, redirectURI: String?
    ) {
        self.id = id
        self.name = name
        self.web = web
        self.openAPI = openAPI
        self.api = api
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    /// qoder.com, signing in as the desktop client does.
    public static let global = QoderSite(
        id: "qoder", name: "Qoder", web: "https://qoder.com",
        openAPI: "https://openapi.qoder.sh", api: "https://api3.qoder.sh",
        clientID: "732aef47-9cf2-46a2-95fe-4cebb5d0d1fa", redirectURI: "qoder-app://"
    )

    /// qoder.cn, whose accounts (Alibaba Cloud or a phone number) exist only
    /// there. The hosts are the ones Qoder CN's CLI builds in, and the client
    /// id is that CLI's: the desktop id is not known to be registered on
    /// qoder.cn (magpie #349).
    public static let cn = QoderSite(
        id: "qoder-cn", name: "Qoder CN", web: "https://qoder.cn",
        openAPI: "https://openapi.qoder.com.cn", api: "https://gateway.qoder.com.cn",
        clientID: "e883ade2-e6e3-4d6d-adf7-f92ceff5fdcb", redirectURI: nil
    )

    public static let all: [QoderSite] = [.global, .cn]

    /// The site a provider id names; anything but Qoder CN is the global one.
    public static func of(_ id: String) -> QoderSite {
        id == cn.id ? cn : global
    }

    static let deviceSelectAccountsPath = "/device/selectAccounts"
    static let deviceTokenPollPath = "/api/v1/deviceToken/poll"
    static let deviceTokenRefreshPath = "/api/v1/deviceToken/refresh"
    static let jobTokenPath = "/api/v1/me/jobToken"
    static let jobTokenRefreshPath = "/api/v1/jobToken/refresh"
    static let userInfoPath = "/api/v1/userinfo"
    static let accountUsagePath = "/sash/api/v2/me/usage"
}

// MARK: - Token answers

/// What the account API says in a token answer, and how long it lasts.
enum QoderTokens {
    /// A token whose answer names no lifetime is taken to last a day
    /// (magpie `store.go`).
    static let defaultLifetimeMs: Int64 = 24 * 60 * 60 * 1000
    /// Refresh this long before the token lapses (magpie `refreshLead`).
    static let refreshLeadMs: Int64 = 5 * 60 * 1000

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ object: [String: Any], _ key: String) -> String {
        ((object[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When a job token stops being used: its `expires_in` is milliseconds.
    static func jobExpiry(_ object: [String: Any], now: Int64) -> Int64 {
        let life = (object["expires_in"] as? NSNumber)?.int64Value ?? 0
        return now + (life > 0 ? life : defaultLifetimeMs) - refreshLeadMs
    }

    /// When a device token stops being used: `expires_at` is an RFC 3339 date
    /// and `expires_in` is seconds, as Qoder's CLI reads them; either may be
    /// missing.
    static func deviceExpiry(_ object: [String: Any], now: Int64) -> Int64 {
        if let at = rfc3339(string(object, "expires_at")) {
            return Int64(at.timeIntervalSince1970 * 1000) - refreshLeadMs
        }
        let seconds = (object["expires_in"] as? NSNumber)?.int64Value ?? 0
        return now + (seconds > 0 ? seconds * 1000 : defaultLifetimeMs) - refreshLeadMs
    }

    private static func rfc3339(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static let jsonHeaders = ["Accept": "application/json", "Content-Type": "application/json"]

    /// The `dt-` device token a finished device flow returns.
    struct Device: Sendable {
        let token: String
        let refresh: String
        let userID: String
        let userName: String
        let expires: Int64

        init?(_ data: Data, now: Int64) {
            guard let object = QoderTokens.object(data) else { return nil }
            token = QoderTokens.string(object, "token")
            refresh = QoderTokens.string(object, "refresh_token")
            userID = QoderTokens.string(object, "user_id")
            userName = QoderTokens.string(object, "user_name")
            expires = QoderTokens.deviceExpiry(object, now: now)
            if token.isEmpty { return nil }
        }
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - Sign-in

extension OAuthLogin {
    /// How long the user has to approve in the browser (magpie
    /// `qoderSignInTimeout`).
    static let qoderSignInTimeout: TimeInterval = 15 * 60

    // Qoder's sign-in is a PKCE device flow with no user code: the page is
    // opened with the challenge, a nonce and a fresh machine id; the poll
    // then answers 200 with the device token once the user has approved.
    // Ported from magpie `oauth.go` + `QoderCompleteSignIn`.

    public static func loginQoder(
        site: QoderSite = .global,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient(),
        pollIntervalMs: UInt64 = 2000
    ) async throws -> OAuthCredentials {
        var raw = [UInt8](repeating: 0, count: 64)
        for i in raw.indices { raw[i] = UInt8.random(in: 0...255) }
        let verifier = PKCE.base64URL(Data(raw))
        let challenge = PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let nonce = UUID().uuidString.lowercased()
        // One machine id per sign-in, saved with the account: every later
        // request names the same one.
        let machineId = UUID().uuidString.lowercased()

        var query = [
            ("challenge", challenge),
            ("challenge_method", "S256"),
            ("client_id", site.clientID),
            ("machine_id", machineId),
            ("nonce", nonce),
        ]
        if let redirect = site.redirectURI { query.append(("redirect_uri", redirect)) }
        guard let page = URL(string: site.web + QoderSite.deviceSelectAccountsPath + "?" + qoderQuery(query)) else {
            throw OAuthError.invalidResponse("\(site.id) authorization page")
        }

        callbacks.onProgress("Sign in to \(site.name) in your browser — waiting for approval…")
        let device = try await present(page, callbacks: callbacks) {
            try await pollQoderDeviceToken(
                site: site, nonce: nonce, verifier: verifier, client: client, intervalMs: pollIntervalMs
            )
        }
        guard !device.userID.isEmpty else {
            throw OAuthError.invalidResponse("\(site.id) device token carried no user id")
        }

        callbacks.onProgress("exchanging the device token for a \(site.name) job token…")
        var extras: [String: JSONValue] = [
            "uid": .string(device.userID),
            "machineId": .string(machineId),
            "deviceToken": .string(device.token),
            "deviceRefresh": .string(device.refresh),
        ]
        var credentials: OAuthCredentials
        let (response, body) = try await client.request(
            url: URL(string: site.openAPI + QoderSite.jobTokenPath)!, method: "POST",
            headers: QoderTokens.jsonHeaders.merging(["Authorization": "Bearer \(device.token)"]) { $1 },
            body: try JSONSerialization.data(withJSONObject: ["clientId": site.clientID])
        )
        if response.statusCode == 200 {
            guard let job = QoderTokens.object(body), !QoderTokens.string(job, "token").isEmpty else {
                throw OAuthError.invalidResponse("\(site.id) job token: empty token in response")
            }
            credentials = OAuthCredentials(
                access: QoderTokens.string(job, "token"),
                refresh: QoderTokens.string(job, "refresh_token"),
                expires: QoderTokens.jobExpiry(job, now: QoderTokens.nowMs())
            )
        } else if site == .cn, (400..<500).contains(response.statusCode) {
            // Qoder CN's CLI never makes a job token: its device token is
            // what signs the model calls. If qoder.cn won't make one for the
            // CLI's client id, the account works the CLI's way (magpie #349).
            extras["deviceChat"] = .bool(true)
            credentials = OAuthCredentials(access: device.token, refresh: device.refresh, expires: device.expires)
        } else {
            let detail = String((String(data: body, encoding: .utf8) ?? "").prefix(512))
            throw OAuthError.refreshFailed("\(site.id) job token: status \(response.statusCode): \(detail)")
        }

        // The account page says who signed in; the label is worth having but
        // not worth failing a finished sign-in over.
        if let (info, data) = try? await client.request(
            url: URL(string: site.openAPI + QoderSite.userInfoPath)!, method: "GET",
            headers: ["Accept": "application/json", "Authorization": "Bearer \(device.token)"], body: nil
        ), (200..<300).contains(info.statusCode), let user = QoderTokens.object(data) {
            let email = QoderTokens.string(user, "email")
            let name = QoderTokens.string(user, "name")
            if !email.isEmpty { extras["email"] = .string(email) }
            if !name.isEmpty { extras["name"] = .string(name) }
        }
        if extras["name"] == nil, !device.userName.isEmpty {
            extras["name"] = .string(device.userName)
        }
        try Task.checkCancellation()
        credentials.extras = extras
        return credentials
    }

    /// Asks for the device token until the user has authorized it. Any answer
    /// but a 200 carrying a token means "not yet" (the poll answers 404 while
    /// it waits); only three thrown requests in a row give up.
    private static func pollQoderDeviceToken(
        site: QoderSite, nonce: String, verifier: String, client: HTTPClient, intervalMs: UInt64
    ) async throws -> QoderTokens.Device {
        let query = qoderQuery([("challenge_method", "S256"), ("nonce", nonce), ("verifier", verifier)])
        let url = URL(string: site.openAPI + QoderSite.deviceTokenPollPath + "?" + query)!
        let deadline = Date().addingTimeInterval(qoderSignInTimeout)
        var consecutiveErrors = 0
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let (response, body) = try await client.request(
                    url: url, method: "GET", headers: ["Accept": "application/json"], body: nil
                )
                consecutiveErrors = 0
                if response.statusCode == 200, let token = QoderTokens.Device(body, now: QoderTokens.nowMs()) {
                    return token
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    throw OAuthError.transport("\(site.id) device poll: \(error.localizedDescription)")
                }
            }
            try await Task.sleep(nanoseconds: intervalMs * 1_000_000)
        }
        throw OAuthLoginError.timedOut
    }

    /// A query string spelled the way the client's is: keys in order, every
    /// character outside the unreserved set escaped (`qoder-app://` goes as
    /// `qoder-app%3A%2F%2F`, which `URLComponents` would leave bare).
    private static func qoderQuery(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return items.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}

// MARK: - Refresh

/// Rotates a Qoder login's chat pair: the job token on
/// `/api/v1/jobToken/refresh`, or, for an account that chats with its device
/// token (`extras.deviceChat`), the device pair on
/// `/api/v1/deviceToken/refresh`. Both take `{"refresh_token"}` and spend it,
/// so the pair returned must be the one kept.
public struct QoderOAuthProvider: OAuthProvider {
    public let site: QoderSite
    public var id: String { site.id }
    public var name: String { site.name }

    public init(site: QoderSite = .global) {
        self.site = site
    }

    public func refresh(
        _ credentials: OAuthCredentials, using client: HTTPClient
    ) async throws -> OAuthCredentials {
        var refreshed = credentials
        if case .bool(true)? = credentials.extras["deviceChat"] {
            let pair = try await rotate(QoderSite.deviceTokenRefreshPath, credentials.refresh, client: client)
            refreshed.access = pair.token
            refreshed.refresh = pair.refresh
            refreshed.expires = pair.deviceExpires
            refreshed.extras["deviceToken"] = .string(pair.token)
            refreshed.extras["deviceRefresh"] = .string(pair.refresh)
            return refreshed
        }
        let pair = try await rotate(QoderSite.jobTokenRefreshPath, credentials.refresh, client: client)
        refreshed.access = pair.token
        refreshed.refresh = pair.refresh
        refreshed.expires = pair.jobExpires

        // The device pair serves only the account pages (usage) and lapses
        // on its own clock. magpie rotates it when a usage read is refused;
        // a usage read here never writes credentials, so it is rotated
        // alongside the job token instead. Chat does not depend on it: a
        // refusal leaves the old pair and the job rotation stands.
        if case .string(let deviceRefresh)? = credentials.extras["deviceRefresh"], !deviceRefresh.isEmpty,
           let device = try? await rotate(QoderSite.deviceTokenRefreshPath, deviceRefresh, client: client) {
            refreshed.extras["deviceToken"] = .string(device.token)
            refreshed.extras["deviceRefresh"] = .string(device.refresh)
        }
        return refreshed
    }

    private struct Pair {
        let token: String
        let refresh: String
        /// The lifetime read as a job token's and as a device token's.
        let jobExpires: Int64
        let deviceExpires: Int64
    }

    private func rotate(_ path: String, _ refreshToken: String, client: HTTPClient) async throws -> Pair {
        let (_, data) = try await OAuthRefreshError.post(
            provider: id, url: URL(string: site.openAPI + path)!,
            headers: QoderTokens.jsonHeaders,
            body: try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken]),
            client: client
        )
        let answer = QoderTokens.object(data) ?? [:]
        // A device refresh may name its token `device_token` instead of
        // `token`; magpie reads either (TestQoderLoginUsage).
        var token = QoderTokens.string(answer, "token")
        if token.isEmpty { token = QoderTokens.string(answer, "device_token") }
        let refresh = QoderTokens.string(answer, "refresh_token")
        guard !token.isEmpty, !refresh.isEmpty else {
            throw OAuthRefreshError(
                providerId: id, kind: .unavailable, status: nil, detail: "incomplete token pair"
            )
        }
        let now = QoderTokens.nowMs()
        return Pair(
            token: token, refresh: refresh,
            jobExpires: QoderTokens.jobExpiry(answer, now: now),
            deviceExpires: QoderTokens.deviceExpiry(answer, now: now)
        )
    }
}

// MARK: - Usage

/// `GET <openapi>/sash/api/v2/me/usage`, the desktop client's account usage
/// page, asked with the device token. Qoder meters credits, not time windows:
/// the plan's own credits are the main reading and every other pool (add-on,
/// shared, dedicated) keeps its name. Ported from magpie `usage.go` and
/// `parseQoderQuota`.
public struct QoderUsageReader: OAuthUsageReader {
    public let site: QoderSite
    public var providerId: String { site.id }

    public init(site: QoderSite = .global) {
        self.site = site
    }

    public func usage(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> [OAuthUsageWindow] {
        var deviceToken = ""
        if case .string(let stored)? = credentials.extras["deviceToken"] { deviceToken = stored }
        if deviceToken.isEmpty, case .bool(true)? = credentials.extras["deviceChat"] { deviceToken = credentials.access }
        guard !deviceToken.isEmpty else {
            throw OAuthUsageError.unavailable(
                providerId: providerId, status: nil, detail: "the stored login carries no device token"
            )
        }
        let (response, body) = try await OAuthUsage.get(
            URL(string: site.openAPI + QoderSite.accountUsagePath)!,
            headers: [
                "Accept": "application/json",
                "Authorization": "Bearer \(deviceToken)",
                "Cosy-ClientType": "10",
                "User-Agent": "Qoder",
            ],
            provider: providerId,
            client: client
        )
        guard let windows = Self.windows(fromJSON: body) else {
            throw OAuthUsageError.unavailable(
                providerId: providerId, status: response.statusCode, detail: "missing quota data"
            )
        }
        return windows
    }

    /// The normalization, separate from the wire for tests. Nil when the
    /// answer is not a usage envelope; an enterprise account has no personal
    /// pools and reads as none.
    public static func windows(fromJSON body: Data) -> [OAuthUsageWindow]? {
        guard let envelope = QoderTokens.object(body) else { return nil }
        switch envelope["displayMode"] as? String {
        case "enterprise":
            return []
        case "qoder":
            guard let usage = envelope["qoderUsage"] as? [String: Any] else { return nil }
            return windows(from: usage)
        default:
            return nil
        }
    }

    private static func windows(from usage: [String: Any]) -> [OAuthUsageWindow] {
        var windows: [OAuthUsageWindow] = []
        // A pool counts when it names a positive size (`total`, or `cap`) and
        // either what was used or what remains.
        func add(_ raw: Any?, id: String?, name: String) {
            guard let pool = raw as? [String: Any] else { return }
            func number(_ key: String) -> Double? { (pool[key] as? NSNumber)?.doubleValue }
            guard let total = number("total") ?? number("cap"), total > 0 else { return }
            let used: Double
            if let spent = number("used") {
                used = spent
            } else if let remaining = number("remaining") {
                used = total - remaining
            } else {
                return
            }
            guard used >= 0 else { return }
            let own = (pool["name"] as? String) ?? ""
            windows.append(OAuthUsageWindow(
                window: id == nil ? .primary : .secondary,
                usedPercent: 100 * used / total,
                resetsAt: nil,
                windowSeconds: nil,
                limitID: id,
                limitName: id == nil ? nil : (own.isEmpty ? name : own)
            ))
        }
        // Both spellings are read, as magpie reads them.
        func field(_ camel: String, _ snake: String) -> Any? { usage[camel] ?? usage[snake] }
        add(field("userQuota", "user_quota"), id: nil, name: "Credits")
        add(field("addOnQuota", "add_on_quota"), id: "addOnQuota", name: "Add-on credits")
        add(field("orgResourcePackage", "org_resource_package"), id: "orgResourcePackage", name: "Shared credits")
        let dedicated = field("dedicatedResourcePackages", "dedicated_resource_packages") as? [Any] ?? []
        for (index, pool) in dedicated.enumerated() {
            add(pool, id: "dedicatedResourcePackages.\(index)", name: "Dedicated credits")
        }
        return windows
    }
}
