import Foundation
import NIOConcurrencyHelpers

/// A shareable cancellation token, analogous to the browser's `AbortSignal`.
///
/// Pi-AI passes `AbortSignal` to streaming calls so that long-running requests
/// can be cancelled from the outside. Swift has `Task.isCancelled`, but it
/// only applies to the calling task — so we model an external handle that can
/// be awaited and queried by producers and consumers alike.
public struct CancellationRegistration: Sendable {
    private let cancelHandler: @Sendable () -> Void

    init(_ cancelHandler: @escaping @Sendable () -> Void) {
        self.cancelHandler = cancelHandler
    }

    public func cancel() {
        cancelHandler()
    }
}

public final class CancellationHandle: Sendable {
    private struct State {
        var isCancelled = false
        var reason: String?
        var listeners: [(id: UUID, handler: @Sendable (String?) -> Void)] = []
    }

    private let state = NIOLockedValueBox(State())

    public init() {}

    public var isCancelled: Bool {
        state.withLockedValue { $0.isCancelled }
    }

    public var reason: String? {
        state.withLockedValue { $0.reason }
    }

    /// Cancel the handle. Subsequent calls are no-ops.
    public func cancel(reason: String? = nil) {
        let callbacks: [@Sendable (String?) -> Void]? = state.withLockedValue { state in
            if state.isCancelled { return nil }
            state.isCancelled = true
            state.reason = reason
            let callbacks = state.listeners.map(\.handler)
            state.listeners.removeAll()
            return callbacks
        }
        guard let callbacks else { return }
        for cb in callbacks {
            cb(reason)
        }
    }

    /// Register a callback that fires exactly once when the handle is cancelled.
    /// If already cancelled, fires synchronously.
    @discardableResult
    public func onCancel(_ handler: @Sendable @escaping (String?) -> Void) -> CancellationRegistration {
        let id = UUID()
        // `.some(reason)` when already cancelled; the handler then fires
        // synchronously, outside the lock.
        let alreadyCancelled: String?? = state.withLockedValue { state in
            if state.isCancelled { return .some(state.reason) }
            state.listeners.append((id: id, handler: handler))
            return nil
        }
        if let r = alreadyCancelled {
            handler(r)
            return CancellationRegistration {}
        }
        return CancellationRegistration { [weak self] in
            self?.removeListener(id)
        }
    }

    private func removeListener(_ id: UUID) {
        state.withLockedValue { state in
            state.listeners.removeAll { $0.id == id }
        }
    }

    /// Throw CancellationError if already cancelled.
    public func throwIfCancelled() throws {
        if isCancelled { throw CancellationError() }
    }
}
