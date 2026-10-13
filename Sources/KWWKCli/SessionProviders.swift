import Foundation
import KWWKAI

// `ProviderSlot` and `SessionAuthResolvers` live in `KWWKAI` (see
// `StoredProviders.swift` there); this file keeps the TUI-side session state.

/// Mutable, session-scoped set of logged-in providers. Shared by `/model`
/// (reads, to list + route across providers), `/login` (appends a freshly
/// authenticated provider), and `/logout` (removes one). Reference type so a
/// single instance is observed by every slash handler.
@MainActor
final class SessionProviders {
    private(set) var slots: [ProviderSlot]
    /// Each login's own model list, where its provider has one; `/model`
    /// shows it in place of the bundled catalog once it has been read.
    let accountModels = AccountModelLists()

    /// The session's logged-out invariant: no provider slot is registered.
    /// Single predicate shared by the prompt gate, `/goal`, `/model`, and the
    /// goal-continuation loop so they can never drift onto different
    /// definitions of "logged out".
    var isLoggedOut: Bool { slots.isEmpty }

    init(_ slots: [ProviderSlot] = []) {
        self.slots = slots
    }

    /// Add or replace the slot for a provider (re-login overwrites its
    /// template), keeping priority order stable by de-duplicating on storeId.
    func upsert(_ slot: ProviderSlot) {
        slots.removeAll { $0.storeId == slot.storeId }
        slots.append(slot)
    }

    func remove(storeId: String) {
        slots.removeAll { $0.storeId == storeId }
        accountModels.remove(storeId: storeId)
    }

    /// Reads the own lists of the given logins (all of them by default) in
    /// the background. The token comes through the session's resolvers, so
    /// a refresh here is the same one a request would make.
    func refreshAccountModels(authResolvers: SessionAuthResolvers?, only storeId: String? = nil) {
        guard let authResolvers else { return }
        let lists = accountModels
        for slot in slots where AccountModels.lists(storeId: slot.storeId) && (storeId ?? slot.storeId) == slot.storeId {
            Task.detached(priority: .utility) {
                guard let token = try? await authResolvers.resolve(slot.template, nil)?.token,
                      let store = try? OAuthStore(url: OAuthStore.defaultURL()),
                      let credentials = await store.get(slot.storeId) else { return }
                await lists.refresh(storeId: slot.storeId, token: token, credentials: credentials)
            }
        }
    }

    func slot(forStoreId storeId: String) -> ProviderSlot? {
        slots.first { $0.storeId == storeId }
    }
}
