import Foundation
import Testing
@testable import KWWKAI

@Suite("TransformMessages")
struct TransformMessagesTests {

    // MARK: - Helpers

    private func textModel(id: String = "m-1", provider: String = "p", api: String = "a") -> Model {
        Model(id: id, api: api, provider: provider, input: [.text])
    }

    private func visionModel(id: String = "m-1", provider: String = "p", api: String = "a") -> Model {
        Model(id: id, api: api, provider: provider, input: [.text, .image])
    }

    private func assistant(
        _ content: [AssistantBlock],
        provider: String = "p",
        api: String = "a",
        model: String = "m-1",
        stopReason: StopReason = .stop
    ) -> Message {
        .assistant(AssistantMessage(
            content: content, api: api, provider: provider, model: model, stopReason: stopReason
        ))
    }

    private func text(_ m: Message) -> [String] {
        switch m {
        case .user(let u):
            return u.content.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }
        case .assistant(let a):
            return a.content.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }
        case .toolResult(let r):
            return r.content.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }
        case .system:
            return []
        }
    }

    // MARK: - (a) Image downgrade

    @Test("non-vision model replaces user image with placeholder")
    func downgradeUserImage() {
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        let msgs: [Message] = [.user(UserMessage(content: [.text(TextContent(text: "look")), .image(img)]))]
        let out = TransformMessages.downgradeUnsupportedImages(msgs, model: textModel())
        #expect(text(out[0]) == ["look", TransformMessages.nonVisionUserImagePlaceholder])
    }

    @Test("vision model leaves images untouched")
    func visionKeepsImages() {
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        let msgs: [Message] = [.user(UserMessage(content: [.image(img)]))]
        let out = TransformMessages.downgradeUnsupportedImages(msgs, model: visionModel())
        #expect(out == msgs)
    }

    @Test("adjacent images collapse to a single placeholder")
    func collapseAdjacentImages() {
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        let msgs: [Message] = [.user(UserMessage(content: [.image(img), .image(img), .text(TextContent(text: "x"))]))]
        let out = TransformMessages.downgradeUnsupportedImages(msgs, model: textModel())
        #expect(text(out[0]) == [TransformMessages.nonVisionUserImagePlaceholder, "x"])
    }

    @Test("non-vision model replaces tool-result image")
    func downgradeToolImage() {
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        let msgs: [Message] = [.toolResult(ToolResultMessage(
            toolCallId: "c1", toolName: "shot", content: [.image(img)]
        ))]
        let out = TransformMessages.downgradeUnsupportedImages(msgs, model: textModel())
        #expect(text(out[0]) == [TransformMessages.nonVisionToolImagePlaceholder])
    }

    // MARK: - (b) Thinking strip

    @Test("same model keeps thinking blocks and signatures")
    func sameModelKeepsThinking() {
        let msgs: [Message] = [assistant([
            .thinking(ThinkingContent(thinking: "", thinkingSignature: "sig")),
            .text(TextContent(text: "hi")),
        ])]
        let out = TransformMessages.stripCrossModelThinking(msgs, model: textModel())
        #expect(out == msgs)
    }

    @Test("cross model downgrades non-empty thinking to text")
    func crossModelThinkingToText() {
        let msgs: [Message] = [assistant([
            .thinking(ThinkingContent(thinking: "reasoning")),
            .text(TextContent(text: "answer")),
        ], model: "other")]
        let out = TransformMessages.stripCrossModelThinking(msgs, model: textModel())
        #expect(text(out[0]) == ["reasoning", "answer"])
    }

    @Test("cross model drops redacted and empty thinking")
    func crossModelDropsRedactedAndEmpty() {
        let msgs: [Message] = [assistant([
            .thinking(ThinkingContent(thinking: "secret", redacted: true)),
            .thinking(ThinkingContent(thinking: "   ")),
            .text(TextContent(text: "answer")),
        ], model: "other")]
        let out = TransformMessages.stripCrossModelThinking(msgs, model: textModel())
        #expect(text(out[0]) == ["answer"])
        guard case .assistant(let a) = out[0] else { Issue.record("expected assistant"); return }
        #expect(a.content.count == 1)
    }

    @Test("cross model strips thought signature from tool calls")
    func crossModelStripsThoughtSignature() {
        let msgs: [Message] = [assistant([
            .toolCall(ToolCall(id: "c1", name: "f", arguments: .null, thoughtSignature: "ts")),
        ], model: "other", stopReason: .toolUse)]
        let out = TransformMessages.stripCrossModelThinking(msgs, model: textModel())
        guard case .assistant(let a) = out[0], case .toolCall(let tc) = a.content[0] else {
            Issue.record("expected tool call"); return
        }
        #expect(tc.thoughtSignature == nil)
    }

    // MARK: - (c) Error-turn skip

    @Test("errored assistant turn is skipped")
    func skipErroredTurn() {
        let msgs: [Message] = [
            .user(UserMessage(text: "hi")),
            assistant([.text(TextContent(text: "partial"))], stopReason: .error),
            .user(UserMessage(text: "retry")),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.role == .user })
    }

    @Test("aborted assistant turn is skipped")
    func skipAbortedTurn() {
        let msgs: [Message] = [assistant([.text(TextContent(text: "x"))], stopReason: .aborted)]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(out.isEmpty)
    }

    // MARK: - (d) Orphan tool calls / results

    @Test("orphaned tool call gets synthetic error result")
    func synthesizeOrphanResult() {
        let msgs: [Message] = [assistant([
            .toolCall(ToolCall(id: "c1", name: "f", arguments: .null)),
        ], stopReason: .toolUse)]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(out.count == 2)
        guard case .toolResult(let r) = out[1] else { Issue.record("expected synthetic result"); return }
        #expect(r.toolCallId == "c1")
        #expect(r.isError)
        #expect(text(out[1]) == ["No result provided"])
    }

    @Test("matched tool call and result are preserved without synthesis")
    func matchedToolResultPreserved() {
        let msgs: [Message] = [
            assistant([.toolCall(ToolCall(id: "c1", name: "f", arguments: .null))], stopReason: .toolUse),
            .toolResult(ToolResultMessage(toolCallId: "c1", toolName: "f", content: [.text(TextContent(text: "ok"))])),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(out.count == 2)
        guard case .toolResult(let r) = out[1] else { Issue.record("expected result"); return }
        #expect(r.toolCallId == "c1")
        #expect(!r.isError)
    }

    @Test("tool result orphaned by skipped errored turn is dropped")
    func dropOrphanedToolResult() {
        let msgs: [Message] = [
            assistant([.toolCall(ToolCall(id: "c1", name: "f", arguments: .null))], stopReason: .error),
            .toolResult(ToolResultMessage(toolCallId: "c1", toolName: "f", content: [.text(TextContent(text: "ok"))])),
            .user(UserMessage(text: "next")),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(out.count == 1)
        #expect(out[0].role == .user)
    }

    private func call(_ id: String, _ name: String = "f") -> AssistantBlock {
        .toolCall(ToolCall(id: id, name: name, arguments: .null))
    }

    private func toolResult(_ id: String, _ text: String = "ok", name: String = "f") -> Message {
        .toolResult(ToolResultMessage(toolCallId: id, toolName: name, content: [.text(TextContent(text: text))]))
    }

    /// Each message as a short tag, so a whole transcript's shape is one compare.
    private func shape(_ messages: [Message]) -> [String] {
        messages.map { message in
            switch message {
            case .user(let u):
                return "user:" + u.content.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }.joined()
            case .assistant(let a):
                let ids = a.content.compactMap { if case .toolCall(let tc) = $0 { return tc.id } else { return nil } }
                return "assistant[" + ids.joined(separator: ",") + "]"
            case .toolResult(let r):
                return "result:\(r.toolCallId)" + (r.isError ? "!" : "")
            case .system:
                return "system"
            }
        }
    }

    @Test("parallel calls with one result missing get one synthetic result, after the real one")
    func parallelCallsPartialResults() {
        let msgs: [Message] = [
            .user(UserMessage(text: "go")),
            assistant([call("a"), call("b"), call("c")], stopReason: .toolUse),
            toolResult("b"),
            toolResult("a"),
            .user(UserMessage(text: "next")),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(shape(out) == ["user:go", "assistant[a,b,c]", "result:b", "result:a", "result:c!", "user:next"])
    }

    @Test("a result recorded after a user message moves up to its turn instead of a synthetic one")
    func lateResultHoisted() {
        let msgs: [Message] = [
            assistant([call("a"), call("b")], stopReason: .toolUse),
            toolResult("a"),
            .user(UserMessage(text: "steer")),
            .system(SystemMessage(toolsRemoved: ["x"])),
            toolResult("b"),
            assistant([.text(TextContent(text: "done"))]),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(shape(out) == ["assistant[a,b]", "result:a", "result:b", "user:steer", "system", "assistant[]"])
        #expect(text(out[2]) == ["ok"])
    }

    @Test("a restart mid-tool leaves a call that gets a synthetic result before the resumed message")
    func restartMidTool() {
        let msgs: [Message] = [
            .user(UserMessage(text: "build")),
            assistant([call("a", "bash")], stopReason: .toolUse),
            .user(UserMessage(text: "are you there?")),
            assistant([.text(TextContent(text: "yes"))]),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(shape(out) == ["user:build", "assistant[a]", "result:a!", "user:are you there?", "assistant[]"])
    }

    @Test("a second result for the same call is dropped")
    func duplicateResultDropped() {
        let msgs: [Message] = [
            assistant([call("a")], stopReason: .toolUse),
            toolResult("a", "first"),
            toolResult("a", "again"),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(shape(out) == ["assistant[a]", "result:a"])
        #expect(text(out[1]) == ["first"])
    }

    @Test("a result for an earlier turn's call does not land in a later turn")
    func staleResultFromEarlierTurnDropped() {
        let msgs: [Message] = [
            assistant([call("a")], stopReason: .toolUse),
            .user(UserMessage(text: "interrupt")),
            assistant([call("b")], stopReason: .toolUse),
            toolResult("a"),
            toolResult("b"),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(shape(out) == ["assistant[a]", "result:a!", "user:interrupt", "assistant[b]", "result:b"])
    }

    @Test("ids reused across turns pair each result with its own turn")
    func reusedIdsAcrossTurns() {
        let msgs: [Message] = [
            assistant([call("call_0")], stopReason: .toolUse),
            toolResult("call_0", "one"),
            assistant([call("call_0")], stopReason: .toolUse),
            toolResult("call_0", "two"),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(shape(out) == ["assistant[call_0]", "result:call_0", "assistant[call_0]", "result:call_0"])
        #expect(text(out[1]) == ["one"])
        #expect(text(out[3]) == ["two"])
    }

    @Test("a result whose call was compacted away is dropped")
    func resultCutByCompactionDropped() {
        let msgs: [Message] = [
            .user(UserMessage(text: "<previous-session-summary>…</previous-session-summary>")),
            toolResult("gone"),
            assistant([.text(TextContent(text: "hi"))]),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        #expect(shape(out) == ["user:<previous-session-summary>…</previous-session-summary>", "assistant[]"])
    }

    @Test("an aborted turn between a call and its result does not cut the pair")
    func abortedTurnEndsSpan() {
        let msgs: [Message] = [
            assistant([call("a")], stopReason: .toolUse),
            assistant([call("x")], stopReason: .aborted),
            toolResult("x"),
            toolResult("a"),
        ]
        let out = TransformMessages.repairToolFlow(msgs)
        // The aborted turn still ends the span: "a" was answered too late to replay.
        #expect(shape(out) == ["assistant[a]", "result:a!"])
    }

    // MARK: - (e) Surrogate sanitization

    // Note: Swift `String`/`Unicode.Scalar` cannot natively hold a lone
    // UTF-16 surrogate (the scalar initializer returns nil for 0xD800-0xDFFF),
    // so by the time text reaches us it is already surrogate-free. The
    // sanitizer is a defensive guard that must round-trip valid text and
    // preserve valid (paired) astral characters untouched.

    @Test("clean text is returned unchanged")
    func sanitizeCleanText() {
        let s = "hello \u{1F600} world"
        #expect(TransformMessages.sanitize(s) == s)
    }

    @Test("astral characters survive sanitization")
    func sanitizeAstral() {
        // U+1F600 decomposes into a UTF-16 surrogate pair; it must be preserved.
        let s = "emoji: \u{1F600}\u{1F4A9}"
        #expect(TransformMessages.sanitize(s) == s)
    }

    @Test("sanitize pass preserves valid text inside messages")
    func sanitizeAcrossMessages() {
        let msgs: [Message] = [
            .user(UserMessage(text: "café \u{1F600}")),
            assistant([.text(TextContent(text: "naïve"))]),
        ]
        let out = TransformMessages.sanitizeSurrogates(msgs)
        #expect(text(out[0]) == ["café \u{1F600}"])
        #expect(text(out[1]) == ["naïve"])
    }

    // MARK: - Composition

    @Test("normalize composes passes: skip error then synthesize orphan")
    func normalizeComposition() {
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        let msgs: [Message] = [
            .user(UserMessage(content: [.text(TextContent(text: "go")), .image(img)])),
            assistant([.text(TextContent(text: "bad"))], stopReason: .error),
            assistant([.toolCall(ToolCall(id: "c1", name: "f", arguments: .null))], stopReason: .toolUse),
        ]
        let out = TransformMessages.normalize(msgs, model: textModel())
        // user image downgraded
        #expect(text(out[0]) == ["go", TransformMessages.nonVisionUserImagePlaceholder])
        // errored turn skipped, tool-call turn kept, synthetic result appended
        #expect(out.count == 3)
        #expect(out[1].role == .assistant)
        guard case .toolResult(let r) = out[2] else { Issue.record("expected synthetic result"); return }
        #expect(r.isError)
    }
}
