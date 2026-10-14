import Foundation

extension FauxProvider {
    static func estimateTokens(_ text: String) -> Int {
        Int((Double(text.utf8.count) / 4.0).rounded(.up))
    }

    static func estimateUsage(
        message: AssistantMessage,
        context: Context,
        options: StreamOptions?,
        cached: @Sendable (String) -> String?,
        setCached: @Sendable (String, String) -> Void
    ) -> AssistantMessage {
        let prompt = serializeContext(context)
        let promptTokens = estimateTokens(prompt)
        let outputTokens = estimateTokens(assistantContentToText(message.content))
        var input = promptTokens
        var cacheRead = 0
        var cacheWrite = 0
        if let sessionId = options?.sessionId, options?.cacheRetention != CacheRetention.none {
            if let previous = cached(sessionId) {
                let shared = commonPrefixLength(previous, prompt)
                cacheRead = estimateTokens(String(previous.prefix(shared)))
                cacheWrite = estimateTokens(String(prompt.dropFirst(shared)))
                input = max(0, promptTokens - cacheRead)
            } else {
                cacheWrite = promptTokens
            }
            setCached(prompt, sessionId)
        }
        var m = message
        m.usage = Usage(
            input: input,
            output: outputTokens,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            totalTokens: input + outputTokens + cacheRead + cacheWrite,
            cost: Cost()
        )
        return m
    }

    static func serializeContext(_ context: Context) -> String {
        var parts: [String] = []
        if let p = context.systemPrompt { parts.append("system:\(p)") }
        for message in context.messages {
            switch message {
            case .user(let u):
                parts.append("user:\(userContentToText(u.content))")
            case .assistant(let a):
                parts.append("assistant:\(assistantContentToText(a.content))")
            case .toolResult(let t):
                parts.append("toolResult:\(toolResultToText(t))")
            case .system:
                continue
            }
        }
        if let tools = context.tools, !tools.isEmpty {
            if let encoded = try? JSONValueEncoder.encode(tools) {
                parts.append("tools:\(encoded)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    static func userContentToText(_ blocks: [UserBlock]) -> String {
        blocks.map { block in
            switch block {
            case .text(let t): return t.text
            case .image(let i): return "[image:\(i.mimeType):\(i.data.utf8.count)]"
            }
        }.joined(separator: "\n")
    }

    static func assistantContentToText(_ blocks: [AssistantBlock]) -> String {
        blocks.map { block in
            switch block {
            case .fallback: return ""
            case .text(let t): return t.text
            case .thinking(let th): return th.thinking
            case .toolCall(let tc):
                let encoded = (try? JSONValueEncoder.encode(tc.arguments)) ?? "{}"
                return "\(tc.name):\(encoded)"
            }
        }.joined(separator: "\n")
    }

    static func toolResultToText(_ message: ToolResultMessage) -> String {
        var parts: [String] = [message.toolName]
        for block in message.content {
            switch block {
            case .text(let t): parts.append(t.text)
            case .image(let i): parts.append("[image:\(i.mimeType):\(i.data.utf8.count)]")
            }
        }
        return parts.joined(separator: "\n")
    }

    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let ai = Array(a)
        let bi = Array(b)
        let len = min(ai.count, bi.count)
        var i = 0
        while i < len && ai[i] == bi[i] { i += 1 }
        return i
    }
}
