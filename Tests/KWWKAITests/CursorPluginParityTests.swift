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
