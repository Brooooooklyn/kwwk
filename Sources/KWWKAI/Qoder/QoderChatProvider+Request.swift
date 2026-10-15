import Foundation

extension QoderChatProvider {
    // MARK: - Request building

    /// The plaintext JSON `agent_chat_generation` takes: the system prompt
    /// (twice — as `system` and as the first message), the turns as OpenAI
    /// turns, the caller's tools as native function tools, and the model's
    /// own listing entry. `windowCeiling` is the catalog row's context
    /// window, the most the caller means the model to be asked for (see
    /// `contextLength`); nil asks for whatever the request needs.
    static func chatBody(
        model: QoderModelInfo,
        context: Context,
        messages: [Message],
        options: StreamOptions?,
        windowCeiling: Int? = nil
    ) throws -> Data {
        let tools = context.tools ?? []
        var systemText = systemPreamble
        if let prompt = context.systemPrompt, !prompt.isEmpty { systemText += "\n\n" + prompt }
        if case .required? = options?.toolChoice, !tools.isEmpty {
            systemText += "\nYou must call an available function in this response."
        }
        let system: [String: Any] = ["type": "text", "text": systemText]

        var sendsTools = !tools.isEmpty
        if case .none? = options?.toolChoice { sendsTools = false }
        let chatTools = sendsTools ? try tools.map(chatTool) : []
        let turns = [["role": "system", "content": [system]] as [String: Any]] + chatMessages(messages)

        let thinking = thinking(options?.reasoning, model: model)
        let maxTokens = options?.maxTokens.flatMap { $0 > 0 ? $0 : nil } ?? QoderModels.defaultMaxTokens
        var parameters: [String: Any] = ["enable_thinking": thinking.enabled, "max_tokens": maxTokens]
        if let effort = thinking.effort { parameters["reasoning_effort"] = effort }
        let window = contextLength(
            model: model,
            requestBytes: model.windows.isEmpty ? 0 : try JSONSerialization.data(
                withJSONObject: ["m": turns, "t": chatTools],
                options: [.withoutEscapingSlashes]
            ).count,
            reply: maxTokens,
            ceiling: windowCeiling
        )
        if window > 0 { parameters["context_length"] = window }

        let configPlaceholder = "model_config:" + UUID().uuidString
        var body: [String: Any] = [
            "parameters": parameters,
            "business": [
                "product": "app", "version": QoderCosy.clientVersion, "type": "agent",
                "id": QoderCosy.compactUUID(), "name": "kwwk session",
                "begin_at": Int64(Date().timeIntervalSince1970 * 1000), "stage": "start",
            ] as [String: Any],
            "agent_id": "agent_common",
            "task_id": "common",
            "session_type": "app",
            "model_config": configPlaceholder,
            "system": [system],
            "messages": turns,
        ]
        if sendsTools { body["tools"] = chatTools }

        // The listing entry goes back exactly as Qoder listed it, so it is
        // spliced in as text rather than rebuilt.
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let text = String(decoding: encoded, as: UTF8.self)
        guard let slot = text.range(of: "\"\(configPlaceholder)\"") else {
            throw ProviderFailure(message: "Qoder: missing model configuration")
        }
        return Data(text.replacingCharacters(in: slot, with: model.config).utf8)
    }

    /// The context window a request asks for (`context_length`) on a model
    /// that offers several: the one Qoder's client picks by default
    /// (`max_input_tokens` when it flags none) while the request fits it,
    /// else the smallest that holds it, else the largest. A larger window
    /// may cost more — Qoder says changing the Context "may change the
    /// rate" — so it is asked for only when the conversation needs it, and
    /// never past `ceiling`, the catalog row's context window: a caller that
    /// lowers the row keeps its requests in the smaller windows.
    ///
    /// The request is counted generously, a token for every 3 bytes of its
    /// turns and tools as JSON, so a window is raised a little early rather
    /// than late; and the reply's `max_tokens` is counted in it, since a
    /// window holds the prompt and the reply: a 180K conversation asking 32K
    /// for the reply is sent 400K, not the 200K it would overflow
    /// (magpie-plugins qoder 0.2.5 and 0.2.6, yetone/magpie#722 and #700,
    /// `context.test.mjs`). A model that lists no windows is sent its
    /// `max_input_tokens`, as before.
    static func contextLength(model: QoderModelInfo, requestBytes: Int, reply: Int, ceiling: Int? = nil) -> Int {
        guard !model.windows.isEmpty else { return model.maxInputTokens }
        let base = model.defaultWindow > 0 ? model.defaultWindow
            : model.maxInputTokens > 0 ? model.maxInputTokens : model.contextWindow
        let need = (requestBytes + 2) / 3 + max(0, reply)
        if need <= base { return base }
        let offered = model.windows.filter { $0 <= ceiling ?? .max }
        return offered.first { $0 >= need } ?? max(offered.last ?? base, base)
    }

