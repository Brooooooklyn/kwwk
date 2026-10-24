import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

// Ignore rules, time budget and parallel scanning of the grep tool. Shared
// helpers (`makeTempDir`, `write`, `textOutput`) live in ReadToolTests.

private func file(_ relative: String, _ contents: String = "needle", in root: URL) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try write(contents, to: url)
}

private func grep(_ root: URL, _ extra: [String: JSONValue] = [:]) async throws -> AgentToolResult {
    var args: [String: JSONValue] = ["pattern": .string("needle"), "path": .string(root.path)]
    args.merge(extra) { $1 }
    return try await createGrepTool(cwd: root.path).execute("call-grep", .object(args), nil, nil)
}

private func matchedFiles(_ result: AgentToolResult, under root: URL) -> Set<String> {
    let base = Glob.canonicalDirectoryPath(root.path) + "/"
    var out: Set<String> = []
    for line in textOutput(result).split(separator: "\n") {
        guard line.hasPrefix(base), let colon = line.dropFirst(base.count).firstIndex(of: ":") else { continue }
        out.insert(String(line[line.index(line.startIndex, offsetBy: base.count)..<colon]))
    }
    return out
}

@Suite("Grep ignore rules")
struct GrepIgnoreTests {
    @Test("skips .gitignore'd files by default and searches them with includeIgnored")
    func gitignore() async throws {
        let root = makeTempDir("kw-grep")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try file(".git/config", in: root)
        try file(".gitignore", "build/\n*.log\n!keep.log\n", in: root)
        try file("src/a.swift", in: root)
        try file("build/out.swift", in: root)
        try file("debug.log", in: root)
        try file("keep.log", in: root)
        try file("node_modules/pkg/index.js", in: root)
        // A slashless rule in a nested file matches at any depth below it.
        try file("src/.gitignore", "gen.swift\n", in: root)
        try file("src/deep/gen.swift", in: root)
        try file("gen.swift", in: root)

        let skipped = matchedFiles(try await grep(root), under: root)
        #expect(skipped == ["src/a.swift", "keep.log", "gen.swift"])

        let all = matchedFiles(try await grep(root, ["includeIgnored": true]), under: root)
        #expect(all == [
            "src/a.swift", "keep.log", "gen.swift", "build/out.swift", "debug.log",
            "node_modules/pkg/index.js", "src/deep/gen.swift",
        ])
    }

    @Test("honors info/exclude, including a linked worktree's shared one")
    func infoExclude() async throws {
        let root = makeTempDir("kw-grep")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try file(".git/info/exclude", "/.airbuild/\n", in: project)
        try file("App.swift", in: project)
        try file(".airbuild/artifacts/log.txt", in: project)
        // A worktree inside the project: `.git` is a file pointing at
        // .git/worktrees/wt, whose commondir leads back to .git.
        let worktree = project.appendingPathComponent(".airbuild/worktree/wt")
        try file(".git/worktrees/wt/commondir", "../..\n", in: project)
        try file(".git", "gitdir: \(project.path)/.git/worktrees/wt\n", in: worktree)
        try file("Feature.swift", in: worktree)
        try file("scratch/.airbuild/x.txt", in: worktree)

        #expect(matchedFiles(try await grep(project), under: project) == ["App.swift"])
        #expect(matchedFiles(try await grep(worktree), under: worktree) == ["Feature.swift"])
    }

    @Test("a search root that an ancestor ignores is still searched")
    func explicitIgnoredRoot() async throws {
        let root = makeTempDir("kw-grep")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try file(".gitignore", "vendor/\n", in: root)
        try file("vendor/lib/a.c", in: root)
        let vendor = root.appendingPathComponent("vendor/lib")
        #expect(matchedFiles(try await grep(vendor), under: vendor) == ["a.c"])
    }
}

@Suite("Grep scanning")
struct GrepScanTests {
    private func scan(
        root: URL,
        workers: Int,
        budget: TimeInterval,
        limit: Int = 1000,
        delay: TimeInterval
    ) async -> GrepScanOutcome {
        let scan = GrepScan(GrepScan.Configuration(
            root: root,
            rootIsDirectory: true,
            glob: nil,
            includeIgnored: false,
            limit: limit,
            maxTotalBytes: 1 << 20,
            workers: workers,
            timeBudget: budget,
            match: { path, _, _ in
                Thread.sleep(forTimeInterval: delay)
                return [GrepMatch(file: path, line: 1, text: "needle")]
            },
            bytes: { _ in 1 }
        ))
        return await scan.run(cancellation: nil)
    }

