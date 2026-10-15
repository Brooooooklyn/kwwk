import DequeModule
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1

/// The default `KiroLoopbackListener`: a SwiftNIO HTTP server on 127.0.0.1
/// that hands every request on one of Kiro's callback paths to the sign-in
/// and writes back the page or redirect it answers with. Unlike
/// `OAuthCallbackServer` it keeps listening after a request, since an AWS
/// sign-in comes back twice.
public final class KiroCallbackServer: KiroLoopbackListener, Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let state = NIOLockedValueBox(State())

    private struct State {
        var channel: Channel?
        var pending: Deque<KiroCallback> = []
        var waiter: CheckedContinuation<KiroCallback, Error>?
        var stopped = false
    }

    public init() {}

    deinit {
        // Deinit can run on the event loop that just closed the channel, so
        // shut down asynchronously (see `OAuthCallbackServer`).
        group.shutdownGracefully { _ in }
    }

    public func listen(ports: [UInt16]) async throws -> UInt16 {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] child in
                let server = self
                return child.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    child.pipeline.addHandler(KiroCallbackHandler(server: server))
                }
            }
        for port in ports {
            guard let bound = try? await bootstrap.bind(host: "127.0.0.1", port: Int(port)).get() else { continue }
            state.withLockedValue { $0.channel = bound }
            return UInt16(bound.localAddress?.port ?? Int(port))
        }
        throw OAuthError.transport(
            "the ports Kiro's sign-in comes back to are all busy; close the Kiro IDE's sign-in and try again"
        )
    }

    public func nextCallback() async throws -> KiroCallback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Decide under the lock; resume (if at all) after releasing it.
                let immediate: Result<KiroCallback, Error>? = state.withLockedValue { state in
                    if let callback = state.pending.popFirst() {
                        return .success(callback)
                    } else if state.stopped || Task.isCancelled {
                        return .failure(CancellationError())
                    } else {
                        state.waiter = continuation
                        return nil
                    }
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let waiting = state.withLockedValue { state -> CheckedContinuation<KiroCallback, Error>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiting?.resume(throwing: CancellationError())
        }
    }

    public func stop() {
        let (bound, waiting) = state.withLockedValue { state -> (Channel?, CheckedContinuation<KiroCallback, Error>?) in
            defer { state.channel = nil; state.waiter = nil; state.stopped = true }
            return (state.channel, state.waiter)
        }
        waiting?.resume(throwing: CancellationError())
        _ = bound?.close()
    }

    fileprivate func deliver(_ callback: KiroCallback) {
        let waiting = state.withLockedValue { state -> CheckedContinuation<KiroCallback, Error>? in
            guard let waiter = state.waiter else {
                state.pending.append(callback)
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiting?.resume(returning: callback)
    }

    static func page(succeeded: Bool, title: String, message: String) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html>
        <html><head><meta charset=utf-8><title>kw — Kiro sign-in</title>
        <style>body{font-family:ui-sans-serif,system-ui;padding:3em;max-width:30em;margin:0 auto;color:#222}
        h1{color:\(succeeded ? "#0a7" : "#c33")}</style></head>
        <body><h1>\(escaped(title))</h1><p>\(escaped(message))</p></body></html>
        """
    }
}

/// Reads one request, hands it to the sign-in, and writes what it answers.
private final class KiroCallbackHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private weak var server: KiroCallbackServer?
    private var head: HTTPRequestHead?

    init(server: KiroCallbackServer?) { self.server = server }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
        case .body:
            break
        case .end:
            guard let head, let server, let url = URL(string: "http://localhost\(head.uri)"),
                  KiroOAuth.callbackPaths.contains(url.path) else {
                write(context: context, status: .notFound, html: "<p>unknown path</p>", location: nil)
                return
            }
            self.head = nil
            var params: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                params[item.name] = item.value ?? ""
            }
            // The sign-in answers from its own task; the write hops back here.
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            let loop = context.eventLoop
            server.deliver(KiroCallback(path: url.path, params: params) { [self] reply in
                loop.execute {
                    switch reply {
                    case .page(let succeeded, let title, let message):
                        self.write(
                            context: bound.value,
                            status: succeeded ? .ok : .badRequest,
                            html: KiroCallbackServer.page(succeeded: succeeded, title: title, message: message),
                            location: nil
                        )
                    case .redirect(let url):
                        self.write(context: bound.value, status: .found, html: "", location: url.absoluteString)
                    }
                }
            })
        }
    }

    private func write(context: ChannelHandlerContext, status: HTTPResponseStatus, html: String, location: String?) {
        let bodyBytes = Array(html.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/html; charset=utf-8")
        headers.add(name: "content-length", value: String(bodyBytes.count))
        headers.add(name: "connection", value: "close")
        if let location { headers.add(name: "location", value: location) }
        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))),
            promise: nil
        )
        var buffer = context.channel.allocator.buffer(capacity: bodyBytes.count)
        buffer.writeBytes(bodyBytes)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
