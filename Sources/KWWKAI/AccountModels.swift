import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A login's own model list, for the providers whose list depends on the
/// account: what its plan offers, and the limits the provider gives each
/// model there. The bundled catalog cannot know either — it lists Copilot's
/// Claude models at Anthropic's window, and Kiro and Qoder models a free
/// plan refuses ("Invalid model ID", "unknown or disabled model") — so a
/// host asks here and falls back to `ModelsCatalog` when there is no answer.
public enum AccountModels {
    /// The stored logins that have a list of their own to ask for.
    public static let listingStoreIds: Set<String> = ["github-copilot", "kiro", "qoder", "qoder-cn"]

    public static func lists(storeId: String) -> Bool {
        listingStoreIds.contains(storeId)
    }

    /// The models `storeId`'s login may use, as the provider lists them, or
    /// nil for a provider with no list of its own. `token` is a fresh access
    /// token for it (`OAuthManager.apiKey`); `credentials` carry the rest of
    /// the login — Copilot's host, Kiro's profile, Qoder's account.
    public static func fetch(
        storeId: String,
        token: String,
        credentials: OAuthCredentials,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> [Model]? {
        var fresh = credentials
        fresh.access = token
        switch storeId {
        case "github-copilot":
            return try await fetchCopilot(token: token, credentials: credentials, client: client)
        case "kiro":
            return try await KiroModels.fetch(credentials: fresh, client: client).map(seeded)
        case "qoder", "qoder-cn":
            return try await QoderModels.fetch(site: .of(storeId), credentials: fresh, client: client)
        default:
            return nil
        }
    }

    /// The same, for a host that holds the login's `OAuthManager`. Use the
    /// manager the session's requests refresh through: two managers over one
    /// store can each spend the same single-use refresh token.
    public static func fetch(
        storeId: String,
        manager: OAuthManager,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> [Model]? {
        guard lists(storeId: storeId) else { return nil }
        let token = try await manager.apiKey(for: storeId)
        guard let credentials = try await manager.credentials(for: storeId) else {
            throw OAuthError.missing(providerId: storeId)
        }
        return try await fetch(storeId: storeId, token: token, credentials: credentials, client: client)
    }

    /// A live row keeps what the bundled seed knows of the same model and
    /// the list does not say — its display name, above all.
    private static func seeded(_ live: Model) -> Model {
        guard let seed = ModelsCatalog.model(provider: live.provider, id: live.id) else { return live }
        var out = live
        if live.name == live.id { out.name = seed.name }
        return out
    }

    // MARK: - GitHub Copilot

    static let copilotDefaultHost = "https://api.individual.githubcopilot.com"

    private static func fetchCopilot(
        token: String, credentials: OAuthCredentials, client: HTTPClient
    ) async throws -> [Model] {
        var host = copilotDefaultHost
        if case .string(let endpoint) = credentials.extras["endpoint"] ?? .null, !endpoint.isEmpty {
            host = endpoint
        }
        while host.hasSuffix("/") { host.removeLast() }
        guard let url = URL(string: "\(host)/models") else {
            throw ProviderFailure(message: "GitHub Copilot: the login's host is not a URL")
        }
        var headers = ProviderVariants.copilotEditorHeaders(integrationID: "vscode-chat")
        headers["authorization"] = "Bearer \(token)"
        headers["accept"] = "application/json"
        let (response, body) = try await client.request(url: url, method: "GET", headers: headers, body: nil)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                message: "GitHub Copilot listed no models (HTTP \(response.statusCode))",
                httpStatus: response.statusCode
            )
        }
        let models = try copilotModels(from: body, baseURL: host)
        guard !models.isEmpty else { throw ProviderFailure(message: "GitHub Copilot listed no models") }
        return models
    }

