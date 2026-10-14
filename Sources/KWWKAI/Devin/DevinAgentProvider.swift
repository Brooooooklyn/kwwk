import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streaming provider for Devin subscription models (`api == "devin-agent"`).
///
/// Devin's CLI talks to Codeium's Cascade backend over the Connect protocol
/// (HTTP/1.1, protobuf bodies). One turn is:
///
/// 1. `AuthService/GetUserJwt` exchanges the session token for a user JWT
///    (and optionally a per-account API server URL).
/// 2. Router models (`adaptive`) first call `AssignModel` to get the concrete
///    model uid plus an assignment JWT.
/// 3. `ApiServerService/GetChatMessage` takes a gzip-compressed Connect
///    request frame and server-streams `GetChatMessageResponse` deltas (text,
///    thinking, tool calls, usage) until an end-of-stream trailer.
///
/// Tools are ordinary client-side tool calls: the model emits them and the
/// agent loop runs them, like any other provider. Ported from oh-my-pi's
/// `streamDevin`.
public final class DevinAgentProvider: APIProvider, @unchecked Sendable {
    public let api = "devin-agent"
    public let defaultAPIKey: String?
    private let client: HTTPClient

    static let defaultStopPatterns = ["<|user|>", "<|bot|>", "<|context_request|>", "<|endoftext|>", "<|end_of_turn|>"]

    /// Connect frame flags: bit 0x01 = gzip payload, 0x02 = end-of-stream trailer.
    static let compressedFlag: UInt8 = 0x01
    static let endStreamFlag: UInt8 = 0x02
    /// Cap on a single Connect frame payload so a corrupt length prefix fails
    /// fast instead of buffering gigabytes.
    static let maxFramePayload = 16 * 1024 * 1024
    /// History size above which an opaque `invalid_argument` "internal error"
    /// trailer is treated as context overflow (triggers compaction).
    static let largeHistoryRecoveryBytes = 512 * 1024

    public init(client: HTTPClient = URLSessionHTTPClient(), defaultAPIKey: String? = nil) {
        self.client = client
        self.defaultAPIKey = defaultAPIKey
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached { [self] in
            await run(out: out, model: model, context: context, options: options)
        }
        return out
    }

    /// The model uid sent on the wire. Devin selects reasoning effort by model
    /// uid (`claude-opus-5-high`, …); the catalog's `thinkingLevelMap` routes
    /// each level of a collapsed family to its member uid.
    static func wireModelId(model: Model, reasoning: ReasoningLevel?) -> String {
        guard let map = model.thinkingLevelMap else { return model.id }
        let clamped = clampThinkingLevel(model, ModelThinkingLevel(reasoning: reasoning))
        if let entry = map[clamped.rawValue], let mapped = entry { return mapped }
        return model.id
    }

    // MARK: - Run

