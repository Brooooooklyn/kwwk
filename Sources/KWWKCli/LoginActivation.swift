import Foundation
import KWWKAI
import KWWKAgent

/// API-key leg of `/login`: pack the submitted form values into sentinel
/// credentials, persist them (no stdout — the TUI is live; confirmation goes
/// through `ctx.notify`), then register the fresh provider live. `store` is
/// injectable so tests can point it at a temp file instead of the user's
/// real `~/.kwwk/oauth.json`.
@MainActor
func completeAPIKeyLogin(
    values: [String: String],
    storeId: String,
    extrasKeys: [String],
    ctx: SlashContext,
    authResolvers: SessionAuthResolvers,
    store: OAuthStore
) async {
    guard let credentials = apiKeyCredentials(values: values, extrasKeys: extrasKeys) else {
        ctx.notify(Style.error("  /login: API key required"))
        return
    }
    let saved: SavedLogin
    do {
        saved = try await saveCredentials(credentials, providerId: storeId, store: store)
    } catch {
        ctx.notify(Style.error("  /login: couldn't save credentials: \(error.localizedDescription)"))
        return
    }
    var lines = [Style.dimmed("  /login: saved \(storeId) credentials → \(saved.path)")]
    if !saved.otherProviderIds.isEmpty {
        lines.append(Style.dimmed("    (also logged in: \(saved.otherProviderIds.joined(separator: ", ")))"))
    }
    ctx.notifyBlock(lines)
    await activateFreshLogin(storeId: storeId, ctx: ctx, authResolvers: authResolvers, store: store)
}

/// Shared post-login registration for both `/login` legs: same-scope dedup,
/// live registration, session-slot upsert, and — when this is the first
/// provider of a logged-out session — activation of the fresh provider as
/// the live model so the user can prompt immediately.
@MainActor
func activateFreshLogin(
    storeId: String,
    ctx: SlashContext,
    authResolvers: SessionAuthResolvers,
    store: OAuthStore? = nil
) async {
    // Same-scope dedup, mirroring launch-time registerAllStored: two store ids
    // can share one wire scope (Anthropic OAuth + Anthropic API key both →
    // `anthropic`). Don't let a second same-scope login clobber the active
    // provider's registration/resolver this session. The credentials are still
    // saved on disk; priority order decides on the next launch.
    // Compare against each incumbent slot's ACTUAL registered scope
    // (template.provider), not one re-derived from its storeId: an
    // env-authenticated incumbent has storeId "env:<provider>" for which
    // modelProviderScope has no case, but its template.provider is the real
    // wire scope — so deriving from storeId would miss the collision.
    let newScope = modelProviderScope(forStoreId: storeId)
    if let existing = ctx.sessionProviders.slots.first(where: {
        $0.storeId != storeId && $0.template.provider == newScope
    }) {
        ctx.notify(Style.dimmed(
            "  /login: saved \(storeId), but it shares a provider slot with the active \(existing.storeId) — /logout \(existing.storeId) first to use it"
        ))
        return
    }
    guard let slot = await registerStoredProviderLive(
        storeId: storeId, authResolvers: authResolvers, context1m: ctx.context1m, store: store
    ) else {
        ctx.notify(Style.error("  /login: '\(storeId)' logged in but couldn't be activated"))
        return
    }
    let wasLoggedOut = ctx.sessionProviders.slots.isEmpty
    ctx.sessionProviders.upsert(slot)
    if wasLoggedOut {
        // First login of a logged-out session: replace the sentinel model so
        // the user can prompt without an extra /model trip.
        ctx.agent.state.model = slot.template
        ctx.notify(Style.dimmed("  /login: \(slot.displayName) ready — now on \(slot.template.id)"))
    } else {
        ctx.notify(Style.dimmed("  /login: \(slot.displayName) ready — /model to switch to it"))
    }
}

/// `/logout` body with the credential store injected, so tests can drive it
/// against a temp file instead of the user's real `~/.kwwk/oauth.json`.
@MainActor
func performLogout(_ ctx: SlashContext, _ args: String, store: OAuthStore) async {
    let target = args.trimmingCharacters(in: .whitespacesAndNewlines)
    let all = await store.all()
    if all.isEmpty {
        ctx.notify(Style.dimmed("  /logout: no stored logins (running on env keys or none)"))
        return
    }
    let ids = storedProviderOrder(all)

    if target.isEmpty {
        var lines = [Style.dimmed("  logged-in providers:")]
        for id in ids {
            let isActive = ctx.agent.state.model.provider == modelProviderScope(forStoreId: id)
            let tag = isActive ? Style.dimmed("  · active") : ""
            lines.append("    " + id + "  " + Style.dimmed(providerDisplayName(forStoreId: id)) + tag)
        }
        lines.append(Style.dimmed("  /logout <provider> to remove one"))
        ctx.notifyBlock(lines)
        return
    }

    guard ids.contains(target) else {
        ctx.notify(Style.error("  /logout: '\(target)' is not logged in — run /logout to list"))
        return
    }

    let scope = modelProviderScope(forStoreId: target)
    // Only the store id that actually OWNS this session's slot for the scope
    // may tear down the scope's live registration. A shadowed same-scope login
    // (e.g. logging out `anthropic-api-key` while `anthropic` OAuth owns the
    // `anthropic` scope) was never registered — removing it from disk is
    // enough; touching the scope would wrongly unregister the active provider.
    let ownsSlot = ctx.sessionProviders.slot(forStoreId: target) != nil
    try? await store.remove(target)

    guard ownsSlot else {
        ctx.notify(Style.dimmed("  /logout: removed \(target) (was shadowed by a same-vendor login)"))
        return
    }

    await APIRegistry.shared.unregisterScope(scope)
    if let ar = ctx.authResolvers { await ar.remove(scope: scope) }
    ctx.sessionProviders.remove(storeId: target)
    let resetCompactionModel = ctx.agent.compactionModel?.provider == scope
    if resetCompactionModel {
        ctx.agent.compactionModel = nil
    }
    let compactionSuffix = resetCompactionModel
        ? "; compaction model now follows /model"
        : ""

    // If the removed provider was the one in use, switch to a survivor so the
    // next request doesn't hit a now-unregistered provider. (A same-vendor
    // login still on disk isn't re-homed this session — it's available on the
    // next launch, where priority order re-registers it.) With no survivor
    // the session returns to the logged-out sentinel state: prompt submission
    // and /model are gated on the empty slot list, and the next /login
    // re-activates a live model.
    if ctx.agent.state.model.provider == scope {
        if let next = ctx.sessionProviders.slots.first {
            ctx.agent.state.model = next.template
            ctx.notify(Style.dimmed("  /logout: removed \(target); now on \(next.template.id) · \(next.displayName)\(compactionSuffix)"))
        } else {
            ctx.agent.state.model = loggedOutModel
            ctx.notify(Style.dimmed("  /logout: removed \(target) — no providers left; /login to sign in\(compactionSuffix)"))
        }
    } else {
        ctx.notify(Style.dimmed("  /logout: removed \(target)\(compactionSuffix)"))
    }
}
