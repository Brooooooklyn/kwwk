import Foundation

extension EditDiff {

    // MARK: - Diff output

    public struct DiffStringResult: Sendable, Equatable {
        public var diff: String
        public var firstChangedLine: Int?

        public init(diff: String, firstChangedLine: Int? = nil) {
            self.diff = diff
            self.firstChangedLine = firstChangedLine
        }
    }

    /// Backwards-compatible display diff wrapper.
    public static func generateDiff(old: String, new: String, contextLines: Int = 3) -> String {
        generateDiffString(old: old, new: new, contextLines: contextLines).diff
    }

    /// Generate a display-oriented diff with line numbers and folded context,
    /// mirroring pi's `generateDiffString`.
    public static func generateDiffString(
        old: String,
        new: String,
        contextLines: Int = 4
    ) -> DiffStringResult {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let ops = lineDiff(oldLines, newLines)
        let ranges = changedRanges(in: ops, contextLines: contextLines)
        let firstChangedLine = ops.compactMap { op -> Int? in
            switch op {
            case .equal:
                return nil
            case .delete, .insert:
                return op.newLine
            }
        }.first

        guard !ranges.isEmpty else {
            return DiffStringResult(diff: "", firstChangedLine: firstChangedLine)
        }

        var out: [String] = []
        let width = max(String(max(oldLines.count, newLines.count)).count, 1)
        var previousUpper = 0

        for range in ranges {
            if range.lowerBound > previousUpper {
                out.append(skipLine(width: width))
            }
            for op in ops[range] {
                out.append(formatDisplayOp(op, width: width))
            }
            previousUpper = range.upperBound
        }
        if previousUpper < ops.count {
            out.append(skipLine(width: width))
        }

        return DiffStringResult(diff: out.joined(separator: "\n"), firstChangedLine: firstChangedLine)
    }

    /// Generate a standard unified patch (`---`, `+++`, `@@`) for tools that
    /// need machine-readable patch details in addition to the display diff.
    public static func generateUnifiedPatch(
        path: String,
        old: String,
        new: String,
        contextLines: Int = 4
    ) -> String {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let ops = lineDiff(oldLines, newLines)
        let ranges = changedRanges(in: ops, contextLines: contextLines)
        var out = ["--- \(path)", "+++ \(path)"]

        for range in ranges {
            let hunk = Array(ops[range])
            let oldLen = hunk.filter(\.consumesOld).count
            let newLen = hunk.filter(\.consumesNew).count
            guard let first = hunk.first else { continue }
            let oldStart = oldLen == 0 ? max(0, first.oldLine - 1) : first.oldLine
            let newStart = newLen == 0 ? max(0, first.newLine - 1) : first.newLine
            out.append("@@ -\(patchRange(start: oldStart, length: oldLen)) +\(patchRange(start: newStart, length: newLen)) @@")
            for op in hunk {
                out.append(formatPatchOp(op))
            }
        }

        return out.joined(separator: "\n")
    }

    private enum DiffOp {
        case equal(line: String, oldLine: Int, newLine: Int)
        case delete(line: String, oldLine: Int, newLine: Int)
        case insert(line: String, oldLine: Int, newLine: Int)

        var oldLine: Int {
            switch self {
            case .equal(_, let oldLine, _), .delete(_, let oldLine, _), .insert(_, let oldLine, _):
                return oldLine
            }
        }

        var newLine: Int {
            switch self {
            case .equal(_, _, let newLine), .delete(_, _, let newLine), .insert(_, _, let newLine):
                return newLine
            }
        }

        var consumesOld: Bool {
            switch self {
            case .equal, .delete:
                return true
            case .insert:
                return false
            }
        }

        var consumesNew: Bool {
            switch self {
            case .equal, .insert:
                return true
            case .delete:
                return false
            }
        }

        var line: String {
            switch self {
            case .equal(let line, _, _), .delete(let line, _, _), .insert(let line, _, _):
                return line
            }
        }
    }

    private static func lineDiff(_ oldLines: [String], _ newLines: [String]) -> [DiffOp] {
        let difference = newLines.difference(from: oldLines)
        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, let element, _):
                removals[offset] = element
            case .insert(let offset, let element, _):
                insertions[offset] = element
            }
        }

        var oldIndex = 0
        var newIndex = 0
        var ops: [DiffOp] = []
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if let removed = removals[oldIndex] {
                ops.append(.delete(line: removed, oldLine: oldIndex + 1, newLine: newIndex + 1))
                oldIndex += 1
                continue
            }
            if let inserted = insertions[newIndex] {
                ops.append(.insert(line: inserted, oldLine: oldIndex + 1, newLine: newIndex + 1))
                newIndex += 1
                continue
            }
            if oldIndex < oldLines.count && newIndex < newLines.count {
                ops.append(.equal(line: oldLines[oldIndex], oldLine: oldIndex + 1, newLine: newIndex + 1))
                oldIndex += 1
                newIndex += 1
                continue
            }
            if oldIndex < oldLines.count {
                ops.append(.delete(line: oldLines[oldIndex], oldLine: oldIndex + 1, newLine: newIndex + 1))
                oldIndex += 1
                continue
            }
            if newIndex < newLines.count {
                ops.append(.insert(line: newLines[newIndex], oldLine: oldIndex + 1, newLine: newIndex + 1))
                newIndex += 1
            }
        }
        return ops
    }

    private static func changedRanges(in ops: [DiffOp], contextLines: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for index in ops.indices where !isEqual(ops[index]) {
            let lower = max(ops.startIndex, index - contextLines)
            let upper = min(ops.endIndex, index + contextLines + 1)
            if let last = ranges.last, lower <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upper)
            } else {
                ranges.append(lower..<upper)
            }
        }
        return ranges
    }

    private static func isEqual(_ op: DiffOp) -> Bool {
        if case .equal = op { return true }
        return false
    }

    private static func formatDisplayOp(_ op: DiffOp, width: Int) -> String {
        switch op {
        case .equal(let line, let oldLine, _):
            return " \(pad(oldLine, width: width)) \(line)"
        case .delete(let line, let oldLine, _):
            return "-\(pad(oldLine, width: width)) \(line)"
        case .insert(let line, _, let newLine):
            return "+\(pad(newLine, width: width)) \(line)"
        }
    }

    private static func formatPatchOp(_ op: DiffOp) -> String {
        switch op {
        case .equal:
            return " \(op.line)"
        case .delete:
            return "-\(op.line)"
        case .insert:
            return "+\(op.line)"
        }
    }

    private static func patchRange(start: Int, length: Int) -> String {
        length == 1 ? "\(start)" : "\(start),\(length)"
    }

    private static func skipLine(width: Int) -> String {
        " \(String(repeating: " ", count: width)) ..."
    }

    private static func pad(_ n: Int, width: Int) -> String {
        String(format: "%\(width)d", n)
    }
}
