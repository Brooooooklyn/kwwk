import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI /v1/chat/completions streaming provider. Also usable against any
/// wire-compatible endpoint — Groq, xAI, OpenRouter, Cerebras, HuggingFace,
/// Ollama, and OpenAI-compat proxies all work by swapping `model.baseURL`.
///
/// Differences from Anthropic:
///  - Single SSE event stream, `data: {json}` lines, terminated by
///    `data: [DONE]`.
///  - `choices[0].delta.content` streams text; `delta.tool_calls[i]` streams
///    tool calls; `delta.reasoning` / `delta.reasoning_content` streams
///    thinking (some backends, like Groq/OpenRouter/Ollama, expose this).
///  - Tool calls arrive as `tool_calls: [{index, id, function: {name,
///    arguments}}]` — arguments are incremental JSON strings that must be
///    concatenated across deltas.
///  - `tool_choice` and `parallel_tool_calls` live at the request root.
public final class OpenAICompletionsProvider: APIProvider, @unchecked Sendable {
    public typealias URLBuilder = @Sendable (Model, StreamOptions?, URL) -> URL
    public typealias AuthHeaderBuilder = @Sendable (String) -> [String: String]
    /// Hook that receives the already-encoded JSON request body (as a mutable
    /// dictionary) and lets callers inject extra fields. Used by the Copilot
    /// variant to stamp per-turn headers that depend on the messages.
    public typealias BodyDecorator = @Sendable (inout [String: Any], Model, Context, StreamOptions?) -> Void
    public typealias HeadersDecorator = @Sendable (inout [String: String], Model, Context, StreamOptions?) -> Void

    public let api: String
    public let client: HTTPClient
    public let defaultBaseURL: URL
    public let defaultAPIKey: String?
    public let extraHeaders: [String: String]
    public let urlBuilder: URLBuilder
    public let authHeaderBuilder: AuthHeaderBuilder
    public let bodyDecorator: BodyDecorator?
    public let headersDecorator: HeadersDecorator?

    public init(
        api: String = "openai-completions",
        client: HTTPClient = URLSessionHTTPClient(),
        defaultBaseURL: URL = URL(string: "https://api.openai.com")!,
        defaultAPIKey: String? = nil,
        extraHeaders: [String: String] = [:],
        urlBuilder: URLBuilder? = nil,
        authHeaderBuilder: AuthHeaderBuilder? = nil,
        bodyDecorator: BodyDecorator? = nil,
        headersDecorator: HeadersDecorator? = nil
    ) {
        self.api = api
        self.client = client
        self.defaultBaseURL = defaultBaseURL
        self.defaultAPIKey = defaultAPIKey
        self.extraHeaders = extraHeaders
        self.urlBuilder = urlBuilder ?? { model, _, fallback in
            var base = model.baseURL.isEmpty ? fallback.absoluteString : model.baseURL
            while base.hasSuffix("/") { base.removeLast() }
            // Cloudflare catalog entries may carry literal `{CLOUDFLARE_*}`
            // placeholders. The generic provider never reads the process
            // environment; provider variants that support Cloudflare pass
            // explicit values through their own URL builders.
            base = substituteCloudflarePlaceholders(in: base, value: { _ in nil })
            // Tolerate catalog entries that bake a version segment into
            // baseURL — pi-mono's models.generated.ts does this for OpenAI
            // (`…/v1`) and Z.AI (`…/coding/paas/v4`). Without this, the
            // session baseURL `https://api.openai.com` → `/v1/chat/completions`,
            // but a `/model` swap pulls in `https://api.openai.com/v1` and
            // we'd double-suffix; Z.AI's `/v4` would gain a bogus `/v1`.
            let lastSegment = base.split(separator: "/").last ?? ""
            let alreadyVersioned = lastSegment.count > 1
                && lastSegment.first == "v"
                && lastSegment.dropFirst().allSatisfy(\.isNumber)
            let versioned = alreadyVersioned ? base : "\(base)/v1"
            return URL(string: "\(versioned)/chat/completions")
                ?? fallback.appendingPathComponent("v1/chat/completions")
        }
        self.authHeaderBuilder = authHeaderBuilder ?? { key in ["Authorization": bearerHeaderValue(key)] }
        self.bodyDecorator = bodyDecorator
        self.headersDecorator = headersDecorator
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached {
            await self.run(out: out, model: model, context: context, options: options)
        }
        return out
    }

