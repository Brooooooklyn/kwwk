import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

// The chunked matcher must give exactly what matching each line of the whole
// file gives, wherever the chunk and read boundaries fall.

private func reference(_ text: String, pattern: NSRegularExpression, context: Int, cap: Int, file: String) -> [GrepMatch] {
    // Split on the byte. Neither `components(separatedBy: "\n")` (on Linux it
    // keeps "\r\n" whole) nor `hasSuffix("\n")` (a text ending in "\r\n" ends
    // in that one Character) sees every line break.
    var lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
        .map { String(decoding: Array($0), as: UTF8.self) }
    if text.utf8.last == 0x0A { lines.removeLast() }
    if text.isEmpty { lines = [] }
    var found: [GrepMatch] = []
    for (i, line) in lines.enumerated() {
        let ns = line as NSString
        guard pattern.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) != nil else { continue }
        let shown = { (j: Int) in Truncate.truncateLine(lines[j], maxChars: 300).text }
        let before = (max(0, i - context)..<i).map { GrepContextLine(line: $0 + 1, text: shown($0)) }
        let after = ((i + 1)..<min(lines.count, i + 1 + context)).map { GrepContextLine(line: $0 + 1, text: shown($0)) }
        found.append(GrepMatch(file: file, line: i + 1, text: shown(i), before: before, after: after))
        if found.count >= cap { break }
    }
    return found
}

private func matcher(_ pattern: String, options: NSRegularExpression.Options = [], context: Int, chunk: Int, maxLine: Int = 1 << 20) throws -> GrepFileMatcher {
    GrepFileMatcher(
        pattern: try NSRegularExpression(pattern: pattern, options: options),
        patternString: pattern,
        options: options,
        context: context,
        maxLineChars: 300,
        chunkBytes: chunk,
        maxLineBytes: maxLine
    )
}

@Suite("Grep file matcher")
struct GrepFileMatcherTests {
    @Test("matches the per-line reference for random files, patterns and chunk sizes")
    func equivalenceFuzz() throws {
        let dir = makeTempDir("kw-grep-fuzz")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        let words = ["foo", "bar", "baz", "Foo", "", " ", "\t", "x1", "é", "日本", "a\r", "foobar", "#", "end", "\r", "a\u{0C}", "\u{2028}", "\u{85}", "\u{0B}"]
        let patterns = [
            "foo", "^foo", "bar$", "^$", "\\bbaz\\b", "foo(?!bar)", "(?<=foo)bar", "\\Afoo", "end\\z",
            "[^a-z]", "o+b", "^\\s*$", "日本", "x\\d", "foo|end", "a\\r$", ".", "\\Gfoo", "bar(?=$)",
            "a\\s$", "\\s$", "^\\s", "a$", "^a", ".$", "\\u000C$", "\\x{2028}", "[\\s\\S]$", "o.?$",
        ]
        var rng = SystemRandomNumberGenerator()
        for round in 0..<2_000 {
            var text = ""
            let lineCount = Int.random(in: 0...40, using: &rng)
            for _ in 0..<lineCount {
                let n = Int.random(in: 0...5, using: &rng)
                text += (0..<n).map { _ in words.randomElement(using: &rng)! }.joined(separator: Bool.random() ? " " : "")
                text += "\n"
            }
            if Bool.random(using: &rng), !text.isEmpty { text.removeLast() }  // no final newline
            try write(text, to: file)

            let pattern = patterns.randomElement(using: &rng)!
            let options: NSRegularExpression.Options = Bool.random(using: &rng) ? [.caseInsensitive] : []
            let context = Int.random(in: 0...2, using: &rng)
            let cap = Int.random(in: 1...20, using: &rng)
            let chunk = [1, 2, 3, 7, 16, 64, 1 << 20].randomElement(using: &rng)!
            let m = try matcher(pattern, options: options, context: context, chunk: chunk)
            let got = m.matches(inFileAt: file.path, cap: cap) { false }
            let want = reference(text, pattern: m.pattern, context: context, cap: cap, file: file.path)
            #expect(got == want, "round \(round): pattern \(pattern) context \(context) chunk \(chunk) cap \(cap)\n\(text.debugDescription)")
            if got != want { return }
        }
    }

