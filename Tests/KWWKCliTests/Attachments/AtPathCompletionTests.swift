import Foundation
import Testing
@testable import KWWKCli

/// `@path` completion: typing `@` at a word start pops a list of files from
/// the working directory, matching the footer's `@ attach` hint.
@Suite("@path completion")
struct AtPathCompletionTests {

    @Test("query needs a word-start @ with the cursor at the end")
    func queryDetection() {
        #expect(atPathQuery(in: "@", cursor: 1) == AtPathQuery(head: "", path: ""))
        #expect(atPathQuery(in: "see @src/ma", cursor: 11) == AtPathQuery(head: "see ", path: "src/ma"))
        // An e-mail address is not a reference.
        #expect(atPathQuery(in: "me@host", cursor: 7) == nil)
        // Token already finished, or cursor not at the end.
        #expect(atPathQuery(in: "@a ", cursor: 3) == nil)
        #expect(atPathQuery(in: "@abc", cursor: 2) == nil)
        #expect(atPathQuery(in: "plain", cursor: 5) == nil)
    }

    @Test("candidates list the cwd and drill into subdirectories")
    func candidates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let all = atPathCandidates(for: "", cwd: dir.path)
        #expect(all == ["etc/", "notes.md", "Readme.md"])
        #expect(atPathCandidates(for: "r", cwd: dir.path) == ["Readme.md"])
        #expect(atPathCandidates(for: "etc/ho", cwd: dir.path) == ["etc/hosts"])
        #expect(atPathCandidates(for: ".", cwd: dir.path) == [".hidden"])
        #expect(atPathCandidates(for: "nope/", cwd: dir.path).isEmpty)
        // Absolute directories resolve without the cwd.
        #expect(atPathCandidates(for: dir.path + "/etc/", cwd: "/") == [dir.path + "/etc/hosts"])
    }

    @Test("completed input keeps the head and spaces after files only")
    func completedInput() {
        let query = AtPathQuery(head: "look at ", path: "e")
        #expect(atPathCompletedInput(query, candidate: "etc/") == "look at @etc/")
        #expect(atPathCompletedInput(query, candidate: "etc/hosts") == "look at @etc/hosts ")
    }

    @Test("frame pops the @ menu and Tab completes the highlighted row")
    func framePopup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let frame = CodingFrame(viewportHeight: 20)
        frame.atPathCwd = dir.path

        frame.input.value = "@"
        frame.input.moveEnd()
        #expect(frame.atMenuActive)
        let rendered = ANSI.stripEscapes(frame.render(width: 60).joined(separator: "\n"))
        #expect(rendered.contains("@etc/"))
        #expect(rendered.contains("@notes.md"))
        #expect(rendered.contains("Tab complete"))
        #expect(frame.atPathCompletionForTab() == "@etc/")
        // Enter submits as typed until a row is picked with ↑/↓.
        #expect(frame.atPathCompletionForSubmit() == nil)
        frame.atMenuMove(1)
        #expect(frame.atPathCompletionForSubmit() == "@notes.md ")

        frame.input.value = "check @etc/ho"
        frame.input.moveEnd()
        #expect(frame.atPathCompletionForTab() == "check @etc/hosts ")
        // A fully typed file has nothing left to complete.
        frame.input.value = "check @etc/hosts"
        frame.input.moveEnd()
        #expect(!frame.atMenuActive)
    }

    @Test("Esc closes the @ menu without touching the draft")
    func dismiss() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let frame = CodingFrame(viewportHeight: 20)
        frame.atPathCwd = dir.path

        frame.input.value = "@n"
        frame.input.moveEnd()
        #expect(frame.atMenuActive)
        #expect(frame.dismissAtMenu())
        #expect(!frame.atMenuActive)
        #expect(frame.input.value == "@n")
        #expect(!frame.dismissAtMenu())
        // Typing on reopens it.
        frame.input.insert("o")
        #expect(frame.atMenuActive)
    }

    @Test("a recalled history entry ending in @path doesn't hijack ↑/↓")
    func historyBrowsing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let frame = CodingFrame(viewportHeight: 20)
        frame.atPathCwd = dir.path
        frame.input.addToHistory("older")
        frame.input.addToHistory("summarize @e")
        frame.input.addToHistory("newer")

        frame.input.cursorUp()
        frame.input.cursorUp()
        frame.input.cursorUp()
        frame.input.cursorDown()
        #expect(frame.input.value == "summarize @e")
        #expect(frame.input.cursor == frame.input.value.count)
        #expect(!frame.atMenuActive)
        frame.input.cursorDown()
        #expect(frame.input.value == "newer")
        // Editing the recalled entry opens the popup again.
        frame.input.cursorUp()
        frame.input.moveEnd()
        frame.input.insert("t")
        #expect(frame.input.value == "summarize @et")
        #expect(frame.atMenuActive)
    }

    @Test("no cwd, no popup; slash popup wins")
    func gating() {
        let frame = CodingFrame(viewportHeight: 20)
        frame.input.value = "@"
        frame.input.moveEnd()
        #expect(!frame.atMenuActive)

        frame.atPathCwd = "/"
        frame.input.value = "/model"
        frame.input.moveEnd()
        #expect(!frame.atMenuActive)
    }
}

private func makeTempDir() throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory
        .appendingPathComponent("kwwk-atpath-\(UUID().uuidString.prefix(8))")
    try fm.createDirectory(at: dir.appendingPathComponent("etc"), withIntermediateDirectories: true)
    fm.createFile(atPath: dir.appendingPathComponent("etc/hosts").path, contents: Data())
    fm.createFile(atPath: dir.appendingPathComponent("notes.md").path, contents: Data())
    fm.createFile(atPath: dir.appendingPathComponent("Readme.md").path, contents: Data())
    fm.createFile(atPath: dir.appendingPathComponent(".hidden").path, contents: Data())
    fm.createFile(atPath: dir.appendingPathComponent("has space.txt").path, contents: Data())
    return dir
}
