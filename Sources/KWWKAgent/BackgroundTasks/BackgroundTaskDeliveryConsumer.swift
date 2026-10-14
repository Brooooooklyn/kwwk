import Foundation
import KWWKAI

/// One Agent's model-facing background-result mailbox.
///
/// `BackgroundTaskManager` still broadcasts every notification to its public
/// listeners. This mailbox only coordinates the choice between two delivery
/// paths for one Agent: automatic runtime aside, or an explicitly retained
/// `task_poll`/`task_cancel` result. A tool call temporarily watches task ids;
/// terminal notices are held until its result is committed, then restored if
/// that result is rewound (notably Cursor inline-exec retry/abort).
public final class BackgroundTaskDeliveryConsumer: @unchecked Sendable {
    let id = UUID()
    public let sessionId: String?

    private let lock = NSLock()
    private var pending: [BackgroundTaskNotification] = []
    private var deferredTerminal: [String: BackgroundTaskNotification] = [:]
    private var watchCounts: [String: Int] = [:]
    private var deliveredTerminalTaskIds: Set<String> = []
    private var wakeHandler: (@Sendable () -> Void)?

    public init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }

    func accepts(_ notification: BackgroundTaskNotification) -> Bool {
        sessionId == nil || notification.sessionId == sessionId
    }

    func setWakeHandler(_ handler: (@Sendable () -> Void)?) {
        let shouldWake = lock.withLock { () -> Bool in
            wakeHandler = handler
            return handler != nil && !pending.isEmpty
        }
        if shouldWake { handler?() }
    }

    func enqueue(_ notification: BackgroundTaskNotification) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            if isTerminal(notification), (watchCounts[notification.taskId] ?? 0) > 0 {
                deferredTerminal[notification.taskId] = notification
                return nil
            }
            pending.append(notification)
            return wakeHandler
        }
        handler?()
    }

    /// Begin an explicit-delivery transaction. Any terminal notice still in
    /// this mailbox is atomically retracted before the caller re-reads task
    /// state, closing completion-vs-poll races at the Agent boundary.
    func beginWatching(taskIds: [String]) -> Set<String> {
        let ids = Set(taskIds)
        return lock.withLock {
            for id in ids { watchCounts[id, default: 0] += 1 }

            var retained: [BackgroundTaskNotification] = []
            retained.reserveCapacity(pending.count)
            for notification in pending {
                if ids.contains(notification.taskId), isTerminal(notification) {
                    deferredTerminal[notification.taskId] = notification
                } else {
                    retained.append(notification)
                }
            }
            pending = retained
            return ids.intersection(deliveredTerminalTaskIds)
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

        lock.withLock {
            heldTerminalIds = terminalTaskIds.subtracting(deliveredTerminalTaskIds)
            for id in ids {
                let remaining = max(0, (watchCounts[id] ?? 0) - 1)
                if remaining == 0 {
                    watchCounts.removeValue(forKey: id)
                } else {
                    watchCounts[id] = remaining
                }

                // If the final manager snapshot missed a completion that raced
                // immediately after it, this task is not represented by the
                // tool result. Put its deferred notification back.
                if !heldTerminalIds.contains(id), remaining == 0,
                   let notification = deferredTerminal.removeValue(forKey: id) {
                    pending.append(notification)
                    handler = wakeHandler
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
        let notifications = lock.withLock { () -> [BackgroundTaskNotification] in
            let drained = pending
            pending.removeAll()
            for notification in drained where isTerminal(notification) {
                deliveredTerminalTaskIds.insert(notification.taskId)
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
        lock.withLock { !pending.isEmpty }
    }

    /// True while deleting the manager artifact could invalidate an automatic
    /// aside or explicit poll lease which has not settled yet.
    func isHolding(taskId: String) -> Bool {
        lock.withLock {
            pending.contains { $0.taskId == taskId }
                || deferredTerminal[taskId] != nil
                || (watchCounts[taskId] ?? 0) > 0
        }
    }

    func clearPendingMessages() {
        lock.withLock { pending.removeAll() }
    }

    /// Detaching an Agent must not leave terminal notices permanently held by
    /// an abandoned poll. Restore everything to the mailbox; a later reattach
    /// of the same consumer can deliver it, while public listeners were never
    /// affected in the first place.
    func releaseAllWatches() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            watchCounts.removeAll()
            guard !deferredTerminal.isEmpty else { return nil }
            pending.append(contentsOf: deferredTerminal.values)
            deferredTerminal.removeAll()
            return wakeHandler
        }
        handler?()
    }

    private func commit(taskIds: Set<String>) {
        lock.withLock {
            // A terminal poll result supersedes every older notice for the
            // represented task, including a stall warning that may have been
            // queued just before completion.
            pending.removeAll { taskIds.contains($0.taskId) }
            for id in taskIds {
                deferredTerminal.removeValue(forKey: id)
                deliveredTerminalTaskIds.insert(id)
            }
        }
    }

    private func rollback(taskIds: Set<String>) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            var restored = false
            for id in taskIds where (watchCounts[id] ?? 0) == 0 {
                if let notification = deferredTerminal.removeValue(forKey: id) {
                    pending.append(notification)
                    restored = true
                }
            }
            return restored ? wakeHandler : nil
        }
        handler?()
    }

    /// Purge all mailbox bookkeeping for tasks removed from the manager.
    /// Cleanup is an explicit destructive boundary, so an outstanding lease
    /// for one of these ids must not resurrect its obsolete notification.
    func discard(taskIds: Set<String>) {
        lock.withLock {
            pending.removeAll { taskIds.contains($0.taskId) }
            for id in taskIds {
                deferredTerminal.removeValue(forKey: id)
                watchCounts.removeValue(forKey: id)
                deliveredTerminalTaskIds.remove(id)
            }
        }
    }

    private func isTerminal(_ notification: BackgroundTaskNotification) -> Bool {
        !notification.stalled && notification.status.isTerminal
    }
}
