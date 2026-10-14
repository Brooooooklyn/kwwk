import Foundation

/// The persistent **live zone** for the inline coding TUI. Everything the
/// terminal keeps redrawing in place lives here, bottom-anchored:
///
///   - running tool blocks (the streaming tail — `liveLines`)
///   - the slash-command popup (when the user is naming a command)
///   - the rounded prompt box (breadcrumb · input · reasoning/ctx)
///   - a transient state line (generating / ready hints)
///
/// Settled transcript (user turns, assistant prose, finished tool results)
/// and the welcome card are NOT held here — they are committed to the
/// terminal's native scrollback via `TUI.commit`, so the user can scroll
/// back through history with the trackpad. A modal selector temporarily
/// replaces the tail+popup area while staying above the prompt box.
final class CodingFrame: Component, @unchecked Sendable {
    let input: InputComponent
    let promptRow: PromptRow

    /// Top-border breadcrumb for the prompt box (already styled).
    var breadcrumb: String = ""
    /// Bottom-border right label for the prompt box (already styled).
    var metaRight: String = ""
    /// Transient state line under the prompt box (already styled).
    var stateLine: String = ""

    /// Whether the agent is mid-turn. Slash commands are idle-only, so when
    /// busy the popup's footer drops the "↵ run" affordance (Enter is rejected
    /// with the idle-only notice) and explains commands run when idle. Tab
    /// completion stays available either way.
    var isBusy: Bool = false

    /// Pending queued prompts (plain text, in FIFO order) the user submitted
    /// while the agent was busy. Rendered as a dim list that hugs the prompt
    /// box — omp's "pending messages" container. They live in the redrawn
    /// live zone (NOT scrollback), so they appear the moment they're queued
    /// and vanish as the agent drains them into real turns.
    var queuedPrompts: [String] = []

    /// Slash-command catalog (name + one-line description + aliases). When the
    /// input is a bare `/query`, a live-filtered preview of matches pops up
    /// above the prompt box.
    var slashCommands: [SlashCommandInfo] = []
    private var menuSelection = 0
    /// Top index of the visible slash-menu window. Persistent state so the
    /// window scrolls only when the selection crosses an edge (rather than
    /// pinning the selection to the bottom row and scrolling on every step).
    private var menuScroll = 0
    private var menuFilter: String?
    /// Whether the user moved the highlight with ↑/↓ since the query last
    /// changed. Only then may Enter run a row the query doesn't prefix-match.
    private var menuNavigated = false
    private static let menuMaxRows = 8

    /// Directory `@path` completions resolve against. Nil (the default)
    /// disables the `@` popup; the TUI sets it to the session's cwd.
    var atPathCwd: String?
    private var atSelection = 0
    private var atScroll = 0
    /// Whether the user moved the `@` highlight with ↑/↓ since the query
    /// last changed. Only then does Enter accept the highlighted path
    /// instead of submitting the prompt.
    private var atNavigated = false
    /// Candidates for the last query, so a render or key press doesn't
    /// re-list the directory unless the typed path changed.
    private var atCache: (key: String, candidates: [String])?
    /// The query whose popup Esc closed. The popup stays shut until the
    /// typed path changes.
    private var atDismissedKey: String?

    private var liveLines: [String] = []
    private var modalLines: [String]?
    private var viewportHeight: Int
    private var spinnerIndex: Int = 0

    /// 10-frame braille spinner (width-1 glyphs). Advanced by `tick()` on a
    /// dedicated ~90ms cadence — decoupled from the 250ms background-task poll
    /// — so the animation reads as smooth motion rather than visible steps.
    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init(viewportHeight: Int = 20) {
        self.input = InputComponent()
        self.promptRow = PromptRow(prompt: Theme.accentText("❯ ", bold: true), input: input)
        self.viewportHeight = max(1, viewportHeight)
        syncEditorViewport()
    }

    var spinner: String {
        Self.spinnerFrames[spinnerIndex % Self.spinnerFrames.count]
    }

    func setViewport(height: Int) {
        viewportHeight = max(1, height)
        syncEditorViewport()
    }

    /// omp's editor height cap (interactive-mode.ts `computeEditorMaxHeight`):
    /// clamp(rows − 12, 6, 18), further limited to rows − 4, floored at 3.
    /// That figure includes the box's two border rows; the editor caps its
    /// visible *content* rows, so subtract them (never below 1).
    private func syncEditorViewport() {
        let comfortable = max(6, min(18, viewportHeight - 12))
        let maxHeight = max(3, min(comfortable, viewportHeight - 4))
        input.maxVisibleRows = max(1, maxHeight - 2)
    }

