import Foundation
import KWWKAI

extension MCPOAuth {
    // MARK: - Authorization request

    /// Build the authorization URL with a fresh PKCE challenge.
    public static func startAuthorization(
        authorizationServerURL: String,
        metadata: MCPAuthorizationServerMetadata?,
        client: MCPOAuthClientInformation,
        redirectURI: URL,
        scope: String?,
        state: String?,
        resource: String?
    ) throws -> (authorizationURL: URL, codeVerifier: String) {
        let endpoint: URL
        if let metadata {
            guard metadata.responseTypesSupported.contains("code") else {
                throw MCPAuthError.incompatibleServer("does not support response type code")
            }
            if let methods = metadata.codeChallengeMethodsSupported, !methods.contains("S256") {
                throw MCPAuthError.incompatibleServer("does not support code challenge method S256")
            }
            guard let url = URL(string: metadata.authorizationEndpoint) else {
                throw MCPAuthError.incompatibleServer("invalid authorization endpoint \(metadata.authorizationEndpoint)")
            }
            endpoint = url
        } else {
            guard let url = URL(string: "/authorize", relativeTo: URL(string: authorizationServerURL))?.absoluteURL else {
                throw MCPAuthError.incompatibleServer("invalid authorization server URL \(authorizationServerURL)")
            }
            endpoint = url
        }
        let pkce = PKCE.random()
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw MCPAuthError.incompatibleServer("invalid authorization endpoint \(endpoint.absoluteString)")
        }
        var items = (components.queryItems ?? []).filter {
            !["response_type", "client_id", "code_challenge", "code_challenge_method", "redirect_uri", "state", "scope", "resource"]
                .contains($0.name)
        }
        items.append(URLQueryItem(name: "response_type", value: "code"))
        items.append(URLQueryItem(name: "client_id", value: client.clientID))
        items.append(URLQueryItem(name: "code_challenge", value: pkce.challenge))
        items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        items.append(URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString))
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        if scope?.split(separator: " ").contains("offline_access") == true {
            items.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        if let resource { items.append(URLQueryItem(name: "resource", value: resource)) }
        components.percentEncodedQuery = items.map { item in
            "\(MCPAuthHTTP.formEncode(item.name))=\(MCPAuthHTTP.formEncode(item.value ?? ""))"
        }.joined(separator: "&")
        guard let url = components.url else {
            throw MCPAuthError.incompatibleServer("could not build the authorization URL")
        }
        return (url, pkce.verifier)
    }

    // MARK: - Token requests

    /// Exchange an authorization code (after checking `iss` per RFC 9207).
    public static func exchangeAuthorization(
        authorizationServerURL: String,
        metadata: MCPAuthorizationServerMetadata?,
        client: MCPOAuthClientInformation,
        code: String,
        codeVerifier: String,
        redirectURI: URL,
        resource: String?,
        iss: String? = nil,
        validateIssuer: Bool = false,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPOAuthTokens {
        if validateIssuer {
            try validateAuthorizationResponseIssuer(
                iss: iss,
                expectedIssuer: metadata?.issuer,
                issParameterSupported: metadata?.authorizationResponseIssParameterSupported == true
            )
        }
        return try await tokenRequest(
            authorizationServerURL: authorizationServerURL,
            metadata: metadata,
            client: client,
            parameters: [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("code_verifier", codeVerifier),
                ("redirect_uri", redirectURI.absoluteString),
            ],
            resource: resource,
            httpClient: httpClient
        )
    }

    /// Refresh. A response without a new refresh token keeps the old one.
    public static func refreshAuthorization(
        authorizationServerURL: String,
        metadata: MCPAuthorizationServerMetadata?,
        client: MCPOAuthClientInformation,
        refreshToken: String,
        resource: String?,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPOAuthTokens {
        var tokens = try await tokenRequest(
            authorizationServerURL: authorizationServerURL,
            metadata: metadata,
            client: client,
            parameters: [("grant_type", "refresh_token"), ("refresh_token", refreshToken)],
            resource: resource,
            httpClient: httpClient
        )
        if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
        return tokens
    }

    /// The token endpoint authentication method: the one assigned at
    /// registration when the server supports it, else `client_secret_basic`,
    /// `client_secret_post`, then `none`.
    public static func selectClientAuthMethod(client: MCPOAuthClientInformation, supportedMethods: [String]) -> String {
        let known = ["client_secret_basic", "client_secret_post", "none"]
        let hasSecret = client.clientSecret != nil
        if let assigned = client.tokenEndpointAuthMethod, known.contains(assigned),
           supportedMethods.isEmpty || supportedMethods.contains(assigned) {
            return assigned
        }
        if supportedMethods.isEmpty { return hasSecret ? "client_secret_basic" : "none" }
        if hasSecret && supportedMethods.contains("client_secret_basic") { return "client_secret_basic" }
        if hasSecret && supportedMethods.contains("client_secret_post") { return "client_secret_post" }
        if supportedMethods.contains("none") { return "none" }
        return hasSecret ? "client_secret_post" : "none"
    }

    /// Refuse non-TLS token endpoints, except loopback hosts.
    public static func assertSecureTokenEndpoint(_ url: URL) throws {
        if url.scheme?.lowercased() != "https" && !isLoopbackHost(url.host) {
            throw MCPAuthError.insecureTokenEndpoint(url.absoluteString)
        }
    }

    private static func tokenRequest(
        authorizationServerURL: String,
        metadata: MCPAuthorizationServerMetadata?,
        client: MCPOAuthClientInformation,
        parameters: [(String, String)],
        resource: String?,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPOAuthTokens {
        let endpoint: URL
        if let metadata, let url = URL(string: metadata.tokenEndpoint) {
            endpoint = url
        } else if let url = URL(string: "/token", relativeTo: URL(string: authorizationServerURL))?.absoluteURL {
            endpoint = url
        } else {
            throw MCPAuthError.incompatibleServer("invalid token endpoint")
        }
        try assertSecureTokenEndpoint(endpoint)
        var form = parameters
        if let resource { form.append(("resource", resource)) }
        var headers = ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"]
        let method = selectClientAuthMethod(client: client, supportedMethods: metadata?.tokenEndpointAuthMethodsSupported ?? [])
        switch method {
        case "client_secret_basic":
            guard let secret = client.clientSecret else {
                throw MCPAuthError.providerMisconfigured("client_secret_basic authentication requires a client_secret")
            }
            // RFC 6749 §2.3.1: client credentials are form-encoded before Basic.
            let credentials = "\(MCPAuthHTTP.formEncode(client.clientID)):\(MCPAuthHTTP.formEncode(secret))"
            headers["Authorization"] = "Basic " + Data(credentials.utf8).base64EncodedString()
        case "client_secret_post":
            form.append(("client_id", client.clientID))
            if let secret = client.clientSecret { form.append(("client_secret", secret)) }
        default:
            form.append(("client_id", client.clientID))
        }
        let response = try await MCPAuthHTTP.send(MCPAuthHTTPRequest(
            url: endpoint,
            method: "POST",
            headers: headers,
            body: MCPAuthHTTP.formBody(form)
        ), using: httpClient)
        guard response.isSuccess else {
            throw MCPAuthError.oauth(parseErrorResponse(response))
        }
        if let tokens = try? JSONDecoder().decode(MCPOAuthTokens.self, from: response.body) {
            var result = tokens
            result.issuer = nil
            result.expiresAt = tokens.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            return result
        }
        // Some servers answer errors with HTTP 200.
        if let json = try? JSONDecoder().decode(JSONValue.self, from: response.body), json["error"] != nil {
            throw MCPAuthError.oauth(parseErrorResponse(response))
        }
        throw MCPAuthError.requestFailed("Invalid token response: \(response.text.prefix(500))")
    }

    static func parseErrorResponse(_ response: MCPAuthHTTPResponse) -> MCPOAuthErrorResponse {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: response.body),
           case .string(let code)? = json["error"] {
            return MCPOAuthErrorResponse(
                code: code,
                description: json["error_description"]?.mcpString,
                uri: json["error_uri"]?.mcpString,
                status: response.status
            )
        }
        return MCPOAuthErrorResponse(
            code: MCPOAuthErrorResponse.serverError,
            description: "HTTP \(response.status): \(response.text.prefix(500))",
            status: response.status
        )
    }
}
