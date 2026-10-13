import Foundation

// MARK: - Qoder / Qoder CN (OAuth subscription)

/// Registers a stored Qoder login for `site` (`qoder` or `qoder-cn`). Called
/// from `registerStored`.
func registerQoder(
    site: QoderSite,
    manager: OAuthManager,
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
    // Prime the token only for the active provider; the resolver refreshes
    // lazily on the first request for the others. Qoder's refresh token
    // rotates on use, so the manager's single in-flight refresh matters.
    if primeToken {
        _ = try? await manager.apiKey(for: site.id)
    }
    await APIRegistry.shared.register(QoderChatProvider(), scope: site.id)
    let model = qoderModel(id: modelOverride ?? QoderModels.defaultModelId, site: site)
    return ResolvedAuth(
        model: model,
        modelLabel: "\(model.id) · \(site.name)",
        authResolver: qoderResolver(manager: manager, site: site)
    )
}

/// A Qoder request is signed for an account, not just a token: the COSY
/// envelope names the user id and the machine id the sign-in made, so the
/// resolver hands those on beside the (refreshed) chat token.
private func qoderResolver(
    manager: OAuthManager, site: QoderSite
) -> @Sendable (Model, String?) async throws -> ResolvedProviderAuth? {
    { _, _ in
        do {
            let token = try await manager.apiKey(for: site.id)
            let extras = try await manager.credentials(for: site.id)?.extras ?? [:]
            return ResolvedProviderAuth(
                token: token, scheme: .bearer,
                metadata: extras.filter { ["uid", "machineId", "name", "email"].contains($0.key) }
            )
        } catch OAuthError.missing, OAuthError.unknownProvider {
            // Not logged in ⇒ nil, and the provider says to sign in. Any
            // other failure (a refused refresh) propagates.
            return nil
        }
    }
}
