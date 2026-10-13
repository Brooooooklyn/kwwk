import Foundation
import Testing
@testable import KWWKAI

/// Behaviour brought in line with magpie's cursor plugin
/// (`@magpie-community/opencode-cursor-auth` 0.2.10), the maintained
/// implementation of this wire. Each test names the plugin test or commit,
/// or the live measurement, that fixes the expectation.
@Suite("Cursor plugin parity: history")
struct CursorHistoryParityTests {

    private func rootMessages(_ messages: [Message]) -> [[String: Any]] {
        let blobStore = CursorBlobStore()
        let model = Model(id: "auto", api: "cursor-agent", provider: "cursor")
        let bytes = CursorRequestBuilder.build(
            model: model, wireModelId: model.id,
            context: Context(systemPrompt: "", messages: messages),
            conversationId: "conv-1", blobStore: blobStore, cachedCheckpoint: nil
        )
        func fields(_ data: Data, _ number: Int) -> [Data] {
            var out: [Data] = []
            var reader = ProtoReader(data)
            while let f = reader.next() {
                if f.number == number, let d = f.value.asData { out.append(d) }
            }
            return out
        }
        let run = fields(bytes, 1)[0]
        return fields(fields(run, 1)[0], 1).map { id in
            try! JSONSerialization.jsonObject(with: blobStore.get(id)!) as! [String: Any]
        }
    }

    /// The plugin's `conversation()` and Cursor's own server write an image
    /// as `{type: "image", mimeType, image: {__type: "Uint8Array", hex}}`
    /// (server `set_blob` read back 2026-10-13). As base64 under
    /// `mediaType` the picture never reached the model on a later turn.
    @Test("an earlier turn's image rides in history as Cursor's own image part")
    func imageInHistory() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let decoded = rootMessages([
            .user(UserMessage(content: [
                .image(ImageContent(data: png.base64EncodedString(), mimeType: "image/png")),
                .text(TextContent(text: "Here is a picture for later.")),
            ])),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "Got it."))],
                api: "cursor-agent", provider: "cursor", model: "auto"
            )),
            .user(UserMessage(text: "What was in it?")),
        ])
        let parts = try #require(decoded[1]["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text", "image"])
        #expect(parts[1]["mimeType"] as? String == "image/png")
        #expect(parts[1]["mediaType"] == nil)
        let image = try #require(parts[1]["image"] as? [String: Any])
        #expect(image["__type"] as? String == "Uint8Array")
        #expect(image["hex"] as? String == "89504e470d0a1a0a")
    }

    @Test("an image that is not base64 is left out, not sent as bytes it never was")
    func undecodableImage() throws {
        let decoded = rootMessages([
            .user(UserMessage(content: [
                .image(ImageContent(data: "not base64 !!", mimeType: "image/png")),
                .text(TextContent(text: "look")),
            ])),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: "cursor-agent", provider: "cursor", model: "auto"
            )),
            .user(UserMessage(text: "again")),
        ])
        let parts = try #require(decoded[1]["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text"])
    }
}

@Suite("Cursor plugin parity: empty replies")
struct CursorEmptyReplyParityTests {
    private func makeState() -> CursorStreamState {
        CursorStreamState(api: "cursor-agent", model: Model(id: "auto", api: "cursor-agent", provider: "cursor"))
    }

    /// conversation.test.mjs "a turn that ends with thinking only is an
    /// empty reply": thinking "hmm", then TurnEnded counting 3 output.
    @Test("a turn that ends with thinking only is an empty reply, asked again")
    func thinkingOnlyTurn() throws {
        let state = makeState()
        state.appendThinking("hmm", emit: { _ in })
        state.applyTurnEnded(input: 0, output: 3, cacheRead: 0, cacheWrite: 0, reasoning: 0)
        let failure = try #require(state.emptyReplyFailure(how: "Cursor ended the turn"))
        #expect(failure.message == "Cursor sent an empty reply (Cursor ended the turn; "
            + "after 3 chars of thinking, no text and no tool call; Cursor counted 3 output tokens)")
        #expect(failure.isRetryable)

        // …and so at the stream's end, where Cursor counted nothing.
        let ended = makeState()
        ended.appendThinking("hmm", emit: { _ in })
        let atEnd = try #require(ended.emptyReplyFailure(how: CursorConnectResponse.endFrameWords(Data("{}".utf8))))
        #expect(atEnd.message == "Cursor sent an empty reply (the Run's stream ended (an empty end frame); "
            + "after 3 chars of thinking, no text and no tool call)")
    }

    @Test("a turn with text or a tool call is a reply")
    func writtenTurn() {
        let text = makeState()
        text.appendThinking("hmm", emit: { _ in })
        text.appendText("hi", emit: { _ in })
        #expect(text.emptyReplyFailure(how: "Cursor ended the turn") == nil)

        // A turn of tool calls alone has done something; asking it again
        // would do it twice.
        let call = makeState()
        call.synthesizeResolvedToolCall(id: "c1", name: "bash", arguments: ["command": "ls"], emit: { _ in })
        #expect(call.emptyReplyFailure(how: "Cursor ended the turn") == nil)

        let blank = makeState()
        blank.appendText(" \n", emit: { _ in })
        #expect(blank.emptyReplyFailure(how: "Cursor ended the turn") != nil)
    }

    /// conversation.test.mjs "an empty reply says what the Run sent before
    /// it" (#60): what was not read is named by its agent.v1 field number.
    @Test("an empty reply names what Cursor sent that was not read")
    func namesTheUnread() throws {
        let state = makeState()
        state.noteUnread(update: 27)
        state.noteUnread(update: 27)
        state.noteUnread(update: 13)
        state.noteUnread(message: 9)
        let failure = try #require(state.emptyReplyFailure(how: "Cursor ended the turn"))
        #expect(failure.message == "Cursor sent an empty reply (Cursor ended the turn; "
            + "with no thinking, no text and no tool call; updates not read: #13, #27 ×2; messages not read: #9)")
    }

    @Test("an end frame's own words are kept, a long one cut short")
    func endFrameWords() {
        #expect(CursorConnectResponse.endFrameWords(Data()) == "the Run's stream ended (an empty end frame)")
        #expect(CursorConnectResponse.endFrameWords(Data(#"{"metadata":{"a":"b"}}"#.utf8))
            == #"the Run's stream ended (end frame: {"metadata":{"a":"b"}})"#)
        let long = Data("{\"metadata\":\"\(String(repeating: "z", count: 1000))\"}".utf8)
        #expect(CursorConnectResponse.endFrameWords(long).count < 420)
    }
}
