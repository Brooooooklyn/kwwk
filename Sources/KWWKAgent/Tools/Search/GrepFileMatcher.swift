import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Matches one file line by line while reading it in bounded chunks, so a
/// search's memory stays flat however large the files are: each reader holds
/// at most one chunk plus one partial line.
///
/// Files with a NUL byte in their first 8 KiB are binary and skipped; each
/// line is matched on its own. Bytes that are not UTF-8 are read as U+FFFD,
/// as ripgrep does, so one stray Latin-1 byte no longer hides a whole file
/// (the whole-file reader this replaced skipped such files, which a chunked
/// reader could not do consistently). The empty "line" after a file's final
/// newline is not reported.
struct GrepFileMatcher: Sendable {
    /// Bytes read per `read(2)` and the most decoded at once.
    static let defaultChunkBytes = 1 << 20
    /// A line longer than this is matched in pieces of this size; a match
    /// spanning a cut is missed. Real source never comes close.
    static let defaultMaxLineBytes = 1 << 20
    static let binaryProbeBytes = 8192

    let chunkBytes: Int
    let maxLineBytes: Int

    let pattern: NSRegularExpression
    /// Runs over a whole chunk to skip chunks without a match without
    /// splitting them into lines. Nil when the pattern could match a line on
    /// its own but not inside a longer text (lookaround, `\A`, `\z`, `\G`).
    let prefilter: NSRegularExpression?
    let context: Int
    let maxLineChars: Int

    init(
        pattern: NSRegularExpression,
        patternString: String,
        options: NSRegularExpression.Options,
        context: Int,
        maxLineChars: Int,
        chunkBytes: Int = defaultChunkBytes,
        maxLineBytes: Int = defaultMaxLineBytes
    ) {
        self.chunkBytes = max(1, chunkBytes)
        self.maxLineBytes = max(4, maxLineBytes)
        self.pattern = pattern
        self.context = max(0, context)
        self.maxLineChars = maxLineChars
        self.prefilter = Self.prefilterIsSafe(patternString)
            ? try? NSRegularExpression(pattern: patternString, options: options.union(.anchorsMatchLines))
            : nil
    }

    /// Whether a match of the pattern inside one line is also found when the
    /// pattern runs over text holding that line. Lookaround can see past the
    /// line's ends, and `\A` `\Z` `\z` `\G` anchor to the whole input, so a
    /// lone line could match where the same line inside a chunk does not.
    /// Anything else only gains matches across lines, which the per-line pass
    /// then rejects. The check is textual and errs toward "unsafe".
    static func prefilterIsSafe(_ pattern: String) -> Bool {
        !["(?=", "(?!", "(?<", "\\A", "\\Z", "\\z", "\\G"].contains { pattern.contains($0) }
    }

    /// Up to `cap` matches in the file at `path`, with their context lines.
    /// Returns early, with whatever it has, once `shouldStop` says so.
    func matches(inFileAt path: String, cap: Int, shouldStop: () -> Bool) -> [GrepMatch] {
        // Non-blocking so a FIFO or device named as the search root cannot
        // hang the reader; only regular files are read.
        let fd = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Int(info.st_mode) & Int(S_IFMT) == Int(S_IFREG) else { return [] }
        // Most files are small: size the read buffer to the file.
        let size = max(0, Int(info.st_size))
        let readBytes = min(chunkBytes, max(size + 1, 4_096))

        var state = State(file: path, context: context, cap: max(1, cap))
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: readBytes)
        var probed = false
        var atEnd = false

