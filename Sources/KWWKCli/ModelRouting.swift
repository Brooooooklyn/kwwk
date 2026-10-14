import Foundation
import KWWKAI

/// Merge routing info from the current live session onto `picked`. Two
/// regimes:
///
///   - **Same provider** (`current.provider == picked.provider`): the
///     catalog entry already carries the correct wire api, baseURL, and
///     headers — e.g. Copilot models vary per-model across
///     openai-completions / anthropic-messages / openai-responses, and
///     we registered all three variants at login. Just take `picked`
///     as-is.
///   - **Variant-routed provider** (Codex): catalog lists models under
///     `openai-codex` but we registered the live provider under the
///     variant key `chatgpt-codex`. Carry `current`'s routing across so
///     the first request after a switch doesn't hit the canonical
///     endpoint we never registered a token for. Also preserves the
///     Codex-specific `maxTokens == 0` sentinel (do not emit
///     `max_output_tokens`).
///
/// `clampToSessionLimits` preserves route-level limits that are stricter than
/// the shared catalog (currently Anthropic OAuth without the 1M beta and the
/// Claude Code 64k output ceiling). API-key sessions leave it false.
///
/// Internal (not private) so regression tests can pin the sentinel logic.
func adoptFields(
    from current: Model,
    into picked: Model,
    clampToSessionLimits: Bool = false
) -> Model {
    if current.provider == picked.provider {
        // Same provider — adopt picked's identity, wire (api), and
        // capabilities, but keep the session's `baseURL`. The session
        // baseURL carries two things the catalog doesn't:
        //   - Enterprise / Business Copilot's proxy host (refreshed
        //     from the session token's `endpoints.api` claim)
        //   - A user-supplied custom host for `openai-compatible` or
        //     `anthropic-api-key` / `openai-api-key` logins
        // The catalog entry's `baseURL` is the canonical upstream
        // (`https://api.openai.com/v1`, etc.), which can round-trip
        // into double-`/v1` when our providers append their own
        // suffix. Holding the session value is both correct and
        // defensive.
        let isLimitedAnthropicSessionRoute = clampToSessionLimits
            && current.provider == "anthropic"
            && current.api == "anthropic-messages"
        let routedContextWindow = isLimitedAnthropicSessionRoute
            ? min(current.contextWindow, picked.contextWindow)
            : picked.contextWindow
        let routedMaxTokens = isLimitedAnthropicSessionRoute
            ? (picked.maxTokens > 0
                ? min(AnthropicProvider.claudeCodeMaximumOutputTokens, picked.maxTokens)
                : AnthropicProvider.claudeCodeMaximumOutputTokens)
            : picked.maxTokens
        return Model(
            id: picked.id,
            name: picked.name,
            api: picked.api,
            provider: picked.provider,
            baseURL: current.baseURL,
            reasoning: picked.reasoning,
            input: picked.input,
            cost: picked.cost,
            contextWindow: routedContextWindow,
            maxTokens: routedMaxTokens,
            headers: picked.headers,
            compat: picked.compat,
            thinkingLevelMap: picked.thinkingLevelMap
        )
    }
    let resolvedMaxTokens = current.maxTokens == 0 ? 0 : picked.maxTokens
    return Model(
        id: picked.id,
        name: picked.name,
        api: current.api,
        provider: current.provider,
        baseURL: current.baseURL,
        reasoning: picked.reasoning,
        input: picked.input,
        cost: picked.cost,
        contextWindow: picked.contextWindow,
        maxTokens: resolvedMaxTokens,
        headers: current.headers,
        compat: picked.compat,
        thinkingLevelMap: picked.thinkingLevelMap
    )
}
