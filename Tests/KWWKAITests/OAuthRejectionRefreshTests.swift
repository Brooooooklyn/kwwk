import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

/// A token the provider refuses before its recorded expiry is renewed by the
/// manager itself when the source has no renewal of its own and the entry
/// carries a refresh token: one forced refresh for exactly the refused token.
/// The case it exists for: ChatGPT answered a stored Codex token "Your
/// authentication token has expired" with 118h left on its recorded expiry
/// (seen live 2026-10-14), and nothing renewed it until that expiry.
@Suite("OAuth manager renews a refused token")
struct OAuthRejectionRefreshTests {
    final class CountingProvider: OAuthProvider, @unchecked Sendable {
        let id = "x"
        let name = "x"
        private let lock = NSLock()
        private var count = 0
        private let failure: (any Error)?
        private let delayNs: UInt64
        var refreshCount: Int { lock.withLock { count } }
        init(failure: (any Error)? = nil, delayNs: UInt64 = 0) {
            self.failure = failure
            self.delayNs = delayNs
        }
        func refresh(_ c: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
            let n = lock.withLock { count += 1; return count }
            if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
            if let failure { throw failure }
            return OAuthCredentials(access: "renewed-\(n)", refresh: "rotated-\(n)", expires: .max)
        }
    }

    final class StaticSource: OAuthCredentialSource, @unchecked Sendable {
        let entry: OAuthCredentials
        let renewal: OAuthCredentials?
        init(_ entry: OAuthCredentials, renewal: OAuthCredentials? = nil) {
            self.entry = entry
            self.renewal = renewal
        }
        func providerIds() async -> [String] { ["x"] }
        func credentials(for providerId: String) async throws -> OAuthCredentials? { entry }
        func credentialsAfterRejection(of rejectedAccess: String, for providerId: String) async throws -> OAuthCredentials? {
            renewal
        }
    }

    private static let later = Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000

    private func tempStore(_ entry: OAuthCredentials?) async throws -> (OAuthStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-reject-\(UUID().uuidString)").appendingPathComponent("oauth.json")
        let store = try OAuthStore(url: url)
        if let entry { try await store.set(entry, for: "x") }
        return (store, url)
    }

    @Test("a refused, unexpired token is refreshed once and the rotation persisted")
    func refreshesRefusedToken() async throws {
        let (store, url) = try await tempStore(OAuthCredentials(access: "tok", refresh: "r", expires: Self.later))
        let provider = CountingProvider()
        let manager = OAuthManager(store: store, providers: [provider])

        #expect(try await manager.reportRejected("tok", for: "x"))
        #expect(provider.refreshCount == 1)
        #expect(try await manager.apiKey(for: "x") == "renewed-1")
        let disk = try JSONDecoder().decode([String: OAuthCredentials].self, from: Data(contentsOf: url))
        #expect(disk["x"]?.refresh == "rotated-1")
    }

    @Test("a token already rotated past is not refreshed again")
    func alreadyRotatedIsReused() async throws {
        let (store, _) = try await tempStore(OAuthCredentials(access: "tok", refresh: "r", expires: Self.later))
        let provider = CountingProvider()
        let manager = OAuthManager(store: store, providers: [provider])

        #expect(try await manager.reportRejected("tok", for: "x"))
        // A second request that carried the same refused token reports late.
        #expect(try await manager.reportRejected("tok", for: "x"))
        #expect(provider.refreshCount == 1)
    }

    @Test("concurrent refusals of one token share one refresh")
    func concurrentRefusalsShareOneRefresh() async throws {
        let (store, _) = try await tempStore(OAuthCredentials(access: "tok", refresh: "r", expires: Self.later))
        let provider = CountingProvider(delayNs: 50_000_000)
        let manager = OAuthManager(store: store, providers: [provider])

        let answers = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 { group.addTask { try await manager.reportRejected("tok", for: "x") } }
            return try await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(answers == Array(repeating: true, count: 5))
        #expect(provider.refreshCount == 1)
    }

    @Test("a rotation another process wrote to disk is adopted, not refreshed over")
    func adoptsRotationFromDisk() async throws {
        let (store, url) = try await tempStore(OAuthCredentials(access: "tok", refresh: "r", expires: Self.later))
        let provider = CountingProvider()
        let manager = OAuthManager(store: store, providers: [provider])
        // Another kwwk process refreshed: "r" is spent, "r2" is live.
        let other = ["x": OAuthCredentials(access: "tok2", refresh: "r2", expires: Self.later)]
        try JSONEncoder().encode(other).write(to: url)

        #expect(try await manager.reportRejected("tok", for: "x"))
        #expect(provider.refreshCount == 0)
        #expect(try await manager.apiKey(for: "x") == "tok2")
    }

    @Test("an entry without a refresh token has nothing to renew")
    func refreshlessEntryIsNotRenewed() async throws {
        let (store, _) = try await tempStore(OAuthCredentials(access: "tok", refresh: "", expires: Self.later))
        let provider = CountingProvider()
        let manager = OAuthManager(store: store, providers: [provider])

        #expect(try await manager.reportRejected("tok", for: "x") == false)
        #expect(provider.refreshCount == 0)
    }

    @Test("a refresh the provider refuses ends as a credential-source error")
    func refusedRefreshIsTheUsersToFix() async throws {
        let (store, _) = try await tempStore(OAuthCredentials(access: "tok", refresh: "r", expires: Self.later))
        let provider = CountingProvider(failure: OAuthError.refreshFailed(
            #"openai-codex 401: {"error":{"code":"refresh_token_reused"}}"#
        ))
        let manager = OAuthManager(store: store, providers: [provider])

        let thrown = await #expect(throws: OAuthCredentialSourceError.self) {
            _ = try await manager.reportRejected("tok", for: "x")
        }
        #expect(thrown?.providerId == "x")
        #expect(thrown?.errorDescription?.contains("refresh_token_reused") == true)
    }

    @Test("a store-less source's refresh-bearing entry is renewed and the rotation held")
    func storelessSourceRotationIsHeld() async throws {
        let source = StaticSource(OAuthCredentials(access: "tok", refresh: "r", expires: Self.later))
        let provider = CountingProvider()
        let manager = OAuthManager(source: source, providers: [provider])

        #expect(try await manager.reportRejected("tok", for: "x"))
        #expect(try await manager.apiKey(for: "x") == "renewed-1")
        #expect(provider.refreshCount == 1)
    }

    @Test("a source that renews on its own is trusted; the manager does not refresh too")
    func sourceRenewalWins() async throws {
        let source = StaticSource(
            OAuthCredentials(access: "tok", refresh: "r", expires: Self.later),
            renewal: OAuthCredentials(access: "from-authority", refresh: "", expires: Self.later)
        )
        let provider = CountingProvider()
        let manager = OAuthManager(source: source, providers: [provider])

        #expect(try await manager.reportRejected("tok", for: "x"))
        #expect(provider.refreshCount == 0)
    }
}