    @Test("reads files in parallel")
    func parallel() async throws {
        let root = makeTempDir("kw-grep")
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<32 { try file(String(format: "f%02d.txt", i), in: root) }

        let started = Date()
        let outcome = await scan(root: root, workers: 16, budget: 60, delay: 0.5)
        #expect(outcome.stop == nil)
        #expect(outcome.filesSearched == 32)
        // Serial would take 16 s; 16 workers need about 1 s. The bound leaves
        // room for loaded CI machines.
        #expect(Date().timeIntervalSince(started) < 8)
        // Results stay in walk (name) order regardless of completion order.
        let names = outcome.matches.map { URL(fileURLWithPath: $0.file).lastPathComponent }
        #expect(names == (0..<32).map { String(format: "f%02d.txt", $0) })
    }

    @Test("returns what it found when the time budget runs out")
    func timeBudget() async throws {
        let root = makeTempDir("kw-grep")
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<40 { try file(String(format: "f%02d.txt", i), in: root) }

        let started = Date()
        let outcome = await scan(root: root, workers: 2, budget: 1.5, delay: 1.0)
        // A full scan would take 20 s; the budget fits a file or two per
        // worker. The bound leaves room for a loaded CI runner, where waking
        // the awaiting task has taken seconds.
        #expect(Date().timeIntervalSince(started) < 15)
        #expect(outcome.stop == .timeBudget)
        #expect(outcome.walkComplete)
        #expect(outcome.filesFound == 40)
        #expect(outcome.filesSearched > 0 && outcome.filesSearched < 40)
        #expect(outcome.matches.count == outcome.filesSearched)
    }

    @Test("the match limit keeps the first matches in walk order")
    func limitIsDeterministic() async throws {
        let root = makeTempDir("kw-grep")
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<30 { try file(String(format: "f%02d.txt", i), in: root) }

        let outcome = await scan(root: root, workers: 8, budget: 30, limit: 5, delay: 0.01)
        #expect(outcome.stop == .limit)
        let names = outcome.matches.map { URL(fileURLWithPath: $0.file).lastPathComponent }
        #expect(names == (0..<5).map { String(format: "f%02d.txt", $0) })
    }

    @Test("the tool reports a partial search")
    func toolReportsTimeBudget() async throws {
        struct Slow: GrepOperations {
            func grep(params: GrepParams) async throws -> [GrepMatch] { [] }
            func search(params: GrepParams) async throws -> GrepSearchResult {
                GrepSearchResult(
                    matches: [GrepMatch(file: "/x/a.swift", line: 3, text: "needle")],
                    stop: .timeBudget(seconds: 30, filesSearched: 120, filesFound: 900, walkComplete: false)
                )
            }
        }
        let tool = createGrepTool(cwd: "/", options: GrepToolOptions(operations: Slow()))
        let result = try await tool.execute("call-grep", ["pattern": .string("needle")], nil, nil)
        let output = textOutput(result)
        #expect(output.contains("/x/a.swift:3:needle"))
        #expect(output.contains("searching 120 of 900+ files"))
        guard case .object(let details) = result.details else {
            Issue.record("details missing")
            return
        }
        #expect(details["truncatedBy"] == .string("time"))
        #expect(details["filesSearched"] == .int(120))
    }

    @Test("timeoutSeconds is clamped and defaulted")
    func budgetClamp() {
        #expect(LocalGrepOperations.timeBudget(nil) == Truncate.grepDefaultTimeBudgetSeconds)
        #expect(LocalGrepOperations.timeBudget(0) == Truncate.grepDefaultTimeBudgetSeconds)
        #expect(LocalGrepOperations.timeBudget(5) == 5)
        #expect(LocalGrepOperations.timeBudget(1e9) == Truncate.grepMaxTimeBudgetSeconds)
    }
}
