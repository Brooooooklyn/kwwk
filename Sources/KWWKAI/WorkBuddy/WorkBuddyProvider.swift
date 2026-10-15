import Foundation

/// WorkBuddy's plan: chat completions at `<endpoint>/v2/chat/completions`,
/// streamed only ("Non-stream chat request is currently not supported",
/// magpie #124), under the account's access token with its id and domain in
/// headers.
///
/// The wire is OpenAI's, so `OpenAICompletionsProvider` speaks it, and reads
/// its stream's own turns: `"finish_reason": ""` on every chunk that hasn't
/// finished, an empty `reasoning_content` and `"tool_calls": []` on every
/// delta, an empty name repeated on a call's argument fragments (magpie
/// `chattidy.go`). What is WorkBuddy's own goes around it: the client's
/// headers and the chat's ids, the body's mends, tools in shapes its models
/// take with the model's calls named back, the tool choice as the string its
/// gateway takes, and its refusals in its own words.
public struct WorkBuddyProvider: APIProvider {
    public let api = "openai-completions"
    public let site: WorkBuddySite
    private let completions: OpenAICompletionsProvider

    public init(site: WorkBuddySite, client: HTTPClient = URLSessionHTTPClient()) {
        self.site = site
        completions = OpenAICompletionsProvider(
            client: client,
            defaultBaseURL: URL(string: site.chatBaseURL)!,
            extraHeaders: WorkBuddyWire.clientHeaders(site),
            bodyDecorator: { root, _, _, _ in
                WorkBuddyWire.mendMessages(&root)
                WorkBuddyWire.mendToolChoice(&root)
            },
            headersDecorator: { headers, _, context, options in
                let ids = WorkBuddyWire.conversationHeaders(context: context, sessionId: options?.sessionId)
                for (name, value) in ids { headers[name] = value }
            }
        )
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let fitted = WorkBuddyWire.fit(context.tools ?? [])
        var context = context
        var options = options
        if context.tools != nil { context.tools = fitted.tools }
        if !fitted.sent.isEmpty {
            // A call in the chat's history is named as its tool now is.
            context.messages = context.messages.map { Self.renamed($0, fitted.sent) }
            if case .tool(let name)? = options?.toolChoice, let sent = fitted.sent[name] {
                options?.toolChoice = .tool(name: sent)
            }
        }
        let upstream = completions.stream(model: model, context: context, options: options)
        let out = AssistantMessageStream()
        Task.detached {
            for await event in upstream {
                out.push(Self.relayed(event, names: fitted.original))
            }
            out.end(Self.relayed(await upstream.result(), names: fitted.original))
        }
        return out
    }

    // MARK: - Relay

    /// An event as the caller reads it: the model's calls under the names the
    /// caller gave its tools, a failure in WorkBuddy's own words.
    static func relayed(_ event: AssistantMessageEvent, names: [String: String]) -> AssistantMessageEvent {
        func own(_ message: AssistantMessage) -> AssistantMessage { relayed(message, names: names) }
        switch event {
        case .start(let partial):
            return .start(partial: own(partial))
        case .textStart(let index, let partial):
            return .textStart(contentIndex: index, partial: own(partial))
        case .textDelta(let index, let delta, let partial):
            return .textDelta(contentIndex: index, delta: delta, partial: own(partial))
        case .textEnd(let index, let content, let partial):
            return .textEnd(contentIndex: index, content: content, partial: own(partial))
        case .thinkingStart(let index, let partial):
            return .thinkingStart(contentIndex: index, partial: own(partial))
        case .thinkingDelta(let index, let delta, let partial):
            return .thinkingDelta(contentIndex: index, delta: delta, partial: own(partial))
        case .thinkingEnd(let index, let content, let partial):
            return .thinkingEnd(contentIndex: index, content: content, partial: own(partial))
        case .toolCallStart(let index, let partial):
            return .toolCallStart(contentIndex: index, partial: own(partial))
        case .toolCallDelta(let index, let delta, let partial):
            return .toolCallDelta(contentIndex: index, delta: delta, partial: own(partial))
        case .toolCallEnd(let index, var call, let partial):
            call.name = names[call.name] ?? call.name
            return .toolCallEnd(contentIndex: index, toolCall: call, partial: own(partial))
        case .done(let reason, let message):
            return .done(reason: reason, message: own(message))
        case .error(let reason, let message):
            return .error(reason: reason, error: own(message))
        }
    }

    static func relayed(_ message: AssistantMessage, names: [String: String]) -> AssistantMessage {
        var message = message
        if !names.isEmpty {
            message.content = message.content.map { block in
                guard case .toolCall(var call) = block, let own = names[call.name] else { return block }
                call.name = own
                return .toolCall(call)
            }
        }
        if message.stopReason == .error, let failure = message.failure {
            let explained = WorkBuddyWire.explained(failure)
            message.failure = explained
            message.errorMessage = explained.message
        }
        return message
    }

    private static func renamed(_ message: Message, _ sent: [String: String]) -> Message {
        switch message {
        case .assistant(var assistant):
            assistant.content = assistant.content.map { block in
                guard case .toolCall(var call) = block, let name = sent[call.name] else { return block }
                call.name = name
                return .toolCall(call)
            }
            return .assistant(assistant)
        case .toolResult(var result):
            result.toolName = sent[result.toolName] ?? result.toolName
            return .toolResult(result)
        case .user, .system:
            return message
        }
    }
}

// MARK: - Registration

/// Registers a stored WorkBuddy login (`registerStored`'s case for both
/// builds). Each request is signed with the account's token, renewed when it
/// is about to end, and the headers that name the account.
func registerWorkBuddy(
    site: WorkBuddySite,
    manager: OAuthManager,
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
    // Prime the token only for the active provider; the resolver renews it
    // on the first request for the others.
    if primeToken {
        _ = try? await manager.apiKey(for: site.id)
    }
    await APIRegistry.shared.register(WorkBuddyProvider(site: site), scope: site.id)
    let model = WorkBuddyModels.model(site: site, id: modelOverride ?? WorkBuddyModels.defaultModelId(for: site))
    return ResolvedAuth(
        model: model,
        modelLabel: "\(model.id) · \(site.name)",
        authResolver: { _, _ in
            do {
                let authorization = try await manager.authorization(for: site.id)
                // Read after the token: a refresh may have changed the domain.
                guard let credentials = try await manager.credentials(for: site.id) else { return nil }
                return ResolvedProviderAuth(
                    token: authorization.apiKey,
                    scheme: .bearer,
                    headers: WorkBuddyOAuth.accountHeaders(credentials, site: site),
                    onRejected: authorization.onRejected
                )
            } catch OAuthError.missing, OAuthError.unknownProvider {
                // Not signed in ⇒ anonymous, as the other stored logins'
                // resolvers; any other failure reaches the request.
                return nil
            }
        }
    )
}
