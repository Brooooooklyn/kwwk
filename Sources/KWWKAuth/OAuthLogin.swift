import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Whole-flow orchestrator: build the authorize URL, bring up a local
/// callback server, launch the user's browser, exchange the received code
/// for tokens. Returns persistable `OAuthCredentials`.
///
/// Each provider gets a static factory because the URLs, scopes, and
/// redirect ports differ.
public enum OAuthLogin {

    /// Hooks the orchestrator calls as the flow progresses. The SDK does not
    /// print or launch a browser on its own — the embedding app decides how.
    /// Redirect flows default to a NIO loopback listener; an app may supply
    /// its own listener and browser presenter.
    public struct Callbacks: Sendable {
        /// Called with a page the user must open, when no `browser` presenter
        /// is set. The CLI prints and opens it here. A host that sets
        /// `browser` can leave this and `onProgress` at their no-op defaults.
        public var onAuthURL: @Sendable (URL) -> Void
        public var onProgress: @Sendable (String) -> Void
        /// Called once per device flow, before its verification page opens,
        /// with the code the user confirms there.
        public var onUserCode: (@Sendable (_ code: String, _ verificationURL: URL) async -> Void)?
        /// Shows pages and runs the flow's waiting work beside them. Nil runs
        /// the work after handing the page to `onAuthURL`.
        public var browser: (any OAuthBrowserPresenter)?
        /// Builds the listener a redirect flow binds. Defaults to the shared
        /// NIO listener; tests and hosts may supply their own.
        public var loopback: OAuthLoopbackFactory

        public init(
            onAuthURL: @escaping @Sendable (URL) -> Void = { _ in },
            onProgress: @escaping @Sendable (String) -> Void = { _ in },
            onUserCode: (@Sendable (_ code: String, _ verificationURL: URL) async -> Void)? = nil,
            browser: (any OAuthBrowserPresenter)? = nil,
            loopback: @escaping OAuthLoopbackFactory = OAuthLogin.nioLoopback
        ) {
            self.onAuthURL = onAuthURL
            self.onProgress = onProgress
            self.onUserCode = onUserCode
            self.browser = browser
            self.loopback = loopback
        }
    }

    // MARK: - Anthropic

    public static func loginAnthropic(
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let provider = AnthropicOAuthProvider()
        let server = try await openLoopback(callbacks, port: 53692)
        defer { server.stop() }

        let scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
        let redirect = server.redirectURI
        var comps = URLComponents(string: "https://claude.ai/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.verifier),
        ]

        callbacks.onProgress("waiting for Anthropic callback on \(redirect)…")

        let params = try await present(comps.url!, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: "anthropic")
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("anthropic callback had no code")
        }
        guard params["state"] == pkce.verifier else {
            throw OAuthError.invalidResponse("anthropic OAuth state mismatch")
        }

