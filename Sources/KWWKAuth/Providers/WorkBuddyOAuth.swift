import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Tencent's WorkBuddy, the desktop agent packaged from CodeBuddy Code. Its
// plan (the CodeBuddy plan) is served on an OpenAI-compatible endpoint under
// the account's own access token, a JWT the account refreshes, with the
// account's id and domain in headers.
//
// Ported from magpie's `internal/provider/workbuddy.go` and, where the two
// differ, from the plugin magpie now serves WorkBuddy through
// (`@magpie-community/opencode-workbuddy-auth` 0.1.15): the enterprise
// headers come from the plugin alone.

/// One WorkBuddy build. The China build and WorkBuddy AI, the international
/// one, are separate subscriptions: the same API and sign-in at their own
/// endpoints, with their own accounts and models.
public struct WorkBuddySite: Sendable, Hashable {
    /// The `OAuthStore` key, and the `model.provider` scope.
    public let id: String
    public let name: String
    /// The API root: sign-in, billing and the product config sit under it,
    /// chats under its `/v2`.
    public let endpoint: String
    /// What the sign-in is told the client is.
    public let platform: String

    public init(id: String, name: String, endpoint: String, platform: String) {
        self.id = id
        self.name = name
        var root = endpoint
        while root.hasSuffix("/") { root.removeLast() }
        self.endpoint = root
        self.platform = platform
    }

    /// The China build (codebuddy.cn's plan), on copilot.tencent.com.
    public static let china = WorkBuddySite(
        id: "workbuddy",
        name: "WorkBuddy",
        endpoint: "https://copilot.tencent.com",
        platform: "workbuddy"
    )
    /// WorkBuddy AI, the international build (codebuddy.ai's plan).
    public static let international = WorkBuddySite(
        id: "workbuddy-ai",
        name: "WorkBuddy AI",
        endpoint: "https://www.workbuddy.ai",
        platform: "workbuddy-ai"
    )
    public static let all: [WorkBuddySite] = [.china, .international]

    public static func site(id: String) -> WorkBuddySite? {
        all.first { $0.id == id }
    }

    /// The base URL chats are sent under.
    public var chatBaseURL: String { endpoint + "/v2" }

    func url(_ path: String) -> URL {
        URL(string: endpoint + path)!
    }
}

/// Constants and the pieces the sign-in, the refresh, the usage read and the
/// chat provider share.
public enum WorkBuddyOAuth {
    /// The plugin version the sign-in page is told.
    public static let appVersion = "2.0.0"
    /// The WorkBuddy desktop version requests go out as. copilot.tencent.com's
    /// gateway answers code 10085 ("请求不合法") to a User-Agent it doesn't
    /// know, on chat and billing alike (magpie 6294dd0a).
    public static let clientVersion = "5.5.6"
    public static let userAgent = "WorkBuddy/\(clientVersion)"

    /// "Not ready yet" on the sign-in's two polls: the token, then the account.
    static let tokenPendingCode = 11217
    static let accountPendingCode = 12151
    /// How long the sign-in page is waited on.
    static let signInWindow: TimeInterval = 5 * 60
    /// The access token lives an hour; one whose end isn't stated is taken to.
    static let defaultLifetimeMs: Int64 = 60 * 60 * 1000
    /// A token is renewed this long before its end, the lead magpie renews a
    /// WorkBuddy sign-in with (the plugin's `refreshLead`).
    static let expiryMarginMs: Int64 = 5 * 60 * 1000

    /// The headers that name the account on every request made for it: its
    /// id, its domain, and for an enterprise (team) account the enterprise.
    /// Without the last two WorkBuddy answers as the personal account, with
    /// the personal plan's models (magpie-community/plugins #75).
    public static func accountHeaders(_ credentials: OAuthCredentials, site: WorkBuddySite) -> [String: String] {
        var headers = [
            "X-User-Id": string(credentials.extras["uid"]) ?? "",
            "X-Domain": domain(credentials.extras, site: site),
        ]
        if let enterprise = string(credentials.extras["enterpriseId"]) {
            headers["X-Enterprise-Id"] = enterprise
            headers["X-Tenant-Id"] = enterprise
        }
        return headers
    }

