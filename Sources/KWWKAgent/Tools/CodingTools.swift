import Foundation
import KWWKAI

public enum CodingToolError: Error, Equatable, LocalizedError {
    case fileNotFound(String)
    case invalidArgument(String)
    case runtime(String)
    case textNotFound(String)
    case multipleMatches(count: Int)
    case offsetOutOfRange(offset: Int, totalLines: Int)
    case aborted
    case commandFailed(stderr: String, exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "file not found: \(path)"
        case .invalidArgument(let message):
            return message
        case .runtime(let message):
            return message
        case .textNotFound(let message):
            return message
        case .multipleMatches(let count):
            return "found \(count) occurrences of oldText; set replaceAll: true on that edit to replace every occurrence, or include more surrounding lines in oldText so the match is unique"
        case .offsetOutOfRange(let offset, let total):
            return "offset \(offset) is beyond end of file (\(total) lines total)"
        case .aborted:
            return "aborted by user"
        case .commandFailed(let stderr, let exitCode):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "command exited with code \(exitCode)"
            }
            return "\(trimmed) (exit \(exitCode))"
        }
    }
}

// MARK: - Pluggable operations

public protocol ReadOperations: Sendable {
    func readFile(_ absolutePath: String) async throws -> Data
    func access(_ absolutePath: String) async throws
    func detectImageMimeType(_ absolutePath: String) async throws -> String?
}

public protocol WriteOperations: Sendable {
    func writeFile(_ absolutePath: String, content: Data) async throws
    func createParentDirectories(_ absolutePath: String) async throws
}

public protocol EditOperations: Sendable {
    func readFile(_ absolutePath: String) async throws -> Data
    func writeFile(_ absolutePath: String, content: Data) async throws
    func access(_ absolutePath: String) async throws
}

public protocol BashOperations: Sendable {
    func execute(command: String, timeout: Int?, cancellation: CancellationHandle?) async throws -> BashExecutionResult
}

public protocol GrepOperations: Sendable {
    func grep(params: GrepParams) async throws -> [GrepMatch]
    /// The same search, saying why it stopped early. The default wraps
    /// `grep(params:)`, so existing conformers keep working.
    func search(params: GrepParams) async throws -> GrepSearchResult
}

extension GrepOperations {
    public func search(params: GrepParams) async throws -> GrepSearchResult {
        let matches = try await grep(params: params)
        // Older conformers mark a byte-budget stop with a trailing sentinel.
        if let last = matches.last, last.file.isEmpty,
           last.text.hasPrefix("[truncated: total output exceeded") {
            return GrepSearchResult(matches: Array(matches.dropLast()), stop: .bytes)
        }
        let limit = params.limit ?? Truncate.grepDefaultLimit
        return GrepSearchResult(matches: matches, stop: matches.count >= limit ? .limit : nil)
    }
}

/// A grep search's matches and, when it ended early, why.
public struct GrepSearchResult: Sendable, Equatable {
    public enum Stop: Sendable, Equatable {
        /// `limit` matches were found.
        case limit
        /// The output byte budget was used up.
        case bytes
        /// The time budget ran out. The matches are those of the files
        /// searched so far; `filesFound` counts the files the walk had found,
        /// and `walkComplete` says whether it had finished.
        case timeBudget(seconds: Double, filesSearched: Int, filesFound: Int, walkComplete: Bool)
    }

    public var matches: [GrepMatch]
    public var stop: Stop?

    public init(matches: [GrepMatch], stop: Stop? = nil) {
        self.matches = matches
        self.stop = stop
    }
}

public protocol FindOperations: Sendable {
    func find(pattern: String, cwd: String, limit: Int?) async throws -> [String]
}

public protocol LSOperations: Sendable {
    func list(path: String) async throws -> [LSEntry]
}

// MARK: - Tool result structures

public struct BashExecutionResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var durationMs: Int
    public var timedOut: Bool

    public init(stdout: String, stderr: String, exitCode: Int32, durationMs: Int = 0, timedOut: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.timedOut = timedOut
    }
}

public struct GrepParams: Sendable {
    public var pattern: String
    public var path: String
    public var glob: String?
    public var ignoreCase: Bool
    public var literal: Bool
    public var context: Int
    public var limit: Int?
    /// Search files that `.gitignore`, `.ignore` and the repository's
    /// `info/exclude` leave out, and dependency trees like `node_modules`.
    /// Version-control directories stay skipped.
    public var includeIgnored: Bool
    /// Seconds the search may take before it returns what it found so far.
    /// Nil means `Truncate.grepDefaultTimeBudgetSeconds`.
    public var timeBudget: Double?
    public var cancellation: CancellationHandle?

    public init(
        pattern: String,
        path: String,
        glob: String? = nil,
        ignoreCase: Bool = false,
        literal: Bool = false,
        context: Int = 0,
        limit: Int? = nil,
        includeIgnored: Bool = false,
        timeBudget: Double? = nil,
        cancellation: CancellationHandle? = nil
    ) {
        self.pattern = pattern
        self.path = path
        self.glob = glob
        self.ignoreCase = ignoreCase
        self.literal = literal
        self.context = context
        self.limit = limit
        self.includeIgnored = includeIgnored
        self.timeBudget = timeBudget
        self.cancellation = cancellation
    }
}

public struct GrepContextLine: Sendable, Equatable {
    public var line: Int
    public var text: String
    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

public struct GrepMatch: Sendable, Equatable {
    public var file: String
    public var line: Int
    public var text: String
    /// Context lines immediately before/after the match (empty when the
    /// `context` parameter is 0). Each carries its own 1-based line number.
    public var before: [GrepContextLine]
    public var after: [GrepContextLine]
    public init(
        file: String,
        line: Int,
        text: String,
        before: [GrepContextLine] = [],
        after: [GrepContextLine] = []
    ) {
        self.file = file
        self.line = line
        self.text = text
        self.before = before
        self.after = after
    }
}

public struct LSEntry: Sendable, Equatable {
    public enum Kind: Sendable { case file, directory, symlink }
    public var name: String
    public var kind: Kind
    public var size: Int64
    public init(name: String, kind: Kind, size: Int64) {
        self.name = name
        self.kind = kind
        self.size = size
    }
}
