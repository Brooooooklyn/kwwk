import Foundation
import Testing
import KWWKAuth

/// The CLI opens several `OAuthStore`s on `~/.kwwk/oauth.json` in one
/// process (startup, /login, /logout, live registration); a write through
/// one must not undo what another already wrote.
@Suite("OAuth store shared file")
struct OAuthStoreSharedFileTests {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-oauth-\(UUID().uuidString).json")
    }

    private func creds(_ tag: String) -> OAuthCredentials {
        OAuthCredentials(access: "a-\(tag)", refresh: "r-\(tag)", expires: 10)
    }

    @Test("a set through a stale store keeps logins another store wrote")
    func setKeepsOtherStoresLogins() async throws {
        let tmp = tmpURL()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let first = try OAuthStore(url: tmp)
        let second = try OAuthStore(url: tmp)
        try await first.set(creds("a"), for: "a")
        try await second.set(creds("b"), for: "b")
        try await first.set(creds("a2"), for: "a")

        let all = try await OAuthStore(url: tmp).all()
        #expect(all["a"]?.refresh == "r-a2")
        #expect(all["b"]?.refresh == "r-b")
    }

    @Test("a set through a stale store keeps a rotated refresh token")
    func setKeepsRotatedRefreshToken() async throws {
        let tmp = tmpURL()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await OAuthStore(url: tmp).set(creds("a1"), for: "a")
        let first = try OAuthStore(url: tmp)
        let second = try OAuthStore(url: tmp)
        try await first.set(creds("a2"), for: "a")
        try await second.set(creds("b"), for: "b")

        let all = try await OAuthStore(url: tmp).all()
        #expect(all["a"]?.refresh == "r-a2")
        #expect(all["b"]?.refresh == "r-b")
    }

    @Test("a set through a stale store doesn't bring back a logged-out provider")
    func setKeepsLogout() async throws {
        let tmp = tmpURL()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let seed = try OAuthStore(url: tmp)
        try await seed.set(creds("a"), for: "a")
        try await seed.set(creds("b"), for: "b")
        let first = try OAuthStore(url: tmp)
        try await OAuthStore(url: tmp).remove("b")
        try await first.set(creds("a2"), for: "a")

        let all = try await OAuthStore(url: tmp).all()
        #expect(all["a"]?.refresh == "r-a2")
        #expect(all["b"] == nil)
    }
}
