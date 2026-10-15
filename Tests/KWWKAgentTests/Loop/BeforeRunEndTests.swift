import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

private actor RetryAttemptCounter {
    private var value = 0
    func next() -> Int { value += 1; return value }
    func snapshot() -> Int { value }
}

@Suite("Optional host completion policy")
struct BeforeRunEndTests {
    @Test("A host refusal resumes the same run and retains runtime context")
    func continuesSameRun() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("attempt")), .message(fauxAssistantMessage("finished"))])
        let calls = RetryAttemptCounter()
        let starts = RetryAttemptCounter()
        let ends = RetryAttemptCounter()
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel()),
            beforeRunEnd: { _, _ in
                guard await calls.next() == 1 else { return [] }
                return [.user(UserMessage(
                    content: [.text(TextContent(text: "Wait for unfinished work."))],
                    source: .runtime
                ))]
            }
        ))
        _ = agent.subscribe { event, _ in
            if case .agentStart = event { _ = await starts.next() }
            if case .agentEnd = event { _ = await ends.next() }
        }
        try await agent.prompt("work")
        #expect(await starts.snapshot() == 1)
        #expect(await ends.snapshot() == 1)
        #expect(agent.state.messages.contains { if case .user(let message) = $0 { return message.source == .runtime }; return false })
        #expect(await calls.snapshot() == 2)
    }

    @Test("An unset policy preserves natural completion")
    func defaultUnchanged() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("finished"))])
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        try await agent.prompt("work")
        #expect(agent.beforeRunEnd == nil)
        #expect(!agent.state.isStreaming)
    }

    @Test("Errors bypass the completion policy")
    func failureBypassesPolicy() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("failed", stopReason: .aborted))])
        let calls = RetryAttemptCounter()
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel()),
            beforeRunEnd: { _, _ in _ = await calls.next(); return [] }
        ))
        try await agent.prompt("work")
        #expect(await calls.snapshot() == 0)
    }

    @Test("A hard turn cap cannot be extended by host policy")
    func turnLimitWins() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("finished"))])
        let calls = RetryAttemptCounter()
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel()),
            maxTurns: 1,
            beforeRunEnd: { _, _ in _ = await calls.next(); return [.user(UserMessage(text: "continue"))] }
        ))
        try await agent.prompt("work")
        #expect(await calls.snapshot() == 0)
    }
}
