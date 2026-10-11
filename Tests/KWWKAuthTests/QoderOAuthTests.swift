import Foundation
import Crypto
import Testing
@testable import KWWKAuth

// Ported from magpie's `internal/qoder/auth_test.go`, `site_test.go` and the
// sign-in, refresh and usage cases of `internal/provider/qoder_test.go` and
// `qoder_cn_test.go`.

private func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
}

private func jsonBody(_ data: Data?) throws -> [String: String] {
    let data = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
}

private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private let hour: Int64 = 60 * 60 * 1000
private let lead: Int64 = 5 * 60 * 1000

@Suite("Qoder sites")
struct QoderSiteTests {
    @Test("The global site is qoder.com with the desktop client id; Qoder CN is qoder.cn with its CLI's and no redirect")
    func table() {
        #expect(QoderSite.global.id == "qoder")
        #expect(QoderSite.global.web == "https://qoder.com")
        #expect(QoderSite.global.openAPI == "https://openapi.qoder.sh")
        #expect(QoderSite.global.api == "https://api3.qoder.sh")
        #expect(QoderSite.global.clientID == "732aef47-9cf2-46a2-95fe-4cebb5d0d1fa")
        #expect(QoderSite.global.redirectURI == "qoder-app://")
        #expect(QoderSite.cn.id == "qoder-cn")
        #expect(QoderSite.cn.web == "https://qoder.cn")
        #expect(QoderSite.cn.openAPI == "https://openapi.qoder.com.cn")
        #expect(QoderSite.cn.api == "https://gateway.qoder.com.cn")
        #expect(QoderSite.cn.clientID == "e883ade2-e6e3-4d6d-adf7-f92ceff5fdcb")
        #expect(QoderSite.cn.redirectURI == nil)
    }

    @Test("Anything that isn't Qoder CN is the global site")
    func siteOf() {
        #expect(QoderSite.of("qoder-cn") == .cn)
        #expect(QoderSite.of("qoder") == .global)
        #expect(QoderSite.of("") == .global)
    }

    @Test("Both sites refresh and report usage under their own provider id")
    func registered() {
        #expect(OAuthUsage.readers["qoder"] is QoderUsageReader)
        #expect((OAuthUsage.readers["qoder-cn"] as? QoderUsageReader)?.site == .cn)
        #expect(QoderOAuthProvider(site: .cn).id == "qoder-cn")
        #expect(QoderOAuthProvider().name == "Qoder")
    }
}

