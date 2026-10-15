import Foundation
import KWWKAgent

/// Pure helpers for choosing a persisted session from a numbered list:
/// `select(from:line:)` parses a 1-based choice and `renderRow` formats one
/// row. Neither touches stdin or the terminal.
enum SessionPicker {

    /// Pure selection step: given the listed sessions and a single input line,
    /// return the chosen `SessionInfo`. An empty line (or any non-`1...n`
    /// value) cancels and returns `nil`. Factored out so the parsing is unit
    /// testable without touching stdin.
    static func select(from infos: [SessionStore.SessionInfo], line: String) -> SessionStore.SessionInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(trimmed), n >= 1, n <= infos.count else { return nil }
        return infos[n - 1]
    }

    /// One rendered menu row for `info` at 1-based `index`.
    static func renderRow(_ info: SessionStore.SessionInfo, index: Int) -> String {
        let base = (info.cwd as NSString).lastPathComponent
        let dir = base.isEmpty ? info.cwd : base
        // Prefer a user-set title (from /rename); fall back to the dir.
        let label = info.title?.isEmpty == false ? info.title! : dir
        let when = relativeTime(fromMillis: info.updatedAt)
        let idPrefix = String(info.id.prefix(8))
        return "\(index)) \(label) · \(info.messageCount) msgs · \(when) · \(idPrefix)"
    }

    private static func relativeTime(fromMillis millis: Int64) -> String {
        let secondsAgo = Int(Date().timeIntervalSince1970) - Int(millis / 1000)
        if secondsAgo < 0 { return "just now" }
        if secondsAgo < 60 { return "\(secondsAgo)s ago" }
        let minutes = secondsAgo / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}
