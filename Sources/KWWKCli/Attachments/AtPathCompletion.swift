import Foundation

/// The `@path` reference being typed at the end of the editor: the text
/// before the `@` and the path typed after it. Feeds the `@` completion
/// popup in `CodingFrame`.
struct AtPathQuery: Equatable {
    /// Everything before the `@` (kept verbatim on completion).
    let head: String
    /// The path typed after the `@` so far (may be empty).
    let path: String
}

/// The `@path` token the cursor sits at the end of, or nil when there is
/// none. Only a trailing token with the cursor at the very end of the
/// buffer counts, and the `@` must start a word (start of input or after
/// whitespace) so an e-mail address like `me@host` never opens the popup.
func atPathQuery(in input: String, cursor: Int) -> AtPathQuery? {
    let chars = Array(input)
    guard cursor == chars.count else { return nil }
    var start = chars.count
    while start > 0, !chars[start - 1].isWhitespace {
        start -= 1
    }
    guard start < chars.count, chars[start] == "@" else { return nil }
    return AtPathQuery(
        head: String(chars[..<start]),
        path: String(chars[(start + 1)...])
    )
}

/// Upper bound on the candidates collected for one query, so a huge
/// directory can't make every keystroke list thousands of rows.
let atPathCandidateLimit = 200

/// Filesystem completions for the path typed after `@`. Each candidate is
/// the full replacement path (what goes after the `@`), with a trailing
/// `/` on directories so completing one lets the user drill into it.
///
/// The directory part (up to the last `/`) resolves like submit-time
/// attachment resolution: absolute, `~/…`, or relative to `cwd`. The rest
/// is a case-insensitive name prefix. Dotfiles appear only once the typed
/// name starts with `.`; names with whitespace are skipped because an
/// `@path` reference ends at the first whitespace.
func atPathCandidates(for path: String, cwd: String) -> [String] {
    let dirPart: String
    let partial: String
    if let slash = path.lastIndex(of: "/") {
        dirPart = String(path[...slash])
        partial = String(path[path.index(after: slash)...])
    } else {
        dirPart = ""
        partial = path
    }
    let directory = dirPart.isEmpty ? cwd : normalizePastePath(dirPart, cwd: cwd)
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

    let needle = partial.lowercased()
    let showHidden = partial.hasPrefix(".")
    var out: [String] = []
    for name in names.sorted(by: { ($0.lowercased(), $0) < ($1.lowercased(), $1) }) {
        if !showHidden, name.hasPrefix(".") { continue }
        if name.contains(where: { $0.isWhitespace }) { continue }
        guard name.lowercased().hasPrefix(needle) else { continue }
        var isDir: ObjCBool = false
        let full = (directory as NSString).appendingPathComponent(name)
        _ = fm.fileExists(atPath: full, isDirectory: &isDir)
        out.append(dirPart + name + (isDir.boolValue ? "/" : ""))
        if out.count >= atPathCandidateLimit { break }
    }
    return out
}

/// The editor value after accepting `candidate` for `query`. A file gets a
/// trailing space so the user can keep typing; a directory does not, so
/// the popup reopens on its contents.
func atPathCompletedInput(_ query: AtPathQuery, candidate: String) -> String {
    let tail = candidate.hasSuffix("/") ? "" : " "
    return query.head + "@" + candidate + tail
}
