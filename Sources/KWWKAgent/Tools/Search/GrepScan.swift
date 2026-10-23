import Foundation
import KWWKAI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

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
///
/// Memory stays bounded however big the tree is: the walker blocks once
/// `maxPending` paths wait to be read, workers do not run more than `window`
/// files ahead of the oldest unfinished one, and each worker reads in bounded
/// chunks (`GrepFileMatcher`).
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
        /// Matches one file: path, match cap, and a check that says the scan
        /// has ended so a long file can be abandoned.
        var match: @Sendable (String, Int, () -> Bool) -> [GrepMatch]
        var bytes: @Sendable (GrepMatch) -> Int
    }

    /// Paths found but not yet claimed, at most.
    static let maxPending = 4096
    /// How far past the oldest unfinished file workers may claim. Bounds the
    /// results held out of order behind a slow file.
    static let window = 4096

    private let configuration: Configuration
    private let condition = NSCondition()

    // Found paths not yet claimed, each with its walk-order index.
    private var pending: [(index: Int, path: String)] = []
    private var pendingHead = 0
    private var filesFound = 0
    private var walkComplete = false
    private var walkerWaiting = false
    private var windowWaiters = 0
    private var filesSearched = 0
    // Results in walk order for [0, prefixEnd); later finished files wait in
    // `ahead` (only those with matches) and `done` until the prefix reaches
    // them. The limit and byte budget apply to the prefix, so a stop returns
    // exactly what a serial scan returns.
    private var prefixEnd = 0
    private var prefixMatches: [GrepMatch] = []
    private var prefixBytes = 0
    private var ahead: [Int: [GrepMatch]] = [:]
    private var done: Set<Int> = []

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
            pending = [(0, configuration.root.path)]
            filesFound = 1
            walkComplete = true
        }
        let alreadyFinished = finished
        condition.unlock()
        if alreadyFinished {
            // Cancelled before it started: no threads.
            condition.lock()
            runningWorkers = 0
            condition.unlock()
            return
        }

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
        // The budget has its own thread rather than a Dispatch timer: the
        // global queues are only as wide as the CPU count, and a busy process
        // (on a 4-core CI runner, 9 s late) can starve the timer.
        let deadline = Date(timeIntervalSinceNow: configuration.timeBudget)
        let watchdog = Thread { [self] in watch(until: deadline) }
        watchdog.name = "kwwk.grep.deadline"
        watchdog.start()
    }

    /// Ends the scan at `deadline` unless it ends first; wakes on every
    /// broadcast, so it exits as soon as the scan finishes.
    private func watch(until deadline: Date) {
        condition.lock()
        defer { condition.unlock() }
        while !finished {
            if !condition.wait(until: deadline) && !finished && Date() >= deadline {
                stop = .timeBudget
                finishLocked()
            }
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

    /// Stops the scan for `reason` unless it already ended. Workers inside a
    /// file notice within one chunk and exit.
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

    private func isFinished() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return finished
    }

    private func outcome() -> GrepScanOutcome {
        condition.lock()
        defer { condition.unlock() }
        var matches = prefixMatches
        switch stop {
        case .limit:
            matches = Array(matches.prefix(configuration.limit))
        case .timeBudget, .cancelled:
            // Also what finished beyond the prefix, in walk order.
            for index in ahead.keys.sorted() { matches += ahead[index] ?? [] }
        case nil, .bytes:
            break
        }
        return GrepScanOutcome(
            matches: matches,
            stop: stop,
            filesSearched: filesSearched,
            filesFound: filesFound,
            walkComplete: walkComplete
        )
    }

    // MARK: - Workers

    private func work() {
        while true {
            condition.lock()
            var waitingOnWindow = false
            while !finished {
                if pendingHead < pending.count {
                    if pending[pendingHead].index < prefixEnd + Self.window { break }
                    waitingOnWindow = true
                } else if walkComplete {
                    break
                }
                if waitingOnWindow { windowWaiters += 1 }
                condition.wait()
                if waitingOnWindow { windowWaiters -= 1 }
                waitingOnWindow = false
            }
            if finished || pendingHead >= pending.count {
                runningWorkers -= 1
                if runningWorkers == 0 && !finished { finishLocked() }
                condition.unlock()
                return
            }
            let item = pending[pendingHead]
            pendingHead += 1
            if pendingHead >= 1024 && pendingHead * 2 >= pending.count {
                pending.removeFirst(pendingHead)
                pendingHead = 0
            }
            if walkerWaiting { condition.broadcast() }
            condition.unlock()

            let found = drainingAutoreleasePool {
                configuration.match(item.path, configuration.limit) { [self] in isFinished() }
            }

            condition.lock()
            record(found, at: item.index)
            condition.unlock()
        }
    }

    private func record(_ found: [GrepMatch], at index: Int) {
        guard !finished else { return }
        filesSearched += 1
        guard index == prefixEnd else {
            done.insert(index)
            if !found.isEmpty { ahead[index] = found }
            return
        }
        append(found)
        prefixEnd += 1
        while done.remove(prefixEnd) != nil {
            append(ahead.removeValue(forKey: prefixEnd) ?? [])
            prefixEnd += 1
        }
        if windowWaiters > 0 { condition.broadcast() }
        if prefixMatches.count >= configuration.limit {
            stop = .limit
            finishLocked()
        } else if prefixBytes > configuration.maxTotalBytes {
            stop = .bytes
            finishLocked()
        }
    }

    private func append(_ found: [GrepMatch]) {
        for match in found {
            prefixMatches.append(match)
            prefixBytes += configuration.bytes(match)
        }
    }

    // MARK: - Walk

    /// Queues one path for the workers, waiting while the queue is full.
    /// False once the scan has ended.
    private func publish(_ path: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !finished && pending.count - pendingHead >= Self.maxPending {
            walkerWaiting = true
            condition.wait()
        }
        walkerWaiting = false
        if finished { return false }
        pending.append((filesFound, path))
        filesFound += 1
        // A plain signal could wake a worker that is waiting on the window
        // and leave an idle one asleep.
        if windowWaiters > 0 { condition.broadcast() } else { condition.signal() }
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

        // Depth-first, names sorted, so results come back in a stable order.
        var stack: [String] = [rootPath]
        while let dir = stack.popLast() {
            if isFinished() { return }
            guard let entries = Self.listDirectory(dir) else { continue }
            ignore?.enter(directory: dir, names: Set(entries.lazy.map(\.name)))

            var subdirectories: [String] = []
            let keepGoing = drainingAutoreleasePool { () -> Bool in
                for entry in entries {
                    let path = dir.hasSuffix("/") ? dir + entry.name : dir + "/" + entry.name
                    switch entry.kind {
                    case .directory:
                        if pruned.contains(entry.name) { continue }
                        if ignore?.ignores(path, isDirectory: true) == true { continue }
                        subdirectories.append(path)
                    case .file:
                        if ignore?.ignores(path, isDirectory: false) == true { continue }
                        if let globRegex {
                            let candidate = globMatchesRelative ? Self.relativePath(of: path, under: rootPath) : entry.name
                            let ns = candidate as NSString
                            if globRegex.firstMatch(in: candidate, options: [], range: NSRange(location: 0, length: ns.length)) == nil {
                                continue
                            }
                        }
                        if !publish(path) { return false }
                    }
                }
                return true
            }
            if !keepGoing { return }
            // Reversed so the stack pops them in name order.
            stack.append(contentsOf: subdirectories.reversed())
        }
    }

    enum EntryKind { case file, directory }

    /// The regular files and directories in `path`, sorted by name; symlinks
    /// and special files are left out. Reads the type from the directory
    /// entry, so most filesystems need no `stat` per entry, and holds only
    /// names, so a directory of a million entries costs megabytes, not the
    /// gigabyte a `URL` per entry does. Nil when the directory can't be read.
    static func listDirectory(_ path: String) -> [(name: String, kind: EntryKind)]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var out: [(name: String, kind: EntryKind)] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                // Under gVisor a signal during a FUSE readdir surfaces as
                // EINTR; readdir resumes where it stopped.
                if errno == EINTR { continue }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            let type = Int(entry.pointee.d_type)
            if type == Int(DT_DIR) {
                out.append((name, .directory))
            } else if type == Int(DT_REG) {
                out.append((name, .file))
            } else if type == Int(DT_UNKNOWN) {
                // Some filesystems leave the type out; ask, without following
                // a symlink.
                var info = stat()
                let full = path.hasSuffix("/") ? path + name : path + "/" + name
                guard lstat(full, &info) == 0 else { continue }
                let mode = Int(info.st_mode) & Int(S_IFMT)
                if mode == Int(S_IFDIR) {
                    out.append((name, .directory))
                } else if mode == Int(S_IFREG) {
                    out.append((name, .file))
                }
            }
        }
        out.sort { $0.name < $1.name }
        return out
    }

    /// `path` relative to `root`, or `path` itself when it is not under it.
    static func relativePath(of path: String, under root: String) -> String {
        let rootBytes = root.utf8.count
        let prefix = root.hasSuffix("/") ? rootBytes : rootBytes + 1
        let utf8 = path.utf8
        guard utf8.count > prefix else { return path }
        return String(Substring(utf8.dropFirst(prefix)))
    }
}

/// Runs `body` in its own autorelease pool on Apple platforms. The scan's
/// threads are long-lived and never return to a run loop, so Foundation's
/// autoreleased temporaries (bridged strings, directory URLs) would otherwise
/// pile up until the thread exits.
@inline(__always)
func drainingAutoreleasePool<T>(_ body: () -> T) -> T {
    #if canImport(ObjectiveC)
    return autoreleasepool(invoking: body)
    #else
    return body()
    #endif
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
        matcher.add(lines.compactMap { Self.pattern(String($0), prefix: prefix) }, scope: prefix)
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
