import Foundation
import Testing
import KWWKAI
@testable import KWWKAgent

@Suite("Structured provider recovery")
struct ProviderRecoveryTests {
    private let model = Model(
        id: "recovery-test",
        api: "faux",
        provider: "test",
        contextWindow: 100_000,
        maxTokens: 1_000
    )

    /// A stream that streams `committed output` (or a tool call), then fails
    /// with a retryable transport error; succeeds on `succeedOnAttempt`.
    private func partialThenFailAgent(
        tool: Bool,
        attempts: RecoveryAttempts,
        succeedOnAttempt: Int? = nil
    ) -> Agent {
        let model = model
        return Agent(initialState: .init(model: model), streamFn: { _, _, _ in
            let attempt = await attempts.record()
            let pair = AssistantMessageStream.makeStream()
            if attempt == succeedOnAttempt {
                let done = AssistantMessage(
                    content: [.text(TextContent(text: "recovered"))],
                    api: model.api, provider: model.provider, model: model.id,
                    stopReason: .stop
                )
                pair.continuation.push(.start(partial: done))
                pair.continuation.push(.done(reason: .stop, message: done))
                pair.continuation.end(done)
                return pair.stream
            }
            let block: AssistantBlock = tool
                ? .toolCall(ToolCall(id: "call", name: "write", arguments: .object([:])))
                : .text(TextContent(text: "committed output"))
            let partial = AssistantMessage(content: [block], api: model.api, provider: model.provider, model: model.id)
            pair.continuation.push(.start(partial: partial))
            let failure = AssistantMessage(
                content: [],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .error,
                errorMessage: "connection reset"
            )
            pair.continuation.push(.error(reason: .error, error: failure))
            pair.continuation.end(failure)
            return pair.stream
        })
    }

    @Test("streamed text and un-executed tool calls are not side effects: the turn is replayed", arguments: [false, true])
    func replaysPartialOutputWithoutSideEffects(tool: Bool) async throws {
        let attempts = RecoveryAttempts()
        let agent = partialThenFailAgent(tool: tool, attempts: attempts, succeedOnAttempt: 2)
        agent.retryBaseDelayMs = 0
        let rewinds = RecoveryAttempts()
        _ = agent.subscribe { event, _ in
            if case .streamRewind = event { await rewinds.record() }
        }
        try await agent.prompt("go")
        #expect(await attempts.count == 2)
        #expect(await rewinds.count == 1)
        let assistants = agent.state.messages.compactMap { message -> AssistantMessage? in
            if case .assistant(let assistant) = message { return assistant }; return nil
        }
        // The failed attempt is discarded, never kept beside the answer.
        #expect(assistants.count == 1)
        #expect(assistants.last?.stopReason == .stop)
    }

    @Test("output streamed to an irreversible sink is never automatically replayed", arguments: [false, true])
    func preventsReplayAfterIrreversibleOutput(tool: Bool) async throws {
        let attempts = RecoveryAttempts()
        let agent = partialThenFailAgent(tool: tool, attempts: attempts, succeedOnAttempt: 2)
        agent.retryBaseDelayMs = 0
        agent.streamsToIrreversibleSink = true
        try await agent.prompt("go")
        #expect(await attempts.count == 1)
        let final = try #require(agent.state.messages.compactMap { message -> AssistantMessage? in
            if case .assistant(let assistant) = message { return assistant }; return nil
        }.last)
        #expect(!final.content.isEmpty)
        #expect(final.stopReason == .error)
    }

    @Test("structured status and server veto override ambiguous message text", arguments: [402, 429])
    func respectsStructuredVeto(status: Int) async throws {
        let attempts = RecoveryAttempts()
        let model = model
        let agent = Agent(initialState: .init(model: model), streamFn: { _, _, _ in
            await attempts.record()
            let pair = AssistantMessageStream.makeStream()
            let message = AssistantMessage(
                content: [],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .error,
                errorMessage: "503 connection timed out",
                failure: .init(message: "busy", httpStatus: status, shouldRetry: status == 402)
            )
            pair.continuation.end(message)
            return pair.stream
        })
        agent.retryBaseDelayMs = 0
        try await agent.prompt("go")
        #expect(await attempts.count == 1)
    }

    @Test("summary retries transient failures without changing its prompt", arguments: [false, true])
    func summaryRecovery(thrown: Bool) async throws {
        let attempts = RecoveryAttempts()
        let model = model
        let request = CompactionSummaryRequest(
            messages: [.user(UserMessage(text: "preserve this work"))],
            model: model,
            sessionId: "live",
            config: .init(summaryRetryPolicy: .init(baseDelayMs: 0)),
            previousSummary: nil,
            kind: .history,
            reasoning: nil,
            authResolver: nil,
            stream: { _, context, options in
                let index = await attempts.record(context: context)
                #expect(options?.sessionId != "live")
                if index == 1 && thrown { throw URLError(.timedOut) }
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: index == 1 ? [] : [.text(TextContent(text: "durable summary"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    stopReason: index == 1 ? .error : .stop,
                    errorMessage: index == 1 ? "busy" : nil,
                    failure: index == 1 ? .init(message: "busy", httpStatus: 503) : nil
                ))
                return pair.stream
            },
            cancellation: nil
        )
        let summary = try await CompactionSummaryGenerator.generate(request)
        #expect(summary == "durable summary")
        #expect(await attempts.count == 2)
        let contexts = await attempts.contexts
        #expect(contexts[0].messages == contexts[1].messages)
        #expect(contexts[0].systemPrompt == contexts[1].systemPrompt)
    }
}

private actor RecoveryAttempts {
    var count = 0
    var contexts: [Context] = []
    @discardableResult func record(context: Context? = nil) -> Int {
        count += 1
        if let context { contexts.append(context) }
        return count
    }
}
