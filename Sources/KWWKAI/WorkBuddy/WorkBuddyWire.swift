import Foundation
import Crypto

/// What a WorkBuddy chat carries besides an OpenAI chat-completions body:
/// the client's headers, the conversation's ids, and the mends its gateway
/// needs on the body. Ported from magpie's `internal/provider/workbuddy.go`
/// and the plugin magpie serves WorkBuddy through
/// (`@magpie-community/opencode-workbuddy-auth` 0.1.15), where the newer of
/// these were tried against real accounts.
enum WorkBuddyWire {
    // MARK: - Headers

    /// What WorkBuddy's desktop client sends with every chat, on both builds:
    /// the product, the client's name and version, and the request marked as
    /// an XHR ("the gateway's admission convention"). A chat without the
    /// client's is counted under no client in WorkBuddy's usage list
    /// (magpie b5c83420). WorkBuddy AI also takes the agent's type.
    static func clientHeaders(_ site: WorkBuddySite) -> [String: String] {
        var headers = [
            "X-Product": "SaaS",
            "X-IDE-Type": "WorkBuddy",
            "User-Agent": WorkBuddyOAuth.userAgent,
            "X-Requested-With": "XMLHttpRequest",
            "X-Agent-Intent": "craft",
            "X-Agent-Purpose": "conversation",
            "X-IDE-Name": "WorkBuddy",
            "X-IDE-Version": WorkBuddyOAuth.clientVersion,
        ]
        if site == .international { headers["X-Agent-Type"] = "main" }
        return headers
    }

    /// The four ids WorkBuddy's client names a chat by: the conversation,
    /// the user send (turn) it answers, the message, and the request that
    /// carried it — the last two the same one, new for each request.
    ///
    /// WorkBuddy's backend counts a user send as one request by
    /// `X-Conversation-Request-ID`, so every step of one send — a tool
    /// result sent back, a retry — carries the same one and the user's next
    /// message another. No conversation id is sent when nothing names the
    /// conversation: a made-up one would be a conversation of the request's
    /// own, which is what splits one conversation into many in the usage
    /// detail.
    static func conversationHeaders(context: Context, sessionId: String?) -> [String: String] {
        let conversation = conversationKey(context.messages, sessionId: sessionId)
        let request = PKCE.randomHex()
        var headers = [
            "X-Conversation-Message-ID": request,
            "X-Request-ID": request,
        ]
        // A turn is a conversation's own: two conversations whose user
        // message reads the same are still two sends.
        headers["X-Conversation-Request-ID"] = turnKey(context.messages)
            .map { id(for: "turn", key: "\(conversation ?? "")|\($0)") } ?? PKCE.randomHex()
        if let conversation {
            headers["X-Conversation-ID"] = id(for: "conversation", key: conversation)
        }
        return headers
    }

    /// New in each process, so an id says nothing of the words it was made
    /// from.
    private static let salt = PKCE.randomHex()

