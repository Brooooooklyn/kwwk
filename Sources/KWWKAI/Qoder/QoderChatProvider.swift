import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streaming provider for Qoder and Qoder CN subscriptions
/// (`api == "qoder-chat"`).
///
/// Qoder lists no public API, so this speaks the endpoint its desktop client
/// uses: `POST <api>/algo/api/v2/service/pro/sse/agent_chat_generation`.
/// One turn is:
///
/// 1. The account's model listing (fetched once and kept) gives the chosen
///    model's entry, which the request sends back whole as `model_config`.
/// 2. The JSON body goes through the client's own base64 codec
///    (`QoderCodec`) and is signed with the COSY envelope (`QoderCosy`).
/// 3. The reply is SSE: each `data:` line is an envelope whose `body` is an
///    OpenAI chat-completion chunk (text, `reasoning_content`, `tool_calls`,
///    usage), and whose `statusCodeValue` carries a failure.
///
/// Tools are ordinary client-side tool calls in OpenAI's shape. Ported from
/// magpie `internal/gateway/qoder.go`.
public final class QoderChatProvider: APIProvider, @unchecked Sendable {
    public let api = QoderModels.api
    private let client: HTTPClient
    private let listings = Listings()

    /// The query asks for the LLM result, names the common agent, and says
    /// `Encode=1` for the body codec.
    static let chatPath = "/algo/api/v2/service/pro/sse/agent_chat_generation?FetchKeys=llm_model_result&AgentId=agent_common&Encode=1"

    /// Qoder's own line, which the caller's system prompt follows.
    static let systemPreamble = "You are a Qoder agent. Use the instructions below and the tools available to you to assist the user."

    public init(client: HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached { [self] in
            await run(out: out, model: model, context: context, options: options)
        }
        return out
    }

    // MARK: - Run

