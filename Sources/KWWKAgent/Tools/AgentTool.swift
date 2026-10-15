import Foundation
import KWWKAI

/// Tool executed by the agent. Throwing from `execute` is how tools report
/// failures — the agent loop will turn the error into an error tool result.
public struct AgentTool: Sendable {
    public var name: String
    public var label: String
    public var description: String
    public var parameters: JSONValue
    /// Long-running, side-effect-free waits may opt in so queued user
    /// steering can end the wait without aborting the whole agent run.
    public var interruptible: Bool
    /// Treat an optional argument sent as `null`, `""`, or whitespace as if it
    /// were omitted, before schema validation. Some models fill every
    /// optional field instead of leaving it out; tools that opt in give those
    /// calls the same meaning as the call without the field. Required
    /// arguments are never touched.
    public var omitsBlankOptionalArguments: Bool
    /// Internal marker for the built-in blocking background-task poll.
    /// Name matching is insufficient because SDK tools may reuse the name.
    var isBackgroundTaskPollTool: Bool
    /// Filesystem boundary attached to the registered write capability so
    /// provider-native file operations (notably Cursor delete) cannot bypass
    /// the same policy.
    var fileAccessPolicy: FileAccessPolicy?
    var fileAccessCwd: String?
    /// Unforgeable-by-name marker set only by kwwk's built-in coding-tool
    /// factories. Security decisions must use this marker, never `name`.
    var codingToolCapabilities: CodingTools
    /// Shared with the Agent's background attachment so explicit task results
    /// and automatic runtime asides coordinate in the same consumer mailbox.
    var backgroundDeliveryConsumer: BackgroundTaskDeliveryConsumer?
    /// Manager identity paired with `backgroundDeliveryConsumer`. An Agent may
    /// attach several managers under the same session id; matching both keeps
    /// one manager's detach from disabling another manager's wake path.
    var backgroundTaskManager: BackgroundTaskManager?
    public var execute: @Sendable (
        _ toolCallId: String,
        _ args: JSONValue,
        _ cancellation: CancellationHandle?,
        _ onUpdate: AgentToolUpdate?
    ) async throws -> AgentToolResult

    public init(
        name: String,
        label: String,
        description: String,
        parameters: JSONValue,
        interruptible: Bool = false,
        execute: @escaping @Sendable (
            _ toolCallId: String,
            _ args: JSONValue,
            _ cancellation: CancellationHandle?,
            _ onUpdate: AgentToolUpdate?
        ) async throws -> AgentToolResult
    ) {
        self.name = name
        self.label = label
        self.description = description
        self.parameters = parameters
        self.interruptible = interruptible
        self.omitsBlankOptionalArguments = false
        self.isBackgroundTaskPollTool = false
        self.fileAccessPolicy = nil
        self.fileAccessCwd = nil
        self.codingToolCapabilities = []
        self.backgroundDeliveryConsumer = nil
        self.backgroundTaskManager = nil
        self.execute = execute
    }
}

extension AgentTool {
    /// `args` with every optional top-level argument that is `null`, `""`, or
    /// whitespace removed, when the tool opted in; otherwise `args` unchanged.
    func normalizingBlankOptionalArguments(_ args: JSONValue) -> JSONValue {
        guard omitsBlankOptionalArguments,
              case .object(var object) = args,
              case .object(let schema) = parameters else { return args }
        let required: Set<String>
        if case .array(let names) = schema["required"] ?? .null {
            required = Set(names.compactMap { name -> String? in
                if case .string(let string) = name { return string }
                return nil
            })
        } else {
            required = []
        }
        for (key, value) in object where !required.contains(key) {
            switch value {
            case .null:
                object.removeValue(forKey: key)
            case .string(let string) where string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                object.removeValue(forKey: key)
            default:
                continue
            }
        }
        return .object(object)
    }
}
