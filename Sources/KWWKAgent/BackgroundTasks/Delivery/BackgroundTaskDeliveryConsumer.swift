import Foundation
import KWWKAI
import NIOConcurrencyHelpers

/// One Agent's model-facing background-result mailbox.
///
/// `BackgroundTaskManager` still broadcasts every notification to its public
/// listeners. This mailbox only coordinates the choice between two delivery
/// paths for one Agent: automatic runtime aside, or an explicitly retained
/// `task_poll`/`task_cancel` result. A tool call temporarily watches task ids;
/// terminal notices are held until its result is committed, then restored if
/// that result is rewound (notably Cursor inline-exec retry/abort).
public final class BackgroundTaskDeliveryConsumer: Sendable {
    let id = UUID()
    public let sessionId: String?

    private struct State {
        var pending: [BackgroundTaskNotification] = []
        var deferredTerminal: [String: BackgroundTaskNotification] = [:]
        var watchCounts: [String: Int] = [:]
        var deliveredTerminalTaskIds: Set<String> = []
        var wakeHandler: (@Sendable () -> Void)?
    }

    private let state = NIOLockedValueBox(State())

    public init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }

    func accepts(_ notification: BackgroundTaskNotification) -> Bool {
        sessionId == nil || notification.sessionId == sessionId
    }

    func setWakeHandler(_ handler: (@Sendable () -> Void)?) {
        let shouldWake: Bool = state.withLockedValue { state in
            state.wakeHandler = handler
            return handler != nil && !state.pending.isEmpty
        }
        if shouldWake { handler?() }
    }

    func enqueue(_ notification: BackgroundTaskNotification) {
        let handler: (@Sendable () -> Void)? = state.withLockedValue { state in
            if isTerminal(notification), (state.watchCounts[notification.taskId] ?? 0) > 0 {
                state.deferredTerminal[notification.taskId] = notification
                return nil
            }
            state.pending.append(notification)
            return state.wakeHandler
        }
        handler?()
    }

    /// Begin an explicit-delivery transaction. Any terminal notice still in
    /// this mailbox is atomically retracted before the caller re-reads task
    /// state, closing completion-vs-poll races at the Agent boundary.
    func beginWatching(taskIds: [String]) -> Set<String> {
        let ids = Set(taskIds)
        return state.withLockedValue { state in
            for id in ids { state.watchCounts[id, default: 0] += 1 }

            var retained: [BackgroundTaskNotification] = []
            retained.reserveCapacity(state.pending.count)
            for notification in state.pending {
                if ids.contains(notification.taskId), isTerminal(notification) {
                    state.deferredTerminal[notification.taskId] = notification
                } else {
                    retained.append(notification)
                }
            }
            state.pending = retained
            return ids.intersection(state.deliveredTerminalTaskIds)
        }
    }

    /// Stop watching and return a lease for terminal results represented by the
    /// tool output. Running tasks immediately resume normal automatic delivery.
    func finishWatching(
        taskIds: [String],
        terminalTaskIds: Set<String>
    ) -> AgentToolRetentionLease? {
        let ids = Set(taskIds)
        var heldTerminalIds: Set<String> = []
        var handler: (@Sendable () -> Void)?

        state.withLockedValue { state in
            heldTerminalIds = terminalTaskIds.subtracting(state.deliveredTerminalTaskIds)
            for id in ids {
                let remaining = max(0, (state.watchCounts[id] ?? 0) - 1)
                if remaining == 0 {
                    state.watchCounts.removeValue(forKey: id)
                } else {
                    state.watchCounts[id] = remaining
                }

                // If the final manager snapshot missed a completion that raced
                // immediately after it, this task is not represented by the
                // tool result. Put its deferred notification back.
                if !heldTerminalIds.contains(id), remaining == 0,
                   let notification = state.deferredTerminal.removeValue(forKey: id) {
                    state.pending.append(notification)
                    handler = state.wakeHandler
                }
            }
        }
        handler?()

        guard !heldTerminalIds.isEmpty else { return nil }
        let leaseTaskIds = heldTerminalIds
        return AgentToolRetentionLease(
            onCommit: { [weak self] in self?.commit(taskIds: leaseTaskIds) },
            onRollback: { [weak self] in self?.rollback(taskIds: leaseTaskIds) }
        )
    }

    func drainMessages() -> [Message] {
        let notifications: [BackgroundTaskNotification] = state.withLockedValue { state in
            let drained = state.pending
            state.pending.removeAll()
            for notification in drained where isTerminal(notification) {
                state.deliveredTerminalTaskIds.insert(notification.taskId)
            }
            return drained
        }
        return notifications.map { notification in
            .user(UserMessage(
                content: [.text(TextContent(text: notification.messageText()))],
                source: .runtime
            ))
        }
    }

    func hasPendingMessages() -> Bool {
        state.withLockedValue { !$0.pending.isEmpty }
    }

    /// True while deleting the manager artifact could invalidate an automatic
    /// aside or explicit poll lease which has not settled yet.
    func isHolding(taskId: String) -> Bool {
        state.withLockedValue { state in
            state.pending.contains { $0.taskId == taskId }
                || state.deferredTerminal[taskId] != nil
                || (state.watchCounts[taskId] ?? 0) > 0
        }
    }

    func clearPendingMessages() {
        state.withLockedValue { $0.pending.removeAll() }
    }

    /// Detaching an Agent must not leave terminal notices permanently held by
    /// an abandoned poll. Restore everything to the mailbox; a later reattach
    /// of the same consumer can deliver it, while public listeners were never
    /// affected in the first place.
    func releaseAllWatches() {
        let handler: (@Sendable () -> Void)? = state.withLockedValue { state in
            state.watchCounts.removeAll()
            guard !state.deferredTerminal.isEmpty else { return nil }
            state.pending.append(contentsOf: state.deferredTerminal.values)
            state.deferredTerminal.removeAll()
            return state.wakeHandler
        }
        handler?()
    }

    private func commit(taskIds: Set<String>) {
        state.withLockedValue { state in
            // A terminal poll result supersedes every older notice for the
            // represented task, including a stall warning that may have been
            // queued just before completion.
            state.pending.removeAll { taskIds.contains($0.taskId) }
            for id in taskIds {
                state.deferredTerminal.removeValue(forKey: id)
                state.deliveredTerminalTaskIds.insert(id)
            }
        }
    }

    private func rollback(taskIds: Set<String>) {
        let handler: (@Sendable () -> Void)? = state.withLockedValue { state in
            var restored = false
            for id in taskIds where (state.watchCounts[id] ?? 0) == 0 {
                if let notification = state.deferredTerminal.removeValue(forKey: id) {
                    state.pending.append(notification)
                    restored = true
                }
            }
            return restored ? state.wakeHandler : nil
        }
        handler?()
    }

    /// Purge all mailbox bookkeeping for tasks removed from the manager.
    /// Cleanup is an explicit destructive boundary, so an outstanding lease
    /// for one of these ids must not resurrect its obsolete notification.
    func discard(taskIds: Set<String>) {
        state.withLockedValue { state in
            state.pending.removeAll { taskIds.contains($0.taskId) }
            for id in taskIds {
                state.deferredTerminal.removeValue(forKey: id)
                state.watchCounts.removeValue(forKey: id)
                state.deliveredTerminalTaskIds.remove(id)
            }
        }
    }

    private func isTerminal(_ notification: BackgroundTaskNotification) -> Bool {
        !notification.stalled && notification.status.isTerminal
    }
}
