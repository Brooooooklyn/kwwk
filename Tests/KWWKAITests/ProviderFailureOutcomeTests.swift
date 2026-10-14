import Foundation
import Testing
@testable import KWWKAI

/// `ProviderFailure.outcome` is what hosts (the AirBuild Environment, the
/// app) show and act on. The provider quirks behind it live here, once; the
/// recorded refusals under Fixtures/ProviderErrors pin the rest.
@Suite("Provider failure outcome")
struct ProviderFailureOutcomeTests {
    @Test("provider quirks land on the outcome they mean", arguments: [
        // Kimi refuses an over-plan context as 401.
        (ProviderFailure(message: #"{"error":{"type":"authentication_error","message":"Your current plan supports only k3 up to 256K context. 1M context is available on higher-tier Kimi Code plans."},"type":"error"}"#, httpStatus: 401), ProviderFailure.Outcome.contextTooLong),
        // Kimi reports a spent plan window as 403.
        (ProviderFailure(message: "You've reached your 5-hour usage limit. Your quota will reset when the current 5-hour window ends. To continue now, purchase extra usage or upgrade your plan: https://www.kimi.com/membership/subscription?tab=quota", httpStatus: 403), .quotaExhausted),
        // Cursor's region refusal is not about the login.
        (ProviderFailure(message: "This region is not yet available for your team", providerCode: "unauthenticated"), .requestRejected),
        // A 403 naming the plan is the account's limit, not a dead login.
        (ProviderFailure(message: "Your plan does not include this model", httpStatus: 403), .accessDenied),
        // A gRPC `unauthenticated` with no status is a refused login.
        (ProviderFailure(message: "Authentication error: If you are logged in, try logging out and back in.", providerCode: "unauthenticated"), .signInRequired),
        (ProviderFailure(message: "overloaded", httpStatus: 529), .serviceUnavailable),
        (ProviderFailure(message: "slow down", httpStatus: 429), .rateLimited),
    ])
    func quirks(failure: ProviderFailure, outcome: ProviderFailure.Outcome) {
        #expect(failure.outcome == outcome, "\(failure)")
    }

    @Test("every subscription carries the brand a sentence names it by")
    func brands() {
        for provider in OAuthSubscriptions.providers {
            #expect(!provider.brand.isEmpty, "\(provider.id)")
        }
        #expect(OAuthSubscriptions.provider(id: "openai-codex")?.brand == "Codex")
        #expect(OAuthSubscriptions.provider(id: "anthropic")?.brand == "Claude")
        #expect(OAuthSubscriptions.provider(id: "xai")?.brand == "Grok")
    }
}
