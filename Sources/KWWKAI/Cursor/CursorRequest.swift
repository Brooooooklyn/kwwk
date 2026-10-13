import Foundation
import Crypto

/// Builds the `AgentRunRequest` (wrapped in an `AgentClientMessage`) for a
/// Cursor Run against a seeded blob store. Mirrors oh-my-pi's
/// `buildGrpcRequest`:
///
/// - `rootPromptMessagesJson` carries the system prompt PLUS every prior
///   user/assistant/toolResult message as JSON blobs — Cursor's server builds
///   the actual model prompt from this field (`turns[]` is UI metadata), so
///   omitting history here silently loses all multi-turn context.
/// - `turns[]`, each turn's `user_message`, and its `steps[]` are sha256 blob
///   IDs registered in the blob store and resolved by the server through the
///   KV `get_blob` handshake — never inline message bytes.
/// - The trailing user message drives the turn's `userMessageAction`; when the
///   context ends in assistant/tool-result messages instead, the run resumes
///   the previous turn (`resumeAction`) and the trailing messages stay in
///   history.
enum CursorRequestBuilder {
    static func build(
        model: Model,
        wireModelId: String,
        context: Context,
        conversationId: String,
        blobStore: CursorBlobStore,
        cachedCheckpoint: Data?
    ) -> Data {
        // System prompt blob: `{ "role": "system", "content": … }`, keyed by its
        // sha256 id, referenced from rootPromptMessagesJson.
        let systemContent = context.systemPrompt?.isEmpty == false
            ? context.systemPrompt!
            : "You are a helpful assistant."
        let systemId = storeJSONBlob(["role": "system", "content": systemContent], in: blobStore)

        // Final user message → action; everything before it → history.
        let activeIndex = activeUserMessageIndex(context.messages)

        let turns = buildTurns(context.messages, activeIndex: activeIndex, blobStore: blobStore)
        var rootPromptIds = buildRootPromptIds(
            context.messages, activeIndex: activeIndex, systemId: systemId, blobStore: blobStore
        )
        // The server puts its own system prompt in place of the first entry
        // and shows the model the client's rules (how the system prompt
        // reaches it, see `encodeRequestContextResult`) in a user message it
        // writes only when the conversation has no messages yet. A request
        // that carries history therefore has to carry that message itself:
        // without it a model asked on the second turn for a word its system
        // prompt gave it answered that it knew none (measured 2026-10-11).
        if rootPromptIds.count > 1, let prompt = context.systemPrompt, !prompt.isEmpty {
            rootPromptIds.insert(
                storeJSONBlob(["role": "user", "content": rulesMessage(prompt)], in: blobStore), at: 1
            )
        }

        // Preserve cached non-history checkpoint fields (todos, file states,
        // summary archives, …) only while the system prompt is unchanged.
        let preserved = cachedCheckpoint.flatMap { checkpoint in
            CursorProto.rootPromptIds(ofState: checkpoint).first == systemId ? checkpoint : nil
        }
        let conversationState = CursorProto.encodeConversationState(
            rootPromptIds: rootPromptIds, turns: turns, preserving: preserved
        )

        let action: CursorProto.RunAction
        if let activeIndex, case .user(let active) = context.messages[activeIndex] {
            action = .userMessage(encodeUser(active, messageId: UUID().uuidString))
        } else {
            action = .resume
        }

        return CursorProto.encodeRunRequestMessage(
            conversationState: conversationState,
            action: action,
            modelId: wireModelId,
            modelName: model.name,
            conversationId: conversationId,
            customSystemPrompt: nil
        )
    }

    /// Index of the trailing user message when it carries text or images —
    /// that message becomes the action. `nil` means resume (context ends in
    /// assistant/tool-result messages, or the trailing user message is empty).
    /// Tool declarations (`.system`) are bookkeeping, not turns, so a prompt
    /// followed by one is still the active message.
    private static func activeUserMessageIndex(_ messages: [Message]) -> Int? {
        guard let index = messages.lastIndex(where: { $0.role != .system }),
              case .user(let u) = messages[index] else { return nil }
        guard !userText(u).isEmpty || !userImages(u).isEmpty else { return nil }
        return index
    }

    /// The system prompt as the server words a user rule in the message it
    /// opens a conversation with.
    private static func rulesMessage(_ systemPrompt: String) -> String {
        """
        <rules>
        The rules section has a number of possible rules/memories/context that you should consider. \
        In each subsection, we provide instructions about what information the subsection contains \
        and how you should consider/follow the contents of the subsection.

        <user_rules description="These are rules set by the user that you should follow if appropriate.">
        <user_rule>\(systemPrompt)</user_rule>
        </user_rules>
        </rules>
        """
    }

