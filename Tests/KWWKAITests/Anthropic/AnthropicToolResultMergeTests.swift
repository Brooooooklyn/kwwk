import Foundation
import Testing
@testable import KWWKAI

/// Results of parallel tool calls go back in one user message, and a user
/// message that follows them joins it. kwwk encoded each transcript message
/// on its own, so two parallel calls produced two consecutive user messages.
/// Claude merges those; DeepSeek's Anthropic endpoint answers 400 (YEL-514).
/// omp collects consecutive tool results for z.ai's endpoint (anthropic.ts
/// "Collect all consecutive toolResult messages"); magpie joins consecutive
/// same-role turns (gateway/responses.go `mergeTurns`).
@Suite("Anthropic consecutive user turns")
struct AnthropicToolResultMergeTests {
    static let deepseek = Model(
        id: "deepseek-v4-pro", name: "deepseek-v4-pro", api: "anthropic-messages",
        provider: "deepseek", baseURL: "https://api.deepseek.com/anthropic"
    )
    static let claude = Model(
        id: "claude-sonnet-4-5", name: "claude-sonnet-4-5", api: "anthropic-messages",
        provider: "anthropic", baseURL: "https://api.anthropic.com"
    )

    static func parallelCalls(steer: String? = nil) -> [Message] {
        var messages: [Message] = [
            .user(UserMessage(text: "read both files")),
            .assistant(AssistantMessage(content: [
                .toolCall(ToolCall(id: "toolu_a", name: "read", arguments: ["path": "a.txt"])),
                .toolCall(ToolCall(id: "toolu_b", name: "read", arguments: ["path": "b.txt"])),
            ], api: "anthropic-messages", provider: "deepseek", model: "deepseek-v4-pro", stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: "toolu_a", toolName: "read", content: [.text(TextContent(text: "A"))])),
            .toolResult(ToolResultMessage(toolCallId: "toolu_b", toolName: "read", content: [.text(TextContent(text: "B"))])),
        ]
        if let steer { messages.append(.user(UserMessage(text: steer))) }
        return messages
    }

    static func messages(_ model: Model, _ history: [Message]) throws -> [[String: Any]] {
        let body = try AnthropicProvider.encodeBody(model: model, context: Context(messages: history), options: nil)
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(root["messages"] as? [[String: Any]])
    }

    static func blockTypes(_ message: [String: Any]) -> [String] {
        (message["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
    }

    static func roles(_ messages: [[String: Any]]) -> [String] {
        messages.compactMap { $0["role"] as? String }
    }

    @Test("parallel tool results go back in one user message", arguments: [Self.deepseek, Self.claude])
    func parallelResultsShareOneMessage(model: Model) throws {
        let sent = try Self.messages(model, Self.parallelCalls())
        #expect(Self.roles(sent) == ["user", "assistant", "user"])
        let results = try #require(sent.last)
        #expect(Self.blockTypes(results) == ["tool_result", "tool_result"])
        let ids = (results["content"] as? [[String: Any]] ?? []).compactMap { $0["tool_use_id"] as? String }
        #expect(ids == ["toolu_a", "toolu_b"])
    }

    @Test("a user message after the results joins them, results first")
    func steeringJoinsResults() throws {
        let sent = try Self.messages(Self.deepseek, Self.parallelCalls(steer: "also check c.txt"))
        #expect(Self.roles(sent) == ["user", "assistant", "user"])
        #expect(Self.blockTypes(try #require(sent.last)) == ["tool_result", "tool_result", "text"])
    }

    @Test("no two user messages are ever adjacent, and the cache mark stays on the last block")
    func noAdjacentUserMessages() throws {
        var history = Self.parallelCalls(steer: "go on")
        history.append(.assistant(AssistantMessage(
            content: [.text(TextContent(text: "done"))],
            api: "anthropic-messages", provider: "deepseek", model: "deepseek-v4-pro", stopReason: .stop
        )))
        history.append(.user(UserMessage(text: "one")))
        history.append(.user(UserMessage(text: "two")))
        let sent = try Self.messages(Self.claude, history)
        let roles = Self.roles(sent)
        #expect(zip(roles, roles.dropFirst()).allSatisfy { $0 != "user" || $1 != "user" }, "\(roles)")
        let last = try #require(sent.last?["content"] as? [[String: Any]])
        #expect(last.map { $0["text"] as? String } == ["one", "two"])
        let marked = sent.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.filter { $0["cache_control"] != nil }
        #expect(marked.count == 1)
        #expect(last.last?["cache_control"] != nil)
    }
}
