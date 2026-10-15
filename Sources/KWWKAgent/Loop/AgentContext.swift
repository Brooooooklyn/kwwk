import KWWKAI

/// A snapshot of the agent's context at the start of a run. The loop copies
/// these arrays before mutating so the caller's state is never aliased.
public struct AgentContext: Sendable {
    public var systemPrompt: String
    public var messages: [Message]
    public var tools: [AgentTool]

    public init(systemPrompt: String, messages: [Message], tools: [AgentTool]) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}
