import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKCli

@Suite("WorkBuddy registration")
struct WorkBuddyRegistrationTests {
    private func store(_ credentials: OAuthCredentials, for id: String) async throws -> OAuthStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-workbuddy-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try OAuthStore(url: dir.appendingPathComponent("oauth.json"))
        try await store.set(credentials, for: id)
        return store
    }

    @Test("registerStored wires each build's login onto its own endpoint and signs requests as the account", arguments: [
        ("workbuddy", "auto", "https://copilot.tencent.com/v2", "WorkBuddy"),
        ("workbuddy-ai", "default-model", "https://www.workbuddy.ai/v2", "WorkBuddy AI"),
    ])
    func registerStoredWorkBuddy(id: String, defaultModel: String, baseURL: String, name: String) async throws {
        try await withSharedAPIRegistry {
            await APIRegistry.shared.unregisterScope(id)
            // Never-expiring credentials so registration skips the token refresh.
            let store = try await store(OAuthCredentials(
                access: "own-access", refresh: "r", expires: .max,
                extras: ["uid": .string("u1"), "domain": .string("www.codebuddy.cn"), "enterpriseId": .string("ent-1")]
            ), for: id)

            let resolved = try #require(try await registerStored(storeId: id, store: store))
            #expect(resolved.model.id == defaultModel)
            #expect(resolved.model.api == "openai-completions")
            #expect(resolved.model.provider == id)
            #expect(resolved.model.baseURL == baseURL)
            #expect(resolved.modelLabel == "\(defaultModel) · \(name)")
            #expect(await APIRegistry.shared.provider(scope: id, api: "openai-completions") is WorkBuddyProvider)

            let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
            #expect(auth.token == "own-access")
            #expect(auth.scheme == .bearer)
            #expect(auth.headers == [
                "X-User-Id": "u1",
                "X-Domain": "www.codebuddy.cn",
                "X-Enterprise-Id": "ent-1",
                "X-Tenant-Id": "ent-1",
            ])

            // The picker's other models route the same way.
            let picked = try #require(try await registerStored(storeId: id, store: store, modelOverride: "hy3"))
            #expect(picked.model.id == "hy3")
            #expect(picked.model.thinkingLevelMap?["high"] == "high")
            await APIRegistry.shared.unregisterScope(id)
        }
    }

    @Test("An account with no domain kept is asked at the endpoint's own")
    func domainFallback() async throws {
        try await withSharedAPIRegistry {
            let store = try await store(OAuthCredentials(
                access: "a", refresh: "", expires: .max, extras: ["uid": .string("u1")]
            ), for: "workbuddy-ai")
            let resolved = try #require(try await registerStored(storeId: "workbuddy-ai", store: store))
            let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
            #expect(auth.headers == ["X-User-Id": "u1", "X-Domain": "www.workbuddy.ai"])
            await APIRegistry.shared.unregisterScope("workbuddy-ai")
        }
    }

    @Test("Both builds are in the login list and the provider directory")
    func listed() {
        for (id, name) in [("workbuddy", "WorkBuddy"), ("workbuddy-ai", "WorkBuddy AI")] {
            #expect(loginProviders.contains { entry in
                if case .oauth = entry.flow { return entry.id == id }
                return false
            })
            #expect(providerDisplayName(forStoreId: id) == name)
            #expect(ProviderAttribution.displayNames[id] == name)
            #expect(OAuthManager.defaultProviders().contains { $0.id == id })
        }
    }
}
