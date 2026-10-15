import Foundation
import NIOConcurrencyHelpers

/// In-memory terminal used by tests. Interprets a small subset of ANSI escape
/// sequences sufficient to validate rendering output:
///  - printable bytes advance the cursor
///  - `\n` moves to the next row (col 0)
///  - `\r` moves cursor to col 0
///  - `\x1b[<n>A/B/C/D` moves the cursor
///  - `\x1b[<n>G` moves the cursor to a given column
///  - `\x1b[2J` clears the visible screen
///  - `\x1b[3J` clears the scrollback (no-op in this mock)
///  - `\x1b[K` clears from cursor to end of line
///  - `\x1b[?2026h` / `\x1b[?2026l` synchronized output markers (no-op)
final class VirtualTerminal: Terminal, Sendable {
    /// Everything the terminal mutates, guarded together by `state`'s lock.
    private struct State {
        var width: Int
        var height: Int

        // Grid: height rows × width columns.
        var grid: [[Character]]
        var row: Int = 0
        var col: Int = 0

        var resizeHandlers: [UUID: @Sendable (Int, Int) -> Void] = [:]
        var writeBuffer: [String] = []
        var pendingRender: Bool = false

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            self.grid = Array(repeating: Array(repeating: " ", count: width), count: height)
        }

        // MARK: - Minimal ANSI processing
        //
        // We iterate by Unicode scalar rather than Character because Swift treats
        // `\r\n` as a single grapheme cluster — which would cause neither the
        // `\r` nor the `\n` handler to match when both bytes arrive together.

        mutating func processWrite(_ data: String) {
            let scalars = Array(data.unicodeScalars)
            var i = 0
            while i < scalars.count {
                let scalar = scalars[i]
                if scalar.value == 0x1B {
                    i = handleEscape(scalars, startingAfter: i)
                    continue
                }
                if scalar.value == 0x0A { // \n
                    row += 1
                    col = 0
                    if row >= height { row = height - 1 }
                    i += 1
                    continue
                }
                if scalar.value == 0x0D { // \r
                    col = 0
                    i += 1
                    continue
                }
                // Printable
                if row >= 0 && row < height && col >= 0 && col < width {
                    grid[row][col] = Character(scalar)
                }
                col += 1
                if col >= width {
                    col = width - 1
                }
                i += 1
            }
        }

        mutating func handleEscape(_ scalars: [Unicode.Scalar], startingAfter index: Int) -> Int {
            let next = index + 1
            guard next < scalars.count else { return next }
            let marker = scalars[next]
            if marker.value == 0x5B { // '['
                var end = next + 1
                var params = ""
                while end < scalars.count, !isCSIFinal(scalars[end]) {
                    params.unicodeScalars.append(scalars[end])
                    end += 1
                }
                guard end < scalars.count else { return end }
                let final = Character(scalars[end])
                applyCSI(params: params, final: final)
                return end + 1
            }
            if marker.value == 0x5F { // '_' APC: swallow until BEL (0x07)
                var end = next + 1
                while end < scalars.count, scalars[end].value != 0x07 {
                    end += 1
                }
                return end < scalars.count ? end + 1 : end
            }
            // Unknown — skip ESC
            return next
        }

        func isCSIFinal(_ scalar: Unicode.Scalar) -> Bool {
            let v = scalar.value
            // Letters A-Z, a-z
            if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) { return true }
            if v == 0x7E { return true } // ~
            if v == 0x40 { return true } // @
            return false
        }

        mutating func applyCSI(params: String, final: Character) {
            let nums = params.split(separator: ";").map { Int($0) ?? 0 }
            let first = nums.first ?? 0
            switch final {
            case "A":
                row = max(0, row - max(1, first))
            case "B":
                row = min(height - 1, row + max(1, first))
            case "C":
                col = min(width - 1, col + max(1, first))
            case "D":
                col = max(0, col - max(1, first))
            case "G":
                col = max(0, min(width - 1, first - 1))
            case "H":
                let r = (nums.count > 0 ? nums[0] : 1) - 1
                let c = (nums.count > 1 ? nums[1] : 1) - 1
                row = max(0, min(height - 1, r))
                col = max(0, min(width - 1, c))
            case "J":
                if first == 2 {
                    // Clear visible screen
                    for r in 0..<height { grid[r] = Array(repeating: " ", count: width) }
                } else if first == 0 {
                    // Clear from cursor to end of screen
                    if row >= 0 && row < height {
                        if col < width {
                            for c in col..<width { grid[row][c] = " " }
                        }
                        for r in (row + 1)..<height {
                            grid[r] = Array(repeating: " ", count: width)
                        }
                    }
                }
                // 3 → clear scrollback (no-op in mock)
            case "K":
                // Clear line based on param: 0 = from cursor to end, 1 = from start to cursor, 2 = full
                if row >= 0 && row < height {
                    switch first {
                    case 1:
                        for c in 0...min(col, width - 1) { grid[row][c] = " " }
                    case 2:
                        grid[row] = Array(repeating: " ", count: width)
                    default:
                        if col < width {
                            for c in col..<width { grid[row][c] = " " }
                        }
                    }
                }
            default:
                break
            }
        }
    }

    private let state: NIOLockedValueBox<State>

    var width: Int { state.withLockedValue { $0.width } }
    var height: Int { state.withLockedValue { $0.height } }

    init(width: Int, height: Int) {
        self.state = NIOLockedValueBox(State(width: width, height: height))
    }

    // MARK: - Terminal

    func write(_ data: String) {
        state.withLockedValue {
            $0.writeBuffer.append(data)
            $0.processWrite(data)
            $0.pendingRender = false
        }
    }

    func onResize(_ handler: @escaping @Sendable (Int, Int) -> Void) -> () -> Void {
        let id = UUID()
        state.withLockedValue { $0.resizeHandlers[id] = handler }
        return { [weak self] in
            _ = self?.state.withLockedValue { $0.resizeHandlers.removeValue(forKey: id) }
        }
    }

    // MARK: - Test helpers

    func resize(width: Int, height: Int) {
        let handlers: [@Sendable (Int, Int) -> Void] = state.withLockedValue { state in
            state.width = width
            state.height = height
            var newGrid = Array(repeating: Array(repeating: Character(" "), count: width), count: height)
            for r in 0..<min(state.grid.count, height) {
                for c in 0..<min(state.grid[r].count, width) {
                    newGrid[r][c] = state.grid[r][c]
                }
            }
            state.grid = newGrid
            state.pendingRender = true
            return Array(state.resizeHandlers.values)
        }
        for h in handlers { h(width, height) }
    }

    /// Snapshot the visible viewport as an array of strings (rows).
    func getViewport() -> [String] {
        state.withLockedValue { $0.grid.map { String($0) } }
    }

    /// Concatenation of everything written since construction; useful for
    /// asserting ANSI sequences.
    func getWrites() -> String {
        state.withLockedValue { $0.writeBuffer.joined() }
    }

    func clearWrites() {
        state.withLockedValue { $0.writeBuffer.removeAll() }
    }

    /// Yield until the next batch of writes has been processed. For the mock
    /// this just yields once to let the event loop flush.
    func waitForRender() async {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
