import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// An OAuth token the provider refuses at request time is reported back to
/// its credential source once, and the request is replayed once with what the
/// source renews it to. Kimi's over-plan 401 and Cursor's region refusal are
/// not login failures and are never reported.
@Suite("Agent credential rejection retry")
struct CredentialRejectionRetryTests {
    /// A backend-like authority: serves one access token, and on a rejection
    /// report answers with whatever the test scripted.
    final class RenewingSource: OAuthCredentialSource, @unchecked Sendable {
        enum Renewal { case serve(String), sameToken, needsRelogin }
        struct NeedsRelogin: LocalizedError {
            var errorDescription: String? { "[ABERR:BYOK_AUTH_REQUIRED]\nThe 'faux' model login expired." }
        }

        private let lock = NSLock()
        private var access: String
        private let renewal: Renewal
        private var rejected: [String] = []
        var rejections: [String] { lock.withLock { rejected } }

        init(access: String, renewal: Renewal) {
            self.access = access
            self.renewal = renewal
        }

        func providerIds() async -> [String] { ["faux"] }
        func credentials(for providerId: String) async throws -> OAuthCredentials? {
            lock.withLock { OAuthCredentials(access: access, refresh: "", expires: .max) }
        }
        func credentialsAfterRejection(
            of rejectedAccess: String, for providerId: String
        ) async throws -> OAuthCredentials? {
            try lock.withLock {
                rejected.append(rejectedAccess)
                switch renewal {
                case .serve(let fresh): access = fresh
                case .sameToken: break
                case .needsRelogin: throw NeedsRelogin()
                }
                return OAuthCredentials(access: access, refresh: "", expires: .max)
            }
        }
    }

    struct NoRefresh: OAuthProvider {
        let id = "faux"
        let name = "faux"
        func refresh(_ c: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
            throw OAuthError.refreshFailed("not refreshable here")
        }
    }

    /// Records the api key each attempt carried.
    actor KeyLog {
        var keys: [String?] = []
        func record(_ key: String?) { keys.append(key) }
    }

    /// xAI's answer to a bad OAuth token, captured live (2026-10-14): a 403,
    /// which is why a 403 with token evidence still counts as a refusal of
    /// the credential.
    private static func xaiBadToken() -> AssistantMessage {
        failure("The OAuth2 access token could not be validated.", status: 403, code: "unauthenticated:bad-credentials")
    }

    private static func failure(_ message: String, status: Int?, code: String? = nil) -> AssistantMessage {
        var msg = fauxAssistantMessage("", stopReason: .error, errorMessage: message)
        msg.failure = ProviderFailure(message: message, httpStatus: status, providerCode: code)
        return msg
    }

    private static func step(_ log: KeyLog, _ message: AssistantMessage) -> FauxResponseStep {
        .factory { _, options, _, _ in
            await log.record(options?.apiKey)
            return message
        }
    }

    private func agent(
        _ registration: FauxProviderRegistration,
        source: RenewingSource
    ) -> (Agent, RetryEventRecorder) {
        let manager = OAuthManager(source: source, providers: [NoRefresh()])
        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.retryBaseDelayMs = 5
        agent.authResolver = manager.resolver()
        let recorder = RetryEventRecorder()
        _ = agent.subscribe { event, _ in
            if case .streamRetry(let attempt, let delayMs, let reason) = event {
                await recorder.record(attempt: attempt, delayMs: delayMs, reason: reason)
            }
        }
        return (agent, recorder)
    }

    private func lastAssistant(_ agent: Agent) -> AssistantMessage? {
        if case .assistant(let msg) = agent.state.messages.last { return msg }
        return nil
    }

    @Test("a refused token is reported once and the request replays with the renewed one")
    func retriesOnceWithRenewedToken() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        let log = KeyLog()
        registration.setResponses([
            Self.step(log, Self.failure("Access denied: Your authentication token has expired", status: 401)),
            Self.step(log, fauxAssistantMessage("done")),
        ])
        let source = RenewingSource(access: "stale", renewal: .serve("fresh"))
        let (agent, recorder) = agent(registration, source: source)

        try await agent.prompt("hi")

