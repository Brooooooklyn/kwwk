import Foundation
import KWWKAI
import NIOConcurrencyHelpers

/// Thread-safe pending-message queue shared between the Agent and its loop.
/// Matches pi-agent-core's `PendingMessageQueue`.
final class PendingMessageQueue: Sendable {
    private struct State {
        var messages: [Message] = []
        var mode: QueueMode
    }

    private let state: NIOLockedValueBox<State>

    init(mode: QueueMode) {
        self.state = NIOLockedValueBox(State(mode: mode))
    }

    var mode: QueueMode {
        get { state.withLockedValue { $0.mode } }
        set { state.withLockedValue { $0.mode = newValue } }
    }

    func enqueue(_ message: Message) {
        state.withLockedValue { $0.messages.append(message) }
    }

    /// Insert at the head (FIFO front). Used by the TUI's Alt+↑ dequeue-cycle:
    /// a prompt the user is cycling past is pushed back to the front so the
    /// next `popLast()` returns the prior item, rotating through the queue
    /// without dropping anything. Atomic so it can't interleave with `drain()`.
    func enqueueFront(_ message: Message) {
        state.withLockedValue { $0.messages.insert(message, at: 0) }
    }

    func hasItems() -> Bool {
        state.withLockedValue { !$0.messages.isEmpty }
    }

    func count() -> Int {
        state.withLockedValue { $0.messages.count }
    }

    /// Read-only snapshot of the queued messages in FIFO order. Used by UI
    /// layers that want to render a preview (e.g. the status bar's "↓ N
    /// queued" indicator). Returns an `Array` copy — the underlying queue
    /// can be drained independently without invalidating the snapshot.
    func snapshot() -> [Message] {
        state.withLockedValue { $0.messages }
    }

    /// Remove and return the most recently enqueued message (LIFO). Used by
    /// the TUI's "pop the last queued prompt back into the editor" affordance
    /// (Alt+↑) so the user can edit or drop a prompt they just queued.
    func popLast() -> Message? {
        state.withLockedValue { $0.messages.popLast() }
    }

    func drain() -> [Message] {
        state.withLockedValue { state in
            switch state.mode {
            case .all:
                let drained = state.messages
                state.messages.removeAll()
                return drained
            case .oneAtATime:
                guard let first = state.messages.first else { return [] }
                state.messages.removeFirst()
                return [first]
            }
        }
    }

    func clear() {
        state.withLockedValue { $0.messages.removeAll() }
    }
}
