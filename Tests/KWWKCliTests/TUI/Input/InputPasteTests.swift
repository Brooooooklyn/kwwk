import Foundation
import Testing
@testable import KWWKCli

@Suite("InputComponent bracketed paste")
struct InputPasteTests {

    @Test("paste without an onPaste handler falls through to inline insert")
    func defaultInsertsBody() {
        let input = InputComponent()
        let body = "drag and drop text"
        input.handleInput("\u{1B}[200~\(body)\u{1B}[201~")
        #expect(input.value == body)
    }

    @Test("paste with an onPaste handler routes the body instead of inserting")
    func onPasteWins() {
        let input = InputComponent()
        var captured: String?
        input.onPaste = { captured = $0 }
        input.handleInput("\u{1B}[200~/tmp/foo.png\u{1B}[201~")
        #expect(captured == "/tmp/foo.png")
        #expect(input.value == "", "handler was installed — component must not also insert")
    }

    @Test("multi-line paste preserves newlines when no handler is installed")
    func multilinePreservesNewlines() {
        let input = InputComponent()
        input.handleInput("\u{1B}[200~first\nsecond\u{1B}[201~")
        // The editor is multi-line: `\n` in pasted bodies survives as
        // a literal newline in the buffer and renders as a hard break.
        #expect(input.value == "first\nsecond")
    }

    @Test("non-paste input still behaves normally")
    func regularInput() {
        let input = InputComponent()
        input.handleInput("a")
        input.handleInput("b")
        #expect(input.value == "ab")
    }
}