    func tick() {
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerFrames.count
    }

    func setLiveLines(_ lines: [String]) {
        liveLines = lines
    }

    func setModalLines(_ lines: [String]?) {
        modalLines = lines
    }

    // MARK: - Slash menu

    private func slashQuery() -> String? {
        bareSlashQuery(input.value)
    }

    private func filteredCommands() -> [SlashCommandInfo] {
        guard let q = slashQuery() else { return [] }
        // Funnel through the one shared ranker so the highlighted row, Tab
        // completion, and the inline ghost suffix always agree on the top
        // match. `slashCommands` is supplied pre-sorted by name, so equal
        // scores keep alphabetical order.
        return rankSlashCommands(query: q, commands: slashCommands)
    }

    var slashMenuActive: Bool {
        modalLines == nil && slashQuery() != nil && !filteredCommands().isEmpty
    }

    func menuMove(_ delta: Int) {
        let matches = filteredCommands()
        guard !matches.isEmpty else { return }
        syncSelection(matches)
        menuSelection = (menuSelection + delta + matches.count) % matches.count
        menuNavigated = true
    }

    func selectedSlashCommandName() -> String? {
        let matches = filteredCommands()
        guard !matches.isEmpty else { return nil }
        syncSelection(matches)
        return matches[min(menuSelection, matches.count - 1)].name
    }

    /// The command Enter should run for the open popup, or nil when it must
    /// not run anything. A row runs only when the typed query is a prefix of
    /// its name/alias, or the user picked it with ↑/↓ — so a stray `/nope`
    /// never executes whatever loose match happens to be highlighted.
    func slashCommandNameForSubmit() -> String? {
        guard let query = slashQuery() else { return nil }
        let matches = filteredCommands()
        guard !matches.isEmpty else { return nil }
        syncSelection(matches)
        let selected = matches[min(menuSelection, matches.count - 1)]
        guard enterRuns(selected, query: query) else { return nil }
        return selected.name
    }

    /// Whether Enter on the open popup should do nothing and keep it open: a
    /// lone `/` the user hasn't navigated yet. Without this the `/` would fall
    /// through to the prompt path and be sent to the model.
    func slashSubmitKeepsMenuOpen() -> Bool {
        guard slashMenuActive, slashQuery() == "" else { return false }
        return slashCommandNameForSubmit() == nil
    }

    /// The Enter rule shared by submission and the footer's "↵ run" hint.
    private func enterRuns(_ selected: SlashCommandInfo, query: String) -> Bool {
        menuNavigated || slashQueryIsPrefix(query, of: selected)
    }

    private func syncSelection(_ matches: [SlashCommandInfo]) {
        let q = slashQuery()
        if q != menuFilter {
            menuFilter = q
            menuSelection = 0
            menuScroll = 0
            menuNavigated = false
        }
        if menuSelection >= matches.count { menuSelection = max(0, matches.count - 1) }
    }

    // MARK: - @path popup

    private func atQuery() -> AtPathQuery? {
        guard atPathCwd != nil else { return nil }
        return atPathQuery(in: input.value, cursor: input.cursor)
    }

    /// Candidates for the `@path` being typed, empty when the popup would
    /// have nothing useful to offer (no match, or the only match is exactly
    /// what's typed already).
    private func atCandidates() -> [String] {
        guard let cwd = atPathCwd, let query = atQuery() else {
            // No `@` token any more: forget the listing and the dismissal so
            // the next `@` lists the directory afresh.
            atCache = nil
            atDismissedKey = nil
            return []
        }
        let key = cwd + "\u{0}" + query.path
        if key == atDismissedKey { return [] }
        if atDismissedKey != nil { atDismissedKey = nil }
        let candidates: [String]
        if let atCache, atCache.key == key {
            candidates = atCache.candidates
        } else {
            candidates = atPathCandidates(for: query.path, cwd: cwd)
            atCache = (key, candidates)
            atSelection = 0
            atScroll = 0
            atNavigated = false
        }
        if candidates == [query.path] { return [] }
        if atSelection >= candidates.count { atSelection = max(0, candidates.count - 1) }
        return candidates
    }

    /// Whether the `@` file popup is showing. The slash popup and modals
    /// take precedence.
    var atMenuActive: Bool {
        modalLines == nil && slashQuery() == nil && !atCandidates().isEmpty
    }

