import Foundation
import KWWKAI
import NIOConcurrencyHelpers

/// Mutable public state exposed by `Agent`. Consumers read fields directly
/// and use the read/write setters to drive the agent. Array setters copy the
/// assigned array to prevent external aliasing.
///
/// This is a reference type so that the `Agent` actor and the consumer share
/// one view of state; all mutations funnel through one locked box.
public final class AgentState: Sendable {
    private struct State {
        var systemPrompt: String
        var model: Model
        var thinkingLevel: ThinkingLevel
        var thinkingDisplay: ThinkingDisplay
        var verboseEnabled: Bool
        var tools: [AgentTool]
        var toolCatalog: ToolCatalog?
        var messages: [Message]
        /// Advances whenever model-facing context changes. Compaction uses it as a
        /// compare-and-swap guard so a summary built from one prompt snapshot can
        /// never replace a newer one.
        var contextRevision: UInt64 = 0
        var isStreaming: Bool = false
        var streamingMessage: Message?
        var pendingToolCalls: Set<String> = []
        var errorMessage: String?
    }

    private let state: NIOLockedValueBox<State>

    public init(
        systemPrompt: String = "",
        model: Model,
        thinkingLevel: ThinkingLevel = .off,
        thinkingDisplay: ThinkingDisplay = .collapsed,
        verboseEnabled: Bool = false,
        tools: [AgentTool] = [],
        messages: [Message] = []
    ) {
        self.state = NIOLockedValueBox(State(
            systemPrompt: systemPrompt,
            model: model,
            thinkingLevel: thinkingLevel,
            thinkingDisplay: thinkingDisplay,
            verboseEnabled: verboseEnabled,
            tools: tools,
            messages: messages
        ))
    }

    // MARK: - Public properties

    public var systemPrompt: String {
        get { state.withLockedValue { $0.systemPrompt } }
        set {
            state.withLockedValue {
                $0.systemPrompt = newValue
                $0.contextRevision &+= 1
            }
        }
    }

    public var model: Model {
        get { state.withLockedValue { $0.model } }
        set {
            state.withLockedValue {
                $0.model = newValue
                $0.contextRevision &+= 1
            }
        }
    }

    public var thinkingLevel: ThinkingLevel {
        get { state.withLockedValue { $0.thinkingLevel } }
        set { state.withLockedValue { $0.thinkingLevel = newValue } }
    }

    public var thinkingDisplay: ThinkingDisplay {
        get { state.withLockedValue { $0.thinkingDisplay } }
        set { state.withLockedValue { $0.thinkingDisplay = newValue } }
    }

    public var verboseEnabled: Bool {
        get { state.withLockedValue { $0.verboseEnabled } }
        set { state.withLockedValue { $0.verboseEnabled = newValue } }
    }

    /// Array setter copies to prevent external aliasing. Reads return a
    /// snapshot copy as well.
    public var tools: [AgentTool] {
        get { state.withLockedValue { $0.tools } }
        set {
            state.withLockedValue {
                $0.tools = Array(newValue)
                $0.contextRevision &+= 1
            }
        }
    }

    /// Deferred tools (e.g. MCP) this agent can load with `tool_search`.
    /// Its loaded tools join every provider request after `tools`; `tools`
    /// wins on a name clash. Loading is not a context edit: it never
    /// invalidates a compaction in flight. Subagents that may mutate inherit
    /// a child of it.
    public var toolCatalog: ToolCatalog? {
        get { state.withLockedValue { $0.toolCatalog } }
        set { state.withLockedValue { $0.toolCatalog = newValue } }
    }

    /// The tools the next provider request declares: `tools`, then the
    /// catalog's `tool_search` (unless `tools` has one) and loaded tools.
    public var effectiveTools: [AgentTool] {
        let (tools, catalog) = state.withLockedValue { ($0.tools, $0.toolCatalog) }
        return Self.merge(tools, catalog)
    }