    /// The `X-Domain` a request carries: the account's own, or the
    /// endpoint's authority.
    static func domain(_ extras: [String: JSONValue], site: WorkBuddySite) -> String {
        string(extras["domain"]) ?? site.url("").host ?? ""
    }

    static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Takes a token WorkBuddy gave, at sign-in or refresh, into the stored
    /// credentials. Its times come as at-milliseconds or in-seconds; a
    /// refresh that doesn't rotate the refresh token keeps the old one. Nil
    /// when the answer carries no access token.
    static func merge(
        _ token: [String: Any],
        into base: OAuthCredentials?,
        now: Date
    ) -> OAuthCredentials? {
        guard let access = token["accessToken"] as? String, !access.isEmpty else { return nil }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        func time(at: String, in seconds: String) -> Int64? {
            if let at = int64(token[at]), at > 0 { return at }
            if let seconds = int64(token[seconds]), seconds > 0 { return nowMs + seconds * 1000 }
            return nil
        }
        var extras = base?.extras ?? [:]
        for key in ["domain", "tokenType"] {
            if let value = token[key] as? String, !value.isEmpty { extras[key] = .string(value) }
        }
        if let refreshEnds = time(at: "refreshExpiresAt", in: "refreshExpiresIn") {
            extras["refreshExpiresAt"] = .int(Int(refreshEnds))
        }
        let rotated = token["refreshToken"] as? String ?? ""
        return OAuthCredentials(
            access: access,
            refresh: rotated.isEmpty ? (base?.refresh ?? "") : rotated,
            expires: (time(at: "expiresAt", in: "expiresIn")
                ?? OAuth.jwtExpiryMillis(access)
                ?? (nowMs + defaultLifetimeMs)) - expiryMarginMs,
            extras: extras
        )
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as Int: Int64(number)
        case let number as Int64: number
        case let number as Double: Int64(number)
        case let text as String: Int64(text)
        default: nil
        }
    }
}

/// WorkBuddy's JSON endpoints, which wrap what they say in `{code, msg,
/// data}`: code 0 is a success, whatever the HTTP status says.
enum WorkBuddyAPI {
    /// A refusal: WorkBuddy's business code (0 when it gave none), the HTTP
    /// status, and its words.
    struct Failure: Error, LocalizedError, Equatable {
        let code: Int
        let status: Int
        let message: String

        var errorDescription: String? { message }
    }

    static let jsonHeaders = [
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": WorkBuddyOAuth.userAgent,
    ]

    /// The `data` of an answered call; a `Failure` for a non-zero code or an
    /// error status. Transport errors pass through.
    static func call(
        _ site: WorkBuddySite,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        client: HTTPClient
    ) async throws -> Any? {
        let (response, data) = try await client.request(
            url: site.url(path),
            method: method,
            headers: jsonHeaders.merging(headers) { _, given in given },
            body: body
        )
        return try unwrap(data, status: response.statusCode)
    }

    static func unwrap(_ data: Data, status: Int) throws -> Any? {
        let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // The code comes as a number, and from some endpoints as a string.
        let code = WorkBuddyOAuth.int64(envelope["code"]).map(Int.init) ?? 0
        let said = envelope["msg"] as? String ?? ""
        if code != 0 {
            throw Failure(code: code, status: status, message: said.isEmpty ? "error \(code)" : said)
        }
        guard (200..<300).contains(status) else {
            throw Failure(code: 0, status: status, message: said.isEmpty ? "HTTP \(status)" : said)
        }
        let payload = envelope["data"]
        return payload is NSNull ? nil : payload
    }
}

// MARK: - Sign-in

