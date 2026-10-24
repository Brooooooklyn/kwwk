import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

// Concurrency stress for the grep scanner: many searches at once, some
// cancelled mid-flight, some cut by a tiny time budget. Each must return (or
// throw CancellationError) promptly, with results that are a prefix-consistent
// subset of a full search.

@Suite("Grep stress")
struct GrepStressTests {
    private static func tree() throws -> URL {
        let root = makeTempDir("kw-grep-stress")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try write("ignored/\n", to: root.appendingPathComponent(".gitignore"))
        // Small enough that a full search stays under the output byte budget,
        // so it is a complete reference.
        for d in 0..<5 {
            let dir = root.appendingPathComponent("d\(d)/sub")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<25 {
                var text = ""
                for line in 0..<40 { text += line == (d + f) % 40 ? "needle \(d)-\(f)\n" : "hay \(line)\n" }
                try write(text, to: dir.appendingPathComponent("f\(f).txt"))
            }
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ignored"), withIntermediateDirectories: true)
        try write("needle ignored\n", to: root.appendingPathComponent("ignored/x.txt"))
        return root
    }

    @Test("concurrent searches with cancellation and tiny budgets stay consistent")
    func concurrentSearches() async throws {
        let root = try Self.tree()
        defer { try? FileManager.default.removeItem(at: root) }
        // Modest sizes: the suite runs beside timing-sensitive tests, and
        // hundreds of busy threads made those flaky on CI.
        let ops = LocalGrepOperations(concurrency: 4)
        let full = try await ops.search(params: GrepParams(pattern: "needle", path: root.path, limit: 100_000))
        #expect(full.stop == nil)
        #expect(full.matches.count == 125)
        let fullKeys = full.matches.map { "\($0.file):\($0.line)" }
        #expect(!fullKeys.contains { $0.contains("/ignored/") })

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask {
                    let handle = CancellationHandle()
                    let mode = i % 4
                    if mode == 1 {
                        Task {
                            try? await Task.sleep(nanoseconds: UInt64.random(in: 0...20_000_000))
                            handle.cancel()
                        }
                    }
                    let params = GrepParams(
                        pattern: "needle",
                        path: root.path,
                        limit: mode == 2 ? Int.random(in: 1...40) : 100_000,
                        timeBudget: mode == 3 ? 0.001 : nil,
                        cancellation: handle
                    )
                    do {
                        let result = try await ops.search(params: params)
                        let keys = result.matches.map { "\($0.file):\($0.line)" }
                        switch result.stop {
                        case .limit?:
                            // The limit returns exactly the first matches in walk order.
                            #expect(keys == Array(fullKeys.prefix(keys.count)))
                            #expect(keys.count == params.limit)
                        case .timeBudget?:
                            // Partial: every match is a real one.
                            #expect(Set(keys).isSubset(of: Set(fullKeys)))
                        case nil, .bytes?:
                            #expect(keys == Array(fullKeys.prefix(keys.count)))
                        }
                    } catch is CancellationError {
                        #expect(mode == 1)
                    } catch let error as CodingToolError {
                        Issue.record("unexpected error \(error)")
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test("a cancelled handle stops a search before it starts")
    func preCancelled() async throws {
        let root = try Self.tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = CancellationHandle()
        handle.cancel()
        await #expect(throws: (any Error).self) {
            _ = try await LocalGrepOperations().search(params: GrepParams(pattern: "needle", path: root.path, cancellation: handle))
        }
    }
}
