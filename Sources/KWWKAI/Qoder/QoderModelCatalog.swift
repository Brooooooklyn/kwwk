import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One enabled entry of Qoder's model listing (`app[]` or `chat[]`), as much
/// of it as kwwk reads. Ported from magpie `internal/qoder/models.go`, then
/// brought in line with the plugin that replaced it (magpie-plugins
/// `packages/qoder`).
public struct QoderModelInfo: Sendable, Equatable {
    /// The id a request names (`qfmodel`, `qmodel_latest`, …).
    public let key: String
    /// Sent back as `X-Model-Source` (`system` for Qoder's own models).
    public let source: String
    public let displayName: String
    /// `is_vl`: the model reads images.
    public let readsImages: Bool
    /// What a request that names no window gets (180K on Qwen3.8-Flash); not
    /// the model's limit when it offers windows.
    public let maxInputTokens: Int
    /// The context windows the model offers, smallest first (Qoder's Context
    /// setting: 200K / 400K / 1M), and the one Qoder's client picks unless
    /// told otherwise; empty and 0 when the listing names none.
    public let windows: [Int]
    public let defaultWindow: Int
    /// Whether the model can think, and whether it cannot stop.
    public let thinks: Bool
    public let alwaysThinks: Bool
    /// The efforts it thinks at, weakest first; empty when it names none.
    public let efforts: [String]
    /// Costs the plan no credits, as Qoder's client shows it ("0×").
    public let isFree: Bool
    /// The credits a request costs, as a multiple, and the price struck
    /// through beside it while a discount runs; 0 when the listing says none.
    public let rate: Double
    public let rateWas: Double
    /// The entry exactly as listed. A chat request sends it back whole as
    /// `model_config`.
    let config: String

    /// The most the model takes: its largest window, since a request that
    /// needs more than the default is sent a larger one
    /// (`QoderChatProvider.contextLength`); `maxInputTokens` when it lists
    /// none.
    public var contextWindow: Int { windows.last ?? maxInputTokens }
}

/// Qoder's model listing: fetched per account, parsed, and turned into
/// catalog rows.
public enum QoderModels {
    /// Qwen3.8-Flash: free on every plan, and the model magpie's port was
    /// checked against live.
    public static let defaultModelId = "qfmodel"

    static let api = "qoder-chat"
    static let listPath = "/algo/api/v2/model/list?Encode=1"
    static let defaultContextWindow = 200_000
    /// What a request asks for when the caller names no limit (magpie
    /// `qoderChatBody`).
    static let defaultMaxTokens = 32_000

    public enum ListingError: Error, LocalizedError {
        case invalidJSON
        public var errorDescription: String? { "Qoder: invalid models json" }
    }

    // MARK: - Fetch

