import Foundation

// MARK: - Anthropic

public struct AnthropicOAuthProvider: OAuthProvider {
    public let id = "anthropic"
    public let name = "Anthropic (Claude Pro/Max)"
    public let tokenURL: URL
    public let clientID: String

    public init(
        tokenURL: URL = URL(string: "https://platform.claude.com/v1/oauth/token")!,
        clientID: String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
    }

    public func refresh(
        _ credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": credentials.refresh,
        ]
        let json = try await OAuthRefreshError.postForToken(
            provider: id,
            url: tokenURL,
            headers: ["content-type": "application/json", "accept": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body),
            client: client
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: json.accessToken,
            refresh: json.refreshToken ?? credentials.refresh,
            expires: now + Int64(json.expiresIn * 1000) - OAuth.expiryMarginMs,
            extras: credentials.extras
        )
    }
}

// MARK: - OpenAI Codex

public struct OpenAICodexOAuthProvider: OAuthProvider {
    public let id = "openai-codex"
    public let name = "ChatGPT Plus/Pro (Codex Subscription)"
    public let tokenURL: URL
    public let clientID: String

    public init(
        tokenURL: URL = URL(string: "https://auth.openai.com/oauth/token")!,
        clientID: String = "app_EMoamEEZ73f0CkXaXp7hrann"
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
    }

