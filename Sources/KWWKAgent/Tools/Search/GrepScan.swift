import Foundation
import KWWKAI

// The engine behind `LocalGrepOperations`: one thread walks the tree while a
// small pool reads and matches files, all under one time budget.
//
// Why threads and not a task group: file reads are blocking syscalls, and on a
// network filesystem (JuiceFS under gVisor, where a cold read costs ~80 ms) a
// handful of them would pin every thread of Swift's cooperative pool. A
// private pool keeps those waits off the pool, and lets a time-budgeted search
// return without waiting for a read that is still stuck in the kernel.

/// Why a scan ended before searching every file.
enum GrepScanStop: Sendable, Equatable {
    case limit
    case bytes
    case timeBudget
    case cancelled
}

struct GrepScanOutcome: Sendable {
    /// Matches in walk order, each file's matches in line order.
    var matches: [GrepMatch]
    var stop: GrepScanStop?
    var filesSearched: Int
    var filesFound: Int
    var walkComplete: Bool
}

/// One search's shared state. Every mutable field is guarded by `condition`.
final class GrepScan: @unchecked Sendable {
    struct Configuration: Sendable {
        var root: URL
        var rootIsDirectory: Bool
        var glob: String?
        var includeIgnored: Bool
        var limit: Int
        var maxTotalBytes: Int
        var workers: Int
        var timeBudget: TimeInterval
        var match: @Sendable (URL, Int) -> [GrepMatch]
        var bytes: @Sendable (GrepMatch) -> Int
    }

    private let configuration: Configuration
    private let condition = NSCondition()

    // Walk output, appended by the walker thread.
    private var files: [URL] = []
    private var walkComplete = false
    // Next file index a worker will claim.
    private var nextIndex = 0
    // Per-file results; nil while the file is unsearched or in flight.
    private var results: [[GrepMatch]?] = []
    private var filesSearched = 0
    // Contiguous searched prefix [0, prefixEnd) and what it holds, so the
    // match limit and byte budget can stop the scan as soon as the first
    // `limit` matches in walk order are known (identical to a serial scan).
    private var prefixEnd = 0
    private var prefixMatches = 0
    private var prefixBytes = 0

