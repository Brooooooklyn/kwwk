import Foundation
import KWWKAI

/// Partial or final result returned by an `AgentTool.execute` call.
public struct AgentToolResult: Sendable, Hashable {
    public var content: [ToolResultBlock]
    public var details: JSONValue?
    /// Structured runtime events produced by the tool. The agent loop
    /// forwards these as `AgentEvent.runtimeEvent` after the corresponding
    /// tool update/end event. They are process-local telemetry; providers
    /// never see them.
    public var runtimeEvents: [AgentRuntimeEvent]?
    /// Optional UI-only display lines. When non-nil, the TUI renderer
    /// prefers these over its default truncated preview of `content`.
    /// Tools use this to summarize noisy output for the user (e.g.
    /// "listed 847 paths", "matched 3 files", "exit 0 · 2.3s") while
    /// still handing the full `content` to the LLM.
    ///
    /// Pure UI-side data — never leaves the process, never seen by any
    /// provider. Doesn't affect `content` → wire serialization.
    public var uiDisplay: [String]?
    /// Process-local delivery transaction carried by results that replace an
    /// automatic runtime notification. It is deliberately internal: providers,
    /// persisted transcripts, and SDK callers only see the paired tool result.
    var retentionLease: AgentToolRetentionLease?

    public init(
        content: [ToolResultBlock],
        details: JSONValue? = nil,
        runtimeEvents: [AgentRuntimeEvent]? = nil,
        uiDisplay: [String]? = nil
    ) {
        self.content = content
        self.details = details
        self.runtimeEvents = runtimeEvents
        self.uiDisplay = uiDisplay
        self.retentionLease = nil
    }
}

/// A tiny commit/rollback token for side-channel delivery ownership. Identity
/// hashing keeps `AgentToolResult` Hashable without comparing closures.
final class AgentToolRetentionLease: @unchecked Sendable, Hashable {
    private let id = UUID()
    private let lock = NSLock()
    private var resolution: Resolution?
    private let onCommit: @Sendable () -> Void
    private let onRollback: @Sendable () -> Void

    private enum Resolution {
        case committed
        case rolledBack
    }

    init(
        onCommit: @escaping @Sendable () -> Void,
        onRollback: @escaping @Sendable () -> Void
    ) {
        self.onCommit = onCommit
        self.onRollback = onRollback
    }

    deinit {
        rollback()
    }

    func commit() {
        let shouldRun = lock.withLock { () -> Bool in
            guard resolution == nil else { return false }
            resolution = .committed
            return true
        }
        if shouldRun { onCommit() }
    }

    func rollback() {
        let shouldRun = lock.withLock { () -> Bool in
            guard resolution == nil else { return false }
            resolution = .rolledBack
            return true
        }
        if shouldRun { onRollback() }
    }

    static func == (lhs: AgentToolRetentionLease, rhs: AgentToolRetentionLease) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public typealias AgentToolUpdate = @Sendable (AgentToolResult) -> Void
