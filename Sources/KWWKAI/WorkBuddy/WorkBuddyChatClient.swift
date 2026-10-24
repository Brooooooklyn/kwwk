import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The transport under WorkBuddy's chats: it sends a chat once more, mended,
/// where WorkBuddy refused it for a shape it serves in another spelling, as
/// the plugin magpie serves WorkBuddy through does around its fetch
/// (`@magpie-community/opencode-workbuddy-auth`, `makePlugin`'s loader).
///
/// - A system prompt refused as an unapproved channel (11101, 11128) goes
///   again as the user's instructions (`WorkBuddyWire.systemAsUser`), and
///   that prompt goes so at once in every later chat (plugin 0.1.29,
///   af360a5).
/// - Tool results followed by a user message, refused with 11153, go again
///   with an empty reply between (`WorkBuddyWire.replyAfterTools`), and the
///   model that refused them gets it at once in every later chat (plugin
///   0.1.20, a4f8178).
/// - A chat over 2 MiB whose connection was reset before any answer is asked
///   about at the billing API, and a refused sign-in there is the chat's
///   own 401 (plugin 0.1.24, 9a4ec86), which the agent loop renews once and
///   sends again as for any refused token.
///
/// Each is sent again at most once, and only for the code that names it;
/// every other answer, and the last refusal, goes up as it came. What is
/// remembered is this provider's for the process, as the plugin's is for
/// its load.
struct WorkBuddyChatClient: HTTPClient {
    let inner: HTTPClient
    let site: WorkBuddySite
    let memory = WorkBuddyChatMemory()

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        try await chat(url: url, method: method, headers: headers, body: body, cancellation: cancellation, timeout: nil)
    }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?,
        timeoutSeconds: TimeInterval
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        try await chat(
            url: url,
            method: method,
            headers: headers,
            body: body,
            cancellation: cancellation,
            timeout: timeoutSeconds
        )
    }

    private func chat(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?,
        timeout: TimeInterval?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        func post(_ body: Data?) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
            do {
                if let timeout {
                    return try await inner.stream(
                        url: url,
                        method: method,
                        headers: headers,
                        body: body,
                        cancellation: cancellation,
                        timeoutSeconds: timeout
                    )
                }
                return try await inner.stream(
                    url: url,
                    method: method,
                    headers: headers,
                    body: body,
                    cancellation: cancellation
                )
            } catch {
                guard let refused = await unanswered(body: body, error: error, headers: headers, cancellation: cancellation)
                else { throw error }
                return refused
            }
        }
        guard let body, var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              root["messages"] is [Any] else {
            return try await post(body)
        }
        let model = root["model"] as? String ?? ""
        let systemKey = WorkBuddyWire.systemKey(root)
        var changed = false
        if !systemKey.isEmpty, memory.refusedSystem(systemKey), let moved = WorkBuddyWire.systemAsUser(root) {
            root = moved
            changed = true
        }
        func shaped(_ root: [String: Any]) -> [String: Any]? {
            memory.endsAfterTools(model) ? WorkBuddyWire.replyAfterTools(root) : nil
        }
        var (response, stream) = try await post(
            shaped(root).map(encoded) ?? (changed ? encoded(root) : body)
        )
        guard response.statusCode == 400 else { return (response, stream) }
        var said = await read(stream)
        if WorkBuddyWire.refusesChannel(said), !systemKey.isEmpty, !memory.refusedSystem(systemKey),
           let moved = WorkBuddyWire.systemAsUser(root) {
            memory.noteRefusedSystem(systemKey)
            root = moved
            (response, stream) = try await post(encoded(shaped(root) ?? root))
            guard response.statusCode == 400 else { return (response, stream) }
            said = await read(stream)
        }
        if !memory.endsAfterTools(model), WorkBuddyWire.refusesAfterTools(said),
           let again = WorkBuddyWire.replyAfterTools(root) {
            memory.noteEndsAfterTools(model)
            return try await post(encoded(again))
        }
        return (response, replay(said))
    }

    private func encoded(_ root: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func read(_ stream: AsyncThrowingStream<Data, Error>) async -> String {
        var data = Data()
        do {
            for try await chunk in stream { data.append(chunk) }
        } catch {}
        return String(decoding: data, as: UTF8.self)
    }

    private func replay(_ text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            if !text.isEmpty { continuation.yield(Data(text.utf8)) }
            continuation.finish()
        }
    }

    // MARK: - A reset past 2 MiB

    /// How much of a request WorkBuddy's front door (APISIX, on both builds)
    /// reads before it answers a sign-in it refuses. A refused request with
    /// a longer body gets no answer at all: the connection is reset, and the
    /// chat fails as a dropped connection, which says nothing of the sign-in
    /// and is retried as a passing fault. Measured on 2026-10-15 on both
    /// builds: a body of 2097152 bytes with a refused token got 401, one of
    /// 2097153 a reset; with an accepted token 20 MB went through (plugin
    /// 0.1.24, 9a4ec86; `reset.test.mjs`). A long session's chat is past it.
    static let edgeReads = 2 * 1024 * 1024

    /// The answer to a chat whose request failed with `error` before any
    /// answer: for a chat past `edgeReads` and a sign-in the billing API
    /// refuses with its 401 whatever the size, that 401, said as the chat's
    /// own; nil for anything else, which leaves the error as it was. A
    /// cancelled or timed-out request, a smaller chat (which the front door
    /// answers itself), an unreachable billing API and any answer but 401
    /// all leave it. The chat isn't sent again here: the agent loop renews a
    /// refused token once and sends it again itself.
    private func unanswered(
        body: Data?,
        error: Error,
        headers: [String: String],
        cancellation: CancellationHandle?
    ) async -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)? {
        guard let body, body.count > Self.edgeReads, cancellation?.isCancelled != true,
              !(error is CancellationError) else { return nil }
        if let code = (error as? URLError)?.code, code == .cancelled || code == .timedOut { return nil }
        guard let url = URL(string: site.endpoint + "/billing/meter/get-user-resource-summary") else { return nil }
        let response: HTTPURLResponse
        do {
            (response, _) = try await inner.request(
                url: url,
                method: "POST",
                headers: meterHeaders(headers),
                body: Data("{}".utf8),
                cancellation: cancellation
            )
        } catch {
            return nil
        }
        guard response.statusCode == 401 else { return nil }
        let size = String(format: "%.1f", Double(body.count) / Double(1024 * 1024))
        let message = "\(site.name) refused this account's sign-in (401). It closes the connection on a refused "
            + "request over 2 MiB (this one was \(size) MiB) instead of answering, which is why it read as a "
            + "dropped connection. Sign in to \(site.name) again."
        let payload: [String: Any] = ["error": ["message": message, "type": "authentication_error", "code": 401]]
        var fields = ["content-type": "application/json"]
        // Whether the token itself was refused, as the chat's own 401 would
        // have said.
        if let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate") {
            fields["www-authenticate"] = challenge
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let refused = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: fields)
        else { return nil }
        return (refused, replay(String(decoding: data, as: UTF8.self)))
    }

    /// The billing API is asked as kwwk's usage read asks it: the chat's
    /// sign-in and account, WorkBuddy's own client headers, JSON.
    private func meterHeaders(_ chat: [String: String]) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": WorkBuddyOAuth.userAgent,
            "X-Product": "SaaS",
            "X-IDE-Type": "WorkBuddy",
        ]
        let account: Set = ["authorization", "x-user-id", "x-domain", "x-enterprise-id", "x-tenant-id"]
        for (name, value) in chat where account.contains(name.lowercased()) { headers[name] = value }
        return headers
    }
}

/// What a WorkBuddy provider has learned of its chats in this process: the
/// models that refused tool results followed by a user message, and the
/// system prompts refused as an unapproved channel (the last 256, as the
/// plugin keeps them).
final class WorkBuddyChatMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var afterTools: Set<String> = []
    private var systems: [String] = []
    private var systemSet: Set<String> = []

    func endsAfterTools(_ model: String) -> Bool {
        lock.withLock { afterTools.contains(model) }
    }

    func noteEndsAfterTools(_ model: String) {
        _ = lock.withLock { afterTools.insert(model) }
    }

    func refusedSystem(_ key: String) -> Bool {
        lock.withLock { systemSet.contains(key) }
    }

    func noteRefusedSystem(_ key: String) {
        lock.withLock {
            guard systemSet.insert(key).inserted else { return }
            systems.append(key)
            if systems.count > 256 { systemSet.remove(systems.removeFirst()) }
        }
    }
}