    private func run(
        out: AssistantMessageStream,
        model: Model,
        context: Context,
        options: StreamOptions?
    ) async {
        let url = urlBuilder(model, options, defaultBaseURL)

        let body: Data
        do {
            var root = try Self.encodeBodyDict(model: model, context: context, options: options)
            bodyDecorator?(&root, model, context, options)
            body = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        } catch {
            let msg = AssistantMessage.makeError(api: api, model: model, text: "Failed to encode request: \(error)")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
            return
        }

        var headers: [String: String] = [
            "content-type": "application/json",
            "accept": "text/event-stream",
        ]
        for (k, v) in model.headers ?? [:] { headers[k] = v }
        for (k, v) in extraHeaders { headers[k] = v }
        if let auth = options?.resolvedAuth {
            applyResolvedAuth(auth, to: &headers)
        } else if let key = options?.apiKey ?? defaultAPIKey {
            for (k, v) in authHeaderBuilder(key) { headers[k] = v }
        }
        let compat = Self.resolveCompat(model)
        let retention = options?.cacheRetention ?? .short
        if retention != .none,
           let sid = options?.sessionId, !sid.isEmpty,
           compat.sendSessionAffinityHeaders {
            // pi #6496: OpenRouter uses a single `x-session-id` header;
            // OpenAI-style providers take the session_id/affinity trio.
            switch compat.sessionAffinityFormat {
            case "openrouter":
                headers["x-session-id"] = sid
            case "openai-nosession":
                headers["x-client-request-id"] = sid
                headers["x-session-affinity"] = sid
            default:
                headers["session_id"] = sid
                headers["x-client-request-id"] = sid
                headers["x-session-affinity"] = sid
            }
        }
        // Grok keys a conversation's prompt cache by `x-grok-conv-id`; the
        // Grok Build CLI names every request's conversation there
        // (magpie-plugins packages/grok index.mjs). Chat Completions on xAI
        // carries no `prompt_cache_key`, so this is the only name it gets.
        if compat.isXai, retention != .none,
           let sid = Self.clampOpenAIPromptCacheKey(options?.sessionId) {
            headers["x-grok-conv-id"] = sid
        }
        headersDecorator?(&headers, model, context, options)
        for (k, v) in options?.headers ?? [:] { headers[k] = v }

        do {
            let (response, stream) = try await client.stream(
                url: url,
                method: "POST",
                headers: headers,
                body: body,
                cancellation: options?.cancellation
            )
            if response.statusCode >= 400 {
                let failure = await ProviderFailure.http(response, body: stream)
                let msg = AssistantMessage.makeError(api: api, model: model, text: failure.message, failure: failure)
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
                return
            }
            let state = OpenAICompletionsState(api: api, provider: model.provider, modelId: model.id, model: model)
            state.signal = options?.cancellation
            // Bridge external cancellation to the in-flight request (see
            // AnthropicProvider.run for the rationale).
            let driveTask = Task { try await self.drive(events: parseSSE(bytes: stream), out: out, state: state) }
            let cancelReg = options?.cancellation?.onCancel { _ in driveTask.cancel() }
            defer { cancelReg?.cancel() }
            try await driveTask.value
        } catch {
            if options?.cancellation?.isCancelled == true {
                let aborted = AssistantMessage.makeAborted(api: api, model: model)
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
            } else {
                let msg = AssistantMessage.makeError(api: api, model: model, text: "\(error)", failure: .capture(error))
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
            }
        }
    }

