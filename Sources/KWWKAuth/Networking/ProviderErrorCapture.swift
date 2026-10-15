import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOConcurrencyHelpers

/// Keeps the literal bytes of provider error responses on disk, so a refusal
/// seen once can be read again later and turned into a test fixture without
/// re-creating it from memory (magpie's rule: build fixtures from the
/// provider's real bytes, never from a look-alike).
///
/// Off unless enabled: the CLI turns it on for `~/.kwwk/provider-errors`, and
/// `KWWK_PROVIDER_ERROR_DIR` points it anywhere (`off` disables it). Library
/// hosts stay silent unless they call `enable`.
///
/// What a record keeps: method, URL with query values redacted, status, an
/// allowlist of diagnostic headers, and the body (bounded). It never keeps
/// request headers or request bodies, so tokens are not written. A record is
/// the same JSON a fixture under `Tests/KWWKAITests/Fixtures/ProviderErrors`
/// starts from; the fixture adds what the failure must be read as.
public enum ProviderErrorCapture {
    public struct Record: Codable, Sendable, Equatable {
        public struct Request: Codable, Sendable, Equatable {
            public var method: String
            public var url: String
        }
        public struct Response: Codable, Sendable, Equatable {
            public var status: Int
            public var headers: [String: String]
            public var body: String
            public var bodyTruncated: Bool
            /// Set when the error did not come as an HTTP error body but in
            /// a frame of a 200 stream, e.g. `connect-end-stream` for
            /// Cursor's Connect end-of-stream error. Nil for an HTTP body.
            public var frame: String?
        }
        public var capturedAt: String
        public var request: Request
        public var response: Response
    }

    /// Bodies past this are cut; error bodies are small, a proxy's page is not.
    public static let maxBodyBytes = 64 * 1024
    /// Headers worth keeping to explain a refusal. Nothing that authenticates.
    public static let keptHeaders: Set<String> = [
        "content-type", "www-authenticate", "retry-after", "retry-after-ms", "x-should-retry",
        "x-request-id", "request-id", "cf-ray", "x-amzn-requestid", "x-amzn-errortype",
        "grpc-status", "grpc-message", "connect-protocol-version",
    ]

    private struct State {
        var directory: URL?
        var retain = 200
        var configured = false
    }
    private static let state = NIOLockedValueBox(State())

    /// Write records under `directory`, keeping the newest `retain` files.
    /// `KWWK_PROVIDER_ERROR_DIR` still wins, so a user can redirect or turn
    /// off what an app enables.
    public static func enable(directory: URL, retain: Int = 200) {
        state.withLockedValue { state in
            state.configured = true
            state.directory = environmentDirectory() ?? (environmentDisabled() ? nil : directory)
            state.retain = max(1, retain)
        }
    }

    public static func disable() {
        state.withLockedValue { state in
            state.configured = true
            state.directory = nil
        }
    }

    /// Where records go now, or nil when capture is off.
    public static var directory: URL? {
        state.withLockedValue { state in
            if !state.configured {
                state.configured = true
                state.directory = environmentDirectory()
            }
            return state.directory
        }
    }

    private static func environmentDisabled() -> Bool {
        ["off", "0", "false", "none"].contains(ProcessInfo.processInfo.environment["KWWK_PROVIDER_ERROR_DIR"]?.lowercased() ?? "")
    }

    private static func environmentDirectory() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["KWWK_PROVIDER_ERROR_DIR"], !raw.isEmpty,
              !environmentDisabled() else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    /// The URL as it may be written down: no user info, query values masked
    /// (Gemini and others carry a key there), names kept for context.
    public static func redacted(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        if let items = parts.queryItems, !items.isEmpty {
            parts.queryItems = items.map { URLQueryItem(name: $0.name, value: $0.value == nil ? nil : "REDACTED") }
        }
        return parts.string ?? url.absoluteString
    }

    public static func record(method: String, url: URL, status: Int, headers: [String: String], body: Data,
                              truncated: Bool = false, frame: String? = nil, now: Date = Date()) -> Record {
        var kept: [String: String] = [:]
        for (key, value) in headers where keptHeaders.contains(key.lowercased()) { kept[key.lowercased()] = value }
        let cut = body.count > maxBodyBytes
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Record(
            capturedAt: formatter.string(from: now),
            request: .init(method: method, url: redacted(url)),
            response: .init(status: status, headers: kept,
                            body: String(decoding: body.prefix(maxBodyBytes), as: UTF8.self),
                            bodyTruncated: truncated || cut, frame: frame)
        )
    }

    /// Persist an error response when capture is on. Never throws and never
    /// blocks the failure it describes from being reported.
    public static func save(method: String, url: URL, status: Int, headers: [String: String], body: Data,
                            truncated: Bool = false, frame: String? = nil) {
        guard status >= 400 || frame != nil, let directory else { return }
        let retain = state.withLockedValue { $0.retain }
        let entry = record(method: method, url: url, status: status, headers: headers, body: body,
                           truncated: truncated, frame: frame)
        write(entry, to: directory, retain: retain)
    }

    static func write(_ entry: Record, to directory: URL, retain: Int) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let stamp = entry.capturedAt.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: ".", with: "-")
            let host = URL(string: entry.request.url)?.host ?? "unknown"
            let name = "\(stamp)-\(entry.response.status)-\(host)-\(UUID().uuidString.prefix(8)).json"
            _ = fm.createFile(atPath: directory.appendingPathComponent(name).path,
                              contents: try encoder.encode(entry), attributes: [.posixPermissions: 0o600])
            // Names start with the timestamp, so the oldest sort first.
            let names = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
            for old in names.dropLast(retain) {
                try? fm.removeItem(at: directory.appendingPathComponent(old))
            }
        } catch {
            // Capture is a diagnostic; losing one record must not fail a request.
        }
    }

    /// For an error response, read the body (up to `maxBodyBytes`) now,
    /// save it, and hand back a stream that replays those bytes followed by
    /// whatever was left. Other responses pass through untouched.
    static func tee(
        method: String, url: URL, response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>
    ) async -> AsyncThrowingStream<Data, Error> {
        guard response.statusCode >= 400, directory != nil else { return body }
        let reader = BodyReader(body)
        let (head, ended, failure) = await reader.read(upTo: maxBodyBytes)
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String { headers[key] = String(describing: value) }
        }
        save(method: method, url: url, status: response.statusCode, headers: headers, body: head, truncated: !ended)
        return AsyncThrowingStream { continuation in
            if !head.isEmpty { continuation.yield(head) }
            if ended {
                continuation.finish(throwing: failure)
                return
            }
            let pump = Task {
                do {
                    while let chunk = try await reader.next() { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    /// Owns the upstream iterator so the replay task can keep reading it.
    /// Reads are strictly sequential (the eager read finishes before the
    /// replay task starts), so the iterator is never touched concurrently.
    private final class BodyReader: @unchecked Sendable {
        var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator
        init(_ stream: AsyncThrowingStream<Data, Error>) { iterator = stream.makeAsyncIterator() }

        func read(upTo limit: Int) async -> (Data, Bool, Error?) {
            var bytes = Data()
            do {
                while bytes.count < limit {
                    guard let chunk = try await iterator.next() else { return (bytes, true, nil) }
                    bytes.append(chunk)
                }
                return (bytes, false, nil)
            } catch {
                return (bytes, true, error)
            }
        }

        func next() async throws -> Data? { try await iterator.next() }
    }
}