    private func run(out: AssistantMessageStream, model: Model, context: Context, options: StreamOptions?) async {
        let state = QoderStreamState(api: api, model: model)
        let site = QoderSite.of(model.provider)
        guard let auth = options?.resolvedAuth, let token = auth.token, !token.isEmpty,
              let account = QoderAccount(token: token, fields: auth.metadata) else {
            let message = state.failed(ProviderFailure(
                message: "\(site.name) sign-in is required (run /login \(site.id))", httpStatus: 401
            ))
            out.push(.error(reason: .error, error: message))
            out.end(message)
            return
        }
        let cancellation = options?.cancellation
        do {
            let baseURL = model.baseURL.isEmpty ? site.api : model.baseURL
            let listed = try await listings.model(
                model.id, baseURL: baseURL, account: account, site: site, client: client, cancellation: cancellation
            )
            let messages = TransformMessages.normalize(context.messages, model: model)
            let wire = QoderCodec.encodeRequestBody(try Self.chatBody(
                model: listed, context: context, messages: messages, options: options,
                windowCeiling: model.contextWindow
            ))
            let url = baseURL + Self.chatPath
            var headers = try QoderCosy.headers(
                url: url, account: account, body: wire, timestamp: Int64(Date().timeIntervalSince1970)
            )
            headers["Accept"] = "text/event-stream"
            headers["Cache-Control"] = "no-cache"
            headers["X-Model-Key"] = listed.key
            headers["X-Model-Source"] = listed.source
            for (name, value) in options?.headers ?? [:] { headers[name] = value }

            let (response, body) = try await client.stream(
                url: URL(string: url)!, method: "POST", headers: headers, body: Data(wire.utf8),
                cancellation: cancellation
            )
            guard (200..<300).contains(response.statusCode) else {
                throw await Self.httpFailure(response: response, body: body)
            }
            // A web page served 200 is a gateway's, not Qoder's answer
            // (magpie #1012).
            if response.value(forHTTPHeaderField: "content-type")?.lowercased().hasPrefix("text/html") == true {
                throw ProviderFailure(
                    message: "Qoder: answered \(response.statusCode) with a web page, not an API reply", httpStatus: 502
                )
            }

            out.push(.start(partial: state.snapshot()))
            let driveTask = Task {
                try await Self.drive(body: body, state: state, out: out, cancellation: cancellation)
            }
            let cancelRegistration = cancellation?.onCancel { _ in driveTask.cancel() }
            defer { cancelRegistration?.cancel() }
            try await driveTask.value

            if cancellation?.isCancelled == true {
                let aborted = state.aborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            state.closeOpenBlocks(emit: { out.push($0) })
            let final = state.snapshot()
            out.push(.done(reason: final.stopReason, message: final))
            out.end(final)
        } catch {
            if cancellation?.isCancelled == true {
                let aborted = state.aborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
            } else {
                let message = state.failed(.capture(error))
                out.push(.error(reason: .error, error: message))
                out.end(message)
            }
        }
    }

    /// Reads the reply line by line. Qoder's chunks are single `data:` lines;
    /// anything else (blanks, the timing line that closes the stream) is
    /// skipped. The turn ends at the envelope whose body is `[DONE]`, not at
    /// the chunk that names a `finish_reason`: Qoder sends the token usage in
    /// a chunk of its own after the finish, with no choices, so reading only
    /// up to the finish counted every reply as 0 tokens (measured on a real
    /// account, magpie-plugins qoder 0.2.4, `stream.test.mjs`). A stream that
    /// ends without a finish is taken as it stands, unless it stopped inside
    /// a tool call's arguments — those would run as `{}`.
    static func drive(
        body: AsyncThrowingStream<Data, Error>,
        state: QoderStreamState,
        out: AssistantMessageStream,
        cancellation: CancellationHandle?
    ) async throws {
        var splitter = QoderToolCallSplitter()
        var nativeToolIndex = -1
        var buffer = Data()
        let emit: (AssistantMessageEvent) -> Void = { out.push($0) }

        func flushText() {
            let held = splitter.flush()
            if !held.isEmpty { state.appendText(held, emit: emit) }
        }

        /// False once Qoder has said the reply is done.
        func handle(_ line: Data) throws -> Bool {
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("data:") else { return true }
            let payload = text.dropFirst("data:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let envelope = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
                return true
            }
            // The chunk rides as JSON text; one sent as an object reads the
            // same (magpie reads either).
            var inner = envelope["body"] as? String ?? ""
            if let object = envelope["body"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: object) {
                inner = String(decoding: data, as: UTF8.self)
            }
            if let status = Self.int(envelope["statusCodeValue"]), status != 200 {
                throw Self.failure(status: status, body: Data((inner.isEmpty ? payload : inner).utf8))
            }
            if inner.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return false }
            guard let chunk = (try? JSONSerialization.jsonObject(with: Data(inner.utf8))) as? [String: Any] else {
                return true
            }
            let choice = (chunk["choices"] as? [Any])?.first as? [String: Any]
            let delta = choice?["delta"] as? [String: Any] ?? [:]
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                state.appendThinking(reasoning, emit: emit)
            }
            if let content = delta["content"] as? String {
                for fragment in splitter.feed(content) {
                    switch fragment {
                    case .text(let text):
                        state.appendText(text, emit: emit)
                    case .call(let name, let arguments):
                        state.startToolCall(id: "call_" + QoderCosy.compactUUID(), name: name, emit: emit)
                        state.appendToolArguments(arguments, emit: emit)
                    }
                }
            }
            // Qoder also serves tool calls in OpenAI's way. The id it sends
            // is the one the result is answered with, so it is kept; a new
            // `index` opens the next call.
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let function = call["function"] as? [String: Any] ?? [:]
                let index = Self.int(call["index"]) ?? 0
                if index != nativeToolIndex {
                    nativeToolIndex = index
                    flushText()
                    let id = call["id"] as? String ?? ""
                    state.startToolCall(
                        id: id.isEmpty ? "call_" + QoderCosy.compactUUID() : id,
                        name: function["name"] as? String ?? "", emit: emit
                    )
                }
                if let arguments = function["arguments"] as? String, !arguments.isEmpty {
                    state.appendToolArguments(arguments, emit: emit)
                }
            }
            if let finish = choice?["finish_reason"] as? String, !finish.isEmpty {
                state.setFinishReason(finish)
            }
            // Whichever chunk carries the usage: the finishing one, or the
            // one of its own that follows it.
            if let usage = chunk["usage"] as? [String: Any] {
                state.setUsage(
                    prompt: Self.int(usage["prompt_tokens"]) ?? 0,
                    completion: Self.int(usage["completion_tokens"]) ?? 0,
                    cached: Self.int((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]) ?? 0,
                    reasoning: Self.int((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"]) ?? 0
                )
            }
            return true
        }

        var received = false
        var done = false
        do {
            reading: for try await chunk in body {
                if cancellation?.isCancelled == true { return }
                received = received || !chunk.isEmpty
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    if try !handle(Data(line)) {
                        done = true
                        break reading
                    }
                }
            }
        } catch let failure as ProviderFailure {
            throw failure
        } catch {
            if cancellation?.isCancelled == true || error is CancellationError { throw error }
            var failure = ProviderFailure.capture(error)
            failure.message = "Qoder: reading stream: \(failure.message)"
            throw failure
        }
        if cancellation?.isCancelled == true { return }
        if !done {
            if !buffer.isEmpty { _ = try handle(buffer) }
            // Nothing at all under a 200 is no API reply (magpie #1012).
            if !received {
                throw ProviderFailure(message: "Qoder: answered 200 with nothing in it, not an API reply", httpStatus: 502)
            }
            if !state.sawFinishReason, state.hasIncompleteToolArguments {
                throw ProviderFailure(message: "Qoder: stream ended before its tool call was complete")
            }
        }
        flushText()
    }

    // MARK: - Models

    /// Each account's listing, fetched on first use. A model the kept
    /// listing doesn't name gets one fresh read before it is refused: the
    /// roster changes under a long-lived process.
    private actor Listings {
        private var byAccount: [String: [QoderModelInfo]] = [:]

        func model(
            _ key: String, baseURL: String, account: QoderAccount, site: QoderSite,
            client: HTTPClient, cancellation: CancellationHandle?
        ) async throws -> QoderModelInfo {
            let cacheKey = "\(baseURL)\n\(account.uid)"
            if let found = byAccount[cacheKey]?.first(where: { $0.key == key }) { return found }
            let fresh = try await QoderModels.fetchListing(
                baseURL: baseURL, account: account, client: client, cancellation: cancellation
            )
            byAccount[cacheKey] = fresh
            guard let found = fresh.first(where: { $0.key == key }) else {
                throw ProviderFailure(message: "\(site.name): unknown or disabled model \"\(key)\"", httpStatus: 400)
            }
            return found
        }
    }

    private static func httpFailure(
        response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>
    ) async -> ProviderFailure {
        var bytes = Data()
        // A broken error body must not erase a status already received.
        do {
            for try await chunk in body {
                bytes.append(chunk)
                if bytes.count >= 1 << 20 { break }
            }
        } catch {}
        var failure = failure(status: response.statusCode, body: bytes)
        // The wait Qoder's queue names in the body stands; else the header's.
        failure.retryAfterMs = failure.retryAfterMs ?? ProviderFailure.retryDelay(response: response)
        return failure
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }
}
