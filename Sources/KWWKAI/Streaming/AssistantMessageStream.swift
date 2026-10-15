import Foundation
import DequeModule
import NIOConcurrencyHelpers

/// An async sequence of `AssistantMessageEvent` values that also exposes the
/// final settled `AssistantMessage` via `result()`. The stream never throws
/// from iteration — errors are encoded as `.error(...)` events and reflected
/// in the final message's `stopReason`.
///
/// This is the **consumer** surface. It is single-consumer: exactly one task
/// should iterate it (and optionally await `result()`). Producers push events
/// through the paired `Continuation` obtained from `makeStream()`; providers
/// inside this module push directly. Iteration and `result()` are
/// cancellation-aware — cancelling the consuming task resumes them promptly
/// (iteration ends, `result()` returns an aborted message).
public final class AssistantMessageStream: AsyncSequence, Sendable {
    public typealias Element = AssistantMessageEvent

    let state = StreamState()

    init() {}

    /// Create a consumer stream paired with a producer `Continuation`. External
    /// providers use this to feed events without exposing `push`/`end` on the
    /// consumer object handed to callers.
    public static func makeStream() -> (stream: AssistantMessageStream, continuation: Continuation) {
        let stream = AssistantMessageStream()
        return (stream, Continuation(state: stream.state))
    }

    // MARK: - Producer API (internal — in-module providers push directly)

    /// Push an event into the stream. Safe to call from any task.
    func push(_ event: AssistantMessageEvent) {
        state.push(event)
    }

    /// Mark the stream as finished and record the final settled message.
    /// Further `push` calls after `end` are ignored.
    func end(_ message: AssistantMessage) {
        state.end(message)
    }

    // MARK: - Consumer API

    /// Await the final settled assistant message for this run.
    public func result() async -> AssistantMessage {
        await state.awaitResult()
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(state: state)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let state: StreamState
        public mutating func next() async -> AssistantMessageEvent? {
            await state.nextEvent()
        }
    }

    /// Producer handle for an `AssistantMessageStream`. Obtained from
    /// `makeStream()`; hands events and the final message to the paired
    /// consumer stream.
    public struct Continuation: Sendable {
        let state: StreamState

        /// Push an event into the stream. Safe to call from any task.
        public func push(_ event: AssistantMessageEvent) {
            state.push(event)
        }

        /// Mark the stream finished and record the final settled message.
        /// Further `push` calls are ignored.
        public func end(_ message: AssistantMessage) {
            state.end(message)
        }
    }
}

/// Thread-safe queue + awaiters for `AssistantMessageStream`.
public final class StreamState: Sendable {
    private typealias EventWaiter = (id: UUID, cont: CheckedContinuation<AssistantMessageEvent?, Never>)
    private typealias ResultWaiter = (id: UUID, cont: CheckedContinuation<AssistantMessage, Never>)

    private struct State {
        var buffer: Deque<AssistantMessageEvent> = []
        var eventWaiters: Deque<EventWaiter> = []
        var resultWaiters: [ResultWaiter] = []
        var ended = false
        var finalMessage: AssistantMessage?
        var latestPartial: AssistantMessage?

        // A thrown error must not erase prior output.
        func settleFailure(_ input: AssistantMessage) -> AssistantMessage {
            guard input.stopReason == .error || input.stopReason == .aborted else { return input }
            var message = input
            if message.content.isEmpty, let partial = latestPartial {
                message.content = partial.content
                message.usage = partial.usage
                message.responseId = message.responseId ?? partial.responseId
            }
            if message.stopReason == .error, message.failure == nil {
                message.failure = ProviderFailure(message: message.errorMessage ?? "Unknown provider error")
            }
            message.errorMessage = message.errorMessage ?? message.failure?.message
            return message
        }
    }
    private let state = NIOLockedValueBox(State())