    private var runningWorkers = 0
    private var stop: GrepScanStop?
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    func run(cancellation: CancellationHandle?) async -> GrepScanOutcome {
        let registration = cancellation?.onCancel { [self] _ in halt(.cancelled) }
        defer { registration?.cancel() }

        start()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wait(with: continuation)
            }
        } onCancel: { [self] in
            halt(.cancelled)
        }
        return outcome()
    }

    private func start() {
        let workers = max(1, configuration.workers)
        condition.lock()
        runningWorkers = workers
        if !configuration.rootIsDirectory {
            files = [configuration.root]
            results = [nil]
            walkComplete = true
        }
        condition.unlock()

        if configuration.rootIsDirectory {
            let walker = Thread { [self] in walk() }
            walker.name = "kwwk.grep.walk"
            walker.start()
        }
        for n in 0..<workers {
            let worker = Thread { [self] in work() }
            worker.name = "kwwk.grep.\(n)"
            worker.start()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + configuration.timeBudget) { [self] in
            halt(.timeBudget)
        }
    }

    private func wait(with continuation: CheckedContinuation<Void, Never>) {
        condition.lock()
        if finished {
            condition.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            condition.unlock()
        }
    }

    // MARK: - Ending

    /// Stops the scan for `reason` unless it already ended. Workers still
    /// inside a read finish it in the background and then exit.
    private func halt(_ reason: GrepScanStop) {
        condition.lock()
        if !finished {
            stop = reason
            finishLocked()
        }
        condition.unlock()
    }

    private func finishLocked() {
        finished = true
        condition.broadcast()
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    private func outcome() -> GrepScanOutcome {
        condition.lock()
        defer { condition.unlock() }
        var matches: [GrepMatch] = []
        switch stop {
        case .limit, .bytes:
            // Only the contiguous prefix: exactly what a serial scan returns.
            for i in 0..<prefixEnd { matches += results[i] ?? [] }
            if stop == .limit { matches = Array(matches.prefix(configuration.limit)) }
        case nil, .timeBudget, .cancelled:
            // Everything searched so far, in walk order.
            for result in results { matches += result ?? [] }
        }
        return GrepScanOutcome(
            matches: matches,
            stop: stop,
            filesSearched: filesSearched,
            filesFound: files.count,
            walkComplete: walkComplete
        )
    }

    // MARK: - Workers

    private func work() {
        while true {
            condition.lock()
            while !finished && nextIndex >= files.count && !walkComplete {
                condition.wait()
            }
            if finished || nextIndex >= files.count {
                runningWorkers -= 1
                if runningWorkers == 0 && !finished { finishLocked() }
                condition.unlock()
                return
            }
            let index = nextIndex
            nextIndex += 1
            let url = files[index]
            condition.unlock()

            let found = configuration.match(url, configuration.limit)

            condition.lock()
            record(found, at: index)
            condition.unlock()
        }
    }

    private func record(_ found: [GrepMatch], at index: Int) {
        guard !finished else { return }
        results[index] = found
        filesSearched += 1
        while prefixEnd < results.count, let result = results[prefixEnd] {
            prefixEnd += 1
            prefixMatches += result.count
            for match in result { prefixBytes += configuration.bytes(match) }
        }
        if prefixMatches >= configuration.limit {
            stop = .limit
            finishLocked()
        } else if prefixBytes > configuration.maxTotalBytes {
            stop = .bytes
            finishLocked()
        }
    }

    // MARK: - Walk

    private func publish(_ url: URL) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if finished { return false }
        files.append(url)
        results.append(nil)
        condition.signal()
        return true
    }

    private func walk() {
        defer {
            condition.lock()
            walkComplete = true
            condition.broadcast()
            condition.unlock()
        }
        let rootPath = Glob.canonicalDirectoryPath(configuration.root.path)
        let ignore: GrepIgnore? = configuration.includeIgnored ? nil : GrepIgnore(searchRoot: rootPath)
        let globRegex = configuration.glob.flatMap { try? NSRegularExpression(pattern: Glob.patternToRegex($0)) }
        let globMatchesRelative = configuration.glob?.contains("/") ?? false
        let pruned = configuration.includeIgnored ? grepAlwaysPrunedDirectoryNames : ignoredWalkDirectoryNames
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]

        // Depth-first, names sorted, so results come back in a stable order.
        var stack: [String] = [rootPath]
        while let dir = stack.popLast() {
            condition.lock()
            let stopped = finished
            condition.unlock()
            if stopped { return }

            guard let entries = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: keys
            ) else { continue }
            let names = Set(entries.map(\.lastPathComponent))
            ignore?.enter(directory: dir, names: names)

            var subdirectories: [String] = []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? entry.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { continue }
                let path = (dir as NSString).appendingPathComponent(entry.lastPathComponent)
                if values?.isDirectory == true {
                    if pruned.contains(entry.lastPathComponent) { continue }
                    if ignore?.ignores(path, isDirectory: true) == true { continue }
                    subdirectories.append(path)
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                if ignore?.ignores(path, isDirectory: false) == true { continue }
                if let globRegex {
                    let candidate = globMatchesRelative
                        ? Self.relativePath(of: path, under: rootPath)
                        : entry.lastPathComponent
                    let ns = candidate as NSString
                    if globRegex.firstMatch(in: candidate, options: [], range: NSRange(location: 0, length: ns.length)) == nil {
                        continue
                    }
                }
                if !publish(URL(fileURLWithPath: path)) { return }
            }
            // Reversed so the stack pops them in name order.
            stack.append(contentsOf: subdirectories.reversed())
        }
    }

    static func relativePath(of path: String, under root: String) -> String {
        let prefix = root.hasSuffix("/") ? root.count : root.count + 1
        return path.count > prefix ? String(path.dropFirst(prefix)) : path
    }
}

/// Pruned even when the caller asks to include ignored files: version-control
/// internals are never source.
let grepAlwaysPrunedDirectoryNames: Set<String> = [".git", ".hg", ".svn"]

/// Git ignore rules for one search, like ripgrep's defaults: `.gitignore` and
/// `.ignore` files from the repository root down, plus the repository's
/// `info/exclude`. Paths are matched relative to the repository root (or to
/// the search root outside a repository). Only the walker thread uses it.
final class GrepIgnore {
    private static let fileNames = [".gitignore", ".ignore"]
    private let base: String
    private let matcher = IgnoreMatcher()

