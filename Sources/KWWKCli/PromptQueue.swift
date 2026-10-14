import Foundation
import KWWKAI
import KWWKAgent

/// Concatenated text of a queued user message's text blocks (image blocks
/// are ignored). Used to restore a popped prompt back into the editor.
@MainActor
func queuedMessageBodyText(_ msg: Message) -> String {
    guard case .user(let u) = msg else { return "" }
    return u.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined(separator: "\n")
}

/// One-line preview of a queued prompt for the live pending list: text blocks
/// flattened onto a single line, with an `[image]` marker appended when the
/// queued message also carries image content.
@MainActor
func queuedPromptPreview(_ msg: Message) -> String {
    var text = queuedMessageBodyText(msg).replacingOccurrences(of: "\n", with: " ")
    if case .user(let u) = msg,
       u.content.contains(where: { if case .image = $0 { return true } else { return false } }) {
        text = text.isEmpty ? "[image]" : text + "  [image]"
    }
    return text
}

/// Tracks the prompt most recently popped back into the editor by Alt+↑ so a
/// repeat press can keep cycling through the remaining queued items instead of
/// stopping after one. Reference type so the @MainActor keybinding closures can
/// mutate it without capturing a `var` (rejected under Swift 6 concurrency).
@MainActor
final class DequeueCycleState {
    var last: Message?
}

/// One Alt+↑ dequeue-cycle step. Returns the new single-line input value to
/// install, or `nil` for a no-op (the editor holds an edited draft, or the
/// steering queue is empty). Extracted from the keybinding so the cycle logic —
/// draft protection, LIFO rotation, and newline flattening — is unit-testable.
///
/// `input` is the current editor text; `state.last` is the prompt most recently
/// popped back into the editor. When `input` still equals that popped prompt
/// (unedited), the prompt is returned to the front of the queue before the next
/// pop, so repeated presses rotate through every queued item without loss.
@MainActor
func dequeueCycleStep(input: String, state: DequeueCycleState, agent: Agent) -> String? {
    let matchesLast = state.last.map {
        input == queuedMessageBodyText($0).replacingOccurrences(of: "\n", with: " ")
    } ?? false
    // Never clobber a draft the user is mid-composing.
    guard input.isEmpty || matchesLast else { return nil }
    // Cycling onward: return the unedited prompt to the front so the next pop
    // walks back to the prior item rather than re-popping it.
    if matchesLast, let last = state.last {
        agent.pushFrontSteeringMessage(last)
    }
    guard let msg = agent.popLastSteeringMessage() else {
        state.last = nil
        return nil
    }
    state.last = msg
    return queuedMessageBodyText(msg).replacingOccurrences(of: "\n", with: " ")
}