        #expect(await log.keys == ["stale", "fresh"])
        #expect(source.rejections == ["stale"])
        #expect(await recorder.snapshot().map(\.delayMs) == [0])
        #expect(lastAssistant(agent)?.stopReason == .stop)
    }

    @Test("the source handing back the same token ends the run on the refusal, unreplayed")
    func sameTokenIsNotReplayed() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        let log = KeyLog()
        registration.setResponses([
            Self.step(log, Self.failure("Unauthorized", status: 401)),
            Self.step(log, fauxAssistantMessage("never reached")),
        ])
        let source = RenewingSource(access: "stale", renewal: .sameToken)
        let (agent, recorder) = agent(registration, source: source)

        try await agent.prompt("hi")

        #expect(await log.keys == ["stale"])
        #expect(source.rejections == ["stale"])
        #expect(await recorder.snapshot().isEmpty)
        #expect(lastAssistant(agent)?.failure?.httpStatus == 401)
    }

    @Test("a source that says the login is dead ends the run with its copy")
    func needsReloginSurfacesSourceError() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        let log = KeyLog()
        registration.setResponses([
            Self.step(log, Self.xaiBadToken()),
            Self.step(log, fauxAssistantMessage("never reached")),
        ])
        let source = RenewingSource(access: "stale", renewal: .needsRelogin)
        let (agent, recorder) = agent(registration, source: source)

        try await agent.prompt("hi")

        #expect(await log.keys == ["stale"])
        #expect(source.rejections == ["stale"])
        #expect(await recorder.snapshot().isEmpty)
        let last = lastAssistant(agent)
        #expect(last?.stopReason == .error)
        #expect(last?.errorMessage?.hasPrefix("[ABERR:BYOK_AUTH_REQUIRED]") == true)
    }

    @Test("a refusal that persists with the renewed token is reported once, not looped")
    func persistentRefusalIsReportedOnce() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        let log = KeyLog()
        let denied = Self.xaiBadToken()
        registration.setResponses([
            Self.step(log, denied),
            Self.step(log, denied),
            Self.step(log, fauxAssistantMessage("never reached")),
        ])
        let source = RenewingSource(access: "stale", renewal: .serve("fresh"))
        let (agent, _) = agent(registration, source: source)

        try await agent.prompt("hi")

        #expect(await log.keys == ["stale", "fresh"])
        #expect(source.rejections == ["stale"])
        #expect(lastAssistant(agent)?.failure?.httpStatus == 403)
    }

    @Test("refusals about the plan, policy or region, not the token, are not reported")
    func nonLoginRefusalsAreNotReported() async throws {
        let refusals = [
            Self.failure(
                #"{"error":{"type":"authentication_error","message":"Your current plan supports only k3 up to 256K context. 1M context is available on higher-tier Kimi Code plans."},"type":"error"}"#,
                status: 401
            ),
            Self.failure(
                "You've reached your 5-hour usage limit. Your quota will reset when the current 5-hour window ends. To continue now, purchase extra usage or upgrade your plan: https://www.kimi.com/membership/subscription?tab=quota",
                status: 403
            ),
            // A 403 that names the account's plan or policy, not the token.
            Self.failure("Your plan does not include this model", status: 403),
            // Anthropic, verbatim from omp's corpus (auth-storage-force-refresh-rotate.test.ts).
            Self.failure(
                #"{"type":"error","error":{"type":"permission_error","message":"OAuth authentication is currently not allowed for this organization.","details":{"error_code":"oauth_not_allowed_for_organization"}},"request_id":"req_011CfDQosvzzsyor4jWjLsz8"}"#,
                status: 403
            ),
            // Codex model entitlement, wording from omp (flags.ts).
            Self.failure("The 'gpt-5.3-codex-spark' model is not supported when using Codex with a ChatGPT account.", status: 403),
            Self.failure("This region is not yet available for your team", status: nil, code: "permission_denied"),
            Self.failure("This region is not yet available for your team", status: nil, code: "unauthenticated"),
        ]
        for refusal in refusals {
            let registration = await registerFauxProvider()
            defer { registration.unregister() }
            let log = KeyLog()
            registration.setResponses([
                Self.step(log, refusal),
                Self.step(log, fauxAssistantMessage("never reached")),
            ])
            let source = RenewingSource(access: "stale", renewal: .serve("fresh"))
            let (agent, _) = agent(registration, source: source)

            try? await agent.prompt("hi")

            #expect(source.rejections.isEmpty)
            #expect(await log.keys == ["stale"])
        }
    }

    @Test("a thrown 401 is reported and replayed the same way")
    func thrownRefusalIsReplayed() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("done"))])
        let source = RenewingSource(access: "stale", renewal: .serve("fresh"))
        let manager = OAuthManager(source: source, providers: [NoRefresh()])
        let log = KeyLog()
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: registration.getModel()),
            streamFn: { model, context, options in
                await log.record(options?.apiKey)
                if options?.apiKey == "stale" {
                    throw ProviderFailure(message: "Unauthorized", httpStatus: 401)
                }
                return try await KWWKAI.stream(model: model, context: context, options: options)
            }
        ))
        agent.retryBaseDelayMs = 5
        agent.authResolver = manager.resolver()

        try await agent.prompt("hi")

        #expect(await log.keys == ["stale", "fresh"])
        #expect(source.rejections == ["stale"])
        #expect(lastAssistant(agent)?.stopReason == .stop)
    }

    struct RotatingLogin: OAuthProvider {
        let id = "faux"
        let name = "faux"
        func refresh(_ c: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
            OAuthCredentials(access: "fresh", refresh: "r2", expires: .max)
        }
    }

    @Test("over the file store, a refused token is refreshed by kwwk itself and replayed")
    func fileStoreRefreshesRefusedToken() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        let log = KeyLog()
        // Verbatim ChatGPT answer to a stored Codex token 118h before its
        // recorded expiry (live, 2026-10-14).
        registration.setResponses([
            Self.step(log, Self.failure("Your authentication token has expired. Please try refreshing it.", status: 401, code: "token_expired")),
            Self.step(log, fauxAssistantMessage("done")),
        ])
        let store = OAuthStore()
        try await store.set(OAuthCredentials(access: "stale", refresh: "r1", expires: .max), for: "faux")
        let manager = OAuthManager(store: store, providers: [RotatingLogin()])
        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.retryBaseDelayMs = 5
        agent.authResolver = manager.resolver()

        try await agent.prompt("hi")

        #expect(await log.keys == ["stale", "fresh"])
        #expect(await store.get("faux")?.refresh == "r2")
        #expect(lastAssistant(agent)?.stopReason == .stop)
    }

    @Test("auth from a resolver without a rejection hook is not replayed")
    func plainResolverIsNotReplayed() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        let log = KeyLog()
        registration.setResponses([
            Self.step(log, Self.failure("Unauthorized", status: 401)),
            Self.step(log, fauxAssistantMessage("never reached")),
        ])
        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        agent.retryBaseDelayMs = 5
        agent.authResolver = { _, _ in ResolvedProviderAuth(token: "api-key", scheme: .bearer) }

        try await agent.prompt("hi")

        #expect(await log.keys == ["api-key"])
        #expect(lastAssistant(agent)?.failure?.httpStatus == 401)
    }
}
