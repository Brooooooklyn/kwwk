import Foundation

/// DeepSeek's thinking mode requires the thinking of every tool step to come
/// back on later turns. The whole request is turned away when one of these
/// assistant turns has none:
/// - a turn that calls a tool;
/// - a reply that answers a tool result.
///
/// The error is 400 "The `content[].thinking` in the thinking mode must be
/// passed back to the API" on its Anthropic endpoint, and "The
/// `reasoning_content` in the thinking mode must be passed back to the API"
/// on its Chat endpoint. Such a turn has no thinking when another model made
/// it (cross-model replay downgrades or strips foreign thinking) or when the
/// thinking was empty, so switching to a DeepSeek model after tool use fails
/// on every turn.
///
/// Each such turn gets a thinking that holds a single space, which DeepSeek
/// accepts on both endpoints. The rule goes by the model's name, not only
/// DeepSeek's own host, because relays (OpenRouter, OpenCode Go, Vercel,
/// Fireworks, Hugging Face…) pass DeepSeek's rule on unchanged.
///
/// Ported from magpie (yetone/magpie): f4cc7459 (#1822, #1592, #1687),
/// `anthropicReplaysThinking` / `withThinkingOnToolTurns` in
/// internal/gateway/anthropic.go (#1611), and `chatReplaysReasoning` /
/// `withReasoningOnToolTurns` in internal/gateway/chat.go and chattidy.go
/// (#1462). magpie checked the behaviour against api.deepseek.com on
/// 2026-10-11/12.
enum DeepSeekToolTurnReasoning {
    /// What a turn with no thinking of its own is given. It is not empty
    /// because a relay that leaves empty fields out would send nothing, and
    /// DeepSeek's Responses API turns an empty reasoning text away.
    static let noReasoning = " "

    private static let anthropicModel = try! NSRegularExpression(
        pattern: #"(?:^|[/.:-])claude-"#,
        options: [.caseInsensitive]
    )

    /// Whether `model` is a DeepSeek model, served on any host or one whose
    /// host is DeepSeek's.
    static func isDeepSeek(_ model: Model) -> Bool {
        model.id.lowercased().contains("deepseek") || model.baseURL.lowercased().contains("deepseek")
    }

    /// Whether `model` on the Messages API needs each tool turn to carry a
    /// thinking block. Anthropic's own host and Claude models never do.
    static func appliesToAnthropic(_ model: Model) -> Bool {
        let host = URL(string: model.baseURL)?.host?.lowercased() ?? ""
        if host == "api.anthropic.com" { return false }
        let range = NSRange(model.id.startIndex..., in: model.id)
        if anthropicModel.firstMatch(in: model.id, range: range) != nil { return false }
        return isDeepSeek(model)
    }

    /// Whether `model` on the Chat Completions API needs each tool turn to
    /// carry `reasoning_content`.
    static func appliesToChat(_ model: Model) -> Bool {
        isDeepSeek(model)
    }

    /// Prepends a thinking block holding `noReasoning` to an assistant turn
    /// that has none, when the turn has a `tool_use` or answers a user message
    /// that holds only tool results. Each `redacted_thinking` block (Claude's
    /// sealed thinking, which DeepSeek answers 422) becomes that block, or is
    /// left out when the turn already has thinking. Every other message is
    /// left as it is. A system message, which holds a tool change, does not
    /// end a run of tool results.
    static func anthropicMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        let space: [String: Any] = ["type": "thinking", "thinking": noReasoning]
        var out = messages
        var afterTool = false
        for (i, message) in messages.enumerated() {
            let role = message["role"] as? String
            if role == "system" { continue }
            guard role == "assistant" else {
                let blocks = message["content"] as? [[String: Any]] ?? []
                afterTool = !blocks.isEmpty && blocks.allSatisfy { $0["type"] as? String == "tool_result" }
                continue
            }
            let after = afterTool
            afterTool = false
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            var thought = false, called = false, edited = false
            for block in blocks {
                switch block["type"] as? String {
                case "thinking":
                    thought = true
                    kept.append(block)
                case "tool_use":
                    called = true
                    kept.append(block)
                case "redacted_thinking":
                    edited = true
                    if !thought {
                        kept.append(space)
                        thought = true
                    }
                default:
                    kept.append(block)
                }
            }
            if (called || after) && !thought {
                kept.insert(space, at: 0)
                edited = true
            }
            if edited {
                out[i]["content"] = kept
            }
        }
        return out
    }

    /// Gives `reasoning_content` holding `noReasoning` to each assistant
    /// message with `tool_calls`, and to each assistant reply after a tool
    /// message of the same turn, unless it already has reasoning of its own.
    /// An empty `reasoning_content` counts as none: kwwk only writes one as a
    /// placeholder, and DeepSeek's step rule needs it to say something.
    static func chatMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var out = messages
        var afterTool = false
        for (i, message) in messages.enumerated() {
            switch message["role"] as? String {
            case "tool":
                afterTool = true
                continue
            case "user":
                afterTool = false
                continue
            case "assistant":
                break
            default:
                continue
            }
            let calls = message["tool_calls"] as? [Any] ?? []
            guard !calls.isEmpty || afterTool else { continue }
            if let own = message["reasoning_content"] as? String, !own.isEmpty { continue }
            out[i]["reasoning_content"] = noReasoning
        }
        return out
    }
}
