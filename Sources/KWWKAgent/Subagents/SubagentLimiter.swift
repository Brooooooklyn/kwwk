import Foundation
import KWWKAI
import NIOConcurrencyHelpers

/// Process-local capacity gate shared by one subagent surface.
///
/// Foreground calls stay fail-fast: making one tool call wait behind another
/// call in the same parallel batch would turn the parent turn into an implicit
/// wait-all. Background calls are admitted against `maxTotal` immediately and
/// receive a cancellable FIFO reservation which starts as soon as compatible
/// capacity is released.
final class SubagentLimiter: Sendable {
    private struct QueuedRequest {
        let id: UUID
        let mutating: Bool
        let reservation: SubagentCapacityReservation
    }

    private struct State {
        let limits: SubagentLimits
        var active = 0
        var activeMutating = 0
        var total = 0
        var queued: [QueuedRequest] = []

        func validateTotal() throws {
            if let maxTotal = limits.maxTotal, total >= maxTotal {
                throw SubagentLimitError.total(limit: maxTotal)
            }
        }

        func validateAvailableCapacity(mutating: Bool) throws {
            if let maxConcurrent = limits.maxConcurrent, active >= maxConcurrent {
                throw SubagentLimitError.concurrent(limit: maxConcurrent)
            }
            if mutating,
               let maxMutating = limits.maxConcurrentMutating,
               activeMutating >= maxMutating {
                throw SubagentLimitError.mutatingConcurrent(limit: maxMutating)
            }
        }

        func hasAvailableCapacity(mutating: Bool) -> Bool {
            let underConcurrent = limits.maxConcurrent.map { active < $0 } ?? true
            let underMutating = !mutating
                || (limits.maxConcurrentMutating.map { activeMutating < $0 } ?? true)
            return underConcurrent && underMutating
        }

        mutating func claimCapacity(mutating: Bool) {
            active += 1
            if mutating { activeMutating += 1 }
        }
    }

    private let state: NIOLockedValueBox<State>

    init(limits: SubagentLimits) {
        self.state = NIOLockedValueBox(State(limits: limits))
    }

    /// Reserve capacity for a foreground child. This deliberately fails when
    /// no slot is available instead of suspending the parent tool call.
    func reserve(tools: CodingTools, countsTowardTotal: Bool = true) throws -> SubagentPermit {
        let mutating = tools.isMutating
        try state.withLockedValue { state in
            if countsTowardTotal { try state.validateTotal() }
            try state.validateAvailableCapacity(mutating: mutating)
            if countsTowardTotal { state.total += 1 }
            state.claimCapacity(mutating: mutating)
        }
        return SubagentPermit(limiter: self, mutating: mutating)
    }

    /// Admit a background child without waiting for a runner slot. The total
    /// launch budget is charged now, so an arbitrarily large queued fan-out can
    /// never bypass `maxTotal`.
    func enqueue(tools: CodingTools, countsTowardTotal: Bool = true) throws -> SubagentCapacityReservation {
        let mutating = tools.isMutating
        let id = UUID()
        let reservation = SubagentCapacityReservation(id: id, limiter: self)

        let immediatePermit = try state.withLockedValue { state -> SubagentPermit? in
            if countsTowardTotal {
                try state.validateTotal()
                state.total += 1
            }
            if state.hasAvailableCapacity(mutating: mutating) {
                state.claimCapacity(mutating: mutating)
                return SubagentPermit(limiter: self, mutating: mutating)
            } else {
                state.queued.append(QueuedRequest(
                    id: id,
                    mutating: mutating,
                    reservation: reservation
                ))
                return nil
            }
        }

        if let immediatePermit {
            reservation.resolve(.success(immediatePermit))
        }
        return reservation
    }

    /// Spawn-time capacity context: 1-based position of `id` in the queue
    /// (nil once it holds a runner slot), total queued launches, and the
    /// concurrency limit — enough for the model to estimate expected wait.
    func queueStatus(of id: UUID) -> (position: Int?, queuedCount: Int, maxConcurrent: Int?) {
        state.withLockedValue { state in
            let index = state.queued.firstIndex(where: { $0.id == id })
            return (index.map { $0 + 1 }, state.queued.count, state.limits.maxConcurrent)
        }
    }

    fileprivate func cancelQueued(id: UUID) {
        let cancelled = state.withLockedValue { state -> SubagentCapacityReservation? in
            guard let index = state.queued.firstIndex(where: { $0.id == id }) else { return nil }
            return state.queued.remove(at: index).reservation
        }
        cancelled?.resolve(.failure(SubagentExecutionCapacityError.cancelled))
    }

    fileprivate func release(mutating: Bool) {
        let grants = state.withLockedValue { state -> [(SubagentCapacityReservation, SubagentPermit)] in
            var grants: [(SubagentCapacityReservation, SubagentPermit)] = []
            state.active = max(0, state.active - 1)
            if mutating { state.activeMutating = max(0, state.activeMutating - 1) }

            // Preserve FIFO among requests that are currently eligible. A
            // mutating request waiting on the serial mutation slot must not
            // unnecessarily block an independent read-only request.
            while let index = state.queued.firstIndex(where: {
                state.hasAvailableCapacity(mutating: $0.mutating)
            }) {
                let request = state.queued.remove(at: index)
                state.claimCapacity(mutating: request.mutating)
                grants.append((
                    request.reservation,
                    SubagentPermit(limiter: self, mutating: request.mutating)
                ))
            }
            return grants
        }
        for (reservation, permit) in grants {
            reservation.resolve(.success(permit))
        }
    }
}