    /// The 32 hex digits WorkBuddy's own ids are made of.
    private static func id(for kind: String, key: String) -> String {
        SHA256.hash(data: Data("\(salt)|\(kind)|\(key)".utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The conversation a chat belongs to: its session, else its first user
    /// message, which every later turn repeats.
    static func conversationKey(_ messages: [Message], sessionId: String?) -> String? {
        if let sessionId, !sessionId.isEmpty { return "session:\(sessionId.prefix(128))" }
        for case .user(let user) in messages {
            let signature = signature(user)
            if !signature.isEmpty { return "first:\(signature)" }
        }
        return nil
    }

    /// The user send a chat answers: its last user message that is the
    /// user's own, by its place and its signature. A user message right
    /// after a tool's result or an assistant's calls answers them (a tool
    /// result's images go in one), and one the runtime wrote isn't a send —
    /// unless the chat has no other, as after a compaction.
    static func turnKey(_ messages: [Message]) -> String? {
        for ownOnly in [true, false] {
            for index in messages.indices.reversed() {
                guard case .user(let user) = messages[index], !ownOnly || user.source == nil else { continue }
                if index > 0 {
                    switch messages[index - 1] {
                    case .toolResult: continue
                    case .assistant(let assistant) where assistant.content.contains(where: \.isToolCall): continue
                    default: break
                    }
                }
                let signature = signature(user)
                return signature.isEmpty ? nil : "u\(index):\(signature)"
            }
        }
        return nil
    }

    /// A user message's text, and a digest of each image, so a turn of
    /// images alone is a turn of its own too.
    private static func signature(_ user: UserMessage) -> String {
        user.content.map { block in
            switch block {
            case .text(let text): return text.text
            case .image(let image):
                let digest = SHA256.hash(data: Data(image.data.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
                return "[image:\(digest)]"
            }
        }.joined()
    }

    // MARK: - Body

    /// The system message a chat that has none is sent with: WorkBuddy
    /// refuses one whose first message isn't the system prompt, "first
    /// message is not system prompt" (magpie c3489031).
    static let defaultSystemPrompt = "You are a helpful assistant."

    /// Mends an encoded chat body's messages: the words WorkBuddy refuses a
    /// chat for are reworded, and a chat that doesn't open with a system
    /// message is given the default one.
    static func mendMessages(_ root: inout [String: Any]) {
        guard var messages = root["messages"] as? [[String: Any]], !messages.isEmpty else { return }
        for index in messages.indices.reversed() {
            let isSystem = messages[index]["role"] as? String == "system"
            if let text = messages[index]["content"] as? String {
                let reworded = unflagged(text)
                guard reworded != text else { continue }
                if isSystem, reworded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.remove(at: index)
                } else {
                    messages[index]["content"] = reworded
                }
            } else if let parts = messages[index]["content"] as? [[String: Any]] {
                var changed = false
                let kept = parts.compactMap { part -> [String: Any]? in
                    guard let text = part["text"] as? String else { return part }
                    let reworded = unflagged(text)
                    guard reworded != text else { return part }
                    changed = true
                    if reworded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                    var part = part
                    part["text"] = reworded
                    return part
                }
                guard changed else { continue }
                if isSystem, kept.isEmpty {
                    messages.remove(at: index)
                } else {
                    messages[index]["content"] = kept
                }
            }
        }
        if messages.first?["role"] as? String != "system" {
            messages.insert(["role": "system", "content": defaultSystemPrompt], at: 0)
        }
        root["messages"] = messages
    }

    /// The tool choice in the spelling WorkBuddy's gateway takes, a string:
    /// `auto`, `required`, or the name of the tool the model must call.
    /// OpenAI's object for a named tool (`{"type": "function", "function":
    /// {"name"}}`) is answered 400 "Invalid request parameters", the GPT
    /// family above all, and a chat that may call no tool is sent without
    /// its tools rather than with `none` (plugin 0.1.15, 80bd2d9 / #96;
    /// `request.test.mjs`). The name is the one the tool was sent under:
    /// the provider renames the choice before the body is encoded.
    ///
    /// `parallel_tool_calls` goes with the tools. That one is kwwk's own, not
    /// the plugin's, whose client never sends the field: it says how tools
    /// are called, and OpenAI's models refuse it on a chat that has none.
    static func mendToolChoice(_ root: inout [String: Any]) {
        guard let choice = root["tool_choice"] else { return }
        if let word = choice as? String {
            guard word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none" else { return }
            withoutTools(&root)
            return
        }
        guard let object = choice as? [String: Any] else {
            root["tool_choice"] = nil
            return
        }
        switch (object["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none":
            withoutTools(&root)
        case "auto":
            root["tool_choice"] = "auto"
        case "required":
            root["tool_choice"] = "required"
        case "function":
            let name = ((object["function"] as? [String: Any])?["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            root["tool_choice"] = name.isEmpty ? "auto" : name
        default:
            root["tool_choice"] = nil
        }
    }

    private static func withoutTools(_ root: inout [String: Any]) {
        for field in ["tool_choice", "tools", "functions", "parallel_tool_calls"] { root[field] = nil }
    }

    /// The words both builds answer 400 "Illegal API invocation from an
    /// unapproved channel" to (magpie #182), each with words that say the
    /// same and pass. The plugin's authors tried them one by one against both
    /// builds with what Claude Code 2.1.280 and Codex 0.159.2 send: WorkBuddy
    /// reads every message, not only the system prompt (Claude Code puts its
    /// main branch in the first user message), and pays no mind to case.
    /// Claude Code's billing header means nothing to WorkBuddy's models and
    /// goes.
    private static let flagged: [(NSRegularExpression, String)] = [
        (#"x-anthropic-billing-header:[^\n]*\n?"#, ""),
        (#"You are Claude Code, Anthropic['’]s official CLI for Claude"#, "You are Claude Code, Anthropic's CLI for Claude"),
        (#"Main branch \(you will usually use this for PRs\)"#, "Main branch (usually the base for PRs)"),
        (#"(?<!the )Codex CLI is an open source project led by OpenAI\."#, "The Codex CLI is an open source project led by OpenAI."),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }

    static func unflagged(_ text: String) -> String {
        flagged.reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.1)
            )
        }
    }

    // MARK: - Tools

    /// A chat's tools in shapes WorkBuddy's models take, and the names given
    /// them, each to the caller's own.
    ///
    /// WorkBuddy AI answers 400 code 11133 "Invalid request parameters" to a
    /// tool it can't pass on to the model (magpie 21a5cf08, tried on a real
    /// account 2026-10-08): DeepSeek's models turn away each shape mended
    /// here, and Kimi's, GPT's, Gemini's and GLM's some of them. A tool's
    /// name may hold letters, digits, `_` and `-`; any other character is
    /// sent as `_` and the model's calls are named back.
    struct FittedTools {
        var tools: [Tool]
        /// The name sent → the caller's name, for the names that changed.
        var original: [String: String] = [:]
        /// The caller's name → the name sent.
        var sent: [String: String] = [:]
    }

    static func fit(_ tools: [Tool]) -> FittedTools {
        var fitted = FittedTools(tools: tools)
        var taken = Set(tools.map(\.name).filter(isSafeName))
        for index in tools.indices {
            let name = tools[index].name
            if !isSafeName(name) {
                let safe = safeName(name, taken: &taken)
                fitted.original[safe] = name
                fitted.sent[name] = safe
                fitted.tools[index].name = safe
            }
            fitted.tools[index].parameters = fitParameters(tools[index].parameters)
        }
        return fitted
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy(isSafeNameByte)
    }

    private static func isSafeNameByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
    }

    /// `name` with each character WorkBuddy refuses as `_`, kept apart from
    /// the names already taken.
    private static func safeName(_ name: String, taken: inout Set<String>) -> String {
        let base = name.isEmpty ? "tool" : String(name.utf16.map { unit -> Character in
            unit < 0x80 && isSafeNameByte(UInt8(unit)) ? Character(UnicodeScalar(UInt8(unit))) : "_"
        })
        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        taken.insert(candidate)
        return candidate
    }

    /// A tool's parameters as an object at the root — a root union folded,
    /// a root with no type made one — with `fitSchema` applied throughout.
    static func fitParameters(_ parameters: JSONValue) -> JSONValue {
        guard case .object = parameters else {
            return .object(["type": .string("object"), "properties": .object([:])])
        }
        guard case .object(var root) = ToolSchemaRoot.objectRoot(fitSchema(parameters)) else { return parameters }
        if root["type"] != .string("object") {
            root["type"] = .string("object")
            if case .object? = root["properties"] {} else { root["properties"] = .object([:]) }
        }
        return .object(root)
    }

    /// Mends a schema at every depth: a pattern's `\0`, which DeepSeek's
    /// validator says is "not a 'regex'", becomes `\u0000`, which matches the
    /// same; a tuple's `items` (a list) becomes one schema any of them fits.
    static func fitSchema(_ schema: JSONValue, depth: Int = 0) -> JSONValue {
        guard depth <= 64 else { return schema }
        switch schema {
        case .array(let items):
            return .array(items.map { fitSchema($0, depth: depth + 1) })
        case .object(var object):
            if case .string(let pattern)? = object["pattern"] {
                object["pattern"] = .string(withoutNulEscape(pattern))
            }
            if case .array(let tuple)? = object["items"] {
                let schemas = tuple.filter { if case .object = $0 { return true } else { return false } }
                object["items"] = schemas.count == 1 ? schemas[0]
                    : schemas.isEmpty ? .object([:]) : .object(["anyOf": .array(schemas)])
                object["additionalItems"] = nil
            }
            return .object(object.mapValues { fitSchema($0, depth: depth + 1) })
        default:
            return schema
        }
    }

    /// A regex's `\0` (the NUL character) as `\u0000`, stepping over each
    /// `\\` (a backslash) so that a `\\0` is left; `\01`, an octal escape, is
    /// left too.
    private static func withoutNulEscape(_ pattern: String) -> String {
        var out = ""
        var rest = Substring(pattern)
        while let first = rest.first {
            let next = rest.dropFirst().first
            if first == "\\", next == "\\" {
                out += "\\\\"
                rest = rest.dropFirst(2)
            } else if first == "\\", next == "0", rest.dropFirst(2).first?.isASCIIDigit != true {
                out += "\\u0000"
                rest = rest.dropFirst(2)
            } else {
                out.append(first)
                rest = rest.dropFirst()
            }
        }
        return out
    }

    // MARK: - Refusals

    /// What can be done about "Illegal API invocation from an unapproved
    /// channel". Both builds answer it, 400 with code 11101 or 11128, to a
    /// chat holding words of Codex's or Claude Code's own prompts, at any
    /// reasoning level, on any account and whatever the headers (magpie #182,
    /// 2033df0f): it is about what the chat says, never about the account.
    /// `flagged` rewords the ones known; this is for one it doesn't know.
    /// magpie's own hint (`WBRefusedHint`) names the agents it routes for;
    /// this one says the same of a prompt.
    static let refusedHint =
        "WorkBuddy refuses chats that hold words of Codex's or Claude Code's own prompts, whatever the account; "
        + "take them out of the system prompt, or use another provider"

    /// WorkBuddy wants an active credit package even for a model it serves
    /// free: an account with no package, or none left, is answered 429 with
    /// code 14018, "Credits exhausted. Please visit the link below to
    /// purchase add-on packs…", under `error.data` (magpie-community/plugins
    /// #25, `refused.test.mjs`).
    static let exhaustedHint =
        "WorkBuddy requires an active credit package even for 0-rate free models; check your account package balance"

    private static let refused = try! NSRegularExpression(
        pattern: #"unapproved channel|illegal api invocation"#, options: .caseInsensitive
    )
    /// The code is matched whole: one that only begins with 14018 is another
    /// error.
    private static let exhausted = try! NSRegularExpression(
        pattern: #"credits exhausted|额度已用尽|["']code["']\s*:\s*["']?14018(?![\d.])"#, options: .caseInsensitive
    )

    /// A failed chat's failure in WorkBuddy's own words. Its gateway answers
    /// `{"code", "msg"}`, which reads as no error body of OpenAI's shape and
    /// would be shown whole; the message is its `msg` and the code its
    /// `code`. The channel refusal and spent credits say what to do, and
    /// spent credits are named `insufficient_quota`, as the plugin names
    /// them, so they read as quota.
    static func explained(_ failure: ProviderFailure) -> ProviderFailure {
        let raw = failure.message
        var failure = failure
        var code = failure.providerCode
        if case .object(let root)? = parseJSONObject(raw) {
            let error = object(root["error"]) ?? root
            code = [object(error["data"])?["code"], error["code"], root["code"], object(root["data"])?["code"]]
                .lazy.compactMap(text).first ?? code
            let said = [error["message"], object(error["data"])?["msg"], root["error"], root["msg"], object(root["data"])?["msg"]]
                .lazy.compactMap { value -> String? in
                    guard case .string(let words)? = value, !words.isEmpty else { return nil }
                    return words
                }.first
            if let said {
                failure.message = said
                failure.upstreamMessage = failure.upstreamMessage ?? raw
            }
            failure.providerCode = code
        }
        if matches(refused, raw) {
            failure.message += " — \(refusedHint)"
        } else if code == "14018" || matches(exhausted, raw) {
            failure.message += " — \(exhaustedHint)"
            failure.providerCode = "insufficient_quota"
        }
        return failure
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }

    /// A code as text: WorkBuddy's are numbers, and from some endpoints
    /// strings.
    private static func text(_ value: JSONValue?) -> String? {
        switch value {
        case .int(let number)?: String(number)
        case .string(let words)? where !words.isEmpty: words
        default: nil
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

private extension AssistantBlock {
    var isToolCall: Bool {
        if case .toolCall = self { return true }
        return false
    }
}
