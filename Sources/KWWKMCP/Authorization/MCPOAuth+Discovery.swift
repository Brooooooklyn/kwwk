import Foundation
import KWWKAI

extension MCPOAuth {
    // MARK: - Discovery

    /// RFC 9728 protected resource metadata: the given URL, else path-aware
    /// `/.well-known/oauth-protected-resource<path>`, falling back to the
    /// root. Throws when the server publishes none.
    public static func discoverProtectedResourceMetadata(
        serverURL: URL,
        resourceMetadataURL: URL? = nil,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPProtectedResourceMetadata {
        let response = try await discoverMetadataWithFallback(
            serverURL: serverURL,
            wellKnown: "oauth-protected-resource",
            metadataURL: resourceMetadataURL,
            httpClient: httpClient
        )
        guard let response, response.status != 404 else {
            throw MCPAuthError.requestFailed(
                "Resource server does not implement OAuth 2.0 Protected Resource Metadata."
            )
        }
        guard response.isSuccess else {
            throw MCPAuthError.requestFailed(
                "HTTP \(response.status) trying to load OAuth protected resource metadata."
            )
        }
        do {
            return try JSONDecoder().decode(MCPProtectedResourceMetadata.self, from: response.body)
        } catch {
            throw MCPAuthError.requestFailed("Invalid OAuth protected resource metadata: \(error.displayDescription)")
        }
    }

    private static func discoverMetadataWithFallback(
        serverURL: URL,
        wellKnown: String,
        metadataURL: URL?,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPAuthHTTPResponse? {
        let headers = [protocolVersionHeader: MCPClient.protocolVersion]
        if let metadataURL {
            return try await MCPAuthHTTP.send(MCPAuthHTTPRequest(url: metadataURL, headers: headers), using: httpClient)
        }
        var path = serverURL.path
        if path.hasSuffix("/") { path.removeLast() }
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/.well-known/\(wellKnown)\(path)"
        components.fragment = nil
        guard let pathAware = components.url else { return nil }
        let response = try await MCPAuthHTTP.send(
            MCPAuthHTTPRequest(url: pathAware, headers: headers),
            using: httpClient
        )
        let atRoot = path.isEmpty || path == "/"
        let shouldFallBack = !atRoot && ((!response.isSuccess && response.status < 500) || response.status == 502)
        guard shouldFallBack else { return response }
        components.path = "/.well-known/\(wellKnown)"
        components.query = nil
        guard let root = components.url else { return response }
        return try await MCPAuthHTTP.send(MCPAuthHTTPRequest(url: root, headers: headers), using: httpClient)
    }

    /// The URLs to try for authorization server metadata, in order: RFC 8414
    /// path insertion, then OIDC (path insertion, then path appending).
    public static func discoveryURLs(authorizationServerURL: String) -> [(url: URL, isOIDC: Bool)] {
        guard let url = URL(string: authorizationServerURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return [] }
        components.query = nil
        components.fragment = nil
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        func at(_ newPath: String) -> URL? {
            var c = components
            c.path = newPath
            return c.url
        }
        if path.isEmpty {
            return [
                at("/.well-known/oauth-authorization-server").map { ($0, false) },
                at("/.well-known/openid-configuration").map { ($0, true) },
            ].compactMap { $0 }
        }
        return [
            at("/.well-known/oauth-authorization-server\(path)").map { ($0, false) },
            at("/.well-known/openid-configuration\(path)").map { ($0, true) },
            at("\(path)/.well-known/openid-configuration").map { ($0, true) },
        ].compactMap { $0 }
    }

    /// RFC 8414 / OIDC Discovery metadata of an authorization server, or nil
    /// when none is published. The document's `issuer` must equal
    /// `authorizationServerURL` (one trailing `/` tolerated) unless
    /// `skipIssuerValidation`.
    public static func discoverAuthorizationServerMetadata(
        _ authorizationServerURL: String,
        skipIssuerValidation: Bool = false,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPAuthorizationServerMetadata? {
        let headers = [protocolVersionHeader: MCPClient.protocolVersion, "Accept": "application/json"]
        for (url, isOIDC) in discoveryURLs(authorizationServerURL: authorizationServerURL) {
            let response = try await MCPAuthHTTP.send(MCPAuthHTTPRequest(url: url, headers: headers), using: httpClient)
            guard response.isSuccess else {
                if response.status < 500 || response.status == 502 { continue }
                throw MCPAuthError.requestFailed(
                    "HTTP \(response.status) trying to load \(isOIDC ? "OpenID provider" : "OAuth") metadata from \(url.absoluteString)"
                )
            }
            let metadata: MCPAuthorizationServerMetadata
            do {
                metadata = try JSONDecoder().decode(MCPAuthorizationServerMetadata.self, from: response.body)
            } catch {
                throw MCPAuthError.requestFailed(
                    "Invalid authorization server metadata from \(url.absoluteString): \(error.displayDescription)"
                )
            }
            if !skipIssuerValidation {
                let expected = authorizationServerURL
                let matches = metadata.issuer == expected
                    || (expected.hasSuffix("/") && metadata.issuer == String(expected.dropLast()))
                guard matches else {
                    throw MCPAuthError.issuerMismatch(kind: "metadata", expected: expected, actual: metadata.issuer)
                }
            }
            return metadata
        }
        return nil
    }

    /// Find the authorization server of an MCP server: RFC 9728 first, else
    /// the server's origin as the authorization server (legacy fallback).
    public static func discoverServerInfo(
        serverURL: URL,
        resourceMetadataURL: URL? = nil,
        skipIssuerMetadataValidation: Bool = false,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPOAuthServerInfo {
        var resourceMetadata: MCPProtectedResourceMetadata?
        var authorizationServerURL: String?
        do {
            let found = try await discoverProtectedResourceMetadata(
                serverURL: serverURL,
                resourceMetadataURL: resourceMetadataURL,
                httpClient: httpClient
            )
            resourceMetadata = found
            authorizationServerURL = found.authorizationServers?.first
        } catch is MCPAuthError {
            // No protected resource metadata: fall back below. Transport
            // failures (URLError) propagate.
        }
        let server: String
        if let authorizationServerURL {
            server = authorizationServerURL
        } else {
            var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
            components?.path = "/"
            components?.query = nil
            components?.fragment = nil
            server = components?.url?.absoluteString ?? serverURL.absoluteString
        }
        let metadata = try await discoverAuthorizationServerMetadata(
            server,
            skipIssuerValidation: skipIssuerMetadataValidation,
            httpClient: httpClient
        )
        return MCPOAuthServerInfo(
            authorizationServerURL: server,
            authorizationServerMetadata: metadata,
            resourceMetadata: resourceMetadata
        )
    }
}
