import Foundation
import Crypto

/// The body of a `generateAssistantResponse` call, ported from magpie's
/// `buildKiro` (gateway/kiro.go).
///
/// Kiro's API takes a conversation whole — the earlier turns as its history,
/// the last as its current message, with the caller's tools — and is strict
/// about its shape: it opens and ends with the user, every tool call is
/// answered in the message after it, a history may only name tools the
/// request offers, and ids and tool names have patterns of their own.
enum KiroRequest {
    /// What a turn with nothing to say says: Kiro takes no empty message.
    static let proceed = "Please proceed with the task."
    /// What answers a tool call no result was sent for.
    static let noResult = "Tool use was interrupted and did not produce a result."
    /// A tool's output is cut at this many bytes, as Kiro's own agent cuts it.
    static let resultLimit = 250_000

    struct Entry: Encodable {
        var user: UserInput?
        var assistant: AssistantResponse?

        enum CodingKeys: String, CodingKey {
            case user = "userInputMessage"
            case assistant = "assistantResponseMessage"
        }
    }

    struct UserInput: Encodable {
        var content = ""
        var modelId: String
        var origin = "KIRO_CLI"
        var images: [Image] = []
        var tools: [Tool] = []
        var toolResults: [ToolResult]?

        enum CodingKeys: String, CodingKey {
            case content, modelId, origin, images
            case context = "userInputMessageContext"
        }

