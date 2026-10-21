import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Unparsed tool-call arguments")
struct UnparsedToolArgumentsTests {
    @Test("a call whose arguments the stream broke is answered with an error, not run")
    func unparsedCallIsNotRun() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let broken = #"{"action": "send", "card": {"}"#
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    .toolCall(ToolCall(
                        id: "call_broken",
                        name: "send_card",
                        arguments: .object([:]),
                        unparsedArguments: broken
                    )),
                    fauxToolCall(name: "send_card", arguments: ["action": "send"], id: "call_whole"),
                ],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage("done")),
        ])
        let runs = RunCounter()
        let tool = AgentTool(
            name: "send_card",
            label: "send card",
            description: "sends a card",
            parameters: .object([
                "type": "object",
                "properties": .object(["action": .object(["type": "string"])]),
            ]),
            execute: { _, _, _, _ in
                await runs.bump()
                return AgentToolResult(content: [.text(TextContent(text: "sent"))])
            }
        )
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel(), tools: [tool]))
        defer { agent.retire() }
        try await agent.prompt("send it")

        let results = agent.state.messages.compactMap { message -> ToolResultMessage? in
            if case .toolResult(let result) = message { return result }
            return nil
        }
        #expect(results.map(\.toolCallId) == ["call_broken", "call_whole"])
        #expect(results.map(\.isError) == [true, false])
        let text = results.first?.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined() ?? ""
        #expect(text.contains("was not run"))
        #expect(text.contains(broken))
        #expect(await runs.count == 1)
    }
}

private actor RunCounter {
    var count = 0
    func bump() { count += 1 }
}
