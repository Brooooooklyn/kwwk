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
            return try await inner.stream(url: url, method: method, headers: headers, body: body, cancellation: cancellation)
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