        enum ContextKeys: String, CodingKey { case tools, toolResults }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(content, forKey: .content)
            try c.encode(modelId, forKey: .modelId)
            try c.encode(origin, forKey: .origin)
            if !images.isEmpty { try c.encode(images, forKey: .images) }
            if !tools.isEmpty || toolResults != nil {
                var context = c.nestedContainer(keyedBy: ContextKeys.self, forKey: .context)
                if !tools.isEmpty { try context.encode(tools, forKey: .tools) }
                try context.encodeIfPresent(toolResults, forKey: .toolResults)
            }
        }
    }

    struct Image: Encodable, Equatable {
        struct Source: Encodable, Equatable { var bytes: String }
        var format: String
        var source: Source
    }

    struct Tool: Encodable {
        struct Specification: Encodable {
            struct Schema: Encodable { var json: JSONValue }
            var name: String
            var description: String
            var inputSchema: Schema
        }
        var toolSpecification: Specification

        init(name: String, description: String, schema: JSONValue) {
            toolSpecification = .init(name: name, description: description, inputSchema: .init(json: schema))
        }
    }

    struct ToolResult: Encodable, Equatable {
        struct Text: Encodable, Equatable { var text: String }
        var toolUseId: String
        var status: String
        var content: [Text]
    }

    struct AssistantResponse: Encodable {
        var content = ""
        var toolUses: [ToolUse] = []

        enum CodingKeys: String, CodingKey { case content, toolUses }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(content, forKey: .content)
            if !toolUses.isEmpty { try c.encode(toolUses, forKey: .toolUses) }
        }
    }

    struct ToolUse: Encodable {
        var name: String
        var toolUseId: String
        var input: JSONValue
    }

    private struct Body: Encodable {
        struct State: Encodable {
            struct Current: Encodable { var userInputMessage: UserInput }
            var chatTriggerType = "MANUAL"
            var agentTaskType = "vibe"
            var conversationId: String
            var currentMessage: Current
            var history: [Entry]?
        }
        var conversationState: State
        var agentMode = "vibe"
        var profileArn: String?
    }

    static let emptySchema: JSONValue = .object(["type": "object", "properties": .object([:])])

    // MARK: - Ids and names

    /// A tool call's id as Kiro takes one: another vendor's, which Kiro may
    /// not, becomes one of its own, the same each time.
    static func toolID(_ id: String) -> String {
        if id.range(of: #"^[a-zA-Z0-9_.:-]{1,64}$"#, options: .regularExpression) != nil { return id }
        let digest = Data(SHA256.hash(data: Data(id.utf8)))
        return "t_" + String(PKCE.base64URL(digest).prefix(32))
    }

    /// A tool's name as Kiro takes one: a longer one (an MCP server's,
    /// prefixed) is rejected once the history holds a call ("Invalid tool use
    /// format", REQUEST_BODY_INVALID; magpie #369), so it is cut and told
    /// apart by a hash, the same each time; `toolNames` maps it back.
    static func toolName(_ name: String) -> String {
        if name.range(of: #"^[a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression) != nil { return name }
        let digest = SHA256.hash(data: Data(name.utf8))
        var short = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let allowed = ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-"
            short.append(allowed ? scalar : "_")
        }
        return String(String(short).prefix(55)) + "_" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The caller's name for each name `toolName` changed.
    static func toolNames(tools: [KWWKAI.Tool], messages: [Message]) -> [String: String] {
        var names: [String: String] = [:]
        func add(_ name: String) {
            let short = toolName(name)
            if short != name { names[short] = name }
        }
        for tool in tools { add(tool.name) }
        for case .assistant(let assistant) in messages {
            for case .toolCall(let call) in assistant.content { add(call.name) }
        }
        return names
    }

    static func imageFormat(_ mimeType: String) -> String {
        let lower = mimeType.lowercased()
        guard lower.hasPrefix("image/") else { return "png" }
        let format = String(lower.dropFirst("image/".count))
        if format == "jpg" { return "jpeg" }
        return format.isEmpty ? "png" : format
    }

    // MARK: - Thinking

    /// Whether the model is asked to think aloud: when a reasoning level is
    /// set, of a Claude model (or Kiro's Auto, which picks one).
    static func thinks(model: Model, reasoning: ReasoningLevel?) -> Bool {
        let id = model.id.lowercased()
        return reasoning != nil && (id.contains("claude") || id == "auto")
    }

    /// How long a model thinking aloud may think.
    static func thinkingBudget(_ reasoning: ReasoningLevel?) -> Int {
        switch reasoning {
        case .minimal, .low: return 10_000
        case .high: return 30_000
        case .xhigh, .max: return 50_000
        case .medium, nil: return 20_000
        }
    }

    // MARK: - Build

    static func build(
        model: Model,
        systemPrompt: String?,
        messages: [Message],
        tools: [KWWKAI.Tool],
        profileArn: String?,
        reasoning: ReasoningLevel?
    ) throws -> Data {
        var entries = Self.entries(model: model, messages: messages)

        // The conversation opens with something the user said: tool results
        // with no call before them go, and a reply the caller began with.
        while let first = entries.first {
            guard let user = first.user else {
                entries.removeFirst()
                continue
            }
            if user.toolResults != nil, user.content.isEmpty, user.images.isEmpty {
                entries.removeFirst()
                continue
            }
            entries[0].user?.toolResults = nil
            break
        }
        // And ends with it, the message being answered.
        if entries.last?.user == nil {
            entries.append(Entry(user: UserInput(modelId: model.id)))
        }
        // Each call is answered in the message after it, and only calls are.
        for index in entries.indices {
            guard var user = entries[index].user else { continue }
            let calls = index > 0 ? entries[index - 1].assistant?.toolUses ?? [] : []
            var answered = Set<String>()
            var kept: [ToolResult] = []
            for result in user.toolResults ?? []
            where !answered.contains(result.toolUseId) && calls.contains(where: { $0.toolUseId == result.toolUseId }) {
                answered.insert(result.toolUseId)
                kept.append(result)
            }
            for call in calls where !answered.contains(call.toolUseId) {
                answered.insert(call.toolUseId)
                kept.append(ToolResult(toolUseId: call.toolUseId, status: "error", content: [.init(text: noResult)]))
            }
            user.toolResults = kept.isEmpty ? nil : kept
            if user.content.isEmpty, user.toolResults == nil { user.content = proceed }
            entries[index].user = user
        }
        // Only the latest images are sent again, as Kiro's own agent does.
        let latest = entries.lastIndex { !($0.user?.images.isEmpty ?? true) }
        for index in entries.indices where index != latest {
            entries[index].user?.images = []
        }
        // The instructions go at the head of the first message.
        var system = systemPrompt ?? ""
        if thinks(model: model, reasoning: reasoning) {
            let mode = "<thinking_mode>enabled</thinking_mode>"
                + "<max_thinking_length>\(thinkingBudget(reasoning))</max_thinking_length>"
            system = system.isEmpty ? mode : mode + "\n" + system
        }
        if !system.isEmpty, let first = entries[0].user?.content {
            entries[0].user?.content = system + "\n\n" + first
        }

        // The caller's tools, and any the conversation used that it no longer
        // offers — Kiro rejects a history naming a tool it wasn't given.
        var offered = Set<String>()
        var wireTools: [Tool] = []
        for tool in tools {
            let name = toolName(tool.name)
            let schema: JSONValue = tool.parameters == .null ? emptySchema : tool.parameters
            offered.insert(name)
            wireTools.append(Tool(
                name: name, description: tool.description.isEmpty ? tool.name : tool.description, schema: schema
            ))
        }
        for entry in entries {
            for call in entry.assistant?.toolUses ?? [] where !offered.contains(call.name) {
                offered.insert(call.name)
                wireTools.append(Tool(name: call.name, description: "Tool", schema: emptySchema))
            }
        }
        // The last entry is the user's, by the step that ends the conversation.
        var current = entries.removeLast().user!
        current.tools = wireTools

        let body = Body(
            conversationState: .init(
                conversationId: UUID().uuidString.lowercased(),
                currentMessage: .init(userInputMessage: current),
                history: entries.isEmpty ? nil : entries
            ),
            profileArn: (profileArn ?? "").isEmpty ? nil : profileArn
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(body)
    }

    /// kwwk's transcript as Kiro's alternating entries: neighbouring user
    /// turns (a tool's result is one) are one message, and so are
    /// neighbouring replies.
    private static func entries(model: Model, messages: [Message]) -> [Entry] {
        var entries: [Entry] = []
        func joined(_ a: String, _ b: String) -> String {
            a.isEmpty || b.isEmpty ? a + b : a + "\n\n" + b
        }
        for message in messages {
            var user = UserInput(modelId: model.id)
            switch message {
            case .system:
                // Kiro has no mid-conversation tool changes; the current
                // message's tool list already holds every current tool.
                continue
            case .assistant(let assistant):
                var reply = AssistantResponse()
                var texts: [String] = []
                for block in assistant.content {
                    switch block {
                    case .text(let text):
                        if !text.text.isEmpty { texts.append(text.text) }
                    case .toolCall(let call):
                        let input: JSONValue = call.arguments.objectValue == nil ? .object([:]) : call.arguments
                        reply.toolUses.append(ToolUse(name: toolName(call.name), toolUseId: toolID(call.id), input: input))
                    case .thinking, .fallback:
                        break
                    }
                }
                reply.content = texts.joined(separator: "\n\n")
                // A turn that only thought, or failed.
                if reply.content.isEmpty, reply.toolUses.isEmpty { continue }
                if let last = entries.indices.last, let previous = entries[last].assistant {
                    reply.content = joined(previous.content, reply.content)
                    reply.toolUses = previous.toolUses + reply.toolUses
                    entries[last].assistant = reply
                } else {
                    entries.append(Entry(assistant: reply))
                }
                continue
            case .user(let message):
                var texts: [String] = []
                for block in message.content {
                    switch block {
                    case .text(let text):
                        if !text.text.isEmpty { texts.append(text.text) }
                    case .image(let image):
                        if !image.data.isEmpty {
                            user.images.append(Image(format: imageFormat(image.mimeType), source: .init(bytes: image.data)))
                        }
                    }
                }
                user.content = texts.joined(separator: "\n\n")
            case .toolResult(let result):
                var texts: [String] = []
                for block in result.content {
                    switch block {
                    case .text(let text):
                        texts.append(text.text)
                    case .image(let image):
                        // A tool's images (a screenshot, a file read) go with
                        // the message, as Kiro's tool results carry text alone.
                        if !image.data.isEmpty {
                            user.images.append(Image(format: imageFormat(image.mimeType), source: .init(bytes: image.data)))
                        }
                    }
                }
                var output = texts.joined(separator: "\n")
                if output.utf8.count > resultLimit {
                    output = String(decoding: output.utf8.prefix(resultLimit), as: UTF8.self) + "\n… (cut)"
                }
                if output.isEmpty { output = "(no output)" }
                user.toolResults = [ToolResult(
                    toolUseId: toolID(result.toolCallId), status: result.isError ? "error" : "success",
                    content: [.init(text: output)]
                )]
            }
            if let last = entries.indices.last, var previous = entries[last].user {
                previous.content = joined(previous.content, user.content)
                previous.images += user.images
                if let results = user.toolResults {
                    previous.toolResults = (previous.toolResults ?? []) + results
                }
                entries[last].user = previous
            } else {
                entries.append(Entry(user: user))
            }
        }
        return entries
    }
}