    /// Copilot's `GET /models`, the rows its own picker shows:
    ///
    ///     {"data": [{"id": "claude-sonnet-5", "name": "Claude Sonnet 5", "vendor": "Anthropic",
    ///       "model_picker_enabled": true, "policy": {"state": "enabled"},
    ///       "supported_endpoints": ["/v1/messages", "/chat/completions"],
    ///       "capabilities": {"type": "chat",
    ///         "limits": {"max_context_window_tokens": 264000, "max_prompt_tokens": 200000,
    ///                    "max_output_tokens": 64000},
    ///         "supports": {"adaptive_thinking": true, "tool_calls": true, "vision": true,
    ///                      "reasoning_effort": ["low", "medium", "high"]}}}]}
    ///
    /// A row the bundled catalog knows keeps that entry — its `compat` and
    /// thinking levels are not in the list — and takes the list's limits; a
    /// row it does not know is built from the list alone.
    static func copilotModels(from data: Data, baseURL: String) throws -> [Model] {
        struct List: Decodable {
            struct Row: Decodable {
                struct Policy: Decodable { var state: String? }
                struct Capabilities: Decodable {
                    struct Limits: Decodable {
                        var max_context_window_tokens: Int?
                        var max_prompt_tokens: Int?
                        var max_output_tokens: Int?
                    }
                    struct Supports: Decodable {
                        var adaptive_thinking: Bool?
                        var max_thinking_budget: Int?
                        var reasoning_effort: [String]?
                        var vision: Bool?
                        var tool_calls: Bool?
                    }
                    var type: String?
                    var limits: Limits?
                    var supports: Supports?
                }
                var id: String?
                var name: String?
                var vendor: String?
                var model_picker_enabled: Bool?
                var policy: Policy?
                var supported_endpoints: [String]?
                var capabilities: Capabilities?
            }
            var data: [Row]?
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        var out: [Model] = []
        var seen: Set<String> = []
        for row in list.data ?? [] {
            guard let id = row.id, !id.isEmpty, !seen.contains(id),
                  row.model_picker_enabled == true,
                  (row.capabilities?.type ?? "chat") == "chat",
                  row.policy?.state != "disabled",
                  row.capabilities?.supports?.tool_calls != false else { continue }
            seen.insert(id)
            let limits = row.capabilities?.limits
            let supports = row.capabilities?.supports
            let wires = copilotWires(row.supported_endpoints)

            var model: Model
            if let known = ModelsCatalog.model(provider: "github-copilot", id: id), wires.contains(known.api) {
                model = known
            } else {
                var compat = ModelCompat()
                let api = wires.first ?? "openai-completions"
                if api == "anthropic-messages", supports?.adaptive_thinking == true {
                    // Copilot turns down `thinking.type.enabled` for these.
                    compat.forceAdaptiveThinking = true
                }
                model = Model(
                    id: id, name: row.name ?? id, api: api, provider: "github-copilot",
                    reasoning: supports?.adaptive_thinking == true
                        || supports?.max_thinking_budget != nil
                        || !(supports?.reasoning_effort ?? []).isEmpty,
                    input: supports?.vision == true ? [.text, .image] : [.text],
                    compat: compat.forceAdaptiveThinking == true ? compat : nil
                )
            }
            model.baseURL = baseURL
            if let output = limits?.max_output_tokens, output > 0 { model.maxTokens = output }
            // A prompt is budgeted as the window less the output reserve, so
            // the window is what Copilot takes in plus what it gives back.
            if let window = limits?.max_context_window_tokens, window > 0 {
                if let prompt = limits?.max_prompt_tokens, prompt > 0, let output = limits?.max_output_tokens {
                    model.contextWindow = min(window, prompt + output)
                } else {
                    model.contextWindow = window
                }
            }
            out.append(model)
        }
        return out
    }

    /// The wires kwwk speaks among a row's endpoints, the one to prefer
    /// first. A row that names none is a chat-completions model.
    private static func copilotWires(_ endpoints: [String]?) -> [String] {
        guard let endpoints, !endpoints.isEmpty else { return ["openai-completions"] }
        var wires: [String] = []
        if endpoints.contains("/v1/messages") { wires.append("anthropic-messages") }
        if endpoints.contains("/responses") { wires.append("openai-responses") }
        if endpoints.contains("/chat/completions") { wires.append("openai-completions") }
        return wires
    }
}

/// The account lists a session has read, by stored login. Read from any
/// thread: a model picker asks it synchronously and gets the last answer.
public final class AccountModelLists: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [String: [Model]] = [:]

    public init() {}

    /// The login's own list, or nil while none has been read — the caller
    /// then shows the bundled catalog.
    public func models(forStoreId storeId: String) -> [Model]? {
        lock.withLock { lists[storeId] }
    }

    public func set(_ models: [Model], forStoreId storeId: String) {
        lock.withLock { lists[storeId] = models }
    }

    public func remove(storeId: String) {
        lock.withLock { lists[storeId] = nil }
    }

    /// Reads `storeId`'s list and keeps it. A failure keeps the last answer:
    /// the list is a refinement, and being offline must not empty a picker.
    @discardableResult
    public func refresh(
        storeId: String,
        token: String,
        credentials: OAuthCredentials,
        client: HTTPClient = URLSessionHTTPClient()
    ) async -> Bool {
        guard let models = try? await AccountModels.fetch(
            storeId: storeId, token: token, credentials: credentials, client: client
        ), !models.isEmpty else { return false }
        set(models, forStoreId: storeId)
        return true
    }
}