    public func refresh(
        _ credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let form = OAuth.urlEncodedForm([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refresh,
            "client_id": clientID,
        ])
        let json = try await OAuthRefreshError.postForToken(
            provider: id,
            url: tokenURL,
            headers: ["content-type": "application/x-www-form-urlencoded", "accept": "application/json"],
            body: Data(form.utf8),
            client: client
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var extras = credentials.extras
        if let accountId = Self.extractAccountId(fromJWT: json.accessToken) {
            extras["accountId"] = .string(accountId)
        }
        return OAuthCredentials(
            access: json.accessToken,
            refresh: json.refreshToken ?? credentials.refresh,
            expires: now + Int64(json.expiresIn * 1000) - OAuth.expiryMarginMs,
            extras: extras
        )
    }

    /// Extract the ChatGPT account id from the access token JWT claim. Codex
    /// requests route by account id, so we cache it on refresh.
    public static func extractAccountId(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payload = String(parts[1])
        var padded = payload
        while padded.count % 4 != 0 { padded.append("=") }
        let urlSafe = padded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: urlSafe),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Claim path used by pi: "https://api.openai.com/auth".chatgpt_account_id
        if let claim = obj["https://api.openai.com/auth"] as? [String: Any],
           let id = claim["chatgpt_account_id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }
}

// MARK: - GitHub Copilot

public struct GitHubCopilotOAuthProvider: OAuthProvider {
    public let id = "github-copilot"
    public let name = "GitHub Copilot"
    public let tokenURL: URL
    public let extraHeaders: [String: String]

    public init(
        tokenURL: URL = URL(string: "https://api.github.com/copilot_internal/v2/token")!,
        extraHeaders: [String: String] = [
            "editor-version": "vscode/1.107.0",
            "editor-plugin-version": "copilot-chat/0.35.0",
            "user-agent": "GitHubCopilotChat/0.35.0",
            "copilot-integration-id": "vscode-chat",
        ]
    ) {
        self.tokenURL = tokenURL
        self.extraHeaders = extraHeaders
    }

    /// Copilot doesn't do standard OAuth token refresh — the stored `refresh`
    /// is a long-lived GitHub token, and each refresh trades it for a
    /// short-lived session token kept as `access` until it expires.
    public func refresh(
        _ credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> OAuthCredentials {
        var headers: [String: String] = [
            "accept": "application/json",
            "authorization": "Bearer \(credentials.refresh)",
        ]
        for (k, v) in extraHeaders { headers[k] = v }
        let (response, body) = try await client.request(
            url: tokenURL,
            method: "GET",
            headers: headers,
            body: nil
        )
        if response.statusCode >= 400 {
            let text = String(data: body, encoding: .utf8) ?? ""
            throw OAuthError.refreshFailed("github-copilot \(response.statusCode): \(text)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = obj["token"] as? String else {
            throw OAuthError.invalidResponse("github-copilot response missing token")
        }
        // `expires_at` is Unix seconds. Refresh 5 minutes early.
        let expiresAtSec: Int64 = {
            if let v = obj["expires_at"] as? Int { return Int64(v) }
            if let v = obj["expires_at"] as? Int64 { return v }
            if let v = obj["expires_at"] as? Double { return Int64(v) }
            return Int64(Date().timeIntervalSince1970) + 25 * 60
        }()
        var extras = credentials.extras
        if let endpoints = obj["endpoints"] as? [String: Any],
           let api = endpoints["api"] as? String {
            extras["endpoint"] = .string(api)
        }
        return OAuthCredentials(
            access: token,
            refresh: credentials.refresh,
            expires: expiresAtSec * 1000 - OAuth.expiryMarginMs,
            extras: extras
        )
    }
}

// MARK: - Cursor
//
// Cursor's subscription auth is a browser PKCE poll flow (see
// `OAuthLogin.loginCursor`). Tokens are short-lived JWTs; the stored `refresh`
// is exchanged for a fresh access token at `exchange_user_api_key` (an unusual
// pattern where the refresh token rides as the bearer with an empty body).

public struct CursorOAuthProvider: OAuthProvider {
    public let id = "cursor"
    public let name = "Cursor"
    public let refreshURL: URL

    public init(
        refreshURL: URL = URL(string: "https://api2.cursor.sh/auth/exchange_user_api_key")!
    ) {
        self.refreshURL = refreshURL
    }

    public func refresh(
        _ credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let (response, body) = try await OAuthRefreshError.post(
            provider: id,
            url: refreshURL,
            headers: ["authorization": "Bearer \(credentials.refresh)", "content-type": "application/json"],
            body: Data("{}".utf8),
            client: client
        )
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let access = obj["accessToken"] as? String, !access.isEmpty else {
            throw OAuthRefreshError(
                providerId: id,
                kind: .unavailable,
                status: response.statusCode,
                detail: "cursor refresh missing accessToken"
            )
        }
        let newRefresh: String = {
            if let r = obj["refreshToken"] as? String, !r.isEmpty { return r }
            return credentials.refresh
        }()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: access,
            refresh: newRefresh,
            expires: OAuth.jwtExpiryMillis(access) ?? (now + 60 * 60 * 1000),
            extras: credentials.extras
        )
    }
}

// MARK: - Devin
//
// Devin's browser sign-in (`OAuthLogin.loginDevin`) yields a long-lived
// session token with no refresh token, stored with `refresh == ""`. The
// manager therefore never calls `refresh` (an expired refresh-less entry
// surfaces `OAuthError.expired`); the provider exists so `apiKey(for:)`
// recognizes the id.

public struct DevinOAuthProvider: OAuthProvider {
    public let id = "devin"
    public let name = "Devin"

    public init() {}

    public func refresh(
        _ credentials: OAuthCredentials,
        using client: HTTPClient
    ) async throws -> OAuthCredentials {
        throw OAuthError.refreshFailed("devin session tokens cannot be refreshed; run /login devin again")
    }
}

/// Constants for the OpenRouter PKCE callback login (mirrors pi's
/// `openrouter.ts`). The code exchange mints a permanent API key, so there
/// is no refresh provider — the key persists in the sentinel credentials
/// shape the API-key form uses.
public enum OpenRouterOAuth {
    public static let authorizeURL = URL(string: "https://openrouter.ai/auth")!
    public static let keysURL = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
    public static let callbackPort: UInt16 = 53693
}

/// Constants for the Devin browser sign-in (mirrors oh-my-pi's
/// `compat/rules/auth/devin.kdl`).
public enum DevinOAuth {
    public static let authorizeURL = URL(string: "https://app.devin.ai/auth/cli/continue")!
    public static let tokenURL = URL(string: "https://api.devin.ai/auth/cli/token")!
    public static let callbackPort: UInt16 = 59653
    public static let callbackHost = "127.0.0.1"
    public static let callbackPath = "/callback"
    public static let apiEndpoint = "https://api.devin.ai"
    public static let enterpriseURL = "https://app.devin.ai"
    /// Expiry used when the session token carries no JWT `exp` (one year).
    public static let fallbackLifetimeMs: Int64 = 31_536_000_000
}

/// Constants for the Z.AI GLM Coding Plan browser sign-in (mirrors
/// oh-my-pi's `zai.ts`, which itself mirrors ZCode's desktop flow). The
/// flow provisions a durable `id.secret` API key, so there is no refresh
/// provider here either.
/// A GLM Coding Plan site ZCode signs in to: Z.ai, or BigModel (智谱,
/// bigmodel.cn) in China. One polling flow on zcode.z.ai serves both; what
/// differs is ported from magpie's zcode plugin (`SITES`, `authorize`,
/// `bizAuth`, `plan`).
public struct ZaiSite: Sendable, Hashable {
    /// The store id its logins are kept under.
    public let id: String
    public let name: String
    /// What ZCode's flow is opened for (`cli/init` `provider`).
    public let flowProvider: String
    /// The authorization page's parameter naming where the browser goes back
    /// to: Z.ai's `redirect_uri`, BigModel's login page's `redirect`.
    public let redirectParameter: String
    /// The business API: account, organizations and API keys.
    public let businessAPI: URL
    /// Where the subscriptions are asked with the minted key.
    public let planAPI: URL
    /// Z.ai's OAuth token is traded for a business bearer first; BigModel's
    /// goes to the business API as it is, bare.
    public let tradesForBusinessToken: Bool
    /// Where a plan is bought, for a sign-in that finds none.
    public let subscribe: String

    public static let global = ZaiSite(
        id: "zai", name: "Z.ai", flowProvider: "zai", redirectParameter: "redirect_uri",
        businessAPI: URL(string: "https://api.z.ai")!, planAPI: URL(string: "https://api.z.ai")!,
        tradesForBusinessToken: true, subscribe: "z.ai/subscribe"
    )
    public static let china = ZaiSite(
        id: "zai-coding-cn", name: "BigModel", flowProvider: "bigmodel", redirectParameter: "redirect",
        businessAPI: URL(string: "https://bigmodel.cn")!, planAPI: URL(string: "https://open.bigmodel.cn")!,
        tradesForBusinessToken: false, subscribe: "bigmodel.cn/glm-coding"
    )
    public static let all: [ZaiSite] = [.global, .china]

    public static func site(id: String) -> ZaiSite? { all.first { $0.id == id } }
}

public enum ZaiOAuth {
    /// ZCode's polling sign-in: opens a flow and names the page to sign in on.
    public static let cliInitURL = URL(string: "https://zcode.z.ai/api/v1/oauth/cli/init")!
    /// The flow's state, until it hands over Z.ai's access token.
    public static func cliPollURL(flowID: String) -> URL {
        URL(string: "https://zcode.z.ai/api/v1/oauth/cli/poll/")!.appendingPathComponent(flowID)
    }
    /// The ZCode version this sign-in presents as (magpie pins the same).
    public static let zcodeAppVersion = "3.14.3"
    /// Where Z.ai sends the browser back: ZCode's own sign-in page.
    public static var webLoginURL: URL {
        var comps = URLComponents(string: "https://zcode.z.ai/app/oauth/login")!
        comps.queryItems = [
            URLQueryItem(name: "redirect", value: "zcode://oauth/callback"),
            URLQueryItem(name: "app_version", value: zcodeAppVersion),
        ]
        return comps.url!
    }
    /// Business-login endpoint: exchanges the OAuth access token for the biz
    /// bearer the provisioning APIs require.
    public static let businessLoginURL = URL(string: "https://api.z.ai/api/auth/z/login")!
    /// Name of the provisioned key — kwwk-owned, so sign-in never mutates
    /// ZCode's own `zcode-api-key` entry.
    public static let keyName = "kwwk"
}
