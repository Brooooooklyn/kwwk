import Foundation
import NIOCore
import NIOPosix
import NIOHTTP2
import NIOSSL
import NIOHPACK

/// One de-framed Connect-protocol message off the wire. Connect frames a
/// 5-byte prefix (`[flags:1][length:4 big-endian]`) in front of each payload;
/// the end-of-stream frame sets bit `0b10` and its payload is a JSON object
/// that may carry a trailing `error`.
enum CursorConnectFrame: Sendable {
    case message(Data)
    case endStream(Data)
}

enum CursorConnectError: Error, LocalizedError {
    case tlsSetupFailed(String)
    case connectionFailed(String)
    case httpStatus(Int, String)
    case grpc(status: String, message: String)
    case endStream(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .tlsSetupFailed(let s): return "Cursor TLS setup failed: \(s)"
        case .connectionFailed(let s): return "Cursor connection failed: \(s)"
        case .httpStatus(let code, let body): return "Cursor HTTP \(code): \(body)"
        case .grpc(let status, let message): return "Cursor gRPC error \(status): \(message)"
        case .endStream(let s): return "Cursor stream error: \(s)"
        case .transport(let s): return "Cursor transport error: \(s)"
        }
    }
}

/// Helpers for interpreting a Connect end-stream frame payload.
enum CursorConnectResponse {
    /// Parse a Connect end-stream JSON payload; returns an error when it carries
    /// a trailing `{ "error": { code, message } }`.
    static func errorFromEndStream(_ data: Data) -> CursorConnectError? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let error = obj["error"] as? [String: Any] else { return nil }
        let code = error["code"] as? String ?? "unknown"
        return CursorConnectError.grpc(status: code, message: message(of: error) ?? code)
    }

    /// The end-stream error as a ``ProviderFailure``, with Cursor's own word
    /// on whether asking again can help. Each `details[].debug.details`
    /// carries `isRetryable`; a refusal that asking again cannot change says
    /// false — measured 2026-10-11 on a Free plan asking for a named model:
    /// `resource_exhausted`, "Named models unavailable: Free plans can only
    /// use Auto…", `isRetryable: false`. Read by its code alone that is a
    /// rate limit, and was retried four more times with backoff.
    static func failureFromEndStream(_ data: Data) -> ProviderFailure? {
        guard let error = errorFromEndStream(data) else { return nil }
        var failure = ProviderFailure.capture(error)
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let details = (root?["error"] as? [String: Any])?["details"] as? [[String: Any]] ?? []
        let refused = details.contains { detail in
            let debug = (detail["debug"] as? [String: Any])?["details"] as? [String: Any]
            return debug?["isRetryable"] as? Bool == false
        }
        if refused { failure.shouldRetry = false }
        return failure
    }

    /// The failure of a Run answered with an HTTP error instead of a stream.
    /// Cursor answers a Run it refuses outright that way, the Connect error
    /// as the body with no `error` wrapper — a region refusal comes as a 401
    /// `{"code":"unauthenticated","message":"Error","details":[…]}` (the
    /// fixtures of magpie's TestCursorFailure). The plugin reads both forms
    /// with one `failure()`, and so does this: the code, the words in the
    /// details and `isRetryable` count as they do in an end frame. Read as a
    /// plain HTTP error the message was the bare word "Error", and the 401
    /// made a region refusal a sign-in failure. A 4xx status that is only
    /// Connect's rendering of the code (401 for `unauthenticated`, 429 for
    /// `resource_exhausted`, …) says nothing the code does not and is left
    /// out, so the code and the words govern. Any other status is kept: a
    /// 5xx says to ask again whatever the code, and a 4xx Connect would not
    /// have written for that code (a 402, a 401 beside `unknown`) is the
    /// server's own word — the plugin's `statusOf` reads a 401 as a lapsed
    /// sign-in whatever the code. A body that is no Connect error (a
    /// proxy's page, nothing at all) stays the HTTP error it is.
    static func failureFromHTTP(status: Int, body: String) -> ProviderFailure {
        let plain = ProviderFailure.capture(CursorConnectError.httpStatus(status, body))
        guard let root = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return plain
        }
        let error = root["error"] as? [String: Any] ?? root
        guard let code = error["code"] as? String, !code.isEmpty,
              let framed = try? JSONSerialization.data(withJSONObject: ["error": error]),
              var failure = failureFromEndStream(framed) else { return plain }
        if !(connectStatuses[code.lowercased()] ?? []).contains(status) { failure.httpStatus = status }
        return failure
    }

    /// The 4xx statuses Connect writes for each error code over HTTP (the
    /// protocol's code table, with the statuses older servers wrote).
    private static let connectStatuses: [String: Set<Int>] = [
        "canceled": [499, 408], "cancelled": [499, 408],
        "invalid_argument": [400], "failed_precondition": [400, 412], "out_of_range": [400],
        "unauthenticated": [401], "permission_denied": [403],
        "not_found": [404], "unimplemented": [404],
        "already_exists": [409], "aborted": [409],
        "resource_exhausted": [429],
    ]

    /// How a Run's end frame that named no error reads in an empty reply's
    /// words: its JSON, cut short, or that it was empty (the plugin's
    /// `endFrame`).
    static func endFrameWords(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "{}" { return "the Run's stream ended (an empty end frame)" }
        return "the Run's stream ended (end frame: \(text.count > 300 ? String(text.prefix(300)) + "…" : text))"
    }

    /// Cursor's top-level `message` is often the bare word "Error"; what it
    /// means — "Model not available", a region refusal — sits in
    /// `details[].debug.details.{title,detail}`. The last such detail wins
    /// over the generic word.
    static func message(of error: [String: Any]) -> String? {
        var message = (error["message"] as? String).flatMap { $0 == "Error" || $0.isEmpty ? nil : $0 }
        for detail in error["details"] as? [[String: Any]] ?? [] {
            let debug = (detail["debug"] as? [String: Any])?["details"] as? [String: Any] ?? [:]
            let parts = [debug["title"], debug["detail"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
            if !parts.isEmpty { message = parts.joined(separator: ": ") }
        }
        return message
    }
}

/// A single full-duplex Connect-over-HTTP/2 stream to `api2.cursor.sh`. The
/// caller writes framed request messages with ``send(_:)`` (the run request
/// first, then heartbeats / KV / exec replies as the server asks for them) and
/// consumes de-framed server messages from ``frames``. Mirrors the Node
/// `http2` full-duplex usage in oh-my-pi's `streamCursor`.
final class CursorConnectStream: @unchecked Sendable {
    private let channel: Channel
    let frames: AsyncThrowingStream<CursorConnectFrame, Error>

    fileprivate init(channel: Channel, frames: AsyncThrowingStream<CursorConnectFrame, Error>) {
        self.channel = channel
        self.frames = frames
    }

    /// Frame `payload` with the Connect 5-byte prefix and write it as an
    /// HTTP/2 DATA frame. Best-effort: write failures surface on the read side.
    func send(_ payload: Data, flags: UInt8 = 0) {
        var framed = Data(capacity: payload.count + 5)
        framed.append(flags)
        let len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: len) { framed.append(contentsOf: $0) }
        framed.append(payload)

        var buffer = channel.allocator.buffer(capacity: framed.count)
        buffer.writeBytes(framed)
        let frame = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer), endStream: false))
        channel.writeAndFlush(frame, promise: nil)
    }

    func close() {
        channel.close(promise: nil)
    }
}