    private func run(out: AssistantMessageStream, model: Model, context: Context, options: StreamOptions?) async {
        let state = DevinStreamState(api: api, model: model)
        guard let apiKey = options?.resolvedAuth?.token ?? options?.apiKey ?? defaultAPIKey, !apiKey.isEmpty else {
            let msg = state.failed(ProviderFailure(message: "Devin session token is required (run /login devin)"))
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
            return
        }
        let cancellation = options?.cancellation
        do {
            let baseURL = Self.baseURL(model)
            let auth = try await fetchAuth(apiKey: apiKey, baseURL: baseURL, cancellation: cancellation)
            let chatBaseURL = auth.baseURL ?? baseURL
            let cascadeId = options?.sessionId.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            let messages = TransformMessages.normalize(context.messages, model: model)

            var assignment: DevinProto.ModelAssignment?
            if model.compat?.modelRouter == true {
                let assigned = try await assignModel(
                    model: model, apiKey: auth.apiKey, cascadeId: cascadeId,
                    messages: messages, baseURL: chatBaseURL, cancellation: cancellation
                )
                assignment = assigned
                state.setResponseModel(assigned.modelUid)
            }

            let request = Self.buildChatRequest(
                model: model, context: context, messages: messages, options: options,
                apiKey: auth.apiKey, userJwt: auth.userJwt, cascadeId: cascadeId, assignment: assignment
            )
            let requestBytes = request.encode()
            let compressed = try Gzip.compress(requestBytes)
            var frame = Data([Self.compressedFlag])
            frame.append(Self.bigEndian(UInt32(compressed.count)))
            frame.append(compressed)

            var headers: [String: String] = [
                "content-type": "application/connect+proto",
                "connect-protocol-version": "1",
                "connect-content-encoding": "gzip",
                "connect-accept-encoding": "gzip",
                "accept-encoding": "identity",
                "user-agent": DevinWire.connectUserAgent,
            ]
            for (k, v) in options?.headers ?? [:] { headers[k] = v }

            let url = URL(string: chatBaseURL + DevinWire.getChatMessagePath)!
            let (response, body) = try await client.stream(
                url: url, method: "POST", headers: headers, body: frame, cancellation: cancellation
            )
            if response.statusCode >= 400 {
                throw await Self.httpFailure(operation: "API", response: response, body: body)
            }

            out.push(.start(partial: state.snapshot()))
            let driveTask = Task {
                try await self.drive(
                    body: body, state: state, out: out, cancellation: cancellation,
                    historyBytes: { Self.shrinkableHistoryBytes(request: request, context: context) }
                )
            }
            let cancelReg = cancellation?.onCancel { _ in driveTask.cancel() }
            defer { cancelReg?.cancel() }
            try await driveTask.value

            if cancellation?.isCancelled == true {
                let aborted = state.aborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            state.closeOpenBlocks(emit: { out.push($0) })
            let final = state.finalize()
            out.push(.done(reason: final.stopReason, message: final))
            out.end(final)
        } catch {
            if cancellation?.isCancelled == true {
                let aborted = state.aborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
            } else {
                let msg = state.failed(.capture(error))
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
            }
        }
    }

    /// Read Connect frames off the response body and feed each decoded delta
    /// into `state`.
    ///
    /// Every reply Devin sends ends with an end-of-stream frame (flags 0x03,
    /// `{}` or the error), after at least its id and usage frames (measured
    /// 2026-10-11 on SWE-1.6, Sonnet 5 and Opus 5, failed turns included). A
    /// body that stops short of that frame was cut off, and one that holds
    /// nothing else is no reply; both fail the turn as retryable transport
    /// errors, as magpie's `decodeDevin` and `askDevin` do, instead of
    /// passing for a finished answer whose half-received tool arguments
    /// would decode to `{}`.
    private func drive(
        body: AsyncThrowingStream<Data, Error>,
        state: DevinStreamState,
        out: AssistantMessageStream,
        cancellation: CancellationHandle?,
        historyBytes: @escaping @Sendable () -> Int
    ) async throws {
        var parser = ConnectFrameParser(maxPayload: Self.maxFramePayload)
        var messageFrames = 0
        var sawEndStream = false
        for try await chunk in body {
            if cancellation?.isCancelled == true { return }
            for frame in try parser.append(chunk) {
                let payload = frame.flags & Self.compressedFlag != 0
                    ? try Gzip.decompress(frame.payload)
                    : frame.payload
                if frame.flags & Self.endStreamFlag != 0 {
                    if let failure = Self.trailerFailure(payload, historyBytes: historyBytes) { throw failure }
                    if messageFrames == 0 {
                        throw ProviderFailure(message: "Devin stream ended before any reply frame (empty reply)")
                    }
                    sawEndStream = true
                    continue
                }
                messageFrames += 1
                state.apply(DevinProto.GetChatMessageResponse.decode(payload), emit: { out.push($0) })
            }
        }
        if cancellation?.isCancelled == true { return }
        if !sawEndStream {
            throw ProviderFailure(message: "Devin stream ended before its end-of-stream frame")
        }
    }

    // MARK: - Auth

    struct Auth {
        var userJwt: String
        var apiKey: String
        var baseURL: String?
    }

    /// `GetUserJwt` with the prefixed session token; on 401 retry once with the
    /// raw credential (a bare Windsurf API key rather than a session token).
    func fetchAuth(apiKey: String, baseURL: String, cancellation: CancellationHandle?) async throws -> Auth {
        let sessionKey = DevinWire.normalizeSessionToken(apiKey)
        var wireKey = sessionKey
        var (response, body) = try await unary(
            baseURL + DevinWire.getUserJwtPath,
            body: DevinProto.encodeGetUserJwtRequest(metadata: DevinWire.cliMetadata(apiKey: sessionKey)),
            cancellation: cancellation
        )
        if response.statusCode == 401, apiKey != sessionKey {
            wireKey = apiKey
            (response, body) = try await unary(
                baseURL + DevinWire.getUserJwtPath,
                body: DevinProto.encodeGetUserJwtRequest(metadata: DevinWire.cliMetadata(apiKey: apiKey)),
                cancellation: cancellation
            )
        }
        guard response.statusCode < 400 else {
            throw Self.unaryFailure(operation: "auth", response: response, body: body)
        }
        let decoded = DevinProto.GetUserJwtResponse.decode(DevinProto.unaryPayload(body))
        guard !decoded.userJwt.isEmpty else {
            throw ProviderFailure(message: "Devin auth error: GetUserJwt returned an empty user JWT", httpStatus: 401)
        }
        let custom = decoded.customApiServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return Auth(
            userJwt: decoded.userJwt,
            apiKey: wireKey,
            baseURL: custom.isEmpty ? nil : Self.trimSlashes(custom)
        )
    }

    /// Resolve a router slot into a concrete model uid plus the JWT that
    /// authorizes it. A router uid is never a legal `chatModelUid`, so a failed
    /// assignment fails the turn.
    private func assignModel(
        model: Model, apiKey: String, cascadeId: String, messages: [Message],
        baseURL: String, cancellation: CancellationHandle?
    ) async throws -> DevinProto.ModelAssignment {
        let lastUser = messages.last(where: { if case .user = $0 { return true }; return false })
        var prompt: DevinProto.ChatMessagePrompt?
        if case .user(let user)? = lastUser { prompt = Self.userPrompt(user, messageId: "") }
        let (response, body) = try await unary(
            baseURL + DevinWire.assignModelPath,
            body: DevinProto.encodeAssignModelRequest(
                metadata: DevinWire.cliMetadata(apiKey: apiKey),
                modelRouterUid: model.id, cascadeId: cascadeId, prompt: prompt
            ),
            cancellation: cancellation
        )
        guard response.statusCode < 400 else {
            throw Self.unaryFailure(operation: "AssignModel", response: response, body: body)
        }
        guard let assignment = DevinProto.decodeAssignModelResponse(DevinProto.unaryPayload(body)),
              !assignment.assignmentJwt.isEmpty, !assignment.modelUid.isEmpty else {
            throw ProviderFailure(message: "Devin AssignModel error: response carried no assignment JWT and model uid")
        }
        return assignment
    }

    private func unary(
        _ urlString: String, body: Data, cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, Data) {
        try await client.request(
            url: URL(string: urlString)!, method: "POST",
            headers: DevinWire.unaryHeaders, body: body, cancellation: cancellation
        )
    }

    // MARK: - Errors

    /// Connect end-of-stream trailer: `{"error": {"code", "message", "details"}}`.
    static func trailerFailure(_ payload: Data, historyBytes: () -> Int) -> ProviderFailure? {
        guard !payload.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let error = obj["error"] as? [String: Any] else { return nil }
        let code = error["code"] as? String ?? ""
        let message = error["message"] as? String ?? ""
        guard !code.isEmpty || !message.isEmpty else { return nil }
        var text = "Devin stream error\(code.isEmpty ? "" : " \(code)"): \(message)"
        if let details = error["details"],
           let data = try? JSONSerialization.data(withJSONObject: details),
           let detailText = String(data: data, encoding: .utf8), detailText != "[]" {
            text += " [details: \(detailText.prefix(2000))]"
        }
        var failure = ProviderFailure(message: text, providerCode: code.isEmpty ? nil : code.lowercased())
        let lower = message.lowercased()
        let isLimit = code.lowercased() == "resource_exhausted" || lower.contains("quota") || lower.contains("rate limit")
        if !isLimit, lower.contains("content policy") {
            // Devin refuses a prompt it screens out as `permission_denied`
            // "Your request was blocked by our content policy" (measured
            // 2026-10-12). Sent again it is refused again, and signing in
            // again changes nothing: a bad request, as magpie's Devin plugin
            // answers it (`failure`: 400).
            failure.httpStatus = 400
        }
        // Devin's own outage wears the same code: `permission_denied`
        // "internal server error: error number 13" answered every chat of a
        // healthy Pro account on 2026-10-13, from the devin CLI too, which
        // marks it `cognition.ai/errorKind: internal`, `retryable: true`.
        // A server fault to ask again, not a sign-in to redo — only
        // `unauthenticated` means that (magpie's Devin plugin, `failure`).
        if code.lowercased() == "permission_denied", lower.contains("internal server error") {
            failure.providerCode = "internal"
        }
        // Opaque `invalid_argument: internal error` with a large history is far
        // more likely a size rejection; classify it as context overflow so the
        // agent compacts instead of failing the turn outright.
        if code.lowercased() == "invalid_argument",
           message.range(of: #"\binternal error\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
           historyBytes() >= largeHistoryRecoveryBytes {
            failure.providerCode = "context_length_exceeded"
        }
        return failure
    }

    static func httpFailure(
        operation: String, response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>
    ) async -> ProviderFailure {
        let bytes = await ProviderFailure.readBoundedBody(body)
        return unaryFailure(operation: operation, response: response, body: bytes)
    }

    /// Bounded, human-readable error from a failed Connect call. Binary
    /// protobuf and proxy HTML bodies are suppressed to the status line.
    static func unaryFailure(operation: String, response: HTTPURLResponse, body: Data) -> ProviderFailure {
        let status = "\(response.statusCode)"
        var detail: String?
        var code: String?
        let isHTML = response.value(forHTTPHeaderField: "content-type")?.lowercased().contains("text/html") == true
        if !isHTML, let text = String(data: DevinProto.unaryPayload(body).prefix(4096), encoding: .utf8) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                if let error = obj["error"] as? [String: Any] {
                    detail = error["message"] as? String
                    code = error["code"] as? String
                } else {
                    detail = obj["message"] as? String ?? obj["error"] as? String
                    code = obj["code"] as? String
                }
            } else {
                let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let printable = collapsed.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
                if printable, !collapsed.lowercased().hasPrefix("<html"), !collapsed.lowercased().hasPrefix("<!doctype") {
                    detail = collapsed
                }
            }
        }
        var message = "Devin \(operation) error \(status)"
        if let detail, !detail.isEmpty { message += ": \(detail)" }
        var failure = ProviderFailure(message: message, httpStatus: response.statusCode, providerCode: code)
        failure.retryAfterMs = ProviderFailure.retryDelay(response: response)
        return failure
    }

    // MARK: - Helpers

    static func baseURL(_ model: Model) -> String {
        trimSlashes(model.baseURL.isEmpty ? DevinWire.defaultBaseURL : model.baseURL)
    }

    static func trimSlashes(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