        while true {
            if shouldStop() { return state.found }
            if !atEnd {
                let n = Self.readRetrying(fd, into: &chunk)
                if n < 0 { return [] }
                if n == 0 { atEnd = true } else { buffer.append(contentsOf: chunk[0..<n]) }
            }
            if !probed {
                // Decide binary on the first 8 KiB, however the reads split.
                if buffer.count < Self.binaryProbeBytes && !atEnd { continue }
                if buffer.prefix(Self.binaryProbeBytes).contains(0) { return [] }
                probed = true
            }

            // Take every complete line; at the end, the rest is the last line.
            let end: Int
            var forcedCut = false
            if atEnd {
                end = buffer.count
            } else if let newline = buffer.lastIndex(of: 0x0A) {
                end = newline + 1
            } else if buffer.count >= maxLineBytes {
                end = Self.utf8Boundary(in: buffer, before: maxLineBytes)
                forcedCut = true
            } else {
                continue
            }

            if end > 0 {
                let segment = buffer[0..<end]
                process(segment, forcedCut: forcedCut, state: &state)
                buffer.removeSubrange(0..<end)
                if state.isDone { return state.found }
            }
            if atEnd { return state.found }
        }
    }

    // MARK: - Lines

    private struct State {
        let file: String
        let context: Int
        let cap: Int
        var found: [GrepMatch] = []
        /// Number of the line most recently started.
        var lineNumber = 0
        /// The previous `context` lines, oldest first.
        var before: [GrepContextLine] = []
        /// Matches still collecting after-context: index into `found` and
        /// lines still wanted.
        var pendingAfter: [(index: Int, remaining: Int)] = []
        /// The last piece ended in a forced cut, so the next text continues
        /// that line.
        var continuesLine = false

        init(file: String, context: Int, cap: Int) {
            self.file = file
            self.context = context
            self.cap = cap
        }

        var isDone: Bool { found.count >= cap && pendingAfter.isEmpty }
    }

    /// `segment` ends at a line break, at the end of the file, or at a
    /// forced cut on a UTF-8 boundary.
    private func process(_ segment: ArraySlice<UInt8>, forcedCut: Bool, state: inout State) {
        let endsWithNewline = segment.last == 0x0A
        // Fast path: with no context to carry, a chunk without a match needs
        // no line splitting at all. Not with a "\r" in the chunk: ICU treats
        // "\r\n" as one line break, so `$` cannot fall between them over the
        // chunk, while the lone line "…a\r" still matches `a\r$` or `a\s$`.
        if context == 0, let prefilter, !segment.withUnsafeBytes({ $0.baseAddress.map { memchr($0, 0x0D, segment.count) != nil } ?? false }) {
            let text = String(decoding: segment, as: UTF8.self)
            let ns = text as NSString
            if prefilter.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) == nil {
                var pieces = Self.count(0x0A, in: segment) + 1
                if endsWithNewline { pieces -= 1 }
                if state.continuesLine { pieces -= 1 }
                state.lineNumber += max(0, pieces)
                state.continuesLine = forcedCut
                return
            }
        }

        // Split on the bytes, not the String: "\r\n" is one Character, so a
        // String split would fold the "\r" into the break. 0x0A never occurs
        // inside a multi-byte sequence, so each piece decodes as it would in
        // the whole text.
        var lines = segment.split(separator: 0x0A, omittingEmptySubsequences: false)
        // A segment ending in a newline yields a trailing empty piece that is
        // not a line.
        if endsWithNewline, lines.last?.isEmpty == true { lines.removeLast() }
        for (offset, slice) in lines.enumerated() {
            let line = String(decoding: slice, as: UTF8.self)
            let continuing = offset == 0 && state.continuesLine
            if !continuing { state.lineNumber += 1 }
            let number = state.lineNumber
            let shown = Truncate.truncateLine(line, maxChars: maxLineChars).text

            if !continuing && !state.pendingAfter.isEmpty {
                for k in state.pendingAfter.indices {
                    state.found[state.pendingAfter[k].index].after.append(GrepContextLine(line: number, text: shown))
                    state.pendingAfter[k].remaining -= 1
                }
                state.pendingAfter.removeAll { $0.remaining <= 0 }
            }

            if state.found.count < state.cap, state.found.last?.line != number {
                let ns = line as NSString
                if pattern.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                    state.found.append(GrepMatch(file: state.file, line: number, text: shown, before: state.before, after: []))
                    if context > 0 { state.pendingAfter.append((state.found.count - 1, context)) }
                }
            }
            if state.isDone { break }

            if context > 0 && !continuing {
                state.before.append(GrepContextLine(line: number, text: shown))
                if state.before.count > context { state.before.removeFirst(state.before.count - context) }
            }
        }
        state.continuesLine = forcedCut
    }

    /// Occurrences of `byte`, with `memchr` so it stays fast unoptimized too.
    static func count(_ byte: UInt8, in bytes: ArraySlice<UInt8>) -> Int {
        bytes.withUnsafeBytes { raw -> Int in
            guard var p = raw.baseAddress else { return 0 }
            let end = p + raw.count
            var n = 0
            while p < end, let hit = memchr(p, Int32(byte), end - p) {
                n += 1
                p = UnsafeRawPointer(hit) + 1
            }
            return n
        }
    }

    /// The largest cut at or below `limit` that does not split a UTF-8
    /// sequence.
    static func utf8Boundary(in bytes: [UInt8], before limit: Int) -> Int {
        var end = min(limit, bytes.count)
        // Step back over continuation bytes, then over the lead byte they
        // belong to.
        var back = 0
        while end > 0 && back < 3 && bytes[end - 1] & 0xC0 == 0x80 {
            end -= 1
            back += 1
        }
        if end > 0 && bytes[end - 1] & 0xC0 == 0xC0 { end -= 1 }
        return end > 0 ? end : min(limit, bytes.count)
    }

    /// `read(2)` that retries an interrupted call: under gVisor any signal
    /// during a FUSE read surfaces as EINTR.
    private static func readRetrying(_ fd: Int32, into chunk: inout [UInt8]) -> Int {
        while true {
            let n = chunk.withUnsafeMutableBytes { buffer -> Int in
                #if canImport(Darwin)
                return Darwin.read(fd, buffer.baseAddress, buffer.count)
                #elseif canImport(Glibc)
                return Glibc.read(fd, buffer.baseAddress, buffer.count)
                #else
                return Musl.read(fd, buffer.baseAddress, buffer.count)
                #endif
            }
            if n < 0 && errno == EINTR { continue }
            return n
        }
    }
}
