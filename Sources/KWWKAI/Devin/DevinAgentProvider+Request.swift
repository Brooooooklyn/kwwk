import Foundation
import Crypto

extension DevinAgentProvider {
    // MARK: - Request building

    static func buildChatRequest(
        model: Model,
        context: Context,
        messages: [Message],
        options: StreamOptions?,
        apiKey: String,
        userJwt: String,
        cascadeId: String,
        assignment: DevinProto.ModelAssignment?
    ) -> DevinProto.GetChatMessageRequest {
        let chatModelUid = assignment?.modelUid ?? wireModelId(model: model, reasoning: options?.reasoning)
        // Devin's Gemini backend applies Google's tool-schema constraints and
        // rejects JSON-Schema type arrays with an opaque `invalid_argument`.
        let googleSchema = isGeminiUid(model.id) || isGeminiUid(chatModelUid)
        let offered = context.tools ?? []
        let tools = offered.map { tool -> DevinProto.ChatToolDefinition in
            // Devin's Claude models answer 502 to a union at a schema's root.
            let parameters = ToolSchemaRoot.objectRoot(tool.parameters)
            let schema = googleSchema ? normalizeSchemaForGoogle(parameters) : parameters
            // The tool's own words go in the instructions (see
            // `instructions`); the definition only points at them.
            let described = !tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return DevinProto.ChatToolDefinition(
                name: tool.name,
                description: described ? toolDescriptionPointer(tool.name) : tool.name,
                jsonSchemaString: jsonString(schema)
            )
        }
        let instructions = instructions(systemPrompt: context.systemPrompt, tools: offered)
        var prompts = chatMessagePrompts(messages, cascadeId: cascadeId, model: model)
        if !instructions.isEmpty {
            if let first = prompts.firstIndex(where: { $0.source == .user }) {
                prompts[first].prompt = joinNonEmpty(instructions, prompts[first].prompt)
            } else {
                prompts.insert(
                    DevinProto.ChatMessagePrompt(
                        messageId: deterministicUUID("\(cascadeId)\0instructions"),
                        source: .user,
                        prompt: instructions
                    ),
                    at: 0
                )
            }
        }
        // Devin answers 400 "an internal error occurred" to a temperature
        // of exactly 0 on every model; 1e-6 is as near greedy as it takes.
        let requested = options?.temperature ?? 0.4
        let temperature = requested == 0 ? 1e-6 : requested
        let maxTokens = options?.maxTokens ?? (model.maxTokens > 0 ? model.maxTokens : 64_000)
        // ChatToolChoice "required" forces a call (measured 2026-10-11 on
        // Sonnet 5 and Opus 5). A tool's name there is refused with
        // `invalid_argument`, so a named tool is forced only when it is the
        // one tool offered; "none" ends the turn with no content at all, so
        // it stays "auto".
        var toolChoice = "auto"
        switch options?.toolChoice {
        case .required? where !tools.isEmpty:
            toolChoice = "required"
        case .tool(let name)? where tools.count == 1 && tools[0].name == name:
            toolChoice = "required"
        default:
            break
        }
        return DevinProto.GetChatMessageRequest(
            metadata: DevinWire.cliMetadata(apiKey: apiKey, userJwt: userJwt),
            prompt: "",
            chatMessagePrompts: prompts,
            instructions: instructions,
            chatModelUid: chatModelUid,
            configuration: DevinProto.CompletionConfiguration(
                maxTokens: UInt64(max(1, maxTokens)),
                temperature: temperature,
                firstTemperature: temperature,
                topP: 1,
                stopPatterns: defaultStopPatterns
            ),
            tools: tools,
            toolChoice: toolChoice,
            disableParallelToolCalls: !(model.compat?.supportsParallelToolCalls ?? false)
                || options?.parallelToolCalls == false,
            cascadeId: cascadeId,
            executionId: UUID().uuidString.lowercased(),
            modelAssignmentJwt: assignment?.assignmentJwt
        )
    }

    /// What goes at the head of the first user message: the system prompt,
    /// then each tool's description in a `<tool_descriptions>` block, as
    /// magpie's Devin plugin sends them (`build`, `toolDescriptions`).
    ///
    /// Devin screens the request's system field and each tool's own
    /// description, and refuses the whole turn over words it takes in a
    /// message. Measured 2026-10-12 on SWE-1.6 through this builder: the
    /// system prompt "You are a Claude agent, built on Anthropic's Claude
    /// Agent SDK." ends the stream with `permission_denied` "Your request was
    /// blocked by our content policy", and a tool described as "Reads a file
    /// from the local filesystem. You can access any file directly by using
    /// this tool." (WorkBuddy's Read, magpie 85fa42c1) with
    /// `permission_denied` "Unable to process request due to an MCP
    /// configuration issue"; the same words at the head of the user message
    /// are both answered.
    static func instructions(systemPrompt: String?, tools: [Tool]) -> String {
        joinNonEmpty(systemPrompt ?? "", toolDescriptions(tools))
    }

    static func toolDescriptions(_ tools: [Tool]) -> String {
        var out = ""
        for tool in tools {
            let description = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else { continue }
            out += "<tool name=\"\(tool.name)\">\n\(description)\n</tool>\n"
        }
        return out.isEmpty ? "" : "<tool_descriptions>\n\(out)</tool_descriptions>"
    }

    static func toolDescriptionPointer(_ name: String) -> String {
        "Described under <tool name=\"\(name)\"> in <tool_descriptions>, in the instructions."
    }

    static func joinNonEmpty(_ parts: String...) -> String {
        joinNonEmpty(parts)
    }

