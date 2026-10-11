import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAuth

// The answers below are the ones magpie's fake WorkBuddy gives in
// `internal/provider/workbuddy_test.go`, `workbuddy_ai_test.go` and
// `workbuddy_signin_test.go`, wrapped in WorkBuddy's `{code, msg, data}`.

private func answered(_ data: String) -> QueuedHTTPClient.Answer {
    .response(status: 200, body: #"{"code":0,"data":\#(data)}"#)
}

private func pending(_ code: Int) -> QueuedHTTPClient.Answer {
    .response(status: 200, body: #"{"code":\#(code),"msg":"pending"}"#)
}

private let statePage = answered(#"{"state":"s1","authUrl":"https://login.codebuddy.cn/oauth?client_id=c"}"#)
private let tokenGiven = answered(
    #"{"accessToken":"two-access","refreshToken":"two-refresh","expiresIn":3600,"refreshExpiresIn":7200,"domain":"www.codebuddy.cn","tokenType":"Bearer"}"#
)

private func signIn(
    _ site: WorkBuddySite = .china,
    _ client: QueuedHTTPClient,
    presenter: RecordingPresenter = RecordingPresenter(),
    now: @escaping @Sendable () -> Date = { Date() }
) async throws -> OAuthCredentials {
    var callbacks = quietCallbacksBase
    callbacks.browser = presenter
    return try await OAuthLogin.loginWorkBuddy(
        site: site, callbacks: callbacks, client: client, pollSleep: {}, now: now
    )
}

@Suite("WorkBuddy sign-in")
struct WorkBuddySignInTests {
    @Test("The page is opened with the client's version and a session, then the token and the account are asked for until they are ready")
    func browserFlow() async throws {
        let client = QueuedHTTPClient([
            statePage,
            pending(11217),
            tokenGiven,
            pending(12151),
            answered(#"{"uid":"u2","nickname":"Two","phoneNumber":""}"#),
        ])
        let presenter = RecordingPresenter()
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let credentials = try await signIn(.china, client, presenter: presenter)

        let state = client.requests[0]
        #expect(state.method == "POST")
        #expect(state.url.absoluteString == "https://copilot.tencent.com/v2/plugin/auth/state?platform=workbuddy")
        #expect(state.body == Data("{}".utf8))
        #expect(state.headers == [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "WorkBuddy/5.5.6",
            "X-No-Authorization": "true",
            "X-No-User-Id": "true",
            "X-No-Enterprise-Id": "true",
            "X-No-Department-Info": "true",
        ])

        let page = try #require(presenter.shown.first)
        let query = try #require(URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(page.host == "login.codebuddy.cn")
        #expect(query.first { $0.name == "client_id" }?.value == "c")
        #expect(query.first { $0.name == "version" }?.value == "2.0.0")
        #expect(query.first { $0.name == "loginSessionId" }?.value?.count == 32)

        for index in [1, 2] {
            #expect(client.requests[index].method == "GET")
            #expect(client.requests[index].url.absoluteString == "https://copilot.tencent.com/v2/plugin/auth/token?state=s1")
            #expect(client.header("Authorization", request: index) == nil)
            #expect(client.header("User-Agent", request: index) == "WorkBuddy/5.5.6")
        }
        for index in [3, 4] {
            #expect(client.requests[index].url.absoluteString == "https://copilot.tencent.com/v2/plugin/login/account?state=s1")
            #expect(client.header("Authorization", request: index) == "Bearer two-access")
            #expect(client.header("X-Domain", request: index) == "www.codebuddy.cn")
            #expect(client.header("X-No-User-Id", request: index) == "true")
            #expect(client.header("X-No-Enterprise-Id", request: index) == "true")
        }
        #expect(client.requestCount == 5)

        #expect(credentials.access == "two-access")
        #expect(credentials.refresh == "two-refresh")
        // An hour's token, renewed five minutes before its end.
        #expect(credentials.expires >= before + (3600 - 300) * 1000)
        #expect(credentials.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (3600 - 300) * 1000)
        #expect(credentials.extras["uid"] == .string("u2"))
        #expect(credentials.extras["domain"] == .string("www.codebuddy.cn"))
        #expect(credentials.extras["tokenType"] == .string("Bearer"))
        #expect(credentials.extras["accountName"] == .string("Two"))
        #expect(credentials.extras["enterpriseId"] == nil)
        guard case .int(let refreshEnds)? = credentials.extras["refreshExpiresAt"] else {
            Issue.record("no refresh token end kept")
            return
        }
        #expect(Int64(refreshEnds) >= before + 7200 * 1000)
    }

    @Test("The page's own query goes out as WorkBuddy encoded it, its version and session replaced by the client's")
    func pageQueryKept() async throws {
        let client = QueuedHTTPClient([
            answered(
                #"{"state":"a+b==","authUrl":"https://login.codebuddy.cn/oauth?version=1&redirect_uri=https%3A%2F%2Fa.b%2Fcb%3Fx%3D1%26y%3D2&state=a%2Bb%3D%3D"}"#
            ),
            tokenGiven,
            answered(#"{"uid":"u2"}"#),
        ])
        let presenter = RecordingPresenter()
        _ = try await signIn(.china, client, presenter: presenter)
        let page = try #require(presenter.shown.first?.absoluteString)
        #expect(page.hasPrefix(
            "https://login.codebuddy.cn/oauth?redirect_uri=https%3A%2F%2Fa.b%2Fcb%3Fx%3D1%26y%3D2&state=a%2Bb%3D%3D&version=2.0.0&loginSessionId="
        ))
        // The polls name the state as it was given, encoded once.
        #expect(client.requests[1].url.absoluteString == "https://copilot.tencent.com/v2/plugin/auth/token?state=a%2Bb%3D%3D")
        #expect(client.requests[2].url.absoluteString == "https://copilot.tencent.com/v2/plugin/login/account?state=a%2Bb%3D%3D")
    }

    @Test("WorkBuddy AI signs in at its own endpoint as its own platform")
    func internationalBuild() async throws {
        let client = QueuedHTTPClient([
            answered(#"{"state":"s1","authUrl":"https://www.workbuddy.ai/login?platform=workbuddy-ai&state=s1"}"#),
            answered(#"{"accessToken":"ai2-access","refreshToken":"ai2-refresh","expiresIn":3600,"refreshExpiresIn":7200,"domain":"www.codebuddy.ai"}"#),
            answered(#"{"uid":"ai2","nickname":"Second"}"#),
        ])
        let presenter = RecordingPresenter()
        let credentials = try await signIn(.international, client, presenter: presenter)
        #expect(client.requests[0].url.absoluteString == "https://www.workbuddy.ai/v2/plugin/auth/state?platform=workbuddy-ai")
        #expect(client.requests.allSatisfy { $0.url.host == "www.workbuddy.ai" })
        #expect(client.header("X-Domain", request: 2) == "www.codebuddy.ai")
        #expect(presenter.shown.first?.host == "www.workbuddy.ai")
        #expect(credentials.extras["uid"] == .string("ai2"))
        #expect(credentials.extras["accountName"] == .string("Second"))
    }

    @Test("An account is named by its nickname, else its phone number, else its id; one with no domain is asked at the endpoint's")
    func accountName() async throws {
        for (account, name) in [
            (#"{"uid":"u1","nickname":"  ","phoneNumber":"13800000000"}"#, "13800000000"),
            (#"{"uid":"u1"}"#, "u1"),
        ] {
            let client = QueuedHTTPClient([statePage, answered(#"{"accessToken":"a","expiresIn":3600}"#), answered(account)])
            let credentials = try await signIn(.china, client)
            #expect(credentials.extras["accountName"] == .string(name))
            #expect(client.header("X-Domain", request: 2) == "copilot.tencent.com")
            #expect(credentials.refresh == "")
        }
    }

    @Test("An empty answer, a 408 and a 429 are asked again; any other refusal ends the sign-in")
    func pollAnswers() async throws {
        let client = QueuedHTTPClient([
            statePage,
            answered("null"),
            answered("{}"),
            .response(status: 408, body: ""),
            .response(status: 429, body: #"{"msg":"slow down"}"#),
            tokenGiven,
            answered(#"{"uid":"u2"}"#),
        ])
        _ = try await signIn(.china, client)
        #expect(client.requestCount == 7)

        let refused = QueuedHTTPClient([statePage, .response(status: 200, body: #"{"code":10085,"msg":"请求不合法"}"#)])
        await #expect(throws: OAuthLoginError.denied("WorkBuddy: 请求不合法")) {
            _ = try await signIn(.china, refused)
        }
        let unauthorized = QueuedHTTPClient([statePage, tokenGiven, .response(status: 401, body: "")])
        await #expect(throws: OAuthLoginError.denied("WorkBuddy: HTTP 401")) {
            _ = try await signIn(.china, unauthorized)
        }
    }

    @Test("A sign-in nobody finishes in five minutes times out")
    func timesOut() async throws {
        let clock = Clock()
        let client = QueuedHTTPClient([statePage] + Array(repeating: pending(11217), count: 3))
        await #expect(throws: OAuthLoginError.timedOut) {
            _ = try await signIn(.china, client, now: { clock.advance(by: 120) })
        }
        // Asked at 2 and 4 minutes, given up at 6.
        #expect(client.requestCount == 3)
    }

    @Test("No page, a page that isn't https, no token and no account are each refused", arguments: [
        [#"{"state":"","authUrl":"https://login.codebuddy.cn/oauth"}"#],
        [#"{"state":"s1","authUrl":"http://login.codebuddy.cn/oauth"}"#],
        [#"{"state":"s1","authUrl":"https://login.codebuddy.cn/oauth"}"#, #"{"refreshToken":"r"}"#],
        [#"{"state":"s1","authUrl":"https://login.codebuddy.cn/oauth"}"#, #"{"accessToken":"a"}"#, #"{"nickname":"nobody"}"#],
    ])
    func unusableAnswers(answers: [String]) async throws {
        let client = QueuedHTTPClient(answers.map(answered))
        await #expect(throws: OAuthError.self) {
            _ = try await signIn(.china, client)
        }
        #expect(client.requestCount == answers.count)
    }

    @Test("A refused state request ends the sign-in in WorkBuddy's words")
    func stateRefused() async throws {
        let client = QueuedHTTPClient([.response(status: 200, body: #"{"code":10085,"msg":"请求不合法"}"#)])
        await #expect(throws: OAuthLoginError.denied("WorkBuddy: 请求不合法")) {
            _ = try await signIn(.china, client)
        }
    }

    @Test("An enterprise account keeps the enterprise it signed in as")
    func enterprise() async throws {
        // Named by /login/account itself.
        let named = QueuedHTTPClient([
            statePage, tokenGiven, answered(#"{"uid":"u1","nickname":"E","type":"enterprise","enterpriseId":" ent-1 "}"#),
        ])
        #expect(try await signIn(.china, named).extras["enterpriseId"] == .string("ent-1"))
        #expect(named.requestCount == 3)

        // Else the account list's: the uid's only entry of that type.
        let listed = QueuedHTTPClient([
            statePage, tokenGiven, answered(#"{"uid":"u1","nickname":"E","type":"Enterprise"}"#),
            answered(#"""
            {"accounts":[
              {"uid":"u1","type":"personal","enterpriseId":""},
              {"uid":"u1","type":"enterprise","enterpriseId":"ent-2"},
              {"uid":"u9","type":"enterprise","enterpriseId":"ent-9"}]}
            """#),
        ])
        #expect(try await signIn(.china, listed).extras["enterpriseId"] == .string("ent-2"))
        #expect(listed.requests[3].url.absoluteString == "https://copilot.tencent.com/v2/plugin/accounts")
        #expect(listed.header("Authorization", request: 3) == "Bearer two-access")
        #expect(listed.header("X-Domain", request: 3) == "www.codebuddy.cn")

        // Two of the type: the one it last signed in to.
        let lastUsed = QueuedHTTPClient([
            statePage, tokenGiven, answered(#"{"uid":"u1","type":"enterprise"}"#),
            answered(#"""
            {"accounts":[
              {"uid":"u1","type":"enterprise","enterpriseId":"ent-2","lastLogin":0},
              {"uid":"u1","type":"enterprise","enterpriseId":"ent-3","lastLogin":1790000000000}]}
            """#),
        ])
        #expect(try await signIn(.china, lastUsed).extras["enterpriseId"] == .string("ent-3"))

        // A personal account's list is never asked for, and a list that
        // can't be read leaves the account personal.
        let personal = QueuedHTTPClient([statePage, tokenGiven, answered(#"{"uid":"u1","type":"personal"}"#)])
        #expect(try await signIn(.china, personal).extras["enterpriseId"] == nil)
        let unreadable = QueuedHTTPClient([
            statePage, tokenGiven, answered(#"{"uid":"u1","type":"enterprise"}"#), .response(status: 500, body: ""),
        ])
        #expect(try await signIn(.china, unreadable).extras["enterpriseId"] == nil)
    }
}

/// A clock a test moves itself.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(by seconds: TimeInterval) -> Date {
        lock.withLock {
            time += seconds
            return time
        }
    }
}

@Suite("WorkBuddy token refresh")
struct WorkBuddyRefreshTests {
    private let far = Int((Date().timeIntervalSince1970 + 86_400) * 1000)

    private func stale(extras: [String: JSONValue] = [:]) -> OAuthCredentials {
        var all: [String: JSONValue] = [
            "uid": .string("u1"), "domain": .string("www.codebuddy.cn"), "tokenType": .string("Bearer"),
            "refreshExpiresAt": .int(far), "accountName": .string("R"),
        ]
        for (key, value) in extras { all[key] = value }
        return OAuthCredentials(access: "stale", refresh: "good-refresh", expires: 0, extras: all)
    }

    @Test("The refresh token goes in a header with an empty body; a refresh that doesn't rotate it keeps the old one")
    func refresh() async throws {
        let client = QueuedHTTPClient([answered(#"{"accessToken":"fresh","expiresIn":3600}"#)])
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let refreshed = try await WorkBuddyOAuthProvider(site: .china).refresh(stale(), using: client)

        let request = try #require(client.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://copilot.tencent.com/v2/plugin/auth/token/refresh")
        #expect(request.body == Data("{}".utf8))
        #expect(request.headers == [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "WorkBuddy/5.5.6",
            "X-Refresh-Token": "good-refresh",
            "X-Auth-Refresh-Source": "plugin",
            "X-Domain": "www.codebuddy.cn",
        ])

        #expect(refreshed.access == "fresh")
        #expect(refreshed.refresh == "good-refresh")
        #expect(refreshed.extras == stale().extras)
        #expect(refreshed.expires >= before + (3600 - 300) * 1000)
        #expect(refreshed.expires <= Int64(Date().timeIntervalSince1970 * 1000) + (3600 - 300) * 1000)
    }

    @Test("A rotated refresh token, a new domain and the ends given as times are taken")
    func rotation() async throws {
        let client = QueuedHTTPClient([answered(
            #"{"accessToken":"fresh","refreshToken":"next","expiresAt":1900000000000,"refreshExpiresAt":1900000360000,"domain":"www.codebuddy.ai"}"#
        )])
        let refreshed = try await WorkBuddyOAuthProvider(site: .international).refresh(
            stale(extras: ["enterpriseId": .string("ent-1")]), using: client
        )
        #expect(client.requests[0].url.host == "www.workbuddy.ai")
        // An enterprise account is refreshed as the enterprise.
        #expect(client.header("X-Enterprise-Id", request: 0) == "ent-1")
        #expect(client.header("X-Tenant-Id", request: 0) == "ent-1")
        #expect(client.header("X-User-Id", request: 0) == nil)
        #expect(refreshed.refresh == "next")
        #expect(refreshed.expires == 1_900_000_000_000 - 300_000)
        #expect(refreshed.extras["refreshExpiresAt"] == .int(1_900_000_360_000))
        #expect(refreshed.extras["domain"] == .string("www.codebuddy.ai"))
        #expect(refreshed.extras["uid"] == .string("u1"))
        #expect(refreshed.extras["enterpriseId"] == .string("ent-1"))
    }

    private func refreshError(
        _ credentials: OAuthCredentials, _ answers: [QueuedHTTPClient.Answer]
    ) async -> (OAuthRefreshError?, QueuedHTTPClient) {
        let client = QueuedHTTPClient(answers)
        do {
            _ = try await WorkBuddyOAuthProvider(site: .china).refresh(credentials, using: client)
            return (nil, client)
        } catch let error as OAuthRefreshError {
            return (error, client)
        } catch {
            Issue.record("unexpected error \(error)")
            return (nil, client)
        }
    }

    @Test("A refused grant parks the login; a 403, 429, 5xx, a transport failure and an answer with no token do not")
    func classification() async throws {
        // magpie's fake WorkBuddy answers a wrong refresh token 401.
        let (rejected, _) = await refreshError(stale(), [.response(status: 401, body: "")])
        #expect(rejected?.kind == .rejected)
        #expect(rejected?.status == 401)
        #expect(rejected?.providerId == "workbuddy")
        #expect(await refreshError(stale(), [.response(status: 400, body: #"{"code":11217,"msg":"bad"}"#)]).0?.kind == .rejected)
        #expect(await refreshError(stale(), [.response(status: 403, body: "")]).0?.kind == .unavailable)
        #expect(await refreshError(stale(), [.response(status: 429, body: "")]).0?.kind == .unavailable)
        #expect(await refreshError(stale(), [.response(status: 503, body: "busy")]).0?.kind == .unavailable)
        #expect(await refreshError(stale(), [.failure(URLError(.timedOut))]).0?.kind == .unavailable)
        #expect(await refreshError(stale(), [.response(status: 200, body: "<html>")]).0?.kind == .unavailable)
        #expect(await refreshError(stale(), [answered(#"{"refreshToken":"next"}"#)]).0?.kind == .unavailable)
        // A business code under a 200 isn't known to mean the grant is gone.
        let (coded, _) = await refreshError(stale(), [.response(status: 200, body: #"{"code":10085,"msg":"请求不合法"}"#)])
        #expect(coded?.kind == .unavailable)
        #expect(coded?.detail == "请求不合法 (code 10085)")
    }

    @Test("A refresh token past its own end is not sent: the account is signed out")
    func refreshTokenEnded() async throws {
        let ended = stale(extras: ["refreshExpiresAt": .int(Int((Date().timeIntervalSince1970 - 60) * 1000))])
        let (error, client) = await refreshError(ended, [])
        #expect(error?.kind == .rejected)
        #expect(error?.detail == "this WorkBuddy account is signed out; sign in again")
        #expect(client.requestCount == 0)
    }
}

@Suite("WorkBuddy credits")
struct WorkBuddyUsageTests {
    private let credentials = OAuthCredentials(
        access: "own-access", refresh: "r", expires: .max,
        extras: ["uid": .string("u1"), "domain": .string("www.codebuddy.cn")]
    )

    @Test("Credits are summed over the account's packages, from capacities sent as strings")
    func credits() async throws {
        let client = QueuedHTTPClient([answered(#"""
        {"IsPaidUser":true,"Packages":[
          {"PackageCode":"coding","CycleTotalCapacity":"9500","CycleRemainCapacity":"7500","CycleUsedCapacity":"2000"},
          {"PackageCode":"vibe","CycleTotalCapacity":"500","CycleRemainCapacity":"0","CycleUsedCapacity":"500.00000000"}]}
        """#)])
        let windows = try await WorkBuddyUsageReader(site: .china).usage(credentials, using: client)
        #expect(windows == [OAuthUsageWindow(window: .primary, usedPercent: 25, resetsAt: nil, windowSeconds: nil)])

        // The meter has no /v2 prefix, and is asked as WorkBuddy's client asks.
        let request = try #require(client.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://copilot.tencent.com/billing/meter/get-user-resource-summary")
        #expect(request.body == Data("{}".utf8))
        #expect(request.headers == [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "WorkBuddy/5.5.6",
            "Authorization": "Bearer own-access",
            "X-User-Id": "u1",
            "X-Domain": "www.codebuddy.cn",
            "X-Product": "SaaS",
            "X-IDE-Type": "WorkBuddy",
        ])
    }

    @Test("WorkBuddy AI's credits are read at its own endpoint; bare numbers and empty capacities are read too")
    func internationalBuild() async throws {
        let client = QueuedHTTPClient([answered(
            #"{"IsPaidUser":false,"Packages":[{"CycleTotalCapacity":"1000","CycleUsedCapacity":"100"},{"CycleTotalCapacity":1000,"CycleUsedCapacity":""}]}"#
        )])
        let windows = try await WorkBuddyUsageReader(site: .international).usage(credentials, using: client)
        #expect(windows.map(\.usedPercent) == [5])
        #expect(client.requests[0].url.absoluteString == "https://www.workbuddy.ai/billing/meter/get-user-resource-summary")
    }

    @Test("An account whose packages grant nothing has no window")
    func noPackages() async throws {
        for summary in [#"{"IsPaidUser":false,"Packages":[]}"#, "null", #"{"Packages":[{"CycleTotalCapacity":"0","CycleUsedCapacity":"0"}]}"#] {
            let windows = try await WorkBuddyUsageReader(site: .china).usage(credentials, using: QueuedHTTPClient([answered(summary)]))
            #expect(windows.isEmpty)
        }
    }

    @Test("A refusal, a rate limit and an unreadable capacity are failures of the read, in WorkBuddy's words")
    func failures() async throws {
        let reader = WorkBuddyUsageReader(site: .china)
        await #expect(throws: OAuthUsageError.unavailable(providerId: "workbuddy", status: 200, detail: "请求不合法")) {
            _ = try await reader.usage(credentials, using: QueuedHTTPClient([
                .response(status: 200, body: #"{"code":10085,"msg":"请求不合法"}"#),
            ]))
        }
        await #expect(throws: OAuthUsageError.unavailable(providerId: "workbuddy", status: 401, detail: "HTTP 401")) {
            _ = try await reader.usage(credentials, using: QueuedHTTPClient([.response(status: 401, body: "")]))
        }
        await #expect(throws: OAuthUsageError.rateLimited(retryAfterSeconds: 30)) {
            _ = try await reader.usage(credentials, using: QueuedHTTPClient([
                .response(status: 429, body: "", headers: ["Retry-After": "30"]),
            ]))
        }
        await #expect(throws: OAuthUsageError.self) {
            _ = try await reader.usage(credentials, using: QueuedHTTPClient([
                answered(#"{"Packages":[{"CycleTotalCapacity":"lots","CycleUsedCapacity":"1"}]}"#),
            ]))
        }
    }

    @Test("Both builds' readers and refresh providers are registered")
    func registered() {
        #expect(OAuthUsage.readers["workbuddy"] is WorkBuddyUsageReader)
        #expect(OAuthUsage.readers["workbuddy-ai"] is WorkBuddyUsageReader)
        #expect(WorkBuddyOAuthProvider(site: .china).id == "workbuddy")
        #expect(WorkBuddyOAuthProvider(site: .international).id == "workbuddy-ai")
    }
}
