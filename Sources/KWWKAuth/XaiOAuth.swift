import Foundation

// MARK: - xAI Grok (SuperGrok / X Premium subscription)
//
// xAI's subscription auth is an OAuth device-authorization grant against
// `auth.x.ai` (see `OAuthLogin.loginXai`), the same flow the official Grok
// CLI uses. Refresh is a standard `grant_type=refresh_token` form POST to the
// token endpoint; the resulting access token authenticates `api.x.ai`
// requests as a Bearer key.

public struct XaiOAuthProvider: OAuthProvider {
    public let id = "xai"
    public let name = "xAI (Grok subscription)"
    public let tokenURL: URL
    public let clientID: String

    public init(
        tokenURL: URL = XaiOAuth.tokenURL,
        clientID: String = XaiOAuth.clientID
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
    }

    public func refresh(
        _ credentials: OAuthCredentials, using client: HTTPClient
    ) async throws -> OAuthCredentials {
        let form = OAuth.urlEncodedForm([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refresh,
            "client_id": clientID,
        ])
        let json = try await OAuthRefreshError.postForToken(
            provider: id, url: tokenURL,
            headers: ["content-type": "application/x-www-form-urlencoded", "accept": "application/json"],
            body: Data(form.utf8), client: client
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return OAuthCredentials(
            access: json.accessToken,
            // xAI may omit refresh_token when the token isn't rotated.
            refresh: json.refreshToken ?? credentials.refresh,
            expires: now + Int64(json.expiresIn * 1000) - OAuth.expiryMarginMs,
            extras: credentials.extras
        )
    }
}

/// Constants shared by the xAI device-flow login and the refresh provider.
/// Client id and scope mirror the official Grok CLI (same values pi and
/// oh-my-pi ship); the `grok-cli:access` scope is what unlocks subscription
/// inference.
public enum XaiOAuth {
    public static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let scope = "openid profile email offline_access grok-cli:access api:access"
    public static let deviceCodeURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    public static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
}
