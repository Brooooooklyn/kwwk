import KWWKAgent
import Testing
@testable import kwwk

@Suite("kwwk command line")
struct KwwkCommandTests {
    @Test("no arguments launch the TUI with the defaults")
    func defaults() throws {
        let command = try KwwkCommand.parse([])
        #expect(!command.printMode && !command.selfTest)
        #expect(command.thinking == .medium)
        #expect(command.model == nil && !command.context1m && !command.idleCompact)
        #expect(command.builtinSubagents([]) == .all)
        #expect(command.resume([]) == .none)
    }

    @Test("global options are read before, between and after the prompt words")
    func promptWords() throws {
        let argv = ["--thinking", "high", "-p", "fix", "--model", "m", "the", "-v", "flag", "--context-1m"]
        let command = try KwwkCommand.parse(argv)
        #expect(command.printMode)
        #expect(command.thinking == .high)
        #expect(command.model == "m")
        #expect(command.context1m)
        // A word that only looks like a flag stays part of the prompt.
        #expect(command.prompt == ["fix", "the", "-v", "flag"])
        #expect(try KwwkCommand.parse(["-p", "-"]).prompt == ["-"])
        #expect(try KwwkCommand.parse(["--print", "--model=x", "hi"]).model == "x")
    }

    @Test("a stray word or unknown option without -p is a usage error")
    func strayWords() {
        #expect(throws: (any Error).self) { try KwwkCommand.parse(["hello"]) }
        #expect(throws: (any Error).self) { try KwwkCommand.parse(["--bogus"]) }
        #expect(throws: (any Error).self) { try KwwkCommand.parse(["--thinking", "loud"]) }
        #expect(throws: (any Error).self) { try KwwkCommand.parse(["--subagents", "nope"]) }
        #expect(throws: (any Error).self) { try KwwkCommand.parse(["--session"]) }
    }

    @Test("the later of --continue, --resume and --session wins")
    func resumeOrder() throws {
        func resume(_ argv: [String]) throws -> SessionResume { try KwwkCommand.parse(argv).resume(argv) }
        #expect(try resume(["--continue"]) == .latestForCwd)
        #expect(try resume(["--continue", "--resume"]) == .pickInteractive)
        #expect(try resume(["--resume", "--continue"]) == .latestForCwd)
        #expect(try resume(["--session", "abc", "--continue"]) == .latestForCwd)
        #expect(try resume(["--continue", "--session=abc"]) == .id("abc"))
        #expect(try resume(["--session", "a", "--session", "b"]) == .id("b"))
    }

    @Test("the later of --subagents and --no-subagents wins")
    func subagentOrder() throws {
        func selection(_ argv: [String]) throws -> BuiltinSubagentSelection {
            try KwwkCommand.parse(argv).builtinSubagents(argv)
        }
        #expect(try selection(["--no-subagents"]) == .none)
        #expect(try selection(["--subagents", "explore"]) == BuiltinSubagentSelection.parseList("explore"))
        #expect(try selection(["--no-subagents", "--subagents", "plan"]) == BuiltinSubagentSelection.parseList("plan"))
        #expect(try selection(["--subagents", "plan", "--no-subagents"]) == .none)
    }

    @Test("--help is a clean exit")
    func help() {
        do {
            _ = try KwwkCommand.parse(["--help"])
            Issue.record("--help parsed as a command")
        } catch {
            #expect(KwwkCommand.exitCode(for: error) == .success)
        }
    }
}

