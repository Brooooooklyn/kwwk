import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

/// A spent subscription/plan window versus a momentary burst (YEL-521).
@Suite("Provider failure — spent plan vs rate limit")
struct ProviderFailureQuotaTests {
    static let anthropicBody = #"{"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed your account's rate limit. Please try again later."}}"#

    static func http(_ status: Int, headers: [String: String], body: String) async -> ProviderFailure {
        let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: status,
                                       httpVersion: nil, headerFields: headers)!
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data(body.utf8))
            continuation.finish()
        }
        return await ProviderFailure.http(response, body: stream, now: Date(timeIntervalSince1970: 1_000_000))
    }

    @Test func anthropicUnifiedRejectedIsQuotaWithReset() async {
        let failure = await Self.http(429, headers: [
            "anthropic-ratelimit-unified-status": "rejected",
            "anthropic-ratelimit-unified-reset": "1790000000",
            "anthropic-ratelimit-unified-representative-claim": "five_hour",
            "anthropic-ratelimit-unified-5h-status": "rejected",
        ], body: Self.anthropicBody)
        #expect(failure.httpStatus == 429)
        #expect(failure.providerCode == "usage_limit_reached")
        #expect(failure.category == .quota)
        #expect(failure.resetsAt == 1_790_000_000)
        #expect(failure.limitWindow == "five_hour")
        #expect(failure.shouldRetry == false)
        #expect(!failure.isRetryable)
        #expect(ProviderRetryPolicy(baseDelayMs: 0).delay(for: failure, attempt: 0) == nil)
    }

    @Test func anthropicRejectedWithoutResetStillQuota() async {
        let failure = await Self.http(429, headers: ["Anthropic-Ratelimit-Unified-Status": "Rejected"], body: Self.anthropicBody)
        #expect(failure.category == .quota)
        #expect(failure.resetsAt == nil)
        #expect(failure.limitWindow == nil)
        #expect(!failure.isRetryable)
    }

    @Test(arguments: ["allowed", "allowed_warning"])
    func anthropicUnifiedAllowedStaysRateLimit(status: String) async {
        let failure = await Self.http(429, headers: [
            "anthropic-ratelimit-unified-status": status,
            "anthropic-ratelimit-unified-reset": "1790000000",
            "anthropic-ratelimit-unified-representative-claim": "five_hour",
        ], body: Self.anthropicBody)
        #expect(failure.category == .rateLimit)
        #expect(failure.resetsAt == nil)
        #expect(failure.isRetryable)
    }

    @Test func anthropicRejectedWithOverageAllowedIsNotQuota() async {
        let failure = await Self.http(429, headers: [
            "anthropic-ratelimit-unified-status": "rejected",
            "anthropic-ratelimit-unified-overage-status": "allowed",
        ], body: Self.anthropicBody)
        #expect(failure.category == .rateLimit)
        #expect(failure.providerCode == "rate_limit_error")
    }

    @Test func plainRetryAfter429StaysTransient() async {
        let failure = await Self.http(429, headers: ["retry-after": "20"], body: Self.anthropicBody)
        #expect(failure.category == .rateLimit)
        #expect(failure.retryAfterMs == 20_000)
        #expect(failure.isRetryable)
        #expect(ProviderRetryPolicy().delay(for: failure, attempt: 0) == 20_000)
    }

    @Test func codexResetsAt() async {
        let failure = await Self.http(429, headers: [:], body: #"{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"plus","resets_at":1790000000}}"#)
        #expect(failure.category == .quota)
        #expect(failure.resetsAt == 1_790_000_000)
        #expect(!failure.isRetryable)
    }

    @Test func codexResetsInSeconds() async {
        let failure = await Self.http(429, headers: [:], body: #"{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","resets_in_seconds":3600}}"#)
        #expect(failure.category == .quota)
        #expect(failure.resetsAt == 1_003_600)
        #expect(!failure.isRetryable)
    }

    @Test func moonshotExceededCurrentQuotaIsQuota() async {
        let failure = await Self.http(429, headers: [:], body: #"{"error":{"type":"exceeded_current_quota_error","message":"Your account org-x <ak-x> is suspended, please check your plan"}}"#)
        #expect(failure.providerCode == "exceeded_current_quota_error")
        #expect(failure.category == .quota)
        #expect(!failure.isRetryable)
    }

    @Test func legacyEncodedFailureDecodes() throws {
        let legacy = #"{"message":"busy","httpStatus":429,"providerCode":"rate_limit_error","retryAfterMs":1000}"#
        let failure = try JSONDecoder().decode(ProviderFailure.self, from: Data(legacy.utf8))
        #expect(failure.message == "busy")
        #expect(failure.httpStatus == 429)
        #expect(failure.resetsAt == nil)
        #expect(failure.limitWindow == nil)
        #expect(failure.category == .rateLimit)
    }

    @Test func resetFieldsRoundTrip() throws {
        let failure = ProviderFailure(message: "spent", httpStatus: 429, providerCode: "usage_limit_reached",
                                      shouldRetry: false, resetsAt: 1_790_000_000, limitWindow: "seven_day")
        let decoded = try JSONDecoder().decode(ProviderFailure.self, from: JSONEncoder().encode(failure))
        #expect(decoded == failure)
        #expect(decoded.resetsAt == 1_790_000_000)
        #expect(decoded.limitWindow == "seven_day")
    }
}
