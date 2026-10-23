import Foundation
import KWWKAI

public struct GrepToolOptions: Sendable {
    public var operations: GrepOperations
    public init(
        operations: GrepOperations = LocalGrepOperations()
    ) {
        self.operations = operations
    }
}

public struct LocalGrepOperations: GrepOperations {
    /// Files read at once. Reads are latency-bound on network filesystems,
    /// so this is well above the core count.
    public var concurrency: Int

    public init(concurrency: Int = 16) {
        self.concurrency = max(1, concurrency)
    }

    public func grep(params: GrepParams) async throws -> [GrepMatch] {
        let result = try await search(params: params)
        if result.stop == .bytes {
            // Keep the sentinel older callers look for.
            return result.matches + [GrepMatch(
                file: "",
                line: 0,
                text: "[truncated: total output exceeded \(Truncate.formatSize(Truncate.grepMaxTotalBytes))]"
            )]
        }
        return result.matches
    }

    public func search(params: GrepParams) async throws -> GrepSearchResult {
        try params.cancellation?.throwIfCancelled()
        let patternString = params.literal
            ? NSRegularExpression.escapedPattern(for: params.pattern)
            : params.pattern
        var options: NSRegularExpression.Options = []
        if params.ignoreCase { options.insert(.caseInsensitive) }
        let pattern: NSRegularExpression
        do {
            pattern = try NSRegularExpression(pattern: patternString, options: options)
        } catch {
            throw CodingToolError.invalidArgument("grep: invalid pattern — \(error)")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: params.path, isDirectory: &isDirectory) else {
            throw CodingToolError.fileNotFound(params.path)
        }

        let limit = max(1, params.limit ?? Truncate.grepDefaultLimit)
        let maxLineChars = Truncate.grepMaxLineLength
        let maxTotalBytes = Truncate.grepMaxTotalBytes
        let context = max(0, params.context)
        let budget = Self.timeBudget(params.timeBudget)

        let matcher = GrepFileMatcher(
            pattern: pattern,
            patternString: patternString,
            options: options,
            context: context,
            maxLineChars: maxLineChars
        )
        let scan = GrepScan(GrepScan.Configuration(
            root: URL(fileURLWithPath: params.path),
            rootIsDirectory: isDirectory.boolValue,
            glob: params.glob,
            includeIgnored: params.includeIgnored,
            limit: limit,
            maxTotalBytes: maxTotalBytes,
            workers: concurrency,
            timeBudget: budget,
            match: { path, cap, shouldStop in
                matcher.matches(inFileAt: path, cap: cap, shouldStop: shouldStop)
            },
            bytes: { Self.blockBytes($0) }
        ))
        let outcome = await scan.run(cancellation: params.cancellation)
        if outcome.stop == .cancelled {
            try params.cancellation?.throwIfCancelled()
            throw CancellationError()
        }

        // Apply the match limit and byte budget in walk order.
        var matches: [GrepMatch] = []
        var totalBytes = 0
        var stop: GrepSearchResult.Stop?
        for match in outcome.matches {
            let entryBytes = Self.blockBytes(match)
            if totalBytes + entryBytes > maxTotalBytes && !matches.isEmpty {
                stop = .bytes
                break
            }
            if matches.count >= limit {
                stop = .limit
                break
            }
            totalBytes += entryBytes
            matches.append(match)
        }
        if stop == nil, matches.count >= limit, outcome.stop == .limit {
            stop = .limit
        }
        if outcome.stop == .timeBudget {
            // Partial either way: say so even if a cap was also reached.
            stop = .timeBudget(
                seconds: budget,
                filesSearched: outcome.filesSearched,
                filesFound: outcome.filesFound,
                walkComplete: outcome.walkComplete
            )
        }
        return GrepSearchResult(matches: matches, stop: stop)
    }

