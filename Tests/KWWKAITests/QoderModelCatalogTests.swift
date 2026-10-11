import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Ported from magpie's `internal/qoder/models_test.go`, `auth_test.go`
// (TestParseModels) and the listing fixtures of `internal/gateway/qoder_test.go`.

/// magpie's `testQoderModel`: Qwen3.8-Flash as Qoder lists it.
let qoderFlashListing = #"""
{"chat":[{"key":"qfmodel","enable":true,"display_name":"Qwen3.8-Flash","format":"openai","source":"system","is_vl":true,"is_reasoning":true,"max_input_tokens":200000,
 "thinking_config":{"disabled":{"description":"Disable thinking"},"enabled":{"is_default":true,"efforts":{"xhigh":{},"medium":{"is_default":true},"low":{}}}}}]}
"""#

/// A model that cannot stop thinking: no `disabled` branch.
let qoderAlwaysThinkingListing = #"{"chat":[{"key":"gf","enable":true,"is_reasoning":true,"thinking_config":{"enabled":{"is_default":true,"efforts":{"max":{"is_default":true},"high":{},"low":{}}}}}]}"#

func qoderListed(_ listing: String) throws -> QoderModelInfo {
    try #require(try QoderModels.parse(Data(listing.utf8)).first)
}

@Suite("Qoder model listing")
struct QoderModelListingTests {
    private func parse(_ listing: String) throws -> [QoderModelInfo] {
        try QoderModels.parse(Data(listing.utf8))
    }

    @Test("Enabled, routable chat models are kept; the aggregate `auto` and disabled entries are dropped")
    func parseModels() throws {
        let models = try parse(#"""
        {"chat":[
            {"key":"qfmodel","display_name":"Qwen3.8-Flash","enable":true,"is_vl":true,"max_input_tokens":200000},
            {"key":"auto","enable":true},
            {"key":"default","enable":true},
            {"key":"off-model","enable":false}]}
        """#)
        #expect(models.count == 1)
        let model = try #require(models.first)
        #expect(model.key == "qfmodel")
        #expect(model.displayName == "Qwen3.8-Flash")
        #expect(model.maxInputTokens == 200_000)
        #expect(model.readsImages)
        #expect(!model.thinks)
    }

    @Test("A listing that is not JSON is refused; one without chat models is empty")
    func malformed() throws {
        #expect(throws: QoderModels.ListingError.self) { _ = try parse("<html>") }
        #expect(try parse("{}").isEmpty)
        #expect(try parse(#"{"inline":[{"key":"x","enable":true}],"chat":[]}"#).isEmpty)
    }

    @Test("Each model keeps its entry exactly as listed, whatever surrounds it")
    func rawConfig() throws {
        let first = #"{"key":"a","enable":true,"note":"braces } ] and a \" quote","price_factor":0.50,"nested":{"list":[1,2,{"x":null}]}}"#
        let second = #"{ "key" : "b", "enable" : true, "custom_field" : 17 }"#
        let models = try parse(#"{"version":3,"other":[{"chat":[]}],"chat": [ \#(first) ,\#(second)], "tail":"chat"}"#)
        #expect(models.map(\.config) == [first, second])
        // A dropped entry does not shift the ones after it.
        let kept = try parse(#"{"chat":[{"key":"auto","enable":true},\#(second)]}"#)
        #expect(kept.map(\.config) == [second])
    }

    @Test("Efforts come from thinking_config, weakest first; a model with no disabled branch always thinks")
    func thinkingConfig() throws {
        let flash = try qoderListed(qoderFlashListing)
        #expect(flash.thinks)
        #expect(!flash.alwaysThinks)
        #expect(flash.efforts == ["low", "medium", "xhigh"])
        #expect(flash.source == "system")

        let always = try qoderListed(qoderAlwaysThinkingListing)
        #expect(always.thinks)
        #expect(always.alwaysThinks)
        #expect(always.efforts == ["low", "high", "max"])
        #expect(always.displayName == "gf")

        // A config with only a disabled branch does not think, whatever
        // is_reasoning says; without a config is_reasoning stands.
        let models = try parse(#"""
        {"chat":[
            {"key":"off","enable":true,"is_reasoning":true,"thinking_config":{"disabled":{}}},
            {"key":"bare","enable":true,"is_reasoning":true},
            {"key":"plain","enable":true}]}
        """#)
        #expect(models.map(\.thinks) == [false, true, false])
        #expect(models.allSatisfy { $0.efforts.isEmpty && !$0.alwaysThinks })
    }

    @Test("A model at a price_factor of 0 is free, in snake or camel case; is_free counts only on a listing with no price")
    func free() throws {
        let models = try parse(#"""
        {"chat":[
            {"key":"flag","enable":true,"is_free":true,"price_factor":1},
            {"key":"camel-flag","enable":true,"isFree":true},
            {"key":"zero","enable":true,"price_factor":0},
            {"key":"camel-zero","enable":true,"priceFactor":0},
            {"key":"paid","enable":true,"is_free":false,"price_factor":0.5},
            {"key":"unsaid","enable":true}
        ]}
        """#)
        #expect(Dictionary(uniqueKeysWithValues: models.map { ($0.key, $0.isFree) }) == [
            "flag": false, "camel-flag": true, "zero": true, "camel-zero": true, "paid": false, "unsaid": false,
        ])
    }

    // Qoder's listing as it came on 2026-10-02: its app shows Qwen3.8-Max at
    // 0.5× with an off-peak badge, Qwen3.8-Flash at 0× with 0.1× struck
    // through — both carry is_free true. Only Flash is free.
    @Test("Free is the price, not the flag: a running promotion's 0 is a discount")
    func freeIsThePrice() throws {
        let offPeak = #"{"active":false,"badge":{"en":"Off-Peak 60% off","zh":"错峰 4 折"},"timezone":"Asia/Singapore","rule_id":"idle_time_model_credit_discount","discount_factor":0.4,"before_promotion_price_factor":0.5,"window_start":"22:00","window_end":"08:00"}"#
        let models = try parse(#"""
        {"chat":[
            {"key":"qmodel_38max","display_name":"Qwen3.8-Max","enable":true,"is_reasoning":true,"price_factor":0.5,"is_free":true,"promotion":\#(offPeak)},
            {"key":"qfmodel","display_name":"Qwen3.8-Flash","enable":true,"is_reasoning":true,"price_factor":0.0,"original_price_factor":0.1,"is_free":true},
            {"key":"qmodel_latest","display_name":"Qwen3.7-Max","enable":true,"price_factor":0.5,"original_price_factor":0.5},
            {"key":"kmodel_latest","display_name":"Kimi-K3","enable":true,"price_factor":1.4,"is_free":false},
            {"key":"window","enable":true,"price_factor":0,"is_free":true,"promotion":{"active":true,"discount_factor":0.0001,"before_promotion_price_factor":0.5}},
            {"key":"window-camel","enable":true,"priceFactor":0,"promotion":{"active":true,"beforePromotionPriceFactor":1}},
            {"key":"over","enable":true,"price_factor":0,"promotion":{"active":false,"before_promotion_price_factor":0.5}},
            {"key":"nothing","enable":true,"price_factor":0,"promotion":{"active":true,"before_promotion_price_factor":0}},
            {"key":"unpriced","enable":true,"is_free":true},
            {"key":"unpriced2","enable":true,"is_free":false}
        ]}
        """#)
        #expect(Dictionary(uniqueKeysWithValues: models.map { ($0.key, $0.isFree) }) == [
            "qmodel_38max": false, "qfmodel": true, "qmodel_latest": false, "kmodel_latest": false,
            "window": false, "window-camel": false, "over": true, "nothing": true, "unpriced": true, "unpriced2": false,
        ])
    }

    @Test("Each model carries its price as Qoder's client shows it, and the price before a discount")
    func rate() throws {
        let models = try parse(#"""
        {"chat":[
            {"key":"qmodel_38max","enable":true,"price_factor":0.5,"is_free":true,"promotion":{"active":false,"discount_factor":0.4,"before_promotion_price_factor":0.5}},
            {"key":"qmodel_38max-offpeak","enable":true,"price_factor":0.2,"promotion":{"active":true,"discount_factor":0.4,"before_promotion_price_factor":0.5}},
            {"key":"qfmodel","enable":true,"price_factor":0.0,"original_price_factor":0.1,"is_free":true},
            {"key":"qmodel_latest","enable":true,"price_factor":0.5,"original_price_factor":0.5},
            {"key":"kmodel_latest","enable":true,"priceFactor":1.4,"originalPriceFactor":2},
            {"key":"window","enable":true,"price_factor":0,"promotion":{"active":true,"discount_factor":0.5,"before_promotion_price_factor":1}},
            {"key":"window-camel","enable":true,"priceFactor":0,"promotion":{"active":true,"discountFactor":0.25,"beforePromotionPriceFactor":2}},
            {"key":"unpriced","enable":true,"is_free":true}
        ]}
        """#)
        #expect(Dictionary(uniqueKeysWithValues: models.map { ($0.key, [$0.rate, $0.rateWas]) }) == [
            "qmodel_38max": [0.5, 0], "qmodel_38max-offpeak": [0.2, 0.5], "qfmodel": [0, 0.1],
            "qmodel_latest": [0.5, 0], "kmodel_latest": [1.4, 2], "window": [0.5, 1], "window-camel": [0.5, 2],
            "unpriced": [0, 0],
        ])
    }
}

@Suite("Qoder catalog rows")
struct QoderCatalogTests {
    @Test("A listed model becomes a row on its site, offering the levels it names")
    func rows() throws {
        let flash = QoderModels.model(try qoderListed(qoderFlashListing), site: .cn)
        #expect(flash.id == "qfmodel")
        #expect(flash.name == "Qwen3.8-Flash")
        #expect(flash.api == "qoder-chat")
        #expect(flash.provider == "qoder-cn")
        #expect(flash.baseURL == "https://gateway.qoder.com.cn")
        #expect(flash.input == [.text, .image])
        #expect(flash.contextWindow == 200_000)
        #expect(supportedThinkingLevels(flash) == [.off, .low, .medium, .xhigh])

        // One that cannot stop thinking does not offer off.
        let always = QoderModels.model(try qoderListed(qoderAlwaysThinkingListing), site: .global)
        #expect(always.provider == "qoder")
        #expect(always.baseURL == "https://api3.qoder.sh")
        #expect(supportedThinkingLevels(always) == [.low, .high, .max])
        #expect(always.contextWindow == QoderModels.defaultContextWindow)

        let plain = QoderModels.model(try qoderListed(#"{"chat":[{"key":"plain","enable":true}]}"#), site: .global)
        #expect(!plain.reasoning)
        #expect(plain.input == [.text])
        #expect(plain.thinkingLevelMap == nil)
    }

    @Test("The bundled seed lists the same models under both sites, each on its own host")
    func bundledSeed() throws {
        let global = try #require(ModelsCatalog.model(provider: "qoder", id: QoderModels.defaultModelId))
        let cn = try #require(ModelsCatalog.model(provider: "qoder-cn", id: QoderModels.defaultModelId))
        #expect(global.api == "qoder-chat")
        #expect(global.baseURL == QoderSite.global.api)
        #expect(cn.provider == "qoder-cn")
        #expect(cn.baseURL == QoderSite.cn.api)
        #expect(ModelsCatalog.models(for: "qoder").map(\.id) == ModelsCatalog.models(for: "qoder-cn").map(\.id))
        #expect(ModelsCatalog.models(for: "qoder").allSatisfy { $0.api == "qoder-chat" && $0.provider == "qoder" })
        #expect(qoderModel(id: QoderModels.defaultModelId, site: .cn) == cn)
    }

    @Test("A model the seed doesn't carry still routes: the request is built from the live listing")
    func fallbackRow() {
        let model = qoderModel(id: "some-new-model", site: .cn)
        #expect(model.id == "some-new-model")
        #expect(model.api == "qoder-chat")
        #expect(model.provider == "qoder-cn")
        #expect(model.baseURL == "https://gateway.qoder.com.cn")
    }

    @Test("The listing is fetched with the COSY envelope, signed over an empty body")
    func fetch() async throws {
        let client = QoderStubClient(["/algo/api/v2/model/list": [.init(body: qoderFlashListing)]])
        let credentials = OAuthCredentials(
            access: "jt-one", refresh: "rt-one", expires: .max,
            extras: ["uid": "uid-one", "machineId": "machine-one", "deviceToken": "dt-one"]
        )
        let models = try await QoderModels.fetch(site: .cn, credentials: credentials, client: client)
        #expect(models.map(\.id) == ["qfmodel"])
        #expect(models.first?.provider == "qoder-cn")

        let request = try #require(client.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://gateway.qoder.com.cn/algo/api/v2/model/list?Encode=1")
        #expect(request.body == nil)
        #expect(request.headers["Cosy-MachineId"] == "machine-one")
        #expect(request.headers["Cosy-MachineOS"] == QoderCosy.machineOS)
        #expect(request.headers["Cosy-User"] == "uid-one")
        let authorization = try #require(request.headers["Authorization"])
        let parts = authorization.dropFirst("Bearer COSY.".count).split(separator: ".").map(String.init)
        #expect(parts.last == QoderCosy.signature(
            payload: parts[0], key: request.headers["Cosy-Key"] ?? "",
            timestamp: Int64(request.headers["Cosy-Date"] ?? "") ?? 0,
            body: "", path: "/api/v2/model/list"
        ))
    }

    @Test("A login with no account id cannot be listed; a refused listing is a sign-in failure")
    func fetchFailures() async throws {
        await #expect(throws: ProviderFailure.self) {
            _ = try await QoderModels.fetch(
                site: .global, credentials: OAuthCredentials(access: "jt", refresh: "rt", expires: .max),
                client: QoderStubClient([:])
            )
        }
        let client = QoderStubClient(["/algo/api/v2/model/list": [.init(status: 401, body: #"{"message":"token expired"}"#)]])
        do {
            _ = try await QoderModels.fetch(
                site: .global,
                credentials: OAuthCredentials(access: "jt", refresh: "rt", expires: .max, extras: ["uid": "u", "machineId": "m"]),
                client: client
            )
            Issue.record("a refused listing answered")
        } catch let failure as ProviderFailure {
            #expect(failure.category == .authentication)
        }
    }
}
