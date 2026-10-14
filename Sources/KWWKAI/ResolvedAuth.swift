import Foundation

/// Result of resolving which LLM + credentials to use for this session.
/// The provider has already been registered on `APIRegistry.shared`.
public struct ResolvedAuth: Sendable {
    public let model: Model
    public let modelLabel: String
    /// For OAuth-backed providers (Codex, Anthropic OAuth, ...), an
    /// `authResolver` that calls back into `OAuthManager.apiKey(for:)` so
    /// tokens refresh on demand. Nil for static api-key providers.
    public let authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
    /// Every provider registered this session, so the CLI's `/model` can list
    /// + switch across all logged-in accounts. Single-login / env auth yields
    /// one slot.
    public let providerSlots: [ProviderSlot]
    /// The mutable resolver map the agent's `authResolver` delegates to, so
    /// `/login` can add a provider mid-session. Nil for the single-provider
    /// helper paths that don't own one.
    public let authResolvers: SessionAuthResolvers?

    public init(
        model: Model,
        modelLabel: String,
        authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)? = nil,
        providerSlots: [ProviderSlot] = [],
        authResolvers: SessionAuthResolvers? = nil
    ) {
        self.model = model
        self.modelLabel = modelLabel
        self.authResolver = authResolver
        self.providerSlots = providerSlots
        self.authResolvers = authResolvers
    }
}

public enum AuthResolveError: Error, LocalizedError {
    case noCredentials
    case unsupportedProvider(String)

    public var errorDescription: String? {
        switch self {
        case .noCredentials:
            return """
            No credentials configured.

            Launch `kwwk` and run `/login` to pick a provider (OAuth
            subscription or API key), or export a supported API-key
            environment variable (ANTHROPIC_API_KEY, OPENAI_API_KEY,
            GEMINI_API_KEY, OPENROUTER_API_KEY, ...).
            """
        case .unsupportedProvider(let id):
            return """
            Stored credentials for '\(id)' are not yet wired up. Launch
            `kwwk` and run `/login` to pick a different provider.
            """
        }
    }
}

/// One logged-in provider's session-scoped routing template. The CLI's
/// `/model` uses `template` to stamp correct wire routing (api / provider
/// scope / baseURL / headers) onto any catalog model the user switches to,
/// and lists that provider's catalog under `catalogProvider` / `displayName`.
public struct ProviderSlot: Sendable {
    /// The OAuth-store key this provider was logged in under
    /// (`anthropic`, `openai-codex`, `github-copilot`, `anthropic-api-key`, …),
    /// or a synthetic `env:<provider>` marker for environment-key auth.
    public let storeId: String
    /// The `ModelsCatalog.byProvider` key whose models this slot lists.
    public let catalogProvider: String
    /// Human label shown as the group header in the `/model` picker.
    public let displayName: String
    /// The default model built at registration time — carries the resolved
    /// wire `api`, provider scope, session `baseURL`, and headers that every
    /// model under this provider must route through.
    public let template: Model

    public init(
        storeId: String,
        catalogProvider: String,
        displayName: String,
        template: Model
    ) {
        self.storeId = storeId
        self.catalogProvider = catalogProvider
        self.displayName = displayName
        self.template = template
    }
}
