import Foundation
import KWWKAI

public enum SubagentLifecycleKind: String, Sendable, Hashable {
    case started = "subagent_started"
    case toolUpdate = "subagent_tool_update"
    case backgroundStarted = "subagent_background_started"
    case completed = "subagent_completed"
    case failed = "subagent_failed"
}

public struct SubagentLifecycleEvent: Sendable, Hashable {
    public var kind: SubagentLifecycleKind
    public var toolCallId: String?
    public var subagentType: String
    public var childSessionId: String
    public var description: String?
    public var model: String?
    public var stopReason: StopReason?
    public var usage: Usage?
    public var usageEstimated: Bool
    public var turns: Int?
    public var cost: Cost?
    public var durationMs: Int?
    public var backgroundTaskId: String?
    public var outputFile: String?
    public var message: String?
    public var errorMessage: String?

    public init(
        kind: SubagentLifecycleKind,
        toolCallId: String? = nil,
        subagentType: String,
        childSessionId: String,
        description: String? = nil,
        model: String? = nil,
        stopReason: StopReason? = nil,
        usage: Usage? = nil,
        usageEstimated: Bool = false,
        turns: Int? = nil,
        cost: Cost? = nil,
        durationMs: Int? = nil,
        backgroundTaskId: String? = nil,
        outputFile: String? = nil,
        message: String? = nil,
        errorMessage: String? = nil
    ) {
        self.kind = kind
        self.toolCallId = toolCallId
        self.subagentType = subagentType
        self.childSessionId = childSessionId
        self.description = description
        self.model = model
        self.stopReason = stopReason
        self.usage = usage
        self.usageEstimated = usageEstimated
        self.turns = turns
        self.cost = cost
        self.durationMs = durationMs
        self.backgroundTaskId = backgroundTaskId
        self.outputFile = outputFile
        self.message = message
        self.errorMessage = errorMessage
    }
}

public enum AgentRuntimeEvent: Sendable, Hashable {
    case subagent(SubagentLifecycleEvent)

    public var type: String {
        switch self {
        case .subagent(let event):
            return event.kind.rawValue
        }
    }
}
