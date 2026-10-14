import Foundation
import KWWKAI

public struct SubagentResult: Sendable {
    public var text: String
    public var model: Model
    public var stopReason: StopReason
    public var usage: Usage
    public var turns: Int
    public var cost: Cost
    public var durationMs: Int

    public init(
        text: String,
        model: Model,
        stopReason: StopReason,
        usage: Usage,
        turns: Int = 0,
        cost: Cost = Cost(),
        durationMs: Int = 0
    ) {
        self.text = text
        self.model = model
        self.stopReason = stopReason
        self.usage = usage
        self.turns = turns
        self.cost = cost
        self.durationMs = durationMs
    }
}

public struct StartedSubagentTask: Sendable {
    public var taskId: String
    public var outputFile: URL
    public var childSessionId: String
    public var subagentType: String
    public var description: String

    public init(
        taskId: String,
        outputFile: URL,
        childSessionId: String,
        subagentType: String,
        description: String
    ) {
        self.taskId = taskId
        self.outputFile = outputFile
        self.childSessionId = childSessionId
        self.subagentType = subagentType
        self.description = description
    }
}