    static func timeBudget(_ requested: Double?) -> Double {
        guard let requested, requested.isFinite, requested > 0 else {
            return Truncate.grepDefaultTimeBudgetSeconds
        }
        return min(requested, Truncate.grepMaxTimeBudgetSeconds)
    }

    static func blockBytes(_ m: GrepMatch) -> Int {
        var total = "\(m.file):\(m.line):\(m.text)\n".utf8.count
        for c in m.before { total += "\(m.file)-\(c.line)-\(c.text)\n".utf8.count }
        for c in m.after { total += "\(m.file)-\(c.line)-\(c.text)\n".utf8.count }
        return total
    }
}

public func createGrepTool(
    cwd: String,
    options: GrepToolOptions = .init(),
    fileAccessPolicy: FileAccessPolicy = .unrestricted
) -> AgentTool {
    let parameters: JSONValue = [
        "type": "object",
        "properties": [
            "pattern": ["type": "string"],
            "path": ["type": "string"],
            "glob": ["type": "string"],
            "ignoreCase": ["type": "boolean"],
            "literal": ["type": "boolean"],
            "context": ["type": "number"],
            "limit": ["type": "number"],
            "includeIgnored": ["type": "boolean"],
            "timeoutSeconds": ["type": "number"],
        ],
        "required": ["pattern"],
    ]
    let ops = options.operations
    let defaultLimit = Truncate.grepDefaultLimit
    let maxLineChars = Truncate.grepMaxLineLength
    let maxTotalBytes = Truncate.grepMaxTotalBytes
    let defaultBudget = Int(Truncate.grepDefaultTimeBudgetSeconds)
    let maxBudget = Int(Truncate.grepMaxTimeBudgetSeconds)
    var tool = AgentTool(
        name: "grep",
        label: "grep",
        description: """
        Search file contents for a regex pattern. Results are capped to avoid flooding the context window:
          - Default \(defaultLimit) matches (override with `limit`)
          - Single lines truncated to \(maxLineChars) chars
          - Total output capped at ~\(Truncate.formatSize(maxTotalBytes))
        Files ignored by .gitignore, .ignore or the repository's info/exclude, and dependency folders like node_modules, are skipped; set `includeIgnored` to search them too.
        The search stops after `timeoutSeconds` (default \(defaultBudget), at most \(maxBudget)) and returns the matches found so far, saying how many files it searched.
        Use a tighter `limit`, `path` or `glob`, or a more specific pattern when searching large codebases.
        """,
        parameters: parameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let obj) = args,
                  case .string(let pattern) = obj["pattern"] ?? .null else {
                throw CodingToolError.invalidArgument("grep: `pattern` is required")
            }
            let rawPath: String
            if case .string(let p) = obj["path"] ?? .null {
                rawPath = p.isEmpty ? "." : p
            } else {
                rawPath = "."
            }
            // Recursive local operations receive a canonical, authorized root.
            // The policy is a path boundary, not an OS-level TOCTOU defense.
            let path = try PathUtils.resolveForAccess(
                rawPath,
                cwd: cwd,
                policy: fileAccessPolicy,
                intent: .read
            )

            let glob: String? = {
                if case .string(let g) = obj["glob"] ?? .null {
                    let trimmed = g.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return nil
            }()
            let ignoreCase: Bool = {
                if case .bool(let v) = obj["ignoreCase"] ?? .null { return v }
                return false
            }()
            let literal: Bool = {
                if case .bool(let v) = obj["literal"] ?? .null { return v }
                return false
            }()
            let context: Int = {
                if case .int(let v) = obj["context"] ?? .null { return max(0, v) }
                if case .double(let v) = obj["context"] ?? .null, let n = clampedToolInt(v) { return max(0, n) }
                return 0
            }()
            let limit: Int? = {
                if case .int(let v) = obj["limit"] ?? .null { return v }
                if case .double(let v) = obj["limit"] ?? .null { return clampedToolInt(v) }
                return nil
            }()
            let includeIgnored: Bool = {
                if case .bool(let v) = obj["includeIgnored"] ?? .null { return v }
                return false
            }()
            let timeBudget: Double? = {
                if case .int(let v) = obj["timeoutSeconds"] ?? .null { return Double(v) }
                if case .double(let v) = obj["timeoutSeconds"] ?? .null { return v }
                return nil
            }()

            let result = try await ops.search(params: GrepParams(
                pattern: pattern,
                path: path,
                glob: glob,
                ignoreCase: ignoreCase,
                literal: literal,
                context: context,
                limit: limit,
                includeIgnored: includeIgnored,
                timeBudget: timeBudget,
                cancellation: cancellation
            ))
            let effectiveMatches = result.matches
            let byteTruncated = result.stop == .bytes
            var timeNotice: String?
            var timeDetails: [String: JSONValue] = [:]
            if case .timeBudget(let seconds, let searched, let found, let walkComplete)? = result.stop {
                let total = walkComplete ? "\(found)" : "\(found)+"
                timeNotice = "[stopped at the \(formatSeconds(seconds)) time budget after searching \(searched) of \(total) files; matches are partial. Narrow `path` or `glob`, or raise `timeoutSeconds`.]"
                timeDetails = [
                    "filesSearched": .int(searched),
                    "filesFound": .int(found),
                    "walkComplete": .bool(walkComplete),
                ]
            }

            if effectiveMatches.isEmpty {
                var details: [String: JSONValue] = ["matches": .array([])]
                var text = "No matches found for \(pattern)"
                if let timeNotice {
                    text += "\n" + timeNotice
                    details["truncated"] = .bool(true)
                    details["truncatedBy"] = .string("time")
                    details.merge(timeDetails) { $1 }
                }
                return AgentToolResult(
                    content: [.text(TextContent(text: text))],
                    details: .object(details)
                )
            }

            var lines: [String] = []
            for m in effectiveMatches {
                for c in m.before { lines.append("\(m.file)-\(c.line)-\(c.text)") }
                lines.append("\(m.file):\(m.line):\(m.text)")
                for c in m.after { lines.append("\(m.file)-\(c.line)-\(c.text)") }
            }
            if byteTruncated {
                lines.append("[truncated: total output exceeded \(Truncate.formatSize(maxTotalBytes))]")
            }
            if let timeNotice {
                lines.append(timeNotice)
            }
            let body = lines.joined(separator: "\n")

            let encoded: [JSONValue] = effectiveMatches.map { m in
                var obj: [String: JSONValue] = [
                    "file": .string(m.file),
                    "line": .int(m.line),
                    "text": .string(m.text),
                ]
                if !m.before.isEmpty {
                    obj["before"] = .array(m.before.map { .object(["line": .int($0.line), "text": .string($0.text)]) })
                }
                if !m.after.isEmpty {
                    obj["after"] = .array(m.after.map { .object(["line": .int($0.line), "text": .string($0.text)]) })
                }
                return .object(obj)
            }

            let limitTruncated = result.stop == .limit || effectiveMatches.count >= (limit ?? defaultLimit)
            var details: [String: JSONValue] = [
                "matches": .array(encoded),
                "totalMatches": .int(effectiveMatches.count),
                "truncated": .bool(byteTruncated || limitTruncated || timeNotice != nil),
            ]
            if timeNotice != nil {
                details["truncatedBy"] = .string("time")
                details.merge(timeDetails) { $1 }
            } else if byteTruncated {
                details["truncatedBy"] = .string("bytes")
            } else if limitTruncated {
                details["truncatedBy"] = .string("limit")
            }

            return AgentToolResult(
                content: [.text(TextContent(text: body))],
                details: .object(details)
            )
        }
    )
    tool.fileAccessPolicy = fileAccessPolicy
    tool.fileAccessCwd = cwd
    tool.codingToolCapabilities = .grep
    return tool
}

private func formatSeconds(_ seconds: Double) -> String {
    seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
}