    private func drive(
        events: AsyncThrowingStream<SSEMessage, Error>,
        out: AssistantMessageStream,
        state: OpenAICompletionsState
    ) async throws {
        var emittedStart = false
        var hasFinishReason = false
        for try await sse in events {
            if state.signal?.isCancelled == true {
                let aborted = state.asAborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            // `[DONE]` sentinel ends the stream.
            if sse.data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                state.finalizeStreamingBlocks(emit: { event in out.push(event) })
                if validateAndFinish(out: out, state: state, hasFinishReason: hasFinishReason) { return }
                let final = state.finalize()
                out.push(.done(reason: final.stopReason, message: final))
                out.end(final)
                return
            }
            guard case .object(let obj)? = parseJSONObject(sse.data) else { continue }
            if let payload = obj["error"], payload != .null {
                let failure = ProviderFailure.payload(.object(obj))
                var message = state.snapshot()
                message.stopReason = .error
                message.errorMessage = failure.message
                message.failure = failure
                out.push(.error(reason: .error, error: message))
                out.end(message)
                return
            }

            // Usage is sent on the final chunk of some providers.
            if case .object(let usage) = obj["usage"] ?? .null {
                state.applyUsage(usage)
            }
            // Response ID: set on first chunk.
            if state.responseId == nil,
               case .string(let id) = obj["id"] ?? .null {
                state.responseId = id
            }

            // choices[0].delta carries incremental content.
            guard case .array(let choices) = obj["choices"] ?? .null,
                  let first = choices.first,
                  case .object(let choice) = first else { continue }

            // Moonshot reports usage on the choice rather than the chunk root.
            if case .object(let usageObj) = obj["usage"] ?? .null {
                _ = usageObj // already applied above; avoid double-apply
            } else if case .object(let choiceUsage) = choice["usage"] ?? .null {
                state.applyUsage(choiceUsage)
            }

            if case .object(let delta) = choice["delta"] ?? .null {
                // Text content delta.
                if case .string(let text) = delta["content"] ?? .null, !text.isEmpty {
                    let (index, firstSeen) = state.noteTextBlock()
                    if !emittedStart {
                        out.push(.start(partial: state.snapshot()))
                        emittedStart = true
                    }
                    if firstSeen {
                        out.push(.textStart(contentIndex: index, partial: state.snapshot()))
                    }
                    state.appendText(index: index, text: text)
                    out.push(.textDelta(contentIndex: index, delta: text, partial: state.snapshot()))
                }
                // Reasoning content delta (provider-specific key). Probe in pi's
                // order — `reasoning_content` (DeepSeek/chutes) first, then
                // `reasoning` (OpenRouter), then `reasoning_text`. The matched
                // field name is stashed as the thinking block's signature so the
                // encoder can round-trip prior reasoning under the same key.
                let reasoningField: (field: String, text: String)? = {
                    if case .string(let r) = delta["reasoning_content"] ?? .null { return ("reasoning_content", r) }
                    if case .string(let r) = delta["reasoning"] ?? .null { return ("reasoning", r) }
                    if case .string(let r) = delta["reasoning_text"] ?? .null { return ("reasoning_text", r) }
                    return nil
                }()
                if let (field, reasoning) = reasoningField, !reasoning.isEmpty {
                    let (index, firstSeen) = state.noteThinkingBlock()
                    if !emittedStart {
                        out.push(.start(partial: state.snapshot()))
                        emittedStart = true
                    }
                    if firstSeen {
                        state.setThinkingSignature(index: index, signature: field)
                        out.push(.thinkingStart(contentIndex: index, partial: state.snapshot()))
                    }
                    state.appendThinking(index: index, text: reasoning)
                    out.push(.thinkingDelta(contentIndex: index, delta: reasoning, partial: state.snapshot()))
                }
                // Tool calls — each entry is indexed by `index` and may
                // partially populate id/name/arguments.
                //
                // Relays stray from that shape, and magpie's Chat decoder
                // records each way one did: a fragment with no `index` is
                // read at its place in the list, and a new id on an index
                // whose call already has another id starts the next call
                // (parallel calls all sent at index 0) rather than being
                // spliced into the open one's arguments (magpie #395).
                // WorkBuddy repeats `"function": {"name": ""}` on every
                // argument fragment after the first (magpie chattidy.go), so
                // an empty id or name says nothing and never replaces the
                // real one. A fragment naming no function never opens a call
                // while one is open, whatever id or index it carries; and
                // arguments that close and then go on are merged when the
                // call ends (`StreamedToolArguments`).
                if case .array(let toolCalls) = delta["tool_calls"] ?? .null {
                    for (position, entry) in toolCalls.enumerated() {
                        guard case .object(let call) = entry else { continue }
                        let rawIndex: Int = {
                            if case .int(let index) = call["index"] ?? .null { return index }
                            return position
                        }()
                        let id: String? = {
                            if case .string(let id) = call["id"] ?? .null, !id.isEmpty { return id }
                            return nil
                        }()
                        let function: [String: JSONValue]? = {
                            if case .object(let function) = call["function"] ?? .null { return function }
                            return nil
                        }()
                        let name: String? = {
                            if case .string(let name) = function?["name"] ?? .null, !name.isEmpty { return name }
                            return nil
                        }()
                        let (contentIndex, firstSeen) = state.noteToolCallBlock(at: rawIndex, id: id, name: name)
                        if !emittedStart {
                            out.push(.start(partial: state.snapshot()))
                            emittedStart = true
                        }
                        if let id {
                            state.updateToolCallID(rawIndex: rawIndex, id: id)
                        }
                        if let function {
                            if let name {
                                state.updateToolCallName(rawIndex: rawIndex, name: name)
                            }
                            if firstSeen {
                                out.push(.toolCallStart(contentIndex: contentIndex, partial: state.snapshot()))
                            }
                            if case .string(let args) = function["arguments"] ?? .null, !args.isEmpty {
                                state.appendToolCallArgs(rawIndex: rawIndex, chunk: args)
                                out.push(.toolCallDelta(
                                    contentIndex: contentIndex,
                                    delta: args,
                                    partial: state.snapshot()
                                ))
                            }
                        }
                    }
                }
                // Encrypted reasoning details (OpenRouter / providers that round-trip
                // opaque reasoning). Each `{type:"reasoning.encrypted", id, data}` is
                // serialized verbatim and attached to the tool call with matching id.
                if case .array(let details) = delta["reasoning_details"] ?? .null {
                    for d in details {
                        guard case .object(let detail) = d,
                              case .string("reasoning.encrypted") = detail["type"] ?? .null,
                              case .string(let id) = detail["id"] ?? .null, !id.isEmpty,
                              case .string(let data) = detail["data"] ?? .null, !data.isEmpty else { continue }
                        if let any = anyFromJSONValue(.object(detail)),
                           let raw = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
                           let serialized = String(data: raw, encoding: .utf8) {
                            state.applyReasoningDetail(id: id, serialized: serialized)
                        }
                    }
                }
            }

            // WorkBuddy's stream carries `"finish_reason": ""` on every chunk
            // that has not finished, where the contract has null (magpie
            // chattidy.go). An empty string is not a reason: read as one it
            // closed every block after its first delta.
            if case .string(let reason) = choice["finish_reason"] ?? .null, !reason.isEmpty {
                state.stopReason = Self.mapStopReason(reason)
                if state.stopReason == .error, state.errorMessage == nil {
                    state.errorMessage = "Provider finish_reason: \(reason)"
                    state.failure = ProviderFailure(message: state.errorMessage!, rawStopReason: reason)
                }
                hasFinishReason = true
                state.finalizeStreamingBlocks(emit: { event in out.push(event) })
            }
        }

        state.finalizeStreamingBlocks(emit: { event in out.push(event) })
        if validateAndFinish(out: out, state: state, hasFinishReason: hasFinishReason) { return }
        let final = state.finalize()
        out.push(.done(reason: final.stopReason, message: final))
        out.end(final)
    }