    static func joinNonEmpty(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func isGeminiUid(_ uid: String) -> Bool {
        let lower = uid.lowercased()
        return lower.contains("gemini") || uid.hasPrefix("MODEL_GOOGLE_GEMINI_")
    }

    /// Flatten one user turn into a Cascade USER prompt with inline images.
    /// A Cascade message holds one text: several text blocks are set apart
    /// by a blank line, as magpie's Devin plugin joins them (`build`), so
    /// the end of one never runs into the start of the next.
    static func userPrompt(_ msg: UserMessage, messageId: String) -> DevinProto.ChatMessagePrompt {
        var prompt = DevinProto.ChatMessagePrompt(messageId: messageId, source: .user)
        var texts: [String] = []
        for block in msg.content {
            switch block {
            case .text(let t): texts.append(t.text)
            case .image(let i): prompt.images.append(.init(base64Data: i.data, mimeType: i.mimeType))
            }
        }
        prompt.prompt = joinNonEmpty(texts)
        return prompt
    }

    /// Map kwwk history onto Cascade `ChatMessagePrompt`s (USER / SYSTEM / TOOL
    /// channels). Message ids are deterministic in (cascade, index, role) so
    /// they stay stable across history rebuilds.
    static func chatMessagePrompts(
        _ messages: [Message],
        cascadeId: String,
        model: Model
    ) -> [DevinProto.ChatMessagePrompt] {
        var prompts: [DevinProto.ChatMessagePrompt] = []
        for (index, message) in messages.enumerated() {
            switch message {
            case .system:
                // Cascade has no mid-conversation tool changes; the request's
                // top-level tool list already holds every current tool.
                continue
            case .user(let user):
                prompts.append(userPrompt(user, messageId: deterministicUUID("\(cascadeId)\0\(index)\0user")))
            case .assistant(let assistant):
                let native = assistant.api == "devin-agent"
                    && assistant.provider == model.provider && assistant.model == model.id
                var prompt = DevinProto.ChatMessagePrompt(source: .system)
                // A Cascade message holds one thinking text and one signature,
                // and Devin's Claude models check the pair: a signature that
                // doesn't match its text fails the turn with `invalid_argument`
                // "There is an issue with this request" (measured 2026-10-11 on
                // Opus 5). Several blocks joined into one text therefore go
                // unsigned, which Devin takes, dropping the thinking.
                let thinkingBlocks = assistant.content.reduce(0) { count, block in
                    if case .thinking = block { return count + 1 }
                    return count
                }
                var texts: [String] = []
                for block in assistant.content {
                    switch block {
                    case .text(let t):
                        texts.append(t.text)
                    case .thinking(let th):
                        prompt.thinking += th.thinking
                        if native, thinkingBlocks == 1, let sig = th.thinkingSignature { prompt.signature = sig }
                    case .toolCall(let call):
                        prompt.toolCalls.append(.init(
                            id: call.id,
                            name: call.name,
                            argumentsJson: jsonString(call.arguments)
                        ))
                    case .fallback:
                        break
                    }
                }
                prompt.prompt = joinNonEmpty(texts)
                if prompt.prompt.isEmpty && prompt.thinking.isEmpty && prompt.signature.isEmpty && prompt.toolCalls.isEmpty {
                    continue
                }
                if native, let responseId = assistant.responseId, !responseId.isEmpty {
                    prompt.messageId = responseId
                } else {
                    prompt.messageId = "bot-" + deterministicUUID("\(cascadeId)\0\(index)\0assistant")
                }
                prompts.append(prompt)
            case .toolResult(let result):
                var prompt = DevinProto.ChatMessagePrompt(
                    messageId: deterministicUUID("\(cascadeId)\0\(index)\0tool\0\(result.toolCallId)"),
                    source: .tool,
                    toolCallId: result.toolCallId,
                    toolResultIsError: result.isError
                )
                for block in result.content {
                    switch block {
                    case .text(let t): prompt.prompt += t.text
                    case .image(let i): prompt.images.append(.init(base64Data: i.data, mimeType: i.mimeType))
                    }
                }
                prompts.append(prompt)
            }
        }
        return prompts
    }

    /// History bytes context maintenance could shrink: every prompt except the
    /// trailing user turn(s) being answered, less the instructions the first
    /// user prompt carries (compaction keeps those).
    static func shrinkableHistoryBytes(request: DevinProto.GetChatMessageRequest, context: Context) -> Int {
        var tail = 0
        if case .user? = context.messages.last { tail = 1 }
        let prompts = request.chatMessagePrompts
        let shrinkable = tail > 0 ? Array(prompts.dropLast(tail)) : prompts
        var bytes = DevinProto.GetChatMessageRequest.historyByteCount(shrinkable)
        if !request.instructions.isEmpty, shrinkable.contains(where: { $0.source == .user }) {
            bytes -= request.instructions.utf8.count
        }
        return max(0, bytes)
    }

    /// RFC-4122-shaped UUID derived from SHA-256 of `seed`.
    static func deterministicUUID(_ seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    static func jsonString(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Minimal Gemini-compatible schema rewrite: JSON-Schema `type` arrays
    /// (`["string", "null"]`) become a single type plus `nullable: true`,
    /// applied recursively.
    static func normalizeSchemaForGoogle(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map(normalizeSchemaForGoogle))
        case .object(var obj):
            if case .array(let types)? = obj["type"] {
                let names = types.compactMap { item -> String? in
                    if case .string(let s) = item { return s }
                    return nil
                }
                let nonNull = names.filter { $0 != "null" }
                if names.contains("null") { obj["nullable"] = .bool(true) }
                if let first = nonNull.first { obj["type"] = .string(first) } else { obj.removeValue(forKey: "type") }
            }
            for (key, child) in obj where key != "type" && key != "enum" && key != "const" && key != "default" {
                obj[key] = normalizeSchemaForGoogle(child)
            }
            return .object(obj)
        default:
            return value
        }
    }
}