extension OAuthLogin {
    /// WorkBuddy's own external-link sign-in, as its desktop app makes it:
    /// ask for a state and a page, open the page (Tencent's, on
    /// login.codebuddy.cn or www.workbuddy.ai), then ask every second for the
    /// token and after it the account, until the user has signed in. There is
    /// no callback and no client id: the state names the sign-in.
    public static func loginWorkBuddy(
        site: WorkBuddySite,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient(),
        // Waits between two asks; tests pass their own, with a clock.
        pollSleep: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> OAuthCredentials {
        callbacks.onProgress("requesting a \(site.name) sign-in page…")
        let started: [String: Any]?
        do {
            started = try await WorkBuddyAPI.call(
                site,
                method: "POST",
                path: "/v2/plugin/auth/state?" + OAuth.urlEncodedForm(["platform": site.platform]),
                headers: [
                    "X-No-Authorization": "true",
                    "X-No-User-Id": "true",
                    "X-No-Enterprise-Id": "true",
                    "X-No-Department-Info": "true",
                ],
                body: Data("{}".utf8),
                client: client
            ) as? [String: Any]
        } catch let failure as WorkBuddyAPI.Failure {
            throw OAuthLoginError.denied("\(site.name): \(failure.message)")
        }
        guard let state = started?["state"] as? String, !state.isEmpty,
              var page = (started?["authUrl"] as? String).flatMap({ URLComponents(string: $0) }),
              page.scheme == "https" else {
            throw OAuthError.invalidResponse("\(site.name) gave no sign-in page")
        }
        // The page is told the client's version and a session of its own.
        // The rest of its query stays as WorkBuddy encoded it: read decoded
        // and written back, a `%2B` in its state would go out as `+`, which
        // the page reads as a space.
        let ours = [
            URLQueryItem(name: "version", value: WorkBuddyOAuth.appVersion),
            URLQueryItem(name: "loginSessionId", value: PKCE.randomHex()),
        ]
        page.percentEncodedQueryItems = (page.percentEncodedQueryItems ?? [])
            .filter { item in !ours.contains { $0.name == item.name } } + ours
        guard let pageURL = page.url else {
            throw OAuthError.invalidResponse("\(site.name) gave no sign-in page")
        }

        callbacks.onProgress("Sign in to \(site.name) in your browser — this finishes by itself…")
        return try await present(pageURL, callbacks: callbacks) {
            let deadline = now().addingTimeInterval(WorkBuddyOAuth.signInWindow)
            let query = OAuth.urlEncodedForm(["state": state])
            let token = try await pollWorkBuddy(
                site,
                path: "/v2/plugin/auth/token?" + query,
                headers: [:],
                pendingCode: WorkBuddyOAuth.tokenPendingCode,
                deadline: deadline,
                client: client,
                pollSleep: pollSleep,
                now: now
            )
            guard var credentials = WorkBuddyOAuth.merge(token, into: nil, now: now()) else {
                throw OAuthError.invalidResponse("\(site.name) gave no token")
            }
            let asAccount = [
                "Authorization": "Bearer \(credentials.access)",
                "X-Domain": WorkBuddyOAuth.domain(credentials.extras, site: site),
            ]
            let account = try await pollWorkBuddy(
                site,
                path: "/v2/plugin/login/account?" + query,
                headers: asAccount.merging(["X-No-User-Id": "true", "X-No-Enterprise-Id": "true"]) { own, _ in own },
                pendingCode: WorkBuddyOAuth.accountPendingCode,
                deadline: deadline,
                client: client,
                pollSleep: pollSleep,
                now: now
            )
            guard let uid = account["uid"] as? String, !uid.isEmpty else {
                throw OAuthError.invalidResponse("\(site.name) gave no account")
            }
            credentials.extras["uid"] = .string(uid)
            // The account is named by its nickname, its phone number, or its id.
            let names = [account["nickname"], account["phoneNumber"]]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            credentials.extras["accountName"] = .string(names.first { !$0.isEmpty } ?? uid)
            let enterprise = await workBuddyEnterprise(site, account: account, headers: asAccount, client: client)
            if !enterprise.isEmpty { credentials.extras["enterpriseId"] = .string(enterprise) }
            return credentials
        }
    }

    /// Asks `path` until it answers with data. WorkBuddy's own "not ready
    /// yet" code, an empty answer, a 408 and a 429 all mean ask again; any
    /// other refusal ends the sign-in. A transport failure is a blip unless
    /// three come in a row.
    private static func pollWorkBuddy(
        _ site: WorkBuddySite,
        path: String,
        headers: [String: String],
        pendingCode: Int,
        deadline: Date,
        client: HTTPClient,
        pollSleep: @Sendable () async throws -> Void,
        now: @Sendable () -> Date
    ) async throws -> [String: Any] {
        var consecutiveErrors = 0
        while true {
            try Task.checkCancellation()
            try await pollSleep()
            if now() > deadline { throw OAuthLoginError.timedOut }
            do {
                let data = try await WorkBuddyAPI.call(
                    site,
                    method: "GET",
                    path: path,
                    headers: headers,
                    client: client
                )
                consecutiveErrors = 0
                if let answer = data as? [String: Any], !answer.isEmpty { return answer }
            } catch let failure as WorkBuddyAPI.Failure {
                consecutiveErrors = 0
                if failure.code == pendingCode || failure.status == 408 || failure.status == 429 { continue }
                throw OAuthLoginError.denied("\(site.name): \(failure.message)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    throw OAuthError.transport("\(site.id) sign-in polling failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The enterprise the signed-in account belongs to, "" for a personal
    /// one: the one `/login/account` names, else, for an account that isn't
    /// personal, the one WorkBuddy's account list has for it — the choice
    /// WorkBuddy's own client makes: the uid's only entry of that type, or
    /// the only one it last signed in to.
    private static func workBuddyEnterprise(
        _ site: WorkBuddySite,
        account: [String: Any],
        headers: [String: String],
        client: HTTPClient
    ) async -> String {
        func trimmed(_ value: Any?) -> String {
            (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let own = trimmed(account["enterpriseId"])
        if !own.isEmpty { return own }
        let type = trimmed(account["type"]).lowercased()
        if type.isEmpty || type == "personal" { return "" }
        let listed = try? await WorkBuddyAPI.call(
            site,
            method: "GET",
            path: "/v2/plugin/accounts",
            headers: headers,
            client: client
        ) as? [String: Any]
        let mine = (listed?["accounts"] as? [[String: Any]] ?? []).filter {
            $0["uid"] as? String == account["uid"] as? String && !trimmed($0["enterpriseId"]).isEmpty
        }
        let sameType = mine.filter { trimmed($0["type"]).lowercased() == type }
        let lastUsed = mine.filter { entry in
            switch entry["lastLogin"] {
            case nil, is NSNull: false
            case let text as String: !text.isEmpty
            // A flag, or a time: 0 is never.
            case let number as NSNumber: number.doubleValue != 0
            default: true
            }
        }
        let pick = sameType.count == 1 ? sameType[0]
            : lastUsed.count == 1 ? lastUsed[0]
            : mine.count == 1 ? mine[0] : nil
        return trimmed(pick?["enterpriseId"])
    }
}

// MARK: - Refresh

/// Trades the refresh token for a fresh access token as WorkBuddy's auth
/// provider does: `POST /v2/plugin/auth/token/refresh` with the refresh token
/// in a header and an empty JSON body.
public struct WorkBuddyOAuthProvider: OAuthProvider {
    public let site: WorkBuddySite
    public var id: String { site.id }
    public var name: String { site.name }

    public init(site: WorkBuddySite) {
        self.site = site
    }

    public func refresh(
        _ credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> OAuthCredentials {
        // A refresh token past its own end is not sent: the account is
        // signed out, and only a new sign-in brings it back.
        if case .int(let ends)? = credentials.extras["refreshExpiresAt"], ends > 0,
           Int64(Date().timeIntervalSince1970 * 1000) >= Int64(ends) {
            throw OAuthRefreshError(
                providerId: id,
                kind: .rejected,
                status: nil,
                detail: "this \(site.name) account is signed out; sign in again"
            )
        }
        var headers = WorkBuddyAPI.jsonHeaders
        headers["X-Refresh-Token"] = credentials.refresh
        headers["X-Auth-Refresh-Source"] = "plugin"
        for (name, value) in WorkBuddyOAuth.accountHeaders(credentials, site: site) where name != "X-User-Id" {
            headers[name] = value
        }
        let (response, body) = try await OAuthRefreshError.post(
            provider: id,
            url: site.url("/v2/plugin/auth/token/refresh"),
            headers: headers,
            body: Data("{}".utf8),
            client: client
        )
        let token: [String: Any]?
        do {
            token = try WorkBuddyAPI.unwrap(body, status: response.statusCode) as? [String: Any]
        } catch let failure as WorkBuddyAPI.Failure {
            // A business code under a 200. Which of them mean the grant is
            // gone isn't known, so none parks the login.
            throw OAuthRefreshError(
                providerId: id,
                kind: .unavailable,
                status: response.statusCode,
                detail: "\(failure.message) (code \(failure.code))"
            )
        }
        guard let refreshed = WorkBuddyOAuth.merge(token ?? [:], into: credentials, now: Date()) else {
            throw OAuthRefreshError(
                providerId: id,
                kind: .unavailable,
                status: response.statusCode,
                detail: "\(site.name) gave no refreshed token"
            )
        }
        return refreshed
    }
}

// MARK: - Usage

/// `POST /billing/meter/get-user-resource-summary`, the meter WorkBuddy's
/// desktop and web apps read: the plan's credits used against what the cycle
/// grants, summed over the account's packages. Unlike the older meters it
/// has no `/v2` prefix, on either build (magpie 5741e3fc).
public struct WorkBuddyUsageReader: OAuthUsageReader {
    public let site: WorkBuddySite
    public var providerId: String { site.id }

    public init(site: WorkBuddySite) {
        self.site = site
    }

    public func usage(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> [OAuthUsageWindow] {
        var headers = WorkBuddyAPI.jsonHeaders
        headers["Authorization"] = "Bearer \(credentials.access)"
        headers["X-Product"] = "SaaS"
        headers["X-IDE-Type"] = "WorkBuddy"
        for (name, value) in WorkBuddyOAuth.accountHeaders(credentials, site: site) { headers[name] = value }

        let response: HTTPURLResponse
        let body: Data
        do {
            (response, body) = try await client.request(
                url: site.url("/billing/meter/get-user-resource-summary"),
                method: "POST",
                headers: headers,
                body: Data("{}".utf8)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OAuthUsageError.unavailable(providerId: providerId, status: nil, detail: error.localizedDescription)
        }
        if response.statusCode == 429 {
            throw OAuthUsageError.rateLimited(
                retryAfterSeconds: OAuthUsage.retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After"))
            )
        }
        do {
            let summary = try WorkBuddyAPI.unwrap(body, status: response.statusCode) as? [String: Any]
            return try Self.windows(fromSummary: summary ?? [:])
        } catch let failure as WorkBuddyAPI.Failure {
            throw OAuthUsageError.unavailable(
                providerId: providerId,
                status: response.statusCode,
                detail: failure.message
            )
        }
    }

    /// The normalization, separate from the wire for tests. An account whose
    /// packages grant nothing has no window.
    static func windows(fromSummary summary: [String: Any]) throws -> [OAuthUsageWindow] {
        var total = 0.0
        var used = 0.0
        for package in summary["Packages"] as? [[String: Any]] ?? [] {
            total += try capacity(package["CycleTotalCapacity"])
            used += try capacity(package["CycleUsedCapacity"])
        }
        guard total > 0 else { return [] }
        return [OAuthUsageWindow(window: .primary, usedPercent: 100 * used / total, resetsAt: nil, windowSeconds: nil)]
    }

    /// A capacity comes as a JSON string ("3300", "438.88000002") and now
    /// and then as a bare number; an empty one is 0 (magpie 6294dd0a).
    private static func capacity(_ value: Any?) throws -> Double {
        switch value {
        case nil, is NSNull: return 0
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let text as String:
            if text.isEmpty { return 0 }
            if let number = Double(text) { return number }
            fallthrough
        default:
            throw WorkBuddyAPI.Failure(
                code: 0,
                status: 200,
                message: "unreadable capacity \(String(describing: value))"
            )
        }
    }
}
