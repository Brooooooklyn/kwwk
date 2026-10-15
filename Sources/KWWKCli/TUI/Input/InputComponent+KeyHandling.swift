import Foundation

extension InputComponent {
    // MARK: - Bracketed paste wrapper

    private static let pasteStart = "\u{1B}[200~"
    private static let pasteEnd = "\u{1B}[201~"

    /// If `data` is a complete bracketed-paste sequence, return the
    /// body; otherwise nil. `StdinBuffer` only emits completed paste
    /// events, so this is just a wrapper-stripping helper that also
    /// normalizes terminal line separators — macOS + most *nix shells
    /// convert Return → `\r` when the body is typed/keystroke-sent,
    /// but the pasted body is logically multi-line. Converting to
    /// `\n` up front means downstream path/attachment detection can
    /// treat newline uniformly.
    private func extractBracketedPasteBody(_ data: String) -> String? {
        guard data.hasPrefix(Self.pasteStart),
              data.hasSuffix(Self.pasteEnd)
        else { return nil }
        let startIdx = data.index(data.startIndex, offsetBy: Self.pasteStart.count)
        let endIdx = data.index(data.endIndex, offsetBy: -Self.pasteEnd.count)
        let raw = String(data[startIdx..<endIdx])
        return raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    func handleInput(_ data: String) {
        // Bracketed paste wrapper `ESC[200~ … ESC[201~` arrives as a
        // single synthetic sequence from StdinBuffer. Unwrap and route
        // to `onPaste` (or insert the body as a fallback so the text
        // isn't silently swallowed).
        if let pasteBody = extractBracketedPasteBody(data) {
            if let handler = onPaste {
                handler(pasteBody)
            } else {
                // No handler configured — insert verbatim. The editor is
                // multi-line, so newlines survive.
                insert(pasteBody)
            }
            return
        }
        guard let event = Keys.parse(data) else {
            // Not a key we recognize — treat printable text as insertion.
            if !data.isEmpty && !data.hasPrefix("\u{1B}") { insert(data) }
            return
        }
        if event.ctrl || event.alt {
            switch (event.name, event.ctrl, event.alt) {
            case ("a", true, false): moveToLineStart()
            case ("e", true, false): moveToLineEnd()
            case ("b", true, false): moveCursor(-1)
            case ("f", true, false): moveCursor(1)
            case ("u", true, false): deleteToStart()
            case ("k", true, false): deleteToEnd()
            // Word-wise editing (emacs/readline). Ctrl+W and Alt+Backspace
            // both delete the word before the cursor; Alt+D deletes the word
            // after it. Alt+B/Alt+F move by word.
            case ("w", true, false): deleteWordBackward()
            case ("backspace", false, true): deleteWordBackward()
            case ("d", false, true): deleteWordForward()
            case ("b", false, true): moveWordLeft()
            case ("f", false, true): moveWordRight()
            // Kill-ring yank / yank-pop.
            case ("y", true, false): yank()
            case ("y", false, true): yankPop()
            // Single-level undo. Ctrl+_ is byte 0x1F (also sent by Ctrl+/ on
            // legacy terminals); Ctrl+Z works where the terminal forwards it in
            // raw mode. Under the Kitty keyboard protocol Ctrl+/ arrives as a
            // distinct "/" codepoint rather than collapsing to 0x1F, so bind it
            // too. All pop the last pre-edit snapshot.
            case ("_", true, false): undo()
            case ("/", true, false): undo()
            case ("z", true, false): undo()
            // Newline-insert triggers. Ctrl+J is the raw LF byte
            // (0x0A); terminals emit it even without any keyboard
            // protocol support. Shift+Enter and Ctrl+Enter require
            // a terminal that tags Enter with modifiers (for example
            // Kitty/Ghostty keyboard protocol support). Alt+Enter
            // arrives as ESC + CR on legacy terminals or CSI 13;3u
            // under the Kitty protocol; both parse to alt+enter.
            case ("j", true, false): insert("\n")
            case ("enter", true, false): insert("\n")
            case ("enter", false, true): insert("\n")
            default: break
            }
            return
        }
        switch event.name {
        case "left": moveCursor(-1)
        case "right": moveCursor(1)
        case "up": cursorUp()
        case "down": cursorDown()
        case "pageup": pageUp()
        case "pagedown": pageDown()
        case "home": moveToLineStart()
        case "end": moveToLineEnd()
        case "backspace": backspace()
        case "delete": deleteForward()
        case "enter":
            if event.shift {
                insert("\n")
            }
            break
        case "escape": break
        case "space": insert(" ")
        case "tab": insert("\t")
        default:
            // Single-char names fall through here.
            if event.name.count == 1 {
                insert(event.shift ? event.name.uppercased() : event.name)
            }
        }
    }
}