/// Opens Connect-over-HTTP/2 streams to the Cursor API. Owns a shared event
/// loop group for the process; kwwk is a short-lived CLI so a single lazily
/// created group is fine.
enum CursorConnect {
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    /// Open a POST stream to `path` on `host` with `headers`, send `initialBody`
    /// (already Connect-framed by the caller? no — we frame it here), and return
    /// a live duplex stream. The initial request body is sent as the first
    /// Connect frame; `endStream` is left open so the caller can keep writing.
    static func open(
        host: String,
        port: Int = 443,
        path: String,
        headers: [(String, String)],
        initialBody: Data
    ) async throws -> CursorConnectStream {
        let sslContext: NIOSSLContext
        do {
            var config = TLSConfiguration.makeClientConfiguration()
            config.applicationProtocols = ["h2"]
            sslContext = try NIOSSLContext(configuration: config)
        } catch {
            throw CursorConnectError.tlsSetupFailed(String(describing: error))
        }

        // Bring up the TCP + TLS + HTTP/2 connection channel.
        let connection: Channel
        do {
            connection = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    // The initializer runs on the channel's event loop, so the
                    // non-Sendable TLS handler goes in synchronously.
                    do {
                        let ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                        try channel.pipeline.syncOperations.addHandler(ssl)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                    return channel.configureHTTP2Pipeline(mode: .client) { _ in
                        channel.eventLoop.makeSucceededVoidFuture()
                    }.map { _ in }
                }
                .connect(host: host, port: port)
                .get()
        } catch {
            throw CursorConnectError.connectionFailed(String(describing: error))
        }

        let (stream, continuation) = AsyncThrowingStream<CursorConnectFrame, Error>.makeStream()
        let handler = CursorStreamHandler(
            host: host,
            path: path,
            headers: headers,
            initialBody: initialBody,
            continuation: continuation
        )

        // The multiplexer is not Sendable: look it up and open the stream on
        // the connection's event loop rather than carrying it out of there.
        let streamChannelPromise = connection.eventLoop.makePromise(of: Channel.self)
        connection.eventLoop.execute {
            do {
                let multiplexer = try connection.pipeline.syncOperations.handler(type: HTTP2StreamMultiplexer.self)
                multiplexer.createStreamChannel(promise: streamChannelPromise) { streamChannel in
                    streamChannel.pipeline.addHandler(handler)
                }
            } catch {
                streamChannelPromise.fail(error)
            }
        }

        let streamChannel: Channel
        do {
            streamChannel = try await streamChannelPromise.futureResult.get()
        } catch {
            connection.close(promise: nil)
            throw CursorConnectError.connectionFailed(String(describing: error))
        }

        // Tear the parent connection down when the stream closes so we don't
        // leak the socket/event-loop registration.
        streamChannel.closeFuture.whenComplete { _ in
            connection.close(promise: nil)
        }

        return CursorConnectStream(channel: streamChannel, frames: stream)
    }
}