    // MARK: - Content extraction

    private static func userText(_ u: UserMessage) -> String {
        u.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text }
            return nil
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func userImages(_ u: UserMessage) -> [ImageContent] {
        u.content.compactMap { block -> ImageContent? in
            if case .image(let i) = block { return i }
            return nil
        }
    }

    private static func assistantText(_ a: AssistantMessage) -> String {
        a.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text }
            return nil
        }.joined(separator: "\n")
    }

    private static func toolResultText(_ tr: ToolResultMessage) -> String {
        tr.content.compactMap { block -> String? in
            switch block {
            case .text(let t): return t.text
            case .image(let i): return "[\(i.mimeType) image]"
            }
        }.joined(separator: "\n")
    }

    private static func encodeUser(_ u: UserMessage, messageId: String) -> Data {
        CursorProto.encodeUserMessage(
            text: userText(u),
            messageId: messageId,
            images: userImages(u).compactMap { image in
                guard let data = Data(base64Encoded: image.data) else { return nil }
                return CursorProto.UserImage(
                    uuid: deterministicUuid("img:\(image.data.prefix(64)):\(image.mimeType)"),
                    mimeType: image.mimeType,
                    data: data
                )
            }
        )
    }

    // MARK: - History builders

    /// `rootPromptMessagesJson` blob IDs: the system prompt followed by one
    /// JSON blob per prior message in Cursor's Vercel-AI-SDK-shaped format.
    /// The active user message is excluded — it rides in the action.
    ///
    /// Tool use is written the way Cursor's own server writes it into this
    /// field (read back from its `set_blob` writes, 2026-10-11): an assistant
    /// message per step whose content ends in `tool-call` parts, then one
    /// `role: "tool"` message per call carrying its `tool-result`. Sent as
    /// plain assistant text plus "[Tool Result]" user messages, a model asked
    /// on the next turn which tools it had run answered that it could not see
    /// any; in this shape it listed each call with its arguments.
    private static func buildRootPromptIds(
        _ messages: [Message], activeIndex: Int?, systemId: Data, blobStore: CursorBlobStore
    ) -> [Data] {
        let history = messages.prefix(activeIndex ?? messages.count)
        var results: [String: ToolResultMessage] = [:]
        for case .toolResult(let tr) in history where results[tr.toolCallId] == nil {
            results[tr.toolCallId] = tr
        }
        // Results already written beside their call; any other result has no
        // call in this history and stays readable as text.
        var paired: Set<String> = []

        var ids: [Data] = [systemId]
        for message in history {
            switch message {
            case .user(let u):
                var parts: [[String: Any]] = []
                let text = userText(u)
                if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                for image in userImages(u) {
                    // An image as Cursor's own server writes one into this
                    // field (read back from its `set_blob`, 2026-10-13, and
                    // what magpie's cursor plugin sends): the bytes in hex
                    // under `__type: "Uint8Array"`, with `mimeType`. Sent as
                    // base64 with `mediaType`, a model asked on the next
                    // turn about the picture answered that it saw none.
                    guard let bytes = Data(base64Encoded: image.data) else { continue }
                    parts.append([
                        "type": "image", "mimeType": image.mimeType,
                        "image": ["__type": "Uint8Array", "hex": bytes.map { String(format: "%02x", $0) }.joined()],
                    ])
                }
                if parts.isEmpty { continue }
                ids.append(storeJSONBlob(["role": "user", "content": parts], in: blobStore))
            case .assistant(let a):
                var parts: [[String: Any]] = []
                var calls: [ToolCall] = []
                // A step ends where text follows its calls: the calls' results
                // go between the two assistant messages, as the server has them.
                func flush() {
                    if !parts.isEmpty {
                        ids.append(storeJSONBlob(["role": "assistant", "content": parts], in: blobStore))
                    }
                    for call in calls {
                        paired.insert(call.id)
                        ids.append(storeJSONBlob(toolMessage(for: call, result: results[call.id]), in: blobStore))
                    }
                    parts = []
                    calls = []
                }
                for block in a.content {
                    switch block {
                    case .text(let t):
                        if t.text.isEmpty { continue }
                        if !calls.isEmpty { flush() }
                        parts.append(["type": "text", "text": t.text])
                    case .toolCall(let call):
                        // One result per id: a repeated id would leave a call
                        // with no result of its own.
                        if paired.contains(call.id) || calls.contains(where: { $0.id == call.id }) { continue }
                        parts.append([
                            "type": "tool-call", "toolCallId": call.id, "toolName": call.name,
                            "args": jsonObject(call.arguments),
                        ])
                        calls.append(call)
                    default:
                        continue
                    }
                }
                flush()
            case .toolResult(let tr):
                if paired.contains(tr.toolCallId) { continue }
                let text = toolResultText(tr)
                if text.isEmpty { continue }
                let prefix = tr.isError ? "[Tool Error]" : "[Tool Result]"
                ids.append(storeJSONBlob(
                    ["role": "user", "content": [["type": "text", "text": "\(prefix)\n\(text)"]]],
                    in: blobStore
                ))
            case .system:
                continue
            }
        }
        return ids
    }

    /// `{ role: "tool", content: [tool-result] }` for one call. Every call
    /// gets one: a call left without a result (an aborted turn) is answered
    /// as an error, since a conversation with an unanswered call is refused
    /// by the model APIs behind Cursor.
    private static func toolMessage(for call: ToolCall, result: ToolResultMessage?) -> [String: Any] {
        let text = result.map(toolResultText) ?? "No result was recorded for this tool call."
        var part: [String: Any] = [
            "type": "tool-result", "toolCallId": call.id, "toolName": call.name,
            "result": text, "experimental_content": [["type": "text", "text": text]],
        ]
        if result?.isError ?? true { part["isError"] = true }
        return ["role": "tool", "content": [part], "id": call.id]
    }

    /// Tool-call arguments as a JSON object for `JSONSerialization`; anything
    /// that is not an object (a truncated call) goes as `{}`.
    private static func jsonObject(_ value: JSONValue) -> Any {
        guard case .object = value,
              let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return [String: Any]()
        }
        return object
    }

    /// Serialize prior messages into `ConversationTurnStructure` blob IDs. Each
    /// turn is a user message followed by the assistant's steps (assistant text
    /// and tool results, folded into assistant-message steps). Message ids are
    /// deterministic so unchanged history re-encodes to identical blob IDs and
    /// stays cached server-side.
    private static func buildTurns(
        _ messages: [Message], activeIndex: Int?, blobStore: CursorBlobStore
    ) -> [Data] {
        var turns: [Data] = []
        var i = 0
        while i < messages.count {
            guard case .user(let u) = messages[i] else { i += 1; continue }
            if i == activeIndex { break }

            let text = userText(u)
            let images = userImages(u)
            if text.isEmpty && images.isEmpty { i += 1; continue }
            let contentKey = "\(text)|\(images.map { "\($0.mimeType):\($0.data.prefix(64))" }.joined())"
            let userMessage = encodeUser(
                u, messageId: deterministicUuid("u:\(turns.count):\(contentKey)")
            )
            let userMessageId = blobStore.store(userMessage)

            var stepIds: [Data] = []
            i += 1
            while i < messages.count {
                if case .user = messages[i] { break }
                switch messages[i] {
                case .assistant(let a):
                    let t = assistantText(a)
                    if !t.isEmpty {
                        stepIds.append(blobStore.store(CursorProto.encodeAssistantStep(text: t)))
                    }
                case .toolResult(let tr):
                    let t = toolResultText(tr)
                    if !t.isEmpty {
                        let prefix = tr.isError ? "[Tool Error]" : "[Tool Result]"
                        stepIds.append(blobStore.store(
                            CursorProto.encodeAssistantStep(text: "\(prefix)\n\(t)")
                        ))
                    }
                case .user, .system:
                    break
                }
                i += 1
            }
            turns.append(blobStore.store(
                CursorProto.encodeAgentTurn(userMessage: userMessageId, steps: stepIds)
            ))
        }
        return turns
    }

    // MARK: - Blob helpers

    private static func storeJSONBlob(_ object: [String: Any], in blobStore: CursorBlobStore) -> Data {
        // Sorted keys keep blob bytes (and thus blob IDs) stable across
        // requests so the server-side blob cache can hit.
        let json = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return blobStore.store(json)
    }

    /// A stable UUID-formatted string derived from `seed`, so re-encoding
    /// unchanged history produces byte-identical blobs.
    static func deterministicUuid(_ seed: String) -> String {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        func hex(_ range: Range<Int>) -> String {
            digest[range].map { String(format: "%02x", $0) }.joined()
        }
        return "\(hex(0..<4))-\(hex(4..<6))-\(hex(6..<8))-\(hex(8..<10))-\(hex(10..<16))"
    }
}