    /// The system prompt the next provider request sends: `systemPrompt`
    /// plus the catalog's instructions.
    public var effectiveSystemPrompt: String {
        let (prompt, catalog) = state.withLockedValue { ($0.systemPrompt, $0.toolCatalog) }
        return Self.compose(prompt, catalog)
    }

    private static func merge(_ tools: [AgentTool], _ catalog: ToolCatalog?) -> [AgentTool] {
        guard let catalog else { return tools }
        var names = Set(tools.map(\.name))
        var result = tools
        if !names.contains(toolSearchToolName) {
            result.append(catalog.searchTool)
            names.insert(toolSearchToolName)
        }
        result.append(contentsOf: catalog.tools.filter { !names.contains($0.name) })
        return result
    }

    private static func compose(_ prompt: String, _ catalog: ToolCatalog?) -> String {
        guard let instructions = catalog?.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
              !instructions.isEmpty
        else { return prompt }
        return prompt.isEmpty ? instructions : prompt + "\n\n" + instructions
    }

    public var messages: [Message] {
        get { state.withLockedValue { $0.messages } }
        set {
            state.withLockedValue {
                $0.messages = Array(newValue)
                $0.contextRevision &+= 1
            }
        }
    }

    public var isStreaming: Bool {
        state.withLockedValue { $0.isStreaming }
    }

    public var streamingMessage: Message? {
        state.withLockedValue { $0.streamingMessage }
    }

    public var pendingToolCalls: Set<String> {
        state.withLockedValue { $0.pendingToolCalls }
    }

    public var errorMessage: String? {
        state.withLockedValue { $0.errorMessage }
    }

    // MARK: - Internal mutators (used by Agent)

    func appendMessage(_ message: Message) {
        state.withLockedValue {
            $0.messages.append(message)
            $0.contextRevision &+= 1
        }
    }

    func snapshotModelContext() -> (revision: UInt64, context: AgentContext, model: Model) {
        let catalog = state.withLockedValue { $0.toolCatalog }
        // Read the catalog outside the state lock: it takes its own locks.
        let extra = catalog.map { (tools: $0.tools, search: $0.searchTool, instructions: $0.instructions) }
        return state.withLockedValue { state in
            var tools = state.tools
            var systemPrompt = state.systemPrompt
            if let extra {
                var names = Set(tools.map(\.name))
                if !names.contains(toolSearchToolName) {
                    tools.append(extra.search)
                    names.insert(toolSearchToolName)
                }
                tools.append(contentsOf: extra.tools.filter { !names.contains($0.name) })
                if let instructions = extra.instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
                    systemPrompt = systemPrompt.isEmpty ? instructions : systemPrompt + "\n\n" + instructions
                }
            }
            return (
                state.contextRevision,
                AgentContext(systemPrompt: systemPrompt, messages: state.messages, tools: tools),
                state.model
            )
        }
    }

    func hasContextRevision(_ expectedRevision: UInt64) -> Bool {
        state.withLockedValue { $0.contextRevision == expectedRevision }
    }

    func replaceMessages(_ messages: [Message], ifRevision expectedRevision: UInt64) -> Bool {
        state.withLockedValue { state in
            guard state.contextRevision == expectedRevision else { return false }
            state.messages = Array(messages)
            state.contextRevision &+= 1
            return true
        }
    }

    func setStreaming(_ value: Bool) {
        state.withLockedValue { $0.isStreaming = value }
    }

    func setStreamingMessage(_ message: Message?) {
        state.withLockedValue { $0.streamingMessage = message }
    }

    func insertPendingToolCall(_ id: String) {
        state.withLockedValue { _ = $0.pendingToolCalls.insert(id) }
    }

    func removePendingToolCall(_ id: String) {
        state.withLockedValue { _ = $0.pendingToolCalls.remove(id) }
    }

    func clearPendingToolCalls() {
        state.withLockedValue { $0.pendingToolCalls.removeAll() }
    }

    func setErrorMessage(_ message: String?) {
        state.withLockedValue { $0.errorMessage = message }
    }
}