    @Test("line numbers and context stay right across 1 MiB chunk boundaries")
    func largeFile() throws {
        let dir = makeTempDir("kw-grep-large")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.log")
        var text = ""
        let filler = String(repeating: "x", count: 90)
        for i in 1...40_000 {
            text += i % 9_973 == 0 ? "NEEDLE \(i)\n" : "\(filler) \(i)\n"
        }
        try write(text, to: file)
        let m = try matcher("NEEDLE", context: 2, chunk: GrepFileMatcher.defaultChunkBytes)
        let got = m.matches(inFileAt: file.path, cap: 100) { false }
        #expect(got == reference(text, pattern: m.pattern, context: 2, cap: 100, file: file.path))
        #expect(got.map(\.line) == [9_973, 19_946, 29_919, 39_892])
    }

    @Test("a line longer than the cap is matched in pieces without shifting later line numbers")
    func overlongLine() throws {
        let dir = makeTempDir("kw-grep-long")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("min.js")
        let long = String(repeating: "a", count: 5_000) + "NEEDLE" + String(repeating: "é", count: 3_000)
        try write("first\n\(long)\nNEEDLE third\n", to: file)
        let m = try matcher("NEEDLE", context: 0, chunk: 1_000, maxLine: 1_024)
        let got = m.matches(inFileAt: file.path, cap: 10) { false }
        #expect(got.map(\.line) == [2, 3])
    }

    @Test("binary files are skipped even when the NUL comes late in the probe; non-UTF-8 bytes are searched")
    func skipsBinaryAndInvalid() throws {
        let dir = makeTempDir("kw-grep-bin")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = try matcher("needle", context: 0, chunk: 100)

        var binary = Data(String(repeating: "needle\n", count: 2_000).utf8)
        binary[8_000] = 0
        try binary.write(to: dir.appendingPathComponent("a.bin"))
        #expect(m.matches(inFileAt: dir.appendingPathComponent("a.bin").path, cap: 10) { false }.isEmpty)

        // Stray non-UTF-8 bytes read as U+FFFD; the file is still searched.
        var latin1 = Data("caf".utf8)
        latin1.append(contentsOf: [0xE9, 0x20])
        latin1.append(contentsOf: Data("needle\n".utf8))
        try latin1.write(to: dir.appendingPathComponent("b.txt"))
        let found = m.matches(inFileAt: dir.appendingPathComponent("b.txt").path, cap: 10) { false }
        #expect(found.map(\.text) == ["caf\u{FFFD} needle"])

        #expect(m.matches(inFileAt: dir.appendingPathComponent("missing").path, cap: 10) { false }.isEmpty)
    }

