import Foundation

/// Chat Completions tools go out with `"strict": false` on every endpoint not
/// on the compat deny-list (`supportsStrictMode`). false is the field's
/// default, but an upstream that validates Chat strictly turns the whole
/// request away for it, e.g. 400 "Unsupported Chat Completions API field:
/// tools[0].function.strict", Pydantic's `extra_forbidden`, or "Unknown
/// parameter: 'tools[3].function.strict'". User-added custom providers get
/// strict by default, so every turn with tools failed there.
///
/// Such an upstream is asked once more with `strict` left out of its tools,
/// and is remembered (in memory, per API, provider and endpoint) so that
/// later requests leave it out at once. One that takes `strict` still gets it.
///
/// Ported from magpie (yetone/magpie): d46fb1e5 (#1980),
/// internal/gateway/strict_refused.go.
enum ToolStrictRefusal {
    /// An upstream refusing the strict field of a request's tools: the
    /// field's path (tools[0].function.strict, tools.0.strict, a segment in
    /// between as a relay may mask it) said unsupported, unknown or not
    /// allowed, before or after it, or Pydantic's extra_forbidden located
    /// there. An invalid value, or a schema strict mode can't take, is a
    /// different fault and doesn't match.
    private static let refusal = try! NSRegularExpression(
        pattern: #"(?:unsupported|unknown|unrecognized|not (?:supported|allowed|permitted)|extra (?:fields?|inputs?|parameters?)|forbidden)[^\n{}]{0,120}?\btools(?:\[\d+\]|\.\d+)(?:\.[^\s.'"\x60]+)?\.strict\b|\btools(?:\[\d+\]|\.\d+)(?:\.[^\s.'"\x60]+)?\.strict\b['"\x60]?[^\n{}]{0,40}?(?:unsupported|unknown|unrecognized|not (?:supported|allowed|permitted)|extra_forbidden|forbidden)|"loc"\s*:\s*\[\s*(?:"body"\s*,\s*)?"tools"\s*,\s*\d+\s*,\s*(?:"function"\s*,\s*)?"strict"\s*\][^{}]*"type"\s*:\s*"extra_forbidden"|"type"\s*:\s*"extra_forbidden"[^{}]*"loc"\s*:\s*\[\s*(?:"body"\s*,\s*)?"tools"\s*,\s*\d+\s*,\s*(?:"function"\s*,\s*)?"strict"\s*\]"#,
        options: [.caseInsensitive])

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var keys: Set<String> = []
    }
    private static let store = Store()

    /// Whether an error body is an upstream refusing a tool's `strict`.
    static func isRefusal(_ body: String) -> Bool {
        refusal.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
    }

    /// The key an upstream's refusal is remembered under.
    static func key(api: String, provider: String, url: URL) -> String {
        "\(api)\n\(provider)\n\(url.absoluteString)"
    }

    static func isRefused(_ key: String) -> Bool {
        store.lock.withLock { store.keys.contains(key) }
    }

    static func remember(_ key: String) {
        _ = store.lock.withLock { store.keys.insert(key) }
    }

    /// Leaves `strict` out of the Chat function tools of `root` and reports
    /// whether any had it.
    @discardableResult
    static func strip(_ root: inout [String: Any]) -> Bool {
        guard var tools = root["tools"] as? [[String: Any]] else { return false }
        var changed = false
        for i in tools.indices {
            guard var fn = tools[i]["function"] as? [String: Any],
                  fn.removeValue(forKey: "strict") != nil else { continue }
            tools[i]["function"] = fn
            changed = true
        }
        if changed { root["tools"] = tools }
        return changed
    }

    /// Reads at most 4 KiB of an error body (what `ProviderFailure.http`
    /// keeps), and a stream that gives those bytes again to whoever reports
    /// the failure.
    static func readErrorBody(
        _ body: AsyncThrowingStream<Data, Error>
    ) async -> (text: String, replay: AsyncThrowingStream<Data, Error>) {
        var bytes = Data()
        do {
            for try await chunk in body {
                bytes.append(contentsOf: chunk.prefix(max(0, 4096 - bytes.count)))
                if bytes.count >= 4096 { break }
            }
        } catch { /* the status stays authoritative */ }
        let replay = AsyncThrowingStream<Data, Error> { cont in
            if !bytes.isEmpty { cont.yield(bytes) }
            cont.finish()
        }
        return (String(decoding: bytes, as: UTF8.self), replay)
    }
}
