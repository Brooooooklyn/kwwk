import Foundation
import KWWKAI

extension MCPOAuth {
    // MARK: - Client metadata and registration

    /// The provider's client metadata with the defaults the flow relies on:
    /// `grant_types` `authorization_code` + `refresh_token` (SEP-2207) and
    /// `application_type` from the redirect URIs (SEP-837). Values the
    /// provider set are kept.
    public static func resolveClientMetadata(_ provider: any MCPOAuthClientProvider) -> MCPOAuthClientMetadata {
        var metadata = provider.clientMetadata
        if metadata.grantTypes == nil { metadata.grantTypes = ["authorization_code", "refresh_token"] }
        if metadata.applicationType == nil { metadata.applicationType = applicationType(for: metadata.redirectURIs) }
        return metadata
    }

    static func applicationType(for redirectURIs: [String]) -> String {
        for raw in redirectURIs {
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { continue }
            if scheme != "http" && scheme != "https" { return "native" }
            if isLoopbackHost(url.host) { return "native" }
        }
        return "web"
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
    }

    static func isHTTPSURLWithPath(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !url.path.isEmpty && url.path != "/"
    }

    /// RFC 7591 dynamic client registration.
    public static func registerClient(
        authorizationServerURL: String,
        metadata: MCPAuthorizationServerMetadata?,
        clientMetadata: MCPOAuthClientMetadata,
        scope: String?,
        httpClient: any MCPAuthHTTPClient
    ) async throws -> MCPOAuthClientInformation {
        let endpoint: URL
        if let metadata {
            guard let registration = metadata.registrationEndpoint, let url = URL(string: registration) else {
                throw MCPAuthError.incompatibleServer("does not support dynamic client registration")
            }
            endpoint = url
        } else {
            guard let url = URL(string: "/register", relativeTo: URL(string: authorizationServerURL))?.absoluteURL else {
                throw MCPAuthError.incompatibleServer("invalid authorization server URL \(authorizationServerURL)")
            }
            endpoint = url
        }
        var submitted = clientMetadata
        if let scope { submitted.scope = scope }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let response = try await MCPAuthHTTP.send(MCPAuthHTTPRequest(
            url: endpoint,
            method: "POST",
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: try encoder.encode(submitted)
        ), using: httpClient)
        guard response.isSuccess else {
            throw MCPAuthError.registrationRejected(status: response.status, body: response.text)
        }
        do {
            var information = try JSONDecoder().decode(MCPOAuthClientInformation.self, from: response.body)
            // Only the client stamps the issuer.
            information.issuer = nil
            return information
        } catch {
            throw MCPAuthError.requestFailed("Invalid client registration response: \(error)")
        }
    }
}
