import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where an account's Runs go.
///
/// Runs go to `api2.cursor.sh` (the model's `baseURL`), which serves an
/// account wherever it is. A team Cursor serves in one region only is turned
/// away there — `unauthenticated`, "This region is not yet available for your
/// team" — and has to be run on the agent API Cursor's server config names for
/// the account: `ServerConfigService/GetServerConfig`'s `agentUrlConfig`,
/// which cursor-agent reads the same way (magpie 0984edaa, the plugin's
/// `agentURL`). So a Run refused over a region asks the config and is tried
/// once more there, and the account's later Runs go there directly.
///
/// The plugin asks the config before an account's first Run. kwwk asks only
/// after a refusal: measured 2026-10-13, the config names
/// `agentn.global.api5.cursor.sh` for an account `api2.cursor.sh` serves
/// just as well, so asking first would cost every process a request to
/// learn nothing.
struct CursorAgentEndpoint: Equatable, Sendable {
    var host: String
    var port: Int = 443
    /// What precedes `/agent.v1.AgentService/Run`, without a trailing slash.
    var pathPrefix: String = ""

    func path(_ rpc: String) -> String { pathPrefix + rpc }

    /// The agent API a `GetServerConfig` reply names: `agentUrl`, which
    /// cursor-agent takes in privacy mode — the mode every Run here asks for
    /// (`x-ghost-mode`) — else `agentnUrl`. Nil when it names none that can
    /// be dialled.
    static func named(byServerConfig body: Data) -> CursorAgentEndpoint? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let config = root["agentUrlConfig"] as? [String: Any] else { return nil }
        for raw in [config["agentUrl"], config["agentnUrl"]] {
            guard let text = raw as? String, let url = URL(string: text),
                  url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { continue }
            var prefix = url.path
            while prefix.hasSuffix("/") { prefix.removeLast() }
            return CursorAgentEndpoint(host: host, port: url.port ?? 443, pathPrefix: prefix)
        }
        return nil
    }

    /// Whether a failure is Cursor refusing the region, as the plugin's
    /// `regional` reads it.
    static func isRegionRefusal(_ failure: ProviderFailure) -> Bool {
        failure.message.lowercased().contains("region")
    }

    /// Ask Cursor's API which agent API serves the account behind `apiKey`;
    /// nil when the config cannot be had or names none.
    static func resolve(
        apiKey: String, apiHost: String, clientVersion: String, client: HTTPClient,
        cancellation: CancellationHandle? = nil
    ) async -> CursorAgentEndpoint? {
        guard let url = URL(string: "https://\(apiHost)/aiserver.v1.ServerConfigService/GetServerConfig") else {
            return nil
        }
        guard let (response, body) = try? await client.request(
            url: url,
            method: "POST",
            headers: [
                "content-type": "application/json",
                "connect-protocol-version": "1",
                "authorization": "Bearer \(apiKey)",
                "x-cursor-client-version": clientVersion,
                "x-cursor-client-type": "cli",
                "x-ghost-mode": "true",
            ],
            body: Data("{}".utf8),
            cancellation: cancellation
        ), response.statusCode < 300 else { return nil }
        return named(byServerConfig: body)
    }
}

/// The agent API each account was moved to after a region refusal, by the
/// hash of its token, for the life of the process.
final class CursorAgentEndpoints: @unchecked Sendable {
    private let lock = NSLock()
    private var learned: [String: CursorAgentEndpoint] = [:]

    private static func key(_ apiKey: String) -> String {
        SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func endpoint(for apiKey: String) -> CursorAgentEndpoint? {
        lock.withLock { learned[Self.key(apiKey)] }
    }

    func remember(_ endpoint: CursorAgentEndpoint, for apiKey: String) {
        lock.withLock { learned[Self.key(apiKey)] = endpoint }
    }
}