    /// The turns as OpenAI turns, the format Qoder's chat endpoint takes: an
    /// assistant's tool calls as `tool_calls` and their results as `tool`
    /// turns named by `tool_call_id`, so a result is paired with its call by
    /// id and not by order. A tool turn holds text only, so the images a
    /// tool returned go after the tool turns in a user turn — as the start
    /// of the user's own turn when one comes next.
    static func chatMessages(_ messages: [Message]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var toolNames: [String: String] = [:]
        var pendingImages: [[String: Any]] = []

        func image(_ image: ImageContent) -> [String: Any]? {
            guard !image.data.isEmpty else { return nil }
            return ["type": "image_url", "image_url": ["url": "data:\(image.mimeType);base64,\(image.data)"]]
        }
        func showPendingImages() {
            guard !pendingImages.isEmpty else { return }
            out.append(["role": "user", "content": pendingImages])
            pendingImages = []
        }

        for message in messages {
            switch message {
            case .system:
                // Qoder has no mid-conversation tool changes; the request's
                // tool list already holds every current tool.
                continue
            case .user(let user):
                let blocks: [[String: Any]] = user.content.compactMap { block in
                    switch block {
                    case .text(let text): ["type": "text", "text": text.text]
                    case .image(let content): image(content)
                    }
                }
                guard !blocks.isEmpty else { continue }
                out.append(["role": "user", "content": pendingImages + blocks])
                pendingImages = []
            case .assistant(let assistant):
                showPendingImages()
                var blocks: [[String: Any]] = []
                var calls: [[String: Any]] = []
                for block in assistant.content {
                    switch block {
                    case .text(let text):
                        blocks.append(["type": "text", "text": text.text])
                    case .toolCall(let call):
                        let id = call.id.isEmpty ? "call_" + QoderCosy.compactUUID() : call.id
                        toolNames[id] = call.name
                        calls.append([
                            "id": id, "type": "function",
                            "function": ["name": call.name, "arguments": json(call.arguments)],
                        ])
                    case .thinking, .fallback:
                        break
                    }
                }
                if !calls.isEmpty {
                    // A turn that calls tools carries its text as a plain
                    // string beside them — all of it, joined, as the plugin's
                    // `textOf` sends it, not only the first block.
                    let text = blocks.compactMap { $0["text"] as? String }.joined()
                    out.append(["role": "assistant", "content": text, "tool_calls": calls])
                } else if !blocks.isEmpty {
                    out.append(["role": "assistant", "content": blocks])
                }
            case .toolResult(let result):
                var text = result.content.compactMap { block -> String? in
                    if case .text(let text) = block { return text.text }
                    return nil
                }.joined()
                if result.isError { text = "Error: " + text }
                let images = result.content.compactMap { block -> [String: Any]? in
                    if case .image(let content) = block { return image(content) }
                    return nil
                }
                if !images.isEmpty {
                    var origin = "tool call \(result.toolCallId)"
                    let name = toolNames[result.toolCallId] ?? result.toolName
                    if !name.isEmpty { origin = "\(name) (\(origin))" }
                    pendingImages.append(["type": "text", "text": "[From the result of \(origin):]"])
                    pendingImages += images
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "\n\n" }
                    text += images.count == 1
                        ? "[The tool returned an image; it follows in the next message.]"
                        : "[The tool returned \(images.count) images; they follow in the next message.]"
                }
                out.append(["role": "tool", "tool_call_id": result.toolCallId, "content": text])
            }
        }
        showPendingImages()
        return out
    }

    private static func chatTool(_ tool: Tool) throws -> [String: Any] {
        var parameters = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(tool.parameters),
            options: [.fragmentsAllowed]
        )
        if parameters is NSNull { parameters = ["type": "object", "properties": [String: Any]()] as [String: Any] }
        return [
            "type": "function",
            "function": ["name": tool.name, "description": tool.description, "parameters": parameters],
        ]
    }

    private static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The reasoning levels agents and vendors name, weakest first.
    private static let effortRank = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// Whether to think and at which of the model's own efforts (nil to send
    /// none). Thinking turned off reaches a model that can stop as off; one
    /// that always thinks then thinks at its lowest (asked for less, Qoder
    /// refuses with "该模型始终思考，不支持关闭思考"). A level the model
    /// doesn't name goes to the nearest one it does, the stronger on a tie.
    static func thinking(_ level: ReasoningLevel?, model: QoderModelInfo) -> (enabled: Bool, effort: String?) {
        guard model.thinks, level != nil || model.alwaysThinks else { return (false, nil) }
        guard let lowest = model.efforts.first else { return (true, nil) }
        guard let level else { return (true, lowest) }
        if model.efforts.contains(level.rawValue) { return (true, level.rawValue) }
        let wanted = effortRank.firstIndex(of: level.rawValue) ?? 0
        var best = level.rawValue
        var distance = effortRank.count
        for effort in model.efforts {
            guard effort != "none", let rank = effortRank.firstIndex(of: effort) else { continue }
            if abs(rank - wanted) < distance || abs(rank - wanted) == distance && rank > wanted {
                best = effort
                distance = abs(rank - wanted)
            }
        }
        return (true, best)
    }
}