        callbacks.onProgress("exchanging authorization code…")
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": provider.clientID,
            "code": code,
            "state": pkce.verifier,
            "redirect_uri": redirect,
            "code_verifier": pkce.verifier,
        ]
        let response = try await postJSON(
            url: provider.tokenURL,
            body: body,
            client: client
        )
        guard !response.accessToken.isEmpty,
              let refresh = response.refreshToken, !refresh.isEmpty else {
            throw OAuthError.invalidResponse("anthropic token response missing credentials")
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: response.accessToken,
            refresh: refresh,
            expires: now + Int64(response.expiresIn * 1000) - OAuth.expiryMarginMs,
            extras: [:]
        )
    }

    // MARK: - OpenAI Codex

    public static func loginOpenAICodex(
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let provider = OpenAICodexOAuthProvider()
        let pkce = PKCE.random()
        let state = PKCE.randomHex()
        // OpenAI registered exactly this redirect for the Codex CLI's client.
        let server = try await openLoopback(callbacks, port: 1455, path: "/auth/callback")
        defer { server.stop() }

        var comps = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "redirect_uri", value: server.redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        callbacks.onProgress("waiting for ChatGPT callback on \(server.redirectURI)…")

        let params = try await present(comps.url!, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: "codex")
        guard params["state"] == state else {
            throw OAuthError.invalidResponse("codex OAuth state mismatch")
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("codex callback had no code")
        }

        callbacks.onProgress("exchanging authorization code…")
        let form = OAuth.urlEncodedForm([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": provider.clientID,
            "redirect_uri": server.redirectURI,
            "code_verifier": pkce.verifier,
        ])
        let (response, body) = try await client.request(
            url: provider.tokenURL,
            method: "POST",
            headers: [
                "content-type": "application/x-www-form-urlencoded",
                "accept": "application/json",
            ],
            body: Data(form.utf8)
        )
        if response.statusCode >= 400 {
            throw OAuthError.refreshFailed("codex exchange \(response.statusCode): \(String(data: body, encoding: .utf8) ?? "")")
        }
        let json = try OAuth.decodeTokenResponse(body)
        // `offline_access` is requested; a grant without a refresh token
        // would die at its first expiry, so it is refused here.
        guard let refresh = json.refreshToken, !refresh.isEmpty else {
            throw OAuthError.invalidResponse("codex token response missing refresh token")
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var extras: [String: JSONValue] = [:]
        if let accountId = OpenAICodexOAuthProvider.extractAccountId(fromJWT: json.accessToken) {
            extras["accountId"] = .string(accountId)
        }
        return OAuthCredentials(
            access: json.accessToken,
            refresh: refresh,
            expires: now + Int64(json.expiresIn * 1000) - OAuth.expiryMarginMs,
            extras: extras
        )
    }

    // MARK: - OpenRouter (PKCE callback flow)
    //
    // OpenRouter's OAuth exchanges the authorization code for a permanent,
    // user-controlled API key rather than an expiring token pair (mirrors
    // pi's `openrouter.ts`). The minted key persists in the same sentinel
    // credentials shape as the API-key login form (`refresh: ""`,
    // `expires: .max`), so the stored `openrouter` registration path is
    // unchanged.

    public static func loginOpenRouter(
        port: UInt16 = OpenRouterOAuth.callbackPort,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let server = try await openLoopback(callbacks, port: port)
        defer { server.stop() }

        var comps = URLComponents(url: OpenRouterOAuth.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "callback_url", value: server.redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        callbacks.onProgress("waiting for OpenRouter callback on \(server.redirectURI)…")

        let params = try await present(comps.url!, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: "openrouter")
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("openrouter callback had no code")
        }

        callbacks.onProgress("exchanging authorization code for an API key…")
        let (response, responseBody) = try await client.request(
            url: OpenRouterOAuth.keysURL,
            method: "POST",
            headers: ["content-type": "application/json", "accept": "application/json"],
            body: try JSONSerialization.data(withJSONObject: [
                "code": code,
                "code_verifier": pkce.verifier,
                "code_challenge_method": "S256",
            ])
        )
        if response.statusCode >= 400 {
            throw OAuthError.refreshFailed("openrouter key exchange \(response.statusCode): \(String(data: responseBody, encoding: .utf8) ?? "")")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let key = obj["key"] as? String, !key.isEmpty else {
            throw OAuthError.invalidResponse("openrouter key exchange response carried no key")
        }
        return OAuthCredentials(access: key, refresh: "", expires: .max)
    }

    // MARK: - Devin (browser PKCE callback flow)
    //
    // Ported from oh-my-pi's `auth/devin.kdl` (`login "oauth-code"`): a PKCE
    // authorization-code grant against app.devin.ai with a loopback callback
    // on 127.0.0.1:59653, then a JSON code exchange at api.devin.ai that
    // returns a long-lived session token. There is no refresh token — the
    // expiry comes from the token's JWT `exp` (falling back to one year) and
    // the user re-runs `/login devin` when it lapses.

    public static func loginDevin(
        port: UInt16 = DevinOAuth.callbackPort,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let state = UUID().uuidString.lowercased()
        // Devin registered the numeric loopback host, not `localhost`.
        let server = try await openLoopback(
            callbacks,
            host: DevinOAuth.callbackHost,
            port: port,
            path: DevinOAuth.callbackPath
        )
        defer { server.stop() }
        let redirectURI = server.redirectURI

        var comps = URLComponents(url: DevinOAuth.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        callbacks.onProgress("Sign in to Devin in your browser — waiting for the callback on \(redirectURI)…")

        let params = try await present(comps.url!, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: "devin")
        guard params["state"] == state else {
            throw OAuthError.invalidResponse("devin callback state mismatch")
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("devin callback had no code")
        }

        callbacks.onProgress("exchanging authorization code for a Devin session token…")
        let (response, responseBody) = try await client.request(
            url: DevinOAuth.tokenURL,
            method: "POST",
            headers: ["content-type": "application/json", "accept": "application/json"],
            body: try JSONSerialization.data(withJSONObject: [
                "code": code,
                "code_verifier": pkce.verifier,
            ])
        )
        if response.statusCode >= 400 {
            throw OAuthError.refreshFailed("devin token exchange \(response.statusCode): \(String(data: responseBody, encoding: .utf8) ?? "")")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else {
            throw OAuthError.invalidResponse("devin token exchange response carried no token")
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: token,
            refresh: "",
            expires: OAuth.jwtExpiryMillis(token) ?? (now + DevinOAuth.fallbackLifetimeMs - OAuth.expiryMarginMs),
            extras: [
                "apiEndpoint": .string(DevinOAuth.apiEndpoint),
                "enterpriseUrl": .string(DevinOAuth.enterpriseURL),
            ]
        )
    }

    // MARK: - JSON helpers

    private static func postJSON(
        url: URL,
        body: [String: Any],
        client: HTTPClient
    ) async throws -> OAuth.TokenResponse {
        let data = try JSONSerialization.data(withJSONObject: body)
        let (response, responseBody) = try await client.request(
            url: url,
            method: "POST",
            headers: ["content-type": "application/json", "accept": "application/json"],
            body: data
        )
        if response.statusCode >= 400 {
            let text = String(data: responseBody, encoding: .utf8) ?? ""
            throw OAuthError.refreshFailed("\(url.host ?? "oauth") \(response.statusCode): \(text)")
        }
        return try OAuth.decodeTokenResponse(responseBody)
    }
}