    func atMenuMove(_ delta: Int) {
        let candidates = atCandidates()
        guard !candidates.isEmpty else { return }
        atSelection = (atSelection + delta + candidates.count) % candidates.count
        atNavigated = true
    }

    /// The editor value Tab produces: the `@path` token replaced by the
    /// highlighted candidate. Nil when the popup is closed.
    func atPathCompletionForTab() -> String? {
        guard atMenuActive, let query = atQuery() else { return nil }
        let candidates = atCandidates()
        return atPathCompletedInput(query, candidate: candidates[atSelection])
    }

    /// The editor value Enter produces, only once the user picked a row
    /// with ↑/↓; otherwise nil and Enter submits the prompt as typed.
    func atPathCompletionForSubmit() -> String? {
        guard atNavigated else { return nil }
        return atPathCompletionForTab()
    }

    /// Close the `@` popup without touching the draft (first Esc). Returns
    /// false when it wasn't open.
    func dismissAtMenu() -> Bool {
        guard atMenuActive, let cwd = atPathCwd, let query = atQuery() else { return false }
        atDismissedKey = cwd + "\u{0}" + query.path
        return true
    }

    // MARK: - Render

    func render(width: Int) -> [String] {
        let safeWidth = max(0, width)
        guard safeWidth > 0 else { return [] }

        let box = renderPromptBox(width: safeWidth)
        let reserved = box.count
        let available = max(0, viewportHeight - reserved)

        var overlay: [String]
        if let modalLines {
            overlay = wrap(modalLines, width: safeWidth)
            if overlay.count > available { overlay = Array(overlay.suffix(available)) }
        } else {
            var rows = wrap(liveLines, width: safeWidth)
            // One blank line of breathing room above the footer slot. The
            // overlay (slash popup or queue list) hugs the prompt box directly
            // below it; the blank sits above the overlay, not between it and
            // the box.
            rows.append("")
            // The footer slot directly above the prompt box shows ONE overlay.
            // The slash-command popup takes priority; when it isn't open the
            // pending queue list takes the same slot. (A modal replaces this
            // whole branch.)
            let menu = renderSlashMenu(width: safeWidth)
            let atMenu = menu.isEmpty ? renderAtMenu(width: safeWidth) : []
            if !menu.isEmpty {
                rows.append(contentsOf: menu)
            } else if !atMenu.isEmpty {
                rows.append(contentsOf: atMenu)
            } else {
                rows.append(contentsOf: renderQueuedPrompts(width: safeWidth))
            }
            // Keep the most recent rows so the prompt box never gets pushed
            // off the bottom of the terminal.
            if rows.count > available { rows = Array(rows.suffix(available)) }
            overlay = rows
        }

        return (overlay + box).map { ANSI.truncate($0, to: safeWidth) }
    }

    func invalidate() {}

    private func wrap(_ source: [String], width: Int) -> [String] {
        var out: [String] = []
        for line in source {
            if line.isEmpty { out.append("") } else {
                out.append(contentsOf: ANSI.wrap(line, width: width))
            }
        }
        return out
    }

    private func renderPromptBox(width: Int) -> [String] {
        // Two-space left margin matches the welcome card, queue list, state
        // line, and slash popup so every chrome element shares one gutter.
        let margin = "  "
        let boxWidth = max(0, width - 4)

        guard boxWidth >= 6 else {
            let promptLines = promptRow.render(width: width)
            var out = promptLines.map { ANSI.truncate($0, to: width) }
            if !stateLine.isEmpty { out.append(ANSI.truncate(stateLine, to: width)) }
            return out
        }

        let promptLines = promptRow.render(width: max(1, boxWidth - 4))
        var out: [String] = []
        out.append(margin + Box.top(width: boxWidth, label: breadcrumb.isEmpty ? nil : breadcrumb))
        for line in promptLines {
            out.append(margin + Box.row(line, width: boxWidth))
        }
        out.append(margin + Box.bottom(width: boxWidth, rightLabel: metaRight.isEmpty ? nil : metaRight))
        if !stateLine.isEmpty {
            out.append("  " + ANSI.truncate(stateLine, to: max(0, width - 2)))
        }
        return out
    }