    /// The account's models as catalog rows for `site`, read live. The
    /// roster and each model's limits are the account's own; the bundled
    /// `qoder-models.json` is only the seed the model picker starts from.
    public static func fetch(
        site: QoderSite,
        credentials: OAuthCredentials,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> [Model] {
        guard let account = QoderAccount(token: credentials.access, fields: credentials.extras) else {
            throw ProviderFailure(message: "\(site.name): the stored login carries no account id (run /login \(site.id) again)")
        }
        return try await fetchListing(baseURL: site.api, account: account, client: client)
            .map { model($0, site: site) }
    }

    /// `GET <api>/algo/api/v2/model/list?Encode=1`. The request carries the
    /// same COSY envelope as every `/algo` call, signed over an empty body;
    /// the answer is plain JSON.
    static func fetchListing(
        baseURL: String, account: QoderAccount, client: HTTPClient, cancellation: CancellationHandle? = nil
    ) async throws -> [QoderModelInfo] {
        let url = baseURL + listPath
        let headers = try QoderCosy.headers(
            url: url, account: account, body: "", timestamp: Int64(Date().timeIntervalSince1970)
        )
        let (response, body) = try await client.request(
            url: URL(string: url)!, method: "GET", headers: headers, body: nil, cancellation: cancellation
        )
        guard (200..<300).contains(response.statusCode) else {
            throw QoderChatProvider.failure(status: response.statusCode, body: body)
        }
        return try parse(body)
    }

    // MARK: - Parse

    /// The enabled, routable models of a listing. Placeholder ids (`auto`,
    /// `default`) route between models inside Qoder and are not one model a
    /// caller can pick, so they are dropped.
    ///
    /// The listing has a list per scene. The models are the `app` scene's —
    /// what Qoder's app shows, and the scene a request names (`session_type`
    /// and `product` are `app`) — in its order, then any model only `chat`
    /// still lists, after the model it follows there, so a model picked
    /// before stays served. Each key once; the app's entry wins, and a model
    /// the app turns off is off. A listing with one scene gives that one.
    /// On 2026-10-12 the app listed Fast (`fast`, 0.8×) where chat still
    /// listed Performance (1.1×), and reading `chat` alone never showed Fast
    /// (magpie-plugins qoder 0.2.13, #97, `models.test.mjs`).
    public static func parse(_ listing: Data) throws -> [QoderModelInfo] {
        guard let root = (try? JSONSerialization.jsonObject(with: listing)) as? [String: Any] else {
            throw ListingError.invalidJSON
        }
        let bytes = Array(listing)
        func scene(_ name: String) throws -> [(entry: [String: Any]?, config: String)] {
            let entries = root[name] as? [Any] ?? []
            let raw = rawEntries(bytes, of: name)
            guard raw.count == entries.count else { throw ListingError.invalidJSON }
            return zip(entries, raw).map { ($0 as? [String: Any], $1) }
        }
        func key(_ entry: [String: Any]?) -> String? { entry?["key"] as? String }
        var listed = try scene("app")
        var after = -1
        for model in try scene("chat") {
            if let at = listed.firstIndex(where: { key($0.entry) == key(model.entry) }) {
                after = at
                continue
            }
            after += 1
            listed.insert(model, at: after)
        }
        return listed.compactMap { entry, config in
            guard let entry else { return nil }
            let key = entry["key"] as? String ?? ""
            guard entry["enable"] as? Bool == true, isRoutable(key) else { return nil }
            let thinking = thinking(entry)
            let price = price(entry)
            let windows = windows(entry)
            let name = entry["display_name"] as? String ?? ""
            return QoderModelInfo(
                key: key,
                source: entry["source"] as? String ?? "",
                displayName: name.isEmpty ? key : name,
                readsImages: entry["is_vl"] as? Bool ?? false,
                maxInputTokens: (entry["max_input_tokens"] as? NSNumber)?.intValue ?? 0,
                windows: windows.all,
                defaultWindow: windows.byDefault,
                thinks: thinking.thinks,
                alwaysThinks: thinking.always,
                efforts: thinking.efforts,
                isFree: price.free,
                rate: price.rate,
                rateWas: price.rateWas,
                config: config
            )
        }
    }

    static func isRoutable(_ key: String) -> Bool {
        !["", "auto", "default"].contains(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Qoder's effort names, weakest first.
    private static let effortOrder = ["minimal", "low", "medium", "high", "xhigh", "max"]

    /// Qoder keeps the efforts a model offers in `thinking_config`: a model
    /// thinks when it has an `enabled` branch and cannot stop when it has no
    /// `disabled` one. `is_reasoning` alone stands for a model listed without
    /// a config (`reasoning_efforts`, which the same listing declares, is a
    /// field no model fills — magpie #162).
    private static func thinking(_ entry: [String: Any]) -> (thinks: Bool, always: Bool, efforts: [String]) {
        guard let config = entry["thinking_config"] as? [String: Any] else {
            return (entry["is_reasoning"] as? Bool ?? false, false, entry["reasoning_efforts"] as? [String] ?? [])
        }
        guard let enabled = config["enabled"] as? [String: Any] else { return (false, false, []) }
        func rank(_ effort: String) -> Int { effortOrder.firstIndex(of: effort) ?? effortOrder.count }
        let efforts = (enabled["efforts"] as? [String: Any] ?? [:]).keys.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0 < $1
        }
        return (true, config["disabled"] == nil, efforts)
    }

    /// The context windows an entry offers, smallest first, and the one
    /// Qoder's client picks unless asked for another: `context_config`'s
    /// entries (`{"200K": {"token_count": 200000, "is_default": true},
    /// "1M": {"token_count": 1000000}, …}`), else `available_context_windows`
    /// with `default_context_window`, as Qoder's client reads them
    /// (magpie-plugins qoder 0.2.5, `context.test.mjs`; the real listing of
    /// 2026-10-12 carries `context_config` on every model but Efficient).
    private static func windows(_ entry: [String: Any]) -> (all: [Int], byDefault: Int) {
        func count(_ value: Any?) -> Int {
            guard let number = value as? NSNumber, number.doubleValue == number.doubleValue.rounded(),
                  number.doubleValue > 0, number.doubleValue < 1e15 else { return 0 }
            return number.intValue
        }
        var all: [Int] = []
        var byDefault = 0
        if let config = (entry["context_config"] ?? entry["contextConfig"]) as? [String: Any] {
            for case let window as [String: Any] in config.values {
                let tokens = count(window["token_count"])
                guard tokens > 0 else { continue }
                if !all.contains(tokens) { all.append(tokens) }
                let flag = window["is_default"]
                // Should two be flagged, the smaller: a larger window may
                // cost more.
                if flag as? Bool == true || flag as? String == "1", byDefault == 0 || tokens < byDefault {
                    byDefault = tokens
                }
            }
        }
        if all.isEmpty {
            let listed = (entry["available_context_windows"] ?? entry["availableContextWindows"]) as? [Any] ?? []
            for tokens in listed.map(count) where tokens > 0 && !all.contains(tokens) { all.append(tokens) }
            byDefault = count(entry["default_context_window"] ?? entry["defaultContextWindow"])
            if !all.contains(byDefault) { byDefault = 0 }
        }
        return (all.sorted(), byDefault)
    }

    /// Whether a model costs the plan no credits, and its price as Qoder's
    /// client shows it. Free is a `price_factor` of 0 (`priceFactor` in camel
    /// case). `is_free` is no word on that — Qoder's listing has it true on
    /// Qwen3.8-Max at 0.5× with an off-peak discount — and counts only on a
    /// listing with no price at all. A price of 0 for the while an active
    /// promotion lasts, with a price before it, is a discount, not a free
    /// model; then the price is the one before times the discount.
    private static func price(_ entry: [String: Any]) -> (free: Bool, rate: Double, rateWas: Double) {
        func number(_ object: [String: Any], _ key: String) -> Double? {
            (object[key] as? NSNumber)?.doubleValue
        }
        guard let price = number(entry, "price_factor") ?? number(entry, "priceFactor") else {
            return ((entry["is_free"] as? Bool) ?? (entry["isFree"] as? Bool) ?? false, 0, 0)
        }
        // Qoder's own listing has spelled the key both ways.
        let promotion = (entry["promotion"] as? [String: Any]) ?? (entry["prommotion"] as? [String: Any]) ?? [:]
        let before = number(promotion, "before_promotion_price_factor")
            ?? number(promotion, "beforePromotionPriceFactor") ?? 0
        let discounted = promotion["active"] as? Bool == true && before > 0
        var rate = max(price, 0)
        var rateWas = max(number(entry, "original_price_factor") ?? 0, number(entry, "originalPriceFactor") ?? 0)
        if discounted {
            rateWas = before
            if rate == 0 {
                let discount = number(promotion, "discount_factor") ?? 0
                rate = before * (discount != 0 ? discount : number(promotion, "discountFactor") ?? 0)
            }
        }
        if rateWas <= rate { rateWas = 0 }
        return (price == 0 && !discounted, rate, rateWas)
    }

    /// The text of each element of the top-level array `name` (`app`,
    /// `chat`), as listed; none when the listing has no such array. Called on
    /// a document `JSONSerialization` has already accepted.
    static func rawEntries(_ json: [UInt8], of name: String) -> [String] {
        let quote = UInt8(ascii: "\"")
        var index = 0
        func skipSpace() {
            while index < json.count, [0x20, 0x09, 0x0a, 0x0d].contains(json[index]) { index += 1 }
        }
        func skipString() {
            index += 1
            while json[index] != quote { index += json[index] == UInt8(ascii: "\\") ? 2 : 1 }
            index += 1
        }
        /// Moves past the value at `index`: a string, a bracketed value with
        /// everything nested in it, or a bare literal.
        func skipValue() {
            switch json[index] {
            case quote:
                skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                repeat {
                    switch json[index] {
                    case quote:
                        skipString()
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                    default:
                        break
                    }
                    index += 1
                } while depth > 0
            default:
                while index < json.count, !Array(",]} \t\r\n".utf8).contains(json[index]) { index += 1 }
            }
        }

        skipSpace()
        guard index < json.count, json[index] == UInt8(ascii: "{") else { return [] }
        index += 1
        while true {
            skipSpace()
            guard index < json.count, json[index] == quote else { return [] }
            let keyStart = index
            skipValue()
            let key = Array(json[keyStart..<index])
            skipSpace()
            index += 1 // the colon
            skipSpace()
            if key == Array("\"\(name)\"".utf8), json[index] == UInt8(ascii: "[") {
                var entries: [String] = []
                index += 1
                while true {
                    skipSpace()
                    if json[index] == UInt8(ascii: "]") { return entries }
                    let start = index
                    skipValue()
                    entries.append(String(decoding: json[start..<index], as: UTF8.self))
                    skipSpace()
                    if json[index] == UInt8(ascii: ",") { index += 1 }
                }
            }
            skipValue()
            skipSpace()
            guard index < json.count, json[index] == UInt8(ascii: ",") else { return [] }
            index += 1
        }
    }

    // MARK: - Catalog rows

    /// The catalog row of a listed model on `site`.
    static func model(_ info: QoderModelInfo, site: QoderSite) -> Model {
        // The levels a model names are the ones offered; a model that cannot
        // stop thinking does not offer `off`.
        var levels: [String: String?]?
        if info.thinks, !info.efforts.isEmpty || info.alwaysThinks {
            var map: [String: String?] = [:]
            if info.alwaysThinks { map["off"] = .some(nil) }
            if !info.efforts.isEmpty {
                for level in effortOrder { map[level] = .some(info.efforts.contains(level) ? level : nil) }
            }
            levels = map
        }
        return Model(
            id: info.key,
            name: info.displayName,
            api: api,
            provider: site.id,
            baseURL: site.api,
            reasoning: info.thinks,
            input: info.readsImages ? [.text, .image] : [.text],
            contextWindow: info.contextWindow > 0 ? info.contextWindow : defaultContextWindow,
            maxTokens: defaultMaxTokens,
            thinkingLevelMap: levels
        )
    }

    /// The bundled seed, placed on `site`: both sites speak one protocol and
    /// the seed names models both list.
    static func placed(_ model: Model, on site: QoderSite) -> Model {
        var placed = model
        placed.provider = site.id
        placed.baseURL = site.api
        return placed
    }
}

/// The catalog row for a Qoder model id on `site`, or a usable fallback for
/// ids the bundled seed doesn't carry (the roster is the account's own; the
/// request itself is built from the live listing).
public func qoderModel(id: String, site: QoderSite) -> Model {
    if let catalog = ModelsCatalog.model(provider: site.id, id: id) { return catalog }
    return Model(
        id: id,
        name: id,
        api: QoderModels.api,
        provider: site.id,
        baseURL: site.api,
        reasoning: true,
        input: [.text],
        contextWindow: QoderModels.defaultContextWindow,
        maxTokens: QoderModels.defaultMaxTokens
    )
}

extension QoderAccount {
    /// The account behind a login: its chat token plus the fields sign-in
    /// stored beside it (`OAuthCredentials.extras`, handed on as
    /// `ResolvedProviderAuth.metadata`). Nil without a user id.
    init?(token: String, fields: [String: JSONValue]) {
        func field(_ key: String) -> String {
            if case .string(let value)? = fields[key] { return value }
            return ""
        }
        guard !field("uid").isEmpty else { return nil }
        self.init(
            uid: field("uid"), name: field("name"), email: field("email"),
            token: token, machineId: field("machineId")
        )
    }
}
