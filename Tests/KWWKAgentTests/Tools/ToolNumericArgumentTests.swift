import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

/// Out-of-range numeric arguments from the model (negative limits, huge
/// doubles that don't fit in Int) must not trap the process. In-range values
/// keep their existing behaviour.
@Suite("Tool numeric argument bounds")
struct ToolNumericArgumentTests {
    private func makeLinesFile(in dir: URL, count: Int) throws -> URL {
        let file = dir.appendingPathComponent("lines.txt")
        try write((1...count).map { "line \($0)" }.joined(separator: "\n"), to: file)
        return file
    }

    @Test("read with a negative limit returns no lines instead of trapping")
    func readNegativeLimit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeLinesFile(in: dir, count: 3)

        let tool = createReadTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-1",
            ["path": .string(file.path), "limit": .int(-1)],
            nil,
            nil
        )
        #expect(!textOutput(result).contains("line 1"))
    }

    @Test("read with an offset and a negative limit does not trap")
    func readOffsetNegativeLimit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeLinesFile(in: dir, count: 20)

        let tool = createReadTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-2",
            ["path": .string(file.path), "offset": .int(10), "limit": .int(-3)],
            nil,
            nil
        )
        #expect(!textOutput(result).contains("line 10"))
    }

    @Test("read with a huge double limit reads to EOF")
    func readHugeDoubleLimit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeLinesFile(in: dir, count: 3)

        let tool = createReadTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-3",
            ["path": .string(file.path), "limit": .double(1e20)],
            nil,
            nil
        )
        #expect(textOutput(result) == "line 1\nline 2\nline 3")
    }

    @Test("read with an offset and Int.max limit reads to EOF")
    func readOffsetIntMaxLimit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeLinesFile(in: dir, count: 3)

        let tool = createReadTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-4",
            ["path": .string(file.path), "offset": .int(2), "limit": .int(Int.max)],
            nil,
            nil
        )
        #expect(textOutput(result) == "line 2\nline 3")
    }

    @Test("read with a hugely negative offset starts at line 1")
    func readHugeNegativeOffset() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeLinesFile(in: dir, count: 2)

        let tool = createReadTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-5",
            ["path": .string(file.path), "offset": .double(-1e20)],
            nil,
            nil
        )
        #expect(textOutput(result) == "line 1\nline 2")
    }

    @Test("ls with a negative limit lists nothing instead of trapping")
    func lsNegativeLimit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("x", to: dir.appendingPathComponent("a.txt"))

        let tool = createLSTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-6",
            ["path": .string(""), "limit": .int(-1)],
            nil,
            nil
        )
        #expect(!textOutput(result).contains("a.txt"))
    }

    @Test("ls with a huge double limit lists everything")
    func lsHugeDoubleLimit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("x", to: dir.appendingPathComponent("a.txt"))

        let tool = createLSTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-7",
            ["path": .string(""), "limit": .double(1e20)],
            nil,
            nil
        )
        #expect(textOutput(result).contains("a.txt"))
    }

    @Test("find with a huge double limit finds every match")
    func findHugeDoubleLimit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("x", to: dir.appendingPathComponent("a.txt"))

        let tool = createFindTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-8",
            ["pattern": .string("*.txt"), "limit": .double(1e20)],
            nil,
            nil
        )
        #expect(textOutput(result).contains("a.txt"))
    }

    @Test("grep with huge double limit and context finds the match")
    func grepHugeDoubleLimit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("needle\n", to: dir.appendingPathComponent("a.txt"))

        let tool = createGrepTool(cwd: dir.path)
        let result = try await tool.execute(
            "call-9",
            [
                "pattern": .string("needle"),
                "limit": .double(1e20),
                "context": .double(1e20),
            ],
            nil,
            nil
        )
        #expect(textOutput(result).contains("needle"))
    }

    @Test("bash with a huge double timeout clamps to the max timeout")
    func bashHugeDoubleTimeout() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tool = createBashTool(cwd: dir.path, options: BashToolOptions(
            environment: testBashEnvironment
        ))
        let result = try await tool.execute(
            "call-10",
            ["command": .string("echo ok"), "timeout": .double(1e20)],
            nil,
            nil
        )
        #expect(textOutput(result).contains("ok"))
    }
}
