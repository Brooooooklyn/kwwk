import Foundation

public enum AgentError: Error, Equatable {
    case noMessagesToContinue
    case cannotContinueFromRole(String)
    case alreadyRunning
    case maxRetriesExceeded
    case aborted
}

enum AgentContextPreflightError: Error, LocalizedError, Sendable {
    case irreducible(tokens: Int, inputBudget: Int)
    case compactionFailed(AgentContextCompactionOutcome)

    var errorDescription: String? {
        switch self {
        case .irreducible(let tokens, let inputBudget):
            return "context requires approximately \(tokens) input tokens, exceeding the usable \(inputBudget)-token input budget even after compaction"
        case .compactionFailed(let outcome):
            if case .failed(let reason) = outcome {
                return "context is too large and compaction failed: \(reason)"
            }
            return "context is too large and could not be compacted"
        }
    }
}
