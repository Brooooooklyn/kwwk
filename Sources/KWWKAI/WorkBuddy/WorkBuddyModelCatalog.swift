import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The models of WorkBuddy's two plans. The bundled
/// `Resources/workbuddy-models.json` and `workbuddy-ai-models.json` hold
/// magpie's written-in lists (`wbModels`, `wbAIModels` in
/// `internal/provider/workbuddy.go`), which are WorkBuddy's CLI agent's picks
/// with the names, context windows and reasoning levels its config gave
/// them; `fetch` reads the account's own list live, as magpie's
/// `workbuddy_models.go` does.
public enum WorkBuddyModels {
    /// The first of each build's picker.
    public static func defaultModelId(for site: WorkBuddySite) -> String {
        site == .international ? "default-model" : "auto"
    }

    /// The catalog row for a model id, or a usable fallback for ids the
    /// bundled list doesn't carry (the live list changes with the plan).
    public static func model(site: WorkBuddySite, id: String) -> Model {
        ModelsCatalog.model(provider: site.id, id: id)
            ?? row(site: site, id: id, name: id, contextWindow: 200_000, maxTokens: 0, images: false, efforts: [])
    }

    /// One model of the live list: the catalog row, and what a request of it
    /// costs of the plan's credits as a multiple, as WorkBuddy's picker shows
    /// it ("x0.03" is 0.03, "x0.00" is free). Nil where the config gives no
    /// rate or one that can't be read.
    public struct Listing: Sendable, Hashable {
        public var model: Model
        public var creditRate: Double?
    }

    // MARK: - Live list

