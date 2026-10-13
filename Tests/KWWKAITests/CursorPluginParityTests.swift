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

@Suite("Cursor plugin parity: region routing")
struct CursorRegionRoutingParityTests {
    /// The refusal a team served in one region only got from the global API
    /// (magpie 0984edaa; the fixture of its TestServeCursorRegion).
    static let regionRefusal = Data(#"{"error":{"code":"unauthenticated","message":"Error","details":[{"debug":{"details":{"title":"Unauthorized request.","detail":"This region is not yet available for your team"}}}]}}"#.utf8)

    /// `agentUrlConfig` as GetServerConfig answered it for a Free account,
    /// 2026-10-13, and as magpie's TestCursorAgentURL has a regional one.
    @Test("the server config names the agent API: agentUrl, else agentnUrl")
    func serverConfigNamesTheAgent() {
        let global = Data(#"{"configVersion":"x","agentUrlConfig":{"agentUrl":"https://agentn.global.api5.cursor.sh","agentnUrl":"https://agentn.global.api5.cursor.sh"}}"#.utf8)
        #expect(CursorAgentEndpoint.named(byServerConfig: global)
            == CursorAgentEndpoint(host: "agentn.global.api5.cursor.sh"))

        // Privacy mode, which every Run asks for: agentUrl, not agentnUrl.
        let regional = Data(#"{"agentUrlConfig":{"agentUrl":"https://agent.us.example/","agentnUrl":"https://agent.us.example/n"}}"#.utf8)
        #expect(CursorAgentEndpoint.named(byServerConfig: regional) == CursorAgentEndpoint(host: "agent.us.example"))

        let second = Data(#"{"agentUrlConfig":{"agentUrl":"","agentnUrl":"https://agent.eu.example:8443/n/"}}"#.utf8)
        let endpoint = CursorAgentEndpoint.named(byServerConfig: second)
        #expect(endpoint == CursorAgentEndpoint(host: "agent.eu.example", port: 8443, pathPrefix: "/n"))
        #expect(endpoint?.path("/agent.v1.AgentService/Run") == "/n/agent.v1.AgentService/Run")

        // Nothing that can be dialled over TLS is no answer.
        for body in [#"{}"#, #"{"agentUrlConfig":{}}"#, #"{"agentUrlConfig":{"agentUrl":"http://plain.example"}}"#, "down"] {
            #expect(CursorAgentEndpoint.named(byServerConfig: Data(body.utf8)) == nil)
        }
    }

    @Test("a region refusal with nothing written is tried on the agent API the config names")
    func regionRefusalReroutes() throws {
        let refusal = try #require(CursorConnectResponse.failureFromEndStream(Self.regionRefusal))
        #expect(CursorAgentProvider.shouldReroute(refusal, written: []))
        // Once something of a reply is out, running again would say it twice.
        #expect(!CursorAgentProvider.shouldReroute(refusal, written: [.text(TextContent(text: "Hel"))]))
        // A sign-in that lapsed is not a region's doing.
        let login = Data(#"{"error":{"code":"unauthenticated","message":"Error","details":[{"debug":{"error":"ERROR_NOT_LOGGED_IN","details":{"title":"Authentication error","detail":"If you are logged in, try logging out and back in."}}}]}}"#.utf8)
        #expect(!CursorAgentProvider.shouldReroute(try #require(CursorConnectResponse.failureFromEndStream(login)), written: []))
    }

    @Test("the config is asked of Cursor's API as the CLI asks it")
    func resolveAsksTheServerConfig() async throws {
        let client = SequentialStubClient()
        client.queue.append((status: 200, body: #"{"agentUrlConfig":{"agentUrl":"https://agent.us.example"}}"#))
        let endpoint = await CursorAgentEndpoint.resolve(
            apiKey: "tok", apiHost: "api2.cursor.sh", clientVersion: "cli-2026.09.23-86fc751", client: client
        )
        #expect(endpoint == CursorAgentEndpoint(host: "agent.us.example"))
        let request = try #require(client.recorded.first)
        #expect(request.url.absoluteString == "https://api2.cursor.sh/aiserver.v1.ServerConfigService/GetServerConfig")
        #expect(request.method == "POST")
        #expect(request.body == Data("{}".utf8))
        #expect(request.headers["authorization"] == "Bearer tok")
        #expect(request.headers["connect-protocol-version"] == "1")
        #expect(request.headers["x-cursor-client-type"] == "cli")
        #expect(request.headers["x-cursor-client-version"] == "cli-2026.09.23-86fc751")

        // A config Cursor cannot give leaves the Run where it was.
        client.queue.append((status: 503, body: "down"))
        #expect(await CursorAgentEndpoint.resolve(
            apiKey: "tok", apiHost: "api2.cursor.sh", clientVersion: "v", client: client
        ) == nil)
    }

    @Test("an account moved to its region's agent API stays there; another account is not moved")
    func learnedEndpointIsPerAccount() {
        let endpoints = CursorAgentEndpoints()
        #expect(endpoints.endpoint(for: "tok-a") == nil)
        endpoints.remember(CursorAgentEndpoint(host: "agent.us.example"), for: "tok-a")
        #expect(endpoints.endpoint(for: "tok-a") == CursorAgentEndpoint(host: "agent.us.example"))
        #expect(endpoints.endpoint(for: "tok-b") == nil)
    }
}

@Suite("Cursor plugin parity: the model picker")
struct CursorPickerParityTests {
    /// Cursor's picker as `AvailableModels` answers it in JSON, cut down
    /// from the plugin's context.test.mjs PICKER (whose shapes the live
    /// reply of 2026-10-13 has too).
    static let picker = Data(#"""
    {"models":[
      {"name":"claude-opus-5-5","supportsImages":true,"contextTokenLimit":300000,"contextTokenLimitForMaxMode":1000000,"supportsNonMaxMode":true,
       "variants":[
        {"parameterValues":[{"id":"context","value":"300k"},{"id":"effort","value":"medium"},{"id":"fast","value":"false"}],"isDefaultNonMaxConfig":true,"legacySlug":"claude-opus-5-5-medium"},
        {"parameterValues":[{"id":"context","value":"300k"},{"id":"effort","value":"medium"},{"id":"fast","value":"true"}],"isMaxMode":true,"legacySlug":"claude-opus-5-5-medium-fast"},
        {"parameterValues":[{"id":"context","value":"1m"},{"id":"effort","value":"medium"},{"id":"fast","value":"false"}],"isMaxMode":true,"isDefaultMaxConfig":true,"legacySlug":"claude-opus-5-5-medium"},
        {"parameterValues":[{"id":"context","value":"1m"},{"id":"effort","value":"medium"},{"id":"fast","value":"true"}],"isMaxMode":true,"legacySlug":"claude-opus-5-5-medium-fast"}]},
      {"name":"grok-4.7","supportsImages":false,"contextTokenLimit":256000,"contextTokenLimitForMaxMode":500000,"supportsNonMaxMode":true,
       "variants":[
        {"parameterValues":[{"id":"context","value":"256k"},{"id":"reasoning_effort","value":"high"}],"isDefaultNonMaxConfig":true,"legacySlug":"grok-4.7-high"},
        {"parameterValues":[{"id":"context","value":"500k"},{"id":"reasoning_effort","value":"high"}],"isMaxMode":true}]},
      {"name":"grok-4.6","supportsImages":true,"contextTokenLimit":256000,"contextTokenLimitForMaxMode":256000,"supportsNonMaxMode":true,
       "variants":[{"parameterValues":[{"id":"effort","value":"high"}],"isDefaultNonMaxConfig":true,"legacySlug":"cursor-grok-4.6-high"}]},
      {"name":"max-only","contextTokenLimit":200000,"contextTokenLimitForMaxMode":400000,"supportsNonMaxMode":false,
       "variants":[{"parameterValues":[],"legacySlug":"max-only"}]},
      {"name":"default","supportsImages":true,"supportsNonMaxMode":true,
       "variants":[{"isDefaultNonMaxConfig":true,"legacySlug":"default"}]},
      {"name":"secret","isHidden":true,"contextTokenLimit":123000,"variants":[{"legacySlug":"secret"}]},
      {"name":"tab-only","onlySupportsCmdK":true,"contextTokenLimit":123000,"variants":[{"legacySlug":"tab-only"}]}
    ]}
    """#.utf8)

    @Test("a wire id's window is the one it runs at outside Max Mode")
    func windowsByWireId() {
        let facts = CursorModelCatalog.pickerFacts(fromAvailableModels: Self.picker)
        // One id for two sizes: the 1M one is Max Mode's, never asked for.
        #expect(facts["claude-opus-5-5-medium"]?.contextWindow == 300_000)
        // An id Cursor serves in Max Mode only: the smallest size it has.
        #expect(facts["claude-opus-5-5-medium-fast"]?.contextWindow == 300_000)
        #expect(facts["grok-4.7-high"]?.contextWindow == 256_000)
        // No sizes: Cursor's limit, Max Mode's for a model served only there.
        #expect(facts["cursor-grok-4.6-high"]?.contextWindow == 256_000)
        #expect(facts["max-only"]?.contextWindow == 400_000)
        // Auto is given no limit.
        #expect(facts["default"] == CursorModelCatalog.PickerFacts(contextWindow: nil, image: true))
        #expect(facts["grok-4.7-high"]?.image == false)
        // Hidden and Tab-only models are not the agent's.
        #expect(facts["secret"] == nil)
        #expect(facts["tab-only"] == nil)
        #expect(CursorModelCatalog.pickerFacts(fromAvailableModels: Data("down".utf8)).isEmpty)
    }

    @Test("context sizes read as tokens")
    func contextSizes() {
        #expect(CursorModelCatalog.contextTokens("300k") == 300_000)
        #expect(CursorModelCatalog.contextTokens("1m") == 1_000_000)
        #expect(CursorModelCatalog.contextTokens("1.5M") == 1_500_000)
        #expect(CursorModelCatalog.contextTokens("large") == 0)
        #expect(CursorModelCatalog.contextTokens("") == 0)
    }

    @Test("the picker's window and image input win over the table and the family rule")
    func normalizeTakesThePicker() throws {
        func usable(_ id: String) -> CursorProto.UsableModel {
            CursorProto.UsableModel(
                modelId: id, displayName: id, displayNameShort: "", displayModelId: "", aliases: [], hasThinking: false
            )
        }
        let ids = ["claude-opus-5-5-medium", "grok-4.7-high", "cursor-grok-4.6-high", "gpt-9-unlisted"]
        let models = CursorModelCatalog.normalize(
            ids.map(usable), host: "api2.cursor.sh",
            picker: CursorModelCatalog.pickerFacts(fromAvailableModels: Self.picker)
        )
        let by = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        #expect(by["claude-opus-5-5-medium"]?.contextWindow == 300_000)
        #expect(by["grok-4.7-high"]?.contextWindow == 256_000)
        #expect(by["grok-4.7-high"]?.input == [.text])
        // The family rule reads grok-4.6 as text only; Cursor says images.
        #expect(by["cursor-grok-4.6-high"]?.input == [.text, .image])
        // An id the picker says nothing of keeps the defaults.
        #expect(by["gpt-9-unlisted"]?.contextWindow == 200_000)
        #expect(by["gpt-9-unlisted"]?.input == [.text, .image])
    }

    /// The bundled list carries the picker's windows as read 2026-10-13.
    /// Read off the names they were 200K for nearly every model, and for
    /// GPT-5.2 more than Cursor serves (400K against 272K).
    @Test("the bundled catalog carries the picker's windows")
    func bundledWindows() {
        func window(_ id: String) -> Int? { ModelsCatalog.model(provider: "cursor", id: id)?.contextWindow }
        #expect(window("claude-opus-5-5-medium") == 300_000)
        #expect(window("grok-4.7-high") == 256_000)
        #expect(window("gpt-5.2") == 272_000)
        #expect(window("composer-2.5") == 200_000)
        // Auto is given no limit by Cursor and keeps the default.
        #expect(window("default") == 200_000)
    }
}