    /// Post-stream validation mirroring pi's openai-completions end-of-stream
    /// checks: aborted/error stop reasons and a missing `finish_reason` are
    /// surfaced as error events rather than a silent successful completion.
    /// Returns true if it emitted a terminal event (caller should return).
    private func validateAndFinish(
        out: AssistantMessageStream,
        state: OpenAICompletionsState,
        hasFinishReason: Bool
    ) -> Bool {
        if state.signal?.isCancelled == true || state.stopReason == .aborted {
            let m = state.asAborted()
            out.push(.error(reason: .aborted, error: m))
            out.end(m)
            return true
        }
        if state.stopReason == .error {
            var m = state.finalize()
            m.stopReason = .error
            m.errorMessage = state.errorMessage ?? "Provider returned an error stop reason"
            m.failure = state.failure
            out.push(.error(reason: .error, error: m))
            out.end(m)
            return true
        }
        if !hasFinishReason {
            var m = state.finalize()
            m.stopReason = .error
            m.errorMessage = "Stream ended without finish_reason"
            out.push(.error(reason: .error, error: m))
            out.end(m)
            return true
        }
        return false
    }

    private static func mapStopReason(_ raw: String) -> StopReason {
        switch raw {
        case "stop", "end": return .stop
        case "length", "max_tokens": return .length
        case "tool_calls", "function_call": return .toolUse
        // pi surfaces these as errors rather than a clean stop so the agent
        // doesn't treat a filtered/aborted turn as a successful completion.
        // Z.ai ends a 200 stream with `model_context_window_exceeded` when
        // the conversation no longer fits and Zhipu with `sensitive` when its
        // content review blocks the reply; neither is a finished answer. The
        // raw reason is kept on the failure, where the first classifies as a
        // context overflow and the second as a refusal.
        case "content_filter", "network_error", "model_context_window_exceeded", "sensitive": return .error
        default: return .stop
        }
    }
}

/// Expand Cloudflare base-URL placeholders (`{CLOUDFLARE_ACCOUNT_ID}` /
/// `{CLOUDFLARE_GATEWAY_ID}`) from an explicit value source. Mirrors pi's
/// `resolveCloudflareBaseUrl`: the catalog stores the literal tokens in
/// `model.baseURL` and they are substituted at request time.
/// Unknown/missing values collapse to the empty string.
func substituteCloudflarePlaceholders(
    in baseURL: String,
    value: (String) -> String?
) -> String {
    guard baseURL.contains("{CLOUDFLARE_") else { return baseURL }
    var result = baseURL
    for token in ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_GATEWAY_ID"] {
        let needle = "{\(token)}"
        guard result.contains(needle) else { continue }
        result = result.replacingOccurrences(of: needle, with: value(token) ?? "")
    }
    return result
}