@Suite("Qoder sign-in")
struct QoderLoginTests {
    private func login(
        site: QoderSite = .global, _ answers: [QueuedHTTPClient.Answer]
    ) async throws -> (OAuthCredentials, QueuedHTTPClient, URL) {
        let client = QueuedHTTPClient(answers)
        let presenter = RecordingPresenter()
        var callbacks = quietCallbacksBase
        callbacks.browser = presenter
        let credentials = try await OAuthLogin.loginQoder(
            site: site, callbacks: callbacks, client: client, pollIntervalMs: 1
        )
        return (credentials, client, try #require(presenter.shown.first))
    }

    @Test("The page carries PKCE S256, a nonce and a machine id; the poll, the job token and the account page follow")
    func fullFlow() async throws {
        let before = nowMs()
        let (credentials, client, page) = try await login([
            .response(status: 404, body: ""), // not authorized yet
            .response(status: 200, body: #"{"token":"dt-abc","refresh_token":"drt","user_id":"uid-9"}"#),
            .response(status: 200, body: #"{"token":"jt-xyz","refresh_token":"jrt","expires_in":3600000}"#),
            .response(status: 200, body: #"{"id":"uid-9","name":"Ethan Xu","email":"e@x.com","source":"sso.google"}"#),
        ])

        #expect(page.absoluteString.hasPrefix("https://qoder.com/device/selectAccounts?challenge="))
        // The app scheme goes escaped, as the client's own query spells it.
        #expect(page.absoluteString.hasSuffix("&redirect_uri=qoder-app%3A%2F%2F"))
        let shown = query(page)
        #expect(shown["challenge_method"] == "S256")
        #expect(shown["client_id"] == QoderSite.global.clientID)
        #expect(shown["redirect_uri"] == "qoder-app://")
        #expect(shown["machine_id"]?.count == 36)

        #expect(client.requestCount == 4)
        let poll = client.requests[1]
        #expect(poll.method == "GET")
        #expect(poll.url.absoluteString.hasPrefix("https://openapi.qoder.sh/api/v1/deviceToken/poll?challenge_method=S256&nonce="))
        let polled = query(poll.url)
        #expect(polled["nonce"] == shown["nonce"])
        let verifier = try #require(polled["verifier"])
        // 64 random bytes, base64url; the page saw only its digest.
        #expect(verifier.count == 86)
        #expect(shown["challenge"] == PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
        #expect(client.header("Accept", request: 1) == "application/json")

        let job = client.requests[2]
        #expect(job.method == "POST")
        #expect(job.url.absoluteString == "https://openapi.qoder.sh/api/v1/me/jobToken")
        #expect(client.header("Authorization", request: 2) == "Bearer dt-abc")
        #expect(client.header("Content-Type", request: 2) == "application/json")
        #expect(try jsonBody(job.body) == ["clientId": QoderSite.global.clientID])

        #expect(client.requests[3].url.absoluteString == "https://openapi.qoder.sh/api/v1/userinfo")
        #expect(client.header("Authorization", request: 3) == "Bearer dt-abc")

        #expect(credentials.access == "jt-xyz")
        #expect(credentials.refresh == "jrt")
        // The job token's `expires_in` is milliseconds.
        #expect(credentials.expires >= before + hour - lead)
        #expect(credentials.expires <= nowMs() + hour - lead)
        #expect(credentials.extras == [
            "uid": "uid-9",
            "machineId": .string(try #require(shown["machine_id"])),
            "deviceToken": "dt-abc",
            "deviceRefresh": "drt",
            "email": "e@x.com",
            "name": "Ethan Xu",
        ])
    }

    @Test("A 200 that carries no token yet keeps the poll going")
    func pollWaitsForToken() async throws {
        let (credentials, client, _) = try await login([
            .response(status: 200, body: "{}"),
            .response(status: 200, body: #"{"token":"dt","refresh_token":"drt","user_id":"u1"}"#),
            .response(status: 200, body: #"{"token":"jt","refresh_token":"rt","expires_in":3600000}"#),
            .response(status: 200, body: #"{"id":"u1"}"#),
        ])
        #expect(client.requestCount == 4)
        #expect(credentials.access == "jt")
    }

    @Test("The account page is a label, not a gate: without it the poll's own user name stands")
    func userInfoIsOptional() async throws {
        let (credentials, _, _) = try await login([
            .response(status: 200, body: #"{"token":"dt","refresh_token":"drt","user_id":"u1","user_name":"One"}"#),
            .response(status: 200, body: #"{"token":"jt","refresh_token":"rt"}"#),
            .response(status: 500, body: "busy"),
        ])
        #expect(credentials.extras["name"] == "One")
        #expect(credentials.extras["email"] == nil)
        // A job token that names no lifetime is taken to last a day.
        #expect(credentials.expires > nowMs() + 23 * hour)
        #expect(credentials.expires <= nowMs() + 24 * hour - lead)
    }

    @Test("A job token the global site refuses fails the sign-in")
    func globalRefusedJobToken() async throws {
        await #expect(throws: OAuthError.self) {
            _ = try await login([
                .response(status: 200, body: #"{"token":"dt","refresh_token":"drt","user_id":"u1"}"#),
                .response(status: 403, body: #"{"message":"client not allowed"}"#),
            ])
        }
    }

    @Test("A device token with no user id is no sign-in")
    func missingUserId() async throws {
        await #expect(throws: OAuthError.self) {
            _ = try await login([.response(status: 200, body: #"{"token":"dt","refresh_token":"drt"}"#)])
        }
    }

    @Test("Qoder CN signs in on qoder.cn with its CLI's client id and stays on its own hosts")
    func cnFlow() async throws {
        let (credentials, client, page) = try await login(site: .cn, [
            .response(status: 200, body: #"{"token":"dt-cn","refresh_token":"drt-cn","user_id":"u-cn","user_name":"CN","expires_in":7200}"#),
            .response(status: 200, body: #"{"token":"jt-cn","refresh_token":"rt-cn","expires_in":3600000}"#),
            .response(status: 200, body: #"{"id":"u-cn","email":"cn@x","name":"CN"}"#),
        ])
        #expect(page.host == "qoder.cn")
        #expect(page.path == "/device/selectAccounts")
        let shown = query(page)
        #expect(shown["client_id"] == QoderSite.cn.clientID)
        #expect(shown["redirect_uri"] == nil)
        #expect(shown["challenge_method"] == "S256")
        #expect(shown["nonce"]?.isEmpty == false)
        #expect(shown["machine_id"]?.isEmpty == false)
        #expect(client.requests.map { ($0.url.host ?? "") + $0.url.path } == [
            "openapi.qoder.com.cn/api/v1/deviceToken/poll",
            "openapi.qoder.com.cn/api/v1/me/jobToken",
            "openapi.qoder.com.cn/api/v1/userinfo",
        ])
        #expect(try jsonBody(client.requests[1].body) == ["clientId": QoderSite.cn.clientID])
        #expect(credentials.access == "jt-cn")
        #expect(credentials.refresh == "rt-cn")
        #expect(credentials.extras["deviceChat"] == nil)
        #expect(credentials.extras["email"] == "cn@x")
    }

    @Test("When qoder.cn won't make a job token the device token signs the model calls, as its CLI's does")
    func cnDeviceChat() async throws {
        let (credentials, _, _) = try await login(site: .cn, [
            .response(status: 200, body: #"{"token":"dt-cn","refresh_token":"drt-cn","user_id":"u-cn","user_name":"CN","expires_in":7200}"#),
            .response(status: 403, body: #"{"message":"client not allowed"}"#),
            .response(status: 200, body: #"{"id":"u-cn","email":"cn@x","name":"CN"}"#),
        ])
        #expect(credentials.access == "dt-cn")
        #expect(credentials.refresh == "drt-cn")
        #expect(credentials.extras["deviceChat"] == true)
        #expect(credentials.extras["deviceToken"] == "dt-cn")
        // The device token's `expires_in` is seconds.
        #expect(credentials.expires > nowMs() + hour)
        #expect(credentials.expires <= nowMs() + 2 * hour - lead)
    }

    @Test("A Qoder CN outage is not a refusal: a 5xx job token fails the sign-in")
    func cnServerError() async throws {
        await #expect(throws: OAuthError.self) {
            _ = try await login(site: .cn, [
                .response(status: 200, body: #"{"token":"dt-cn","refresh_token":"drt-cn","user_id":"u-cn"}"#),
                .response(status: 503, body: "busy"),
            ])
        }
    }
}

@Suite("Qoder refresh")
struct QoderRefreshTests {
    private let stale = OAuthCredentials(
        access: "jt-one", refresh: "rt-one", expires: 0,
        extras: ["uid": "one", "machineId": "machine-one", "deviceToken": "dt-one", "deviceRefresh": "drt-one"]
    )

    @Test("The job pair rotates on jobToken/refresh and the account-page pair beside it")
    func jobRotation() async throws {
        let before = nowMs()
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"token":"jt-new","refresh_token":"jrt2","expires_in":7200000}"#),
            .response(status: 200, body: #"{"device_token":"dt-new","refresh_token":"drt-new"}"#),
        ])
        let refreshed = try await QoderOAuthProvider().refresh(stale, using: client)

        #expect(client.requests[0].method == "POST")
        #expect(client.requests[0].url.absoluteString == "https://openapi.qoder.sh/api/v1/jobToken/refresh")
        #expect(try jsonBody(client.requests[0].body) == ["refresh_token": "rt-one"])
        #expect(client.header("Accept", request: 0) == "application/json")
        #expect(client.header("Content-Type", request: 0) == "application/json")
        #expect(client.header("Authorization", request: 0) == nil)
        #expect(client.requests[1].url.absoluteString == "https://openapi.qoder.sh/api/v1/deviceToken/refresh")
        #expect(try jsonBody(client.requests[1].body) == ["refresh_token": "drt-one"])

        #expect(refreshed.access == "jt-new")
        #expect(refreshed.refresh == "jrt2")
        #expect(refreshed.expires >= before + 2 * hour - lead)
        #expect(refreshed.expires <= nowMs() + 2 * hour - lead)
        #expect(refreshed.extras["deviceToken"] == "dt-new")
        #expect(refreshed.extras["deviceRefresh"] == "drt-new")
        #expect(refreshed.extras["uid"] == "one")
        #expect(refreshed.extras["machineId"] == "machine-one")
    }

    @Test("A refused account-page refresh leaves chat alone: the job rotation stands and the old pair is kept")
    func deviceRefusalIsNotFatal() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"token":"jt-new","refresh_token":"rt-new","expires_in":3600000}"#),
            .response(status: 401, body: ""),
        ])
        let refreshed = try await QoderOAuthProvider().refresh(stale, using: client)
        #expect(refreshed.access == "jt-new")
        #expect(refreshed.refresh == "rt-new")
        #expect(refreshed.extras == stale.extras)
    }

    private func refreshError(_ answer: QueuedHTTPClient.Answer) async -> OAuthRefreshError? {
        do {
            _ = try await QoderOAuthProvider().refresh(stale, using: QueuedHTTPClient([answer]))
            return nil
        } catch let error as OAuthRefreshError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    @Test("A refused job refresh parks the login; an outage, a lost connection and a half answer do not")
    func classification() async throws {
        let refused = await refreshError(.response(status: 401, body: ""))
        #expect(refused?.kind == .rejected)
        #expect(refused?.providerId == "qoder")
        #expect(await refreshError(.response(status: 400, body: "{}"))?.kind == .rejected)
        // magpie takes Qoder's 403 as the sign-in gone too (qoderRefreshFailed;
        // its own test stubs only 401), where the shared rule reads an outage.
        let forbidden = await refreshError(.response(status: 403, body: "no"))
        #expect(forbidden?.kind == .rejected)
        #expect(forbidden?.status == 403)
        #expect(await refreshError(.response(status: 503, body: "busy"))?.kind == .unavailable)
        #expect(await refreshError(.failure(URLError(.timedOut)))?.kind == .unavailable)
        // A pair with a half missing is not kept: the old one may still work.
        #expect(await refreshError(.response(status: 200, body: #"{"token":"jt-new"}"#))?.kind == .unavailable)
        #expect(await refreshError(.response(status: 200, body: "<html>"))?.kind == .unavailable)
    }

    @Test("A Qoder CN login that chats with its device token refreshes on the device refresh, not the job one")
    func cnDeviceChatRefresh() async throws {
        let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 60 * 60))
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"token":"dt-2","refresh_token":"drt-2","expires_at":"\#(expiresAt)"}"#),
        ])
        let refreshed = try await QoderOAuthProvider(site: .cn).refresh(
            OAuthCredentials(
                access: "dt-1", refresh: "drt-1", expires: 0,
                extras: ["uid": "u", "deviceToken": "dt-1", "deviceRefresh": "drt-1", "deviceChat": true]
            ),
            using: client
        )
        #expect(client.requestCount == 1)
        #expect(client.requests[0].url.absoluteString == "https://openapi.qoder.com.cn/api/v1/deviceToken/refresh")
        #expect(try jsonBody(client.requests[0].body) == ["refresh_token": "drt-1"])
        #expect(refreshed.access == "dt-2")
        #expect(refreshed.refresh == "drt-2")
        #expect(refreshed.extras["deviceToken"] == "dt-2")
        #expect(refreshed.extras["deviceRefresh"] == "drt-2")
        #expect(refreshed.extras["deviceChat"] == true)
        #expect(refreshed.expires > nowMs() + 2 * hour)
        #expect(refreshed.expires <= nowMs() + 3 * hour - lead)
    }

    @Test("A refused device-chat refresh is the sign-in gone")
    func cnDeviceChatRefused() async throws {
        await #expect(throws: OAuthRefreshError.self) {
            _ = try await QoderOAuthProvider(site: .cn).refresh(
                OAuthCredentials(access: "dt-1", refresh: "drt-1", expires: 0, extras: ["deviceChat": true]),
                using: QueuedHTTPClient([.response(status: 401, body: "")])
            )
        }
    }
}

@Suite("Qoder usage")
struct QoderUsageTests {
    private let credentials = OAuthCredentials(
        access: "jt-one", refresh: "rt-one", expires: .max, extras: ["uid": "one", "deviceToken": "dt-one"]
    )

    // magpie TestQoderLoginUsage's answer.
    private let pools = #"{"displayMode":"qoder","qoderUsage":{"userType":"pro","userQuota":{"total":100,"used":25},"addOnQuota":{"cap":50,"remaining":40},"orgResourcePackage":{"total":20,"used":10},"dedicatedResourcePackages":[{"name":"Team","total":10,"used":2}]}}"#

    @Test("The account page is asked with the device token, as the desktop client asks it")
    func request() async throws {
        let client = QueuedHTTPClient([.response(status: 200, body: pools)])
        let windows = try await QoderUsageReader().usage(credentials, using: client)
        #expect(client.requests[0].method == "GET")
        #expect(client.requests[0].url.absoluteString == "https://openapi.qoder.sh/sash/api/v2/me/usage")
        #expect(client.header("Authorization", request: 0) == "Bearer dt-one")
        #expect(client.header("Accept", request: 0) == "application/json")
        #expect(client.header("Cosy-ClientType", request: 0) == "10")
        #expect(client.header("User-Agent", request: 0) == "Qoder")
        #expect(windows.count == 4)
    }

    @Test("The plan's credits are the main reading; add-on, shared and dedicated pools keep their names")
    func windows() throws {
        let windows = try #require(QoderUsageReader.windows(fromJSON: Data(pools.utf8)))
        #expect(windows.map(\.usedPercent) == [25, 20, 50, 20])
        #expect(windows.map(\.window) == [.primary, .secondary, .secondary, .secondary])
        #expect(windows.map(\.limitID) == [nil, "addOnQuota", "orgResourcePackage", "dedicatedResourcePackages.0"])
        #expect(windows.map(\.limitName) == [nil, "Add-on credits", "Shared credits", "Team"])
        #expect(windows.allSatisfy { $0.resetsAt == nil && $0.windowSeconds == nil })
    }

    @Test("Snake-case fields read the same; a pool with no size or no reading is skipped")
    func tolerantFields() throws {
        let body = #"{"displayMode":"qoder","qoderUsage":{"user_quota":{"total":200,"remaining":150},"add_on_quota":{"total":0,"used":0},"org_resource_package":{"total":20},"dedicated_resource_packages":[{"total":10,"used":-1}]}}"#
        let windows = try #require(QoderUsageReader.windows(fromJSON: Data(body.utf8)))
        #expect(windows.map(\.usedPercent) == [25])
    }

    @Test("A pool spent past its size reads full, as magpie caps it")
    func overspent() throws {
        let body = #"{"displayMode":"qoder","qoderUsage":{"userQuota":{"total":100,"used":130}}}"#
        #expect(try #require(QoderUsageReader.windows(fromJSON: Data(body.utf8))).map(\.usedPercent) == [100])
    }

    @Test("An enterprise account has no personal pools; any other answer is no usage")
    func displayModes() throws {
        #expect(QoderUsageReader.windows(fromJSON: Data(#"{"displayMode":"enterprise"}"#.utf8)) == [])
        #expect(QoderUsageReader.windows(fromJSON: Data(#"{"displayMode":"other"}"#.utf8)) == nil)
        #expect(QoderUsageReader.windows(fromJSON: Data(#"{"displayMode":"qoder","qoderUsage":null}"#.utf8)) == nil)
        #expect(QoderUsageReader.windows(fromJSON: Data("<html>".utf8)) == nil)
    }

    @Test("Qoder CN's usage stays on its account host, and a device-chat login asks with its chat token")
    func cnAndDeviceChat() async throws {
        let client = QueuedHTTPClient([
            .response(status: 200, body: #"{"displayMode":"qoder","qoderUsage":{"userType":"pro","userQuota":{"total":100,"used":25}}}"#),
        ])
        let windows = try await QoderUsageReader(site: .cn).usage(
            OAuthCredentials(access: "dt-cn", refresh: "drt-cn", expires: .max, extras: ["deviceChat": true]),
            using: client
        )
        #expect(client.requests[0].url.absoluteString == "https://openapi.qoder.com.cn/sash/api/v2/me/usage")
        #expect(client.header("Authorization", request: 0) == "Bearer dt-cn")
        #expect(windows.map(\.usedPercent) == [25])
    }

    @Test("A refused or unreadable account page is usage unavailable, never a login failure")
    func failures() async throws {
        await #expect(throws: OAuthUsageError.unavailable(providerId: "qoder", status: 401, detail: "")) {
            _ = try await QoderUsageReader().usage(credentials, using: QueuedHTTPClient([.response(status: 401, body: "")]))
        }
        await #expect(throws: OAuthUsageError.unavailable(providerId: "qoder", status: 200, detail: "missing quota data")) {
            _ = try await QoderUsageReader().usage(
                credentials, using: QueuedHTTPClient([.response(status: 200, body: #"{"displayMode":"qoder"}"#)])
            )
        }
        await #expect(throws: OAuthUsageError.self) {
            _ = try await QoderUsageReader().usage(
                OAuthCredentials(access: "jt", refresh: "rt", expires: .max), using: QueuedHTTPClient([])
            )
        }
    }
}
