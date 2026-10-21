import Foundation
import Testing
@testable import KWWKGenerateModelsCore

@Suite("Model catalog generator")
struct GenerateModelsCoreTests {
    @Test("converts pi-mono TypeScript catalog syntax into JSON")
    func convertsGeneratedTypeScript() throws {
        let raw = """
        import type { Model } from "./types.js";

        export const MODELS = {
          "openai": {
            "gpt-5.5": {
              id: "gpt-5.5",
              name: "GPT-5.5",
              api: "openai-responses",
              provider: "openai",
              input: ["text", "image"],
              contextWindow: 400000,
              maxTokens: 128000,
              cost: {
                input: 1.25,
                output: 10,
              },
            } satisfies Model<"openai-responses">,
          },
          "google": {},
        } as const;
        """

        let converted = try GenerateModelsCore.convert(raw)
        let data = try #require(converted.data(using: .utf8))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let openai = try #require(root["openai"] as? [String: Any])
        let model = try #require(openai["gpt-5.5"] as? [String: Any])

        #expect(model["id"] as? String == "gpt-5.5")
        #expect(model["api"] as? String == "openai-responses")
        #expect(model["contextWindow"] as? Int == 400_000)
    }

    @Test("kwwk's overrides lie over pi's catalog: merge, replace, remove")
    func appliesOverrides() throws {
        let raw = """
        export const MODELS = {
          "github-copilot": {
            "claude-sonnet-5": {
              id: "claude-sonnet-5",
              contextWindow: 1000000,
              maxTokens: 128000,
              compat: {
                forceAdaptiveThinking: true,
              },
            },
            "gemini-3.5-flash": {
              id: "gemini-3.5-flash",
              contextWindow: 1000000,
            },
          },
          "google": {
            "gemini-3.1-pro": {
              id: "gemini-3.1-pro",
              contextWindow: 1000000,
            },
          },
        } as const;
        """
        let overrides = Data(#"""
        {"$note": "why",
         "github-copilot": {
           "$note": "where it was read",
           "claude-sonnet-5": {"contextWindow": 264000, "compat": {"supportsTemperature": false}},
           "gemini-3.5-flash": null}}
        """#.utf8)
        let root = try GenerateModelsCore.generate(from: raw, overrides: overrides).root
        let copilot = try #require(root["github-copilot"] as? [String: Any])
        let sonnet = try #require(copilot["claude-sonnet-5"] as? [String: Any])
        #expect(sonnet["contextWindow"] as? Int == 264_000)
        // What the override does not name stays pi's.
        #expect(sonnet["maxTokens"] as? Int == 128_000)
        let compat = try #require(sonnet["compat"] as? [String: Any])
        #expect(compat["forceAdaptiveThinking"] as? Bool == true)
        #expect(compat["supportsTemperature"] as? Bool == false)
        #expect(copilot["gemini-3.5-flash"] == nil)
        #expect(copilot["$note"] == nil)
        #expect(root["$note"] == nil)
        #expect((root["google"] as? [String: Any])?.count == 1)
    }

    @Test("An override marked $replace stands in whole, its nulls kept")
    func replacingOverride() throws {
        let raw = """
        export const MODELS = {
          "kimi-coding": {
            "k3": {
              id: "k3",
              compat: {
                thinkingFormat: "openai",
                supportsStore: false,
              },
            },
          },
        } as const;
        """
        let overrides = Data(#"""
        {"kimi-coding": {"k3": {
          "compat": {"$replace": true, "allowEmptySignature": true},
          "thinkingLevelMap": {"$replace": true, "high": "high", "off": null}}}}
        """#.utf8)
        let root = try GenerateModelsCore.generate(from: raw, overrides: overrides).root
        let k3 = try #require((root["kimi-coding"] as? [String: Any])?["k3"] as? [String: Any])
        let compat = try #require(k3["compat"] as? [String: Any])
        #expect(compat.keys.sorted() == ["allowEmptySignature"])
        let map = try #require(k3["thinkingLevelMap"] as? [String: Any])
        #expect(map.keys.sorted() == ["high", "off"])
        #expect(map["off"] is NSNull)
    }

    @Test("The checked-in overrides are what the bundled catalog carries")
    func bundledCatalogCarriesOverrides() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let overrides = try Data(contentsOf: repo.appendingPathComponent(GenerateModelsCore.defaultOverridesPath))
        let bundled = try #require(try JSONSerialization.jsonObject(with: Data(
            contentsOf: repo.appendingPathComponent(GenerateModelsCore.defaultOutputPath)
        )) as? [String: Any])
        // Laying them over again changes nothing: a regeneration that
        // skipped them, or a hand edit that never reached them, shows here.
        let again = try GenerateModelsCore.applying(overrides: overrides, to: bundled)
        #expect(NSDictionary(dictionary: again).isEqual(to: bundled))
    }

    @Test("inlines split pi provider catalogs")
    func inlinesSplitProviderCatalogs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-generate-models-\(UUID().uuidString)")
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let generated = """
        import { OPENAI_MODELS } from "./providers/openai.models.ts";

        export const MODELS: {
          readonly "openai": typeof OPENAI_MODELS;
        } = {
          "openai": OPENAI_MODELS,
        } as const;
        """
        try generated.write(
            to: root.appendingPathComponent("models.generated.ts"),
            atomically: true,
            encoding: .utf8
        )

        let provider = """
        import type { Model } from "../types.ts";

        export const OPENAI_MODELS = {
          "gpt-5.5": {
            id: "gpt-5.5",
            name: "GPT-5.5",
            api: "openai-responses",
            provider: "openai",
            input: ["text", "image"],
            contextWindow: 400000,
            maxTokens: 128000,
          } satisfies Model<"openai-responses">,
        } as const;
        """
        try provider.write(
            to: providers.appendingPathComponent("openai.models.ts"),
            atomically: true,
            encoding: .utf8
        )

        let result = try GenerateModelsCore.generate(
            fromFile: root.appendingPathComponent("models.generated.ts")
        )
        let openai = try #require(result.root["openai"] as? [String: Any])
        let model = try #require(openai["gpt-5.5"] as? [String: Any])

        #expect(model["id"] as? String == "gpt-5.5")
        #expect(model["api"] as? String == "openai-responses")
        #expect(model["contextWindow"] as? Int == 400_000)
    }

    @Test("inlines JSON-backed split pi provider catalogs")
    func inlinesJSONBackedSplitProviderCatalogs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-generate-models-\(UUID().uuidString)")
        let providers = root.appendingPathComponent("providers")
        let data = providers.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let generated = """
        import { OPENAI_MODELS } from "./providers/openai.models.ts";

        export const MODELS = {
          "openai": OPENAI_MODELS,
        } as const;
        """
        try generated.write(
            to: root.appendingPathComponent("models.generated.ts"),
            atomically: true,
            encoding: .utf8
        )

        let provider = """
        import values from "./data/openai.json" with { type: "json" };
        import { flattenModelCatalog, type ModelCatalog } from "../model-catalog.ts";

        export const OPENAI_MODELS: ModelCatalog<typeof values, "openai"> =
          flattenModelCatalog("openai", values);
        """
        try provider.write(
            to: providers.appendingPathComponent("openai.models.ts"),
            atomically: true,
            encoding: .utf8
        )

        let values = """
        {
          "openai-responses": {
            "gpt-5.5": {
              "id": "gpt-5.5",
              "name": "GPT-5.5",
              "api": "openai-responses",
              "provider": "openai",
              "input": ["text", "image"],
              "contextWindow": 400000,
              "maxTokens": 128000
            }
          }
        }
        """
        try values.write(
            to: data.appendingPathComponent("openai.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = try GenerateModelsCore.generate(
            fromFile: root.appendingPathComponent("models.generated.ts")
        )
        let openai = try #require(result.root["openai"] as? [String: Any])
        let model = try #require(openai["gpt-5.5"] as? [String: Any])

        #expect(model["id"] as? String == "gpt-5.5")
        #expect(model["api"] as? String == "openai-responses")
        #expect(model["contextWindow"] as? Int == 400_000)
    }

    @Test("inlines chat entries from typed pi provider catalogs")
    func inlinesTypedProviderCatalogs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-generate-models-\(UUID().uuidString)")
        let providers = root.appendingPathComponent("providers")
        let data = providers.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let generated = """
        import { OPENAI_CLASSIFIER_MODELS, OPENAI_IMAGE_MODELS, OPENAI_MODELS } from "./providers/openai.models.ts";

        export const MODELS: {
        \treadonly "openai": typeof OPENAI_MODELS;
        } = {
        \t"openai": OPENAI_MODELS,
        };
        """
        try generated.write(
            to: root.appendingPathComponent("models.generated.ts"),
            atomically: true,
            encoding: .utf8
        )

        let provider = """
        import values from "./data/openai.json" with { type: "json" };
        import { flattenChatModelCatalog, flattenImageModelCatalog, type ChatModelCatalog, type ImageModelCatalog } from "../model-catalog.ts";

        export const OPENAI_MODELS: ChatModelCatalog<typeof values, "openai"> =
        \tflattenChatModelCatalog("openai", values);

        export const OPENAI_IMAGE_MODELS: ImageModelCatalog<typeof values, "openai"> =
        \tflattenImageModelCatalog("openai", values);
        """
        try provider.write(
            to: providers.appendingPathComponent("openai.models.ts"),
            atomically: true,
            encoding: .utf8
        )

        let values = """
        {
          "openai-responses": {
            "chat:gpt-5.5": {
              "id": "gpt-5.5",
              "name": "GPT-5.5",
              "api": "openai-responses",
              "provider": "openai",
              "contextWindow": 400000,
              "type": "chat"
            }
          },
          "openai-images": {
            "image:gpt-image-2": {
              "id": "gpt-image-2",
              "api": "openai-images",
              "provider": "openai",
              "type": "image"
            }
          }
        }
        """
        try values.write(
            to: data.appendingPathComponent("openai.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = try GenerateModelsCore.generate(
            fromFile: root.appendingPathComponent("models.generated.ts")
        )
        let openai = try #require(result.root["openai"] as? [String: Any])
        let model = try #require(openai["gpt-5.5"] as? [String: Any])

        #expect(openai.keys.sorted() == ["gpt-5.5"])
        #expect(model["contextWindow"] as? Int == 400_000)
        #expect(model["type"] == nil)
    }

    @Test("preserves providers from the source catalog")
    func preservesSourceProviders() throws {
        let raw = """
        export const MODELS = {
          "google": {},
          "google-vertex": {},
        } as const;
        """

        let result = try GenerateModelsCore.generate(from: raw)

        #expect(result.root.keys.contains("google"))
        #expect(result.root.keys.contains("google-vertex"))
        #expect(result.root.count == 2)
    }

    @Test("writes concise decimal prices")
    func writesConciseDecimalPrices() throws {
        let raw = """
        export const MODELS = {
          "openai": {
            "example": {
              id: "example",
              name: "Example",
              api: "openai-responses",
              provider: "openai",
              cost: { "input": 0.33, "output": 2.75 },
            },
          },
        } as const;
        """

        let result = try GenerateModelsCore.generate(from: raw)
        let output = try #require(String(data: result.outputData, encoding: .utf8))

        #expect(output.contains(#""input" : 0.33"#))
        #expect(!output.contains("0.33000000000000002"))
    }
}
