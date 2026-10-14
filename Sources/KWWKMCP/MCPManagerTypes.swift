import Foundation
import KWWKAgent

/// An MCP tool adapted for the agent.
public struct MCPAgentTool: Sendable {
    /// The agent tool (`mcp__<server>__<tool>`).
    public var tool: AgentTool
    /// Name of the server that offers it.
    public var server: String
}

/// Connection state of one server.
public enum MCPServerState: Sendable, Hashable {
    case connecting
    case connected
    /// The connection dropped after it was established. Its tools stay; the
    /// manager reconnects in the background, and a tool call reconnects too.
    case disconnected(String)
    /// Connecting failed. The manager retries in the background a few times,
    /// then once more on the next tool search or call.
    case failed(String)
    /// The server refused the credentials: a 401 its auth provider could not
    /// recover from, or a 403 `insufficient_scope` while connecting. Its
    /// tools are withdrawn and nothing reconnects in the background; a tool
    /// search, or a `callTool`, connects again only once the provider has a
    /// token other than the refused one.
    case authorizationRequired(String?)
    /// The manager was shut down.
    case closed
}

/// Status of one server, for UI.
public struct MCPServerStatus: Sendable, Hashable {
    public var name: String
    public var state: MCPServerState
    /// Tools the server offers (including hidden ones).
    public var toolCount: Int
    public var serverInfo: MCPServerInfo?
}

/// Background reconnection after a dropped or failed connection.
public struct MCPReconnectPolicy: Sendable, Hashable {
    /// Background attempts after a drop or failure before giving up until
    /// the next tool search or call.
    public var maxAttempts: Int
    public var initialDelaySeconds: Double
    public var maxDelaySeconds: Double

    public init(maxAttempts: Int = 5, initialDelaySeconds: Double = 1, maxDelaySeconds: Double = 30) {
        self.maxAttempts = maxAttempts
        self.initialDelaySeconds = initialDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
    }

    public static let `default` = MCPReconnectPolicy()
    /// No background reconnection.
    public static let none = MCPReconnectPolicy(maxAttempts: 0)

    func delay(afterFailures failures: Int) -> Double {
        let exponent = Double(max(0, failures - 1))
        return min(maxDelaySeconds, initialDelaySeconds * pow(2, exponent))
    }
}

/// Errors of `MCPManager` tool calls.
public enum MCPManagerError: Error, LocalizedError, Sendable, Equatable {
    case unknownServer(String)
    case duplicateServer(String)
    case unavailable(String, String)
    case authorizationRequired(String)
    /// The server refused one call for want of scope (the scope it asked
    /// for, if it said).
    case insufficientScope(String, String?)
    case shutDown

    public var errorDescription: String? {
        switch self {
        case .unknownServer(let name): return "Unknown MCP server \"\(name)\""
        case .duplicateServer(let name): return "MCP server \"\(name)\" already exists"
        case .unavailable(let name, let reason): return "MCP server \"\(name)\" is not available: \(reason)"
        case .authorizationRequired(let name): return "MCP server \"\(name)\" requires authorization."
        case .insufficientScope(let name, let scope):
            let detail = scope.map { " (scope: \($0))" } ?? ""
            return "MCP server \"\(name)\" refused this call: the authorization lacks permission for it\(detail)."
        case .shutDown: return "MCP servers were shut down"
        }
    }
}