    func push(_ event: AssistantMessageEvent) {
        let delivery = state.withLockedValue { state -> (waiter: EventWaiter, event: AssistantMessageEvent)? in
            if state.ended {
                return nil
            }
            var delivered = event
            switch delivered {
            case .start(let partial), .textStart(_, let partial), .textDelta(_, _, let partial),
                 .textEnd(_, _, let partial), .thinkingStart(_, let partial), .thinkingDelta(_, _, let partial),
                 .thinkingEnd(_, _, let partial), .toolCallStart(_, let partial), .toolCallDelta(_, _, let partial),
                 .toolCallEnd(_, _, let partial):
                state.latestPartial = partial
            case .error(let reason, let message):
                delivered = .error(reason: reason, error: state.settleFailure(message))
            case .done: break
            }
            if let waiter = state.eventWaiters.popFirst() {
                return (waiter, delivered)
            }
            state.buffer.append(delivered)
            return nil
        }
        if let (waiter, event) = delivery {
            waiter.cont.resume(returning: event)
        }
    }

    func end(_ message: AssistantMessage) {
        let settled = state.withLockedValue { state -> (
            message: AssistantMessage,
            eventWaiters: Deque<EventWaiter>,
            resultWaiters: [ResultWaiter]
        )? in
            if state.ended {
                return nil
            }
            state.ended = true
            let settledMessage = state.settleFailure(message)
            state.finalMessage = settledMessage
            let eventWaitersToNotify = state.eventWaiters
            state.eventWaiters.removeAll()
            let resultWaitersToNotify = state.resultWaiters
            state.resultWaiters.removeAll()
            return (settledMessage, eventWaitersToNotify, resultWaitersToNotify)
        }
        guard let settled else { return }
        for w in settled.eventWaiters { w.cont.resume(returning: nil) }
        for w in settled.resultWaiters { w.cont.resume(returning: settled.message) }
    }

    func nextEvent() async -> AssistantMessageEvent? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<AssistantMessageEvent?, Never>) in
                let (resume, event) = state.withLockedValue { state -> (Bool, AssistantMessageEvent?) in
                    if let buffered = state.buffer.popFirst() {
                        return (true, buffered)
                    }
                    if state.ended {
                        return (true, nil)
                    }
                    if Task.isCancelled {
                        return (true, nil)
                    }
                    state.eventWaiters.append((id: id, cont: cont))
                    return (false, nil)
                }
                if resume {
                    cont.resume(returning: event)
                }
            }
        } onCancel: {
            // End iteration promptly on consumer-task cancellation. Whichever of
            // this and a concurrent `push`/`end` removes the waiter first owns
            // the resume, so there is no double-resume.
            let waiter = state.withLockedValue { state -> EventWaiter? in
                guard let index = state.eventWaiters.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.eventWaiters.remove(at: index)
            }
            waiter?.cont.resume(returning: nil)
        }
    }

    func awaitResult() async -> AssistantMessage {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<AssistantMessage, Never>) in
                let (resume, message) = state.withLockedValue { state -> (Bool, AssistantMessage?) in
                    if let finalMessage = state.finalMessage {
                        return (true, finalMessage)
                    }
                    if Task.isCancelled {
                        return (true, nil)
                    }
                    state.resultWaiters.append((id: id, cont: cont))
                    return (false, nil)
                }
                if resume {
                    cont.resume(returning: message ?? Self.cancelledResult())
                }
            }
        } onCancel: {
            let waiter = state.withLockedValue { state -> ResultWaiter? in
                guard let index = state.resultWaiters.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.resultWaiters.remove(at: index)
            }
            waiter?.cont.resume(returning: Self.cancelledResult())
        }
    }

    /// Placeholder returned to a consumer that cancels its own `result()` await
    /// before the producer settled the stream.
    private static func cancelledResult() -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: "",
            provider: "",
            model: "",
            usage: Usage(),
            stopReason: .aborted,
            errorMessage: "Consumer cancelled before result settled",
            timestamp: Timestamp.now()
        )
    }
}