/// Per-stream NIO handler: writes the request headers + the first framed body
/// on channel-active, then translates inbound HTTP/2 frames into de-framed
/// Connect messages pushed to an `AsyncThrowingStream` continuation.
private final class CursorStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private let host: String
    private let path: String
    private let headers: [(String, String)]
    private let initialBody: Data
    private let continuation: AsyncThrowingStream<CursorConnectFrame, Error>.Continuation

    private var pending = Data()
    private var status: Int?
    private var finished = false
    /// Whether a Connect end-of-stream frame (flags 0b10) was seen — after it,
    /// connection teardown is a clean end rather than truncation.
    private var sawConnectEndStream = false

    init(
        host: String,
        path: String,
        headers: [(String, String)],
        initialBody: Data,
        continuation: AsyncThrowingStream<CursorConnectFrame, Error>.Continuation
    ) {
        self.host = host
        self.path = path
        self.headers = headers
        self.initialBody = initialBody
        self.continuation = continuation
    }

    func channelActive(context: ChannelHandlerContext) {
        var hpack = HPACKHeaders()
        hpack.add(name: ":method", value: "POST")
        hpack.add(name: ":scheme", value: "https")
        hpack.add(name: ":authority", value: host)
        hpack.add(name: ":path", value: path)
        for (name, value) in headers {
            hpack.add(name: name.lowercased(), value: value)
        }
        let headerFrame = HTTP2Frame.FramePayload.headers(.init(headers: hpack, endStream: false))
        context.write(self.wrapOutboundOut(headerFrame), promise: nil)

        // Request body. Connect streaming (`application/connect+proto`) frames
        // each message with a 5-byte prefix. `endStream` is left open so the
        // caller can keep writing (heartbeats / exec replies).
        var framed = Data(capacity: initialBody.count + 5)
        framed.append(0)
        let len = UInt32(initialBody.count).bigEndian
        withUnsafeBytes(of: len) { framed.append(contentsOf: $0) }
        framed.append(initialBody)
        var buffer = context.channel.allocator.buffer(capacity: framed.count)
        buffer.writeBytes(framed)
        let dataFrame = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer), endStream: false))
        context.writeAndFlush(self.wrapOutboundOut(dataFrame), promise: nil)

        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = self.unwrapInboundIn(data)
        switch payload {
        case .headers(let headerFrame):
            if let statusValue = headerFrame.headers.first(name: ":status"), let code = Int(statusValue) {
                status = code
            }
            // Trailing gRPC status on the closing HEADERS frame.
            if let grpcStatus = headerFrame.headers.first(name: "grpc-status"), grpcStatus != "0" {
                let msg = headerFrame.headers.first(name: "grpc-message") ?? ""
                finish(throwing: CursorConnectError.grpc(
                    status: grpcStatus,
                    message: msg.removingPercentEncoding ?? msg
                ))
            }
            // END_STREAM riding a HEADERS frame ends the response too —
            // headers-only errors (e.g. a body-less 401) and clean trailers
            // would otherwise leave the stream hanging until timeout.
            if headerFrame.endStream { finishSuccessfully() }
        case .data(let dataFrame):
            if case .byteBuffer(let buffer) = dataFrame.data {
                pending.append(contentsOf: buffer.readableBytesView)
                drainFrames()
            }
            if dataFrame.endStream { finishSuccessfully() }
        default:
            break
        }
    }

    /// Split accumulated bytes into complete Connect frames.
    private func drainFrames() {
        while pending.count >= 5 {
            let flags = pending[pending.startIndex]
            let lenBytes = pending.subdata(in: pending.startIndex + 1 ..< pending.startIndex + 5)
            let msgLen = lenBytes.reduce(0) { ($0 << 8) | Int($1) }
            guard pending.count >= 5 + msgLen else { break }
            let start = pending.startIndex + 5
            let messageBytes = pending.subdata(in: start ..< start + msgLen)
            pending.removeSubrange(pending.startIndex ..< start + msgLen)

            if flags & 0b0000_0010 != 0 {
                sawConnectEndStream = true
                continuation.yield(.endStream(messageBytes))
            } else {
                continuation.yield(.message(messageBytes))
            }
        }
    }

    private func finishSuccessfully() {
        if let status, status >= 400 {
            let body = String(data: pending, encoding: .utf8) ?? ""
            finish(throwing: CursorConnectResponse.failureFromHTTP(status: status, body: body))
            return
        }
        finish(throwing: nil)
    }

    private func finish(throwing error: Error?) {
        guard !finished else { return }
        finished = true
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(throwing: CursorConnectError.transport(String(describing: error)))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // The connection died without an end-of-response marker (no END_STREAM,
        // no Connect end-stream frame): the response was truncated. Reporting a
        // clean end here would silently pass off a partial message as complete.
        // (A close after the consumer already stopped reading — normal turn end
        // or user cancel — finishes a continuation nobody is reading; the
        // provider maps the cancel case to `aborted` itself.)
        if sawConnectEndStream {
            finish(throwing: nil)
        } else {
            finish(throwing: CursorConnectError.transport("connection closed before end of stream"))
        }
        context.fireChannelInactive()
    }
}