/// One admitted background launch. Waiting is cancellable independently of
/// the foreground tool task; cancelling while queued removes it from the gate.
final class SubagentCapacityReservation: @unchecked Sendable {
    fileprivate typealias Outcome = Result<SubagentPermit, any Error>

    private struct State {
        var outcome: Outcome?
        var waiter: CheckedContinuation<Outcome, Never>?
        var abandoned = false
        var permitClaimed = false
    }

    private let state = NIOLockedValueBox(State())
    private let id: UUID
    private weak var limiter: SubagentLimiter?

    fileprivate init(id: UUID, limiter: SubagentLimiter) {
        self.id = id
        self.limiter = limiter
    }

    var isWaitingForCapacity: Bool {
        state.withLockedValue { $0.outcome == nil }
    }

    /// Capacity context for spawn-result rendering. Position is nil once the
    /// launch holds a runner slot.
    var queueStatus: (position: Int?, queuedCount: Int, maxConcurrent: Int?)? {
        limiter?.queueStatus(of: id)
    }

    func wait(cancellation: CancellationHandle) async throws -> SubagentPermit {
        let registration = cancellation.onCancel { [weak self] _ in
            self?.abandon()
        }
        defer { registration.cancel() }
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Outcome, Never>) in
            let ready = state.withLockedValue { state -> Outcome? in
                if let outcome = state.outcome { return outcome }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        let permit = try result.get()
        let accepted = state.withLockedValue { state -> Bool in
            guard !state.abandoned, !state.permitClaimed else { return false }
            state.permitClaimed = true
            return true
        }
        guard accepted else {
            permit.release()
            throw SubagentExecutionCapacityError.cancelled
        }
        do {
            try cancellation.throwIfCancelled()
            return permit
        } catch {
            permit.release()
            throw error
        }
    }

    /// Cancel a queued launch that will never call `wait`. This is also safe
    /// after an immediate grant: an unclaimed permit is released exactly once.
    /// A permit already claimed by a running child remains owned by that child.
    func abandon() {
        let unusedPermit = state.withLockedValue { state -> SubagentPermit? in
            guard !state.abandoned else { return nil }
            state.abandoned = true
            guard !state.permitClaimed,
                  case .success(let permit)? = state.outcome else { return nil }
            state.outcome = .failure(SubagentExecutionCapacityError.cancelled)
            return permit
        }
        unusedPermit?.release()
        limiter?.cancelQueued(id: id)
    }

    fileprivate func resolve(_ result: Outcome) {
        let resolution = state.withLockedValue {
            state -> (CheckedContinuation<Outcome, Never>?, Outcome, SubagentPermit?) in
            guard state.outcome == nil else {
                let unused: SubagentPermit?
                if case .success(let permit) = result { unused = permit }
                else { unused = nil }
                return (nil, state.outcome!, unused)
            }
            let settled: Outcome
            let unused: SubagentPermit?
            if state.abandoned {
                settled = .failure(SubagentExecutionCapacityError.cancelled)
                if case .success(let permit) = result { unused = permit }
                else { unused = nil }
            } else {
                settled = result
                unused = nil
            }
            state.outcome = settled
            let pending = state.waiter
            state.waiter = nil
            return (pending, settled, unused)
        }
        resolution.2?.release()
        resolution.0?.resume(returning: resolution.1)
    }
}

final class SubagentPermit: @unchecked Sendable {
    private let released = NIOLockedValueBox(false)
    private weak var limiter: SubagentLimiter?
    private let mutating: Bool

    fileprivate init(limiter: SubagentLimiter, mutating: Bool) {
        self.limiter = limiter
        self.mutating = mutating
    }

    func release() {
        let target = released.withLockedValue { released -> SubagentLimiter? in
            guard !released else { return nil }
            released = true
            return limiter
        }
        target?.release(mutating: mutating)
    }

    deinit {
        release()
    }
}

private enum SubagentExecutionCapacityError: Error, LocalizedError, Sendable {
    case cancelled

    var errorDescription: String? {
        "agent: queued subagent was cancelled before runner capacity became available"
    }
}

enum SubagentLimitError: Error, LocalizedError, Sendable {
    case concurrent(limit: Int)
    case mutatingConcurrent(limit: Int)
    case total(limit: Int)

    var errorDescription: String? {
        switch self {
        case .concurrent(let limit):
            return "agent: concurrent subagent limit reached (max \(limit)); wait for a running child to finish"
        case .mutatingConcurrent(let limit):
            return "agent: concurrent mutating subagent limit reached (max \(limit)); wait for a writing child to finish"
        case .total(let limit):
            return "agent: subagent launch budget exhausted for this parent session (max \(limit))"
        }
    }

    var failureKind: String {
        switch self {
        case .concurrent: return "concurrency_limit"
        case .mutatingConcurrent: return "mutating_concurrency_limit"
        case .total: return "total_limit"
        }
    }
}