    init(searchRoot: String) {
        let repository = Self.repositoryRoot(containing: searchRoot)
        base = repository ?? searchRoot
        if let repository {
            if let exclude = Self.infoExcludePath(repository: repository),
               let text = try? String(contentsOfFile: exclude, encoding: .utf8) {
                add(text, directory: repository)
            }
            // Ignore files of the directories above the search root.
            var directory = repository
            let below = searchRoot == repository ? [] : Self.relativeComponents(of: searchRoot, under: repository)
            for component in below.dropLast() {
                load(directory: directory)
                directory = (directory as NSString).appendingPathComponent(component)
            }
            if !below.isEmpty { load(directory: directory) }
            // A search root the user named explicitly is searched even when an
            // ancestor's rules ignore it (`grep path: node_modules/pkg`).
            if searchRoot != repository && ignores(searchRoot, isDirectory: true) {
                matcher.removeAll()
            }
        }
    }

    /// Adds the rules of `directory`, given the names it contains (so a
    /// directory without ignore files costs no extra lookups).
    func enter(directory: String, names: Set<String>) {
        for name in Self.fileNames where names.contains(name) {
            let path = (directory as NSString).appendingPathComponent(name)
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                add(text, directory: directory)
            }
        }
    }

    func ignores(_ path: String, isDirectory: Bool) -> Bool {
        let relative = GrepScan.relativePath(of: path, under: base)
        return matcher.ignores(isDirectory ? relative + "/" : relative)
    }

    private func load(directory: String) {
        let names = Set(Self.fileNames.filter {
            FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent($0))
        })
        enter(directory: directory, names: names)
    }

    private func add(_ text: String, directory: String) {
        let prefix = directory == base ? "" : GrepScan.relativePath(of: directory, under: base) + "/"
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        matcher.add(lines.compactMap { Self.pattern(String($0), prefix: prefix) })
    }

    /// One gitignore line, rebased onto `prefix` (its directory relative to
    /// the match base). A slashless pattern in a nested file still matches at
    /// any depth below that directory, as git does.
    static func pattern(_ line: String, prefix: String) -> String? {
        var pattern = line.trimmingCharacters(in: .whitespaces)
        if pattern.isEmpty || pattern.hasPrefix("#") { return nil }
        if pattern.hasPrefix("\\#") { pattern.removeFirst() }
        var negated = false
        if pattern.hasPrefix("!") {
            negated = true
            pattern.removeFirst()
        } else if pattern.hasPrefix("\\!") {
            pattern.removeFirst()
        }
        let anchored = pattern.hasPrefix("/")
        if anchored { pattern.removeFirst() }
        if pattern.isEmpty || pattern == "/" { return nil }
        let body = pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
        let floating = !anchored && !body.contains("/")
        let rebased = floating && !prefix.isEmpty ? prefix + "**/" + pattern : prefix + pattern
        return negated ? "!" + rebased : rebased
    }

    static func repositoryRoot(containing path: String) -> String? {
        var directory = path
        while true {
            let dotGit = (directory as NSString).appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: dotGit) { return directory }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory || parent.isEmpty { return nil }
            directory = parent
        }
    }

    /// `info/exclude` of the repository. A linked worktree's `.git` is a file
    /// naming its git dir, whose `commondir` leads to the shared one.
    static func infoExcludePath(repository: String) -> String? {
        let dotGit = (repository as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        var gitDirectory = dotGit
        if !isDirectory.boolValue {
            guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
            else { return nil }
            let named = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDirectory = named.hasPrefix("/") ? named : (repository as NSString).appendingPathComponent(named)
            let commonFile = (gitDirectory as NSString).appendingPathComponent("commondir")
            if let common = try? String(contentsOfFile: commonFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
                gitDirectory = common.hasPrefix("/")
                    ? common
                    : ((gitDirectory as NSString).appendingPathComponent(common) as NSString).standardizingPath
            }
        }
        return ((gitDirectory as NSString).appendingPathComponent("info") as NSString)
            .appendingPathComponent("exclude")
    }

    private static func relativeComponents(of path: String, under root: String) -> [String] {
        GrepScan.relativePath(of: path, under: root).split(separator: "/").map(String.init)
    }
}
