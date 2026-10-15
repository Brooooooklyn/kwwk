import Foundation
import KWWKAI
import NIOConcurrencyHelpers

/// Waiting on an unstructured task with a timeout and cancellation, without
/// waiting for the task itself to finish when either fires.
enum MCPWait {
    /// A timeout in seconds as a `Task.sleep` duration. Capped at 1e9 s
    /// (about 31 years) so a huge configured value means "no timeout": older
    /// runtimes wrap a sleep past `Int64.max` ns into one that fires at once.
    /// Negative and NaN become 0.
    static func nanoseconds(_ seconds: Double) -> UInt64 {
        UInt64(min(max(0, seconds), 1e9) * 1_000_000_000)
    }

    static func value<T: Sendable>(
        of task: Task<T, Error>,
        timeoutSeconds: Double,
        cancellation: CancellationHandle?,
        what: String
    ) async throws -> T {
        let box = OneShot<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                box.set(continuation)
                let waiter = Task {
                    do { box.resume(.success(try await task.value)) } catch { box.resume(.failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: MCPWait.nanoseconds(timeoutSeconds))
                    if !Task.isCancelled {
                        box.resume(.failure(MCPError.timeout(method: what, seconds: timeoutSeconds)))
                    }
                }
                let registration = cancellation?.onCancel { _ in box.resume(.failure(CancellationError())) }
                box.onResume {
                    waiter.cancel()
                    timer.cancel()
                    registration?.cancel()
                }
            }
        } onCancel: {
            box.resume(.failure(CancellationError()))
        }
    }

    final class OneShot<T: Sendable>: Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<T, Error>?
            var early: Result<T, Error>?
            var done = false
            var cleanup: (@Sendable () -> Void)?
        }

        private let state = NIOLockedValueBox(State())

        func set(_ continuation: CheckedContinuation<T, Error>) {
            let pending: Result<T, Error>? = state.withLockedValue { state in
                if let early = state.early { return early }
                state.continuation = continuation
                return nil
            }
            if let pending { continuation.resume(with: pending) }
        }

        func onResume(_ action: @escaping @Sendable () -> Void) {
            let runNow: Bool = state.withLockedValue { state in
                if state.done { return true }
                state.cleanup = action
                return false
            }
            if runNow { action() }
        }

        func resume(_ result: Result<T, Error>) {
            let (continuation, cleanup): (CheckedContinuation<T, Error>?, (@Sendable () -> Void)?) =
                state.withLockedValue { state in
                    if state.done { return (nil, nil) }
                    state.done = true
                    let pair = (state.continuation, state.cleanup)
                    if state.continuation == nil { state.early = result }
                    state.continuation = nil
                    state.cleanup = nil
                    return pair
                }
            continuation?.resume(with: result)
            cleanup?()
        }
    }
}