    /// Asks WorkBuddy's product config for the plan's models: `GET
    /// /v3/config`, signed as a chat is, answers with the product's agents
    /// (the "cli" one's models are WorkBuddy's picker) and each model's
    /// details. Which product answers goes by the User-Agent: WorkBuddy
    /// sends "CLI/<version> WorkBuddy/<version>", and a bare
    /// WorkBuddy/<version> gets CodeBuddy IDE's config, with no cli agent.
    public static func fetch(
        site: WorkBuddySite,
        credentials: OAuthCredentials,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> [Listing] {
        var headers = WorkBuddyWire.clientHeaders(site)
        for (name, value) in WorkBuddyOAuth.accountHeaders(credentials, site: site) { headers[name] = value }
        headers["Authorization"] = bearerHeaderValue(credentials.access)
        headers["User-Agent"] = "CLI/\(WorkBuddyOAuth.appVersion) \(WorkBuddyOAuth.userAgent)"
        headers["Accept"] = "application/json"
        let (response, body) = try await client.request(
            url: URL(string: site.endpoint + "/v3/config")!, method: "GET", headers: headers, body: nil
        )
        let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let said = envelope["msg"] as? String ?? ""
        guard response.statusCode == 200 else {
            throw ProviderFailure(
                message: "\(site.name)'s config: \(said.isEmpty ? "HTTP \(response.statusCode)" : said)",
                httpStatus: response.statusCode
            )
        }
        if let code = envelope["code"] as? Int, code != 0 {
            throw ProviderFailure(message: "\(site.name)'s config: \(said) (\(code))", providerCode: String(code))
        }
        let listings = listings(fromConfig: envelope["data"] as? [String: Any] ?? [:], site: site)
        guard !listings.isEmpty else {
            throw ProviderFailure(message: "\(site.name)'s config lists no models for its CLI agent")
        }
        return listings
    }

    /// The config's "cli" agent's models, in its order, each with the
    /// details the config gives it; a model it lists without details keeps
    /// its id for a name.
    static func listings(fromConfig config: [String: Any], site: WorkBuddySite) -> [Listing] {
        let details = config["models"] as? [[String: Any]] ?? []
        var out: [Listing] = []
        for agent in config["agents"] as? [[String: Any]] ?? [] where agent["name"] as? String == "cli" {
            for id in agent["models"] as? [String] ?? [] {
                let detail = details.first { $0["id"] as? String == id } ?? [:]
                let reasoning = detail["reasoning"] as? [String: Any] ?? [:]
                // The levels WorkBuddy offers the model, and off where it
                // offers that; a model it gives no levels isn't asked for one.
                var efforts = reasoning["supportedEfforts"] as? [String] ?? []
                if !efforts.isEmpty, detail["onlyReasoning"] as? Bool != true,
                   reasoning["canDisableThinking"] as? Bool != false {
                    efforts.insert("none", at: 0)
                }
                let name = detail["name"] as? String ?? ""
                out.append(Listing(
                    model: row(
                        site: site, id: id, name: name.isEmpty ? id : name,
                        // A window the config leaves out is the bundled
                        // row's.
                        contextWindow: (detail["maxInputTokens"] as? Int).flatMap { $0 > 0 ? $0 : nil }
                            ?? model(site: site, id: id).contextWindow,
                        maxTokens: detail["maxOutputTokens"] as? Int ?? 0,
                        images: detail["supportsImages"] as? Bool == true,
                        efforts: efforts
                    ),
                    creditRate: creditRate(detail["credits"])
                ))
            }
        }
        return distinctNames(out)
    }

    /// A model's credits, the multiple WorkBuddy's picker shows by it:
    /// "x0.03", "0" or 0. A rate that can't be read is none.
    static func creditRate(_ raw: Any?) -> Double? {
        let text: String
        switch raw {
        case let string as String: text = string
        case let number as Double: text = String(number)
        case let number as Int: text = String(number)
        default: return nil
        }
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if digits.hasPrefix("x") { digits = digits.dropFirst() }
        guard let rate = Double(digits), rate.isFinite, rate >= 0 else { return nil }
        return rate
    }

    /// Tells apart models the config gives the same name: WorkBuddy AI lists
    /// deepseek-v4.1-flash (free) and deepseek-v4.1-flash-sg (Singapore,
    /// x0.03 credits) both as "Deepseek-V4.1-Flash". A later one is named for
    /// what its id adds to the first's ("… (SG)"), or else its id.
    static func distinctNames(_ listings: [Listing]) -> [Listing] {
        var first: [String: String] = [:]
        return listings.map { listing in
            let model = listing.model
            guard let id = first[model.name] else {
                first[model.name] = model.id
                return listing
            }
            var tag = model.id
            if model.id.hasPrefix(id + "-"), model.id.count > id.count + 1 {
                tag = model.id.dropFirst(id.count + 1).uppercased()
            }
            var listing = listing
            listing.model.name = "\(model.name) (\(tag))"
            return listing
        }
    }

    // MARK: - Rows

    static func row(
        site: WorkBuddySite, id: String, name: String,
        contextWindow: Int, maxTokens: Int, images: Bool, efforts: [String]
    ) -> Model {
        Model(
            id: id,
            name: name,
            api: "openai-completions",
            provider: site.id,
            baseURL: site.chatBaseURL,
            reasoning: !efforts.isEmpty,
            input: images ? [.text, .image] : [.text],
            contextWindow: contextWindow,
            maxTokens: maxTokens,
            compat: compat,
            thinkingLevelMap: thinkingLevelMap(efforts: efforts)
        )
    }

    /// The chat-completions dialect WorkBuddy's gateway takes: the system
    /// prompt under `system` (a chat whose first message isn't one is
    /// refused, "first message is not system prompt"), the output limit as
    /// `max_tokens`, the level as `reasoning_effort`, and none of OpenAI's own
    /// `store`, `strict` and prompt-cache fields.
    static let compat: ModelCompat = {
        var compat = ModelCompat()
        compat.supportsStore = false
        compat.supportsDeveloperRole = false
        compat.supportsStrictMode = false
        compat.supportsReasoningEffort = true
        compat.supportsLongCacheRetention = false
        compat.maxTokensField = "max_tokens"
        compat.thinkingFormat = "openai"
        return compat
    }()

    /// WorkBuddy names a model's reasoning levels as kwwk does, and off as
    /// "none": a level it offers is sent as it is, one it doesn't is
    /// unsupported, so a request for it is clamped to one the model takes.
    static func thinkingLevelMap(efforts: [String]) -> [String: String?]? {
        guard !efforts.isEmpty else { return nil }
        var map: [String: String?] = [:]
        for level in ModelThinkingLevel.allCases {
            let wire = level == .off ? "none" : level.rawValue
            map[level.rawValue] = .some(efforts.contains(wire) ? wire : nil)
        }
        return map
    }
}
