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

    /// The AirBuild Environment's rules for what a user is told, now kwwk's:
    /// prose names no cause, the outer 5xx governs, and transport evidence
    /// alone says only network, timeout or cancelled.
    @Test("prose alone names no cause", arguments: [
        "HTTP 402 insufficient_quota", "model not found", "quota exceeded", "authentication_error",
        "Error Domain=NSURLErrorDomain Code=-1001", "connection failed", "usage_limit_reached",
    ])
    func proseIsUnknown(text: String) {
        #expect(ProviderFailure(message: text).outcome == .unknown)
    }

    @Test("a 5xx governs whatever code rides along")
    func serverStatusGoverns() {
        #expect(ProviderFailure(message: "x", httpStatus: 503, providerCode: "insufficient_quota").outcome == .serviceUnavailable)
        #expect(ProviderFailure(message: "x", httpStatus: 504).outcome == .timeout)
    }

    @Test("transport evidence alone says only network, timeout or cancelled")
    func transportOnly() {
        #expect(ProviderFailure(message: "x", transportDomain: NSURLErrorDomain, transportCode: -1001).outcome == .timeout)
        #expect(ProviderFailure(message: "x", transportDomain: NSURLErrorDomain, transportCode: -1005).outcome == .network)
        #expect(ProviderFailure(message: "x", transportDomain: NSURLErrorDomain, transportCode: -999).outcome == .cancelled)
        #expect(ProviderFailure(message: "x", transportDomain: NSPOSIXErrorDomain, transportCode: Int.max).outcome == .unknown)
    }
}