    /// The pending queued-prompt list shown above the prompt box while the
    /// agent is busy. Each entry is one dim line; a footer hint advertises how
    /// to edit/drop them. Mirrors omp's "pending messages" container.
    private func renderQueuedPrompts(width: Int) -> [String] {
        guard modalLines == nil, !queuedPrompts.isEmpty else { return [] }
        let avail = max(0, width - 4)
        var out: [String] = []
        let label = queuedPrompts.count == 1 ? "queued" : "queued (\(queuedPrompts.count))"
        out.append("  " + Theme.accentText("↓ \(label)", bold: false))
        for prompt in queuedPrompts {
            let body = prompt.isEmpty ? "(empty)" : prompt
            out.append("  " + Theme.paint("↳ ", Theme.accentDim)
                + ANSI.truncate(Theme.faintText(body), to: avail))
        }
        out.append("  " + Theme.faintText("⌥↑ edit · /queue clear to drop"))
        return out
    }

    /// The `@path` completion list that floats above the prompt box, in the
    /// same slot and style as the slash popup.
    private func renderAtMenu(width: Int) -> [String] {
        guard atMenuActive else { return [] }
        let candidates = atCandidates()
        let maxRows = min(Self.menuMaxRows, candidates.count)
        atScroll = edgeScrollOffset(
            selection: atSelection,
            count: candidates.count,
            windowSize: maxRows,
            previous: atScroll
        )
        let start = atScroll
        let visible = candidates[start..<min(candidates.count, start + maxRows)]
        let avail = max(0, width - 4)
        var out: [String] = []
        for (offset, candidate) in visible.enumerated() {
            let selected = start + offset == atSelection
            let marker = selected ? Theme.accentText("❯ ", bold: false) : "  "
            let raw = ANSI.fitTail("@" + candidate, to: avail)
            let label = selected ? Theme.accentText(raw, bold: true) : Theme.mutedText(raw)
            out.append("  " + marker + label)
        }
        let enterHint = atNavigated ? " · ↵ select" : ""
        let position = candidates.count > maxRows ? "\(atSelection + 1)/\(candidates.count) · " : ""
        out.append("  " + Theme.faintText("\(position)↑↓ move · Tab complete\(enterHint) · Esc close"))
        return out
    }

    /// The live slash-command preview that floats above the prompt box.
    private func renderSlashMenu(width: Int) -> [String] {
        guard slashQuery() != nil, modalLines == nil else { return [] }
        let matches = filteredCommands()
        guard !matches.isEmpty else {
            return ["  " + Theme.faintText("no matching commands")]
        }
        syncSelection(matches)

        let maxRows = min(Self.menuMaxRows, matches.count)
        // Scroll only at the edges: keep the current window unless the selection
        // has moved above its top or below its bottom, then shift by the minimum.
        // Up/Down thus move the highlight within the window first and only scroll
        // once it reaches an edge.
        menuScroll = edgeScrollOffset(
            selection: menuSelection,
            count: matches.count,
            windowSize: maxRows,
            previous: menuScroll
        )
        let start = menuScroll
        let visible = matches[start..<min(matches.count, start + maxRows)]

        let nameW = min(18, (matches.map { ANSI.visibleWidth("/\($0.name)") }.max() ?? 0))
        var out: [String] = []
        for (offset, m) in visible.enumerated() {
            let i = start + offset
            let selected = i == menuSelection
            let marker = selected ? Theme.accentText("❯ ", bold: false) : "  "
            let nameRaw = "/\(m.name)"
            let name = selected ? Theme.accentText(nameRaw, bold: true) : Theme.mutedText(nameRaw)
            // 2-space gutter + 2-wide marker so the selected '❯' aligns under
            // the queue list's "↓/↳" and unselected names align with bodies.
            let descAvail = max(0, width - 2 - 2 - nameW - 2)
            let desc = Theme.faintText(ANSI.fit(m.description, to: descAvail))
            out.append("  " + marker + Box.pad(name, to: nameW) + "  " + desc)
        }
        // Enter is rejected while the agent is busy (slash commands are
        // idle-only), so don't advertise "↵ run" mid-stream — only Tab. Idle,
        // "↵ run" shows only when Enter would run the highlighted row (a
        // prefix match or an ↑/↓ pick), not for a loose match or a lone `/`.
        let selectedRunnable = enterRuns(matches[menuSelection], query: slashQuery() ?? "")
        let runHint = isBusy ? " · commands run when idle" : (selectedRunnable ? " · ↵ run" : "")
        if matches.count > maxRows {
            out.append("  " + Theme.faintText("\(menuSelection + 1)/\(matches.count) · ↑↓ move · Tab complete\(runHint)"))
        } else {
            out.append("  " + Theme.faintText("↑↓ move · Tab complete\(runHint)"))
        }
        return out
    }
}
