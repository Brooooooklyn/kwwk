import Foundation

public enum BackgroundTaskError: Error, Equatable, LocalizedError {
    case notFound(String)
    case alreadyTerminal(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "background task \(id) not found"
        case .alreadyTerminal(let id): return "background task \(id) is already in a terminal state"
        }
    }
}