    @Test("a FIFO named directly returns at once instead of blocking")
    func fifoDoesNotBlock() throws {
        let dir = makeTempDir("kw-grep-fifo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let m = try matcher("needle", context: 0, chunk: 4_096)
        let started = Date()
        #expect(m.matches(inFileAt: fifo, cap: 10) { false }.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("stops reading when told to")
    func stops() throws {
        let dir = makeTempDir("kw-grep-stop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        try write(String(repeating: "hay\n", count: 100_000) + "needle\n", to: file)
        let m = try matcher("needle", context: 0, chunk: 4_096)
        var checks = 0
        let got = m.matches(inFileAt: file.path, cap: 10) {
            checks += 1
            return checks > 3
        }
        #expect(got.isEmpty)
        #expect(checks == 4)
    }

    @Test("the prefilter is off for patterns that look past a line or anchor to the input")
    func prefilterSafety() {
        for unsafe in ["foo(?!x)", "(?=a)", "(?<=a)b", "(?<!a)b", "\\Afoo", "foo\\z", "foo\\Z", "\\Gx"] {
            #expect(!GrepFileMatcher.prefilterIsSafe(unsafe), "\(unsafe)")
        }
        for safe in ["foo", "^foo$", "\\bfoo\\b", "[^a]", "(foo|bar)", "(?i)foo", "(?:x)"] {
            #expect(GrepFileMatcher.prefilterIsSafe(safe), "\(safe)")
        }
    }

    @Test("gitignore bracket expressions")
    func bracketClasses() {
        let matcher = IgnoreMatcher()
        matcher.add(["*.py[cod]", "[!.]*.tmp", "file[0-9].log", "weird[", "**/build[_-]out/"])
        #expect(matcher.ignores("a.pyc"))
        #expect(matcher.ignores("pkg/a.pyo"))
        #expect(!matcher.ignores("a.py"))
        #expect(!matcher.ignores("a.pyx"))
        #expect(matcher.ignores("x.tmp"))
        #expect(!matcher.ignores(".x.tmp"))
        #expect(matcher.ignores("file7.log"))
        #expect(!matcher.ignores("fileA.log"))
        #expect(matcher.ignores("weird["))
        #expect(matcher.ignores("a/build-out/"))
        #expect(matcher.ignores("build_out/x.c"))
    }
}

@Suite("Grep scan resources")
struct GrepScanResourceTests {
    @Test("a slow file holds back at most a window of finished files")
    func windowBoundsLookahead() async throws {
        let root = makeTempDir("kw-grep-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let count = GrepScan.window + 600
        for i in 0..<count {
            try write("needle\n", to: root.appendingPathComponent(String(format: "f%05d.txt", i)))
        }
        let first = Glob.canonicalDirectoryPath(root.path) + "/f00000.txt"
        let scan = GrepScan(GrepScan.Configuration(
            root: root, rootIsDirectory: true, glob: nil, includeIgnored: false,
            limit: 1_000_000, maxTotalBytes: 1 << 30, workers: 8, timeBudget: 1.5,
            match: { path, _, shouldStop in
                if path == first {
                    // Stuck until the scan ends, like a hung network read.
                    while !shouldStop() { Thread.sleep(forTimeInterval: 0.01) }
                }
                return [GrepMatch(file: path, line: 1, text: "needle")]
            },
            bytes: { _ in 1 }
        ))
        let outcome = await scan.run(cancellation: nil)
        #expect(outcome.stop == .timeBudget)
        // Everything but the stuck file inside the window, nothing beyond it.
        #expect(outcome.filesSearched == GrepScan.window - 1)
        #expect(outcome.matches.count == GrepScan.window - 1)
    }

    @Test("the walk lists names sorted, skips symlinks and never loops")
    func walkSkipsSymlinks() async throws {
        let root = makeTempDir("kw-grep-links")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b/inner"), withIntermediateDirectories: true)
        try write("needle", to: root.appendingPathComponent("b/inner/x.txt"))
        try write("needle", to: root.appendingPathComponent("a.txt"))
        try write("needle", to: root.appendingPathComponent(".hidden"))
        // A loop back to the root and a link to a file: neither is followed.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("b/inner/loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("c.txt"), withDestinationURL: root.appendingPathComponent("a.txt"))

        let entries = GrepScan.listDirectory(root.path)?.map(\.name)
        #expect(entries == [".hidden", "a.txt", "b"])
        let result = try await LocalGrepOperations().search(params: GrepParams(pattern: "needle", path: root.path))
        let base = Glob.canonicalDirectoryPath(root.path) + "/"
        #expect(result.matches.map { String($0.file.dropFirst(base.count)) } == [".hidden", "a.txt", "b/inner/x.txt"])
    }

    @Test("a finished scan is released at once, not when its time budget would end")
    func releasedAfterFinish() async throws {
        let root = makeTempDir("kw-grep-release")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("needle\n", to: root.appendingPathComponent("a.txt"))
        weak var weakScan: GrepScan?
        do {
            let scan = GrepScan(GrepScan.Configuration(
                root: root, rootIsDirectory: true, glob: nil, includeIgnored: false,
                limit: 10, maxTotalBytes: 1 << 20, workers: 4, timeBudget: 600,
                match: { path, _, _ in [GrepMatch(file: path, line: 1, text: "needle")] },
                bytes: { _ in 1 }
            ))
            weakScan = scan
            _ = await scan.run(cancellation: nil)
        }
        // Worker threads drop their references as they exit.
        for _ in 0..<100 where weakScan != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(weakScan == nil)
    }
}
