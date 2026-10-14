/// Emacs-style kill ring: text removed by a kill command (Ctrl+W, Ctrl+U,
/// Ctrl+K, Alt+D, Alt+Backspace) is pushed here so Ctrl+Y can yank it back.
/// Consecutive kills accumulate into a single entry — prepended for backward
/// deletes, appended for forward — so a run of Ctrl+W yanks as one unit.
/// Port of pi-tui's `kill-ring.ts`.
struct KillRing {
    private var ring: [String] = []
    private let maxEntries = 60

    mutating func push(_ text: String, prepend: Bool, accumulate: Bool) {
        guard !text.isEmpty else { return }
        if accumulate, let last = ring.popLast() {
            ring.append(prepend ? text + last : last + text)
        } else {
            ring.append(text)
            if ring.count > maxEntries { ring.removeFirst() }
        }
    }

    /// Most recent entry without mutating the ring.
    func peek() -> String? { ring.last }

    /// Move the last entry to the front — drives Alt+Y yank-pop cycling.
    mutating func rotate() {
        guard ring.count > 1 else { return }
        let last = ring.removeLast()
        ring.insert(last, at: 0)
    }

    var count: Int { ring.count }
}
