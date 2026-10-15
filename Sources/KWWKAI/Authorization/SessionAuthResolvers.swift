/// Thread-safe, mutable map of per-provider auth resolvers keyed by
/// `model.provider` scope. The agent holds one **stable** closure
/// (`delegatingResolver()`) that reads through here, so `/login` can install a
/// newly-authenticated provider's resolver mid-session and its tokens resolve
/// on the next request — no agent rebuild. Static api-key providers have no
/// entry; `resolve` returns nil and the provider falls back to its baked key.
public actor SessionAuthResolvers {
    private var map: [String: @Sendable (Model, String?) async throws -> ResolvedProviderAuth?]

    public init(_ initial: [String: @Sendable (Model, String?) async throws -> ResolvedProviderAuth?] = [:]) {
        self.map = initial
    }

    public func set(
        scope: String,
        _ resolver: @escaping @Sendable (Model, String?) async throws -> ResolvedProviderAuth?
    ) {
        map[scope] = resolver
    }

    public func remove(scope: String) {
        map.removeValue(forKey: scope)
    }

    public func resolve(_ model: Model, _ sessionId: String?) async throws -> ResolvedProviderAuth? {
        guard let r = map[model.provider] else { return nil }
        return try await r(model, sessionId)
    }

    /// One stable delegating closure to hand the agent. It closes over this
    /// actor, so later `set` / `remove` calls are visible without swapping the
    /// agent's `authResolver`.
    public nonisolated func delegatingResolver() -> @Sendable (Model, String?) async throws -> ResolvedProviderAuth? {
        { model, sid in try await self.resolve(model, sid) }
    }
}
