import Foundation
import Testing
@testable import KWWKAI

@Suite("Account model lists")
struct AccountModelsTests {
    /// Copilot's `/models` as a signed-in account read it on 2026-10-13,
    /// cut to the rows that each exercise one rule.
    static let copilotList = #"""
    {"data": [
      {"id": "claude-sonnet-5", "name": "Claude Sonnet 5", "vendor": "Anthropic", "model_picker_enabled": true,
       "policy": {"state": "enabled"}, "supported_endpoints": ["/v1/messages", "/chat/completions"],
       "capabilities": {"type": "chat",
         "limits": {"max_context_window_tokens": 264000, "max_prompt_tokens": 200000, "max_output_tokens": 64000},
         "supports": {"adaptive_thinking": true, "max_thinking_budget": 32000, "tool_calls": true, "vision": true}}},
      {"id": "gpt-5-mini", "name": "GPT-5 Mini", "vendor": "Azure OpenAI", "model_picker_enabled": true,
       "policy": {"state": "enabled"}, "supported_endpoints": ["/chat/completions", "/responses", "ws:/responses"],
       "capabilities": {"type": "chat",
         "limits": {"max_context_window_tokens": 264000, "max_prompt_tokens": 128000, "max_output_tokens": 64000},
         "supports": {"reasoning_effort": ["low", "medium", "high"], "tool_calls": true, "vision": true}}},
      {"id": "claude-next-9", "name": "Claude Next 9", "vendor": "Anthropic", "model_picker_enabled": true,
       "supported_endpoints": ["/v1/messages"],
       "capabilities": {"type": "chat",
         "limits": {"max_context_window_tokens": 300000, "max_output_tokens": 50000},
         "supports": {"adaptive_thinking": true, "tool_calls": true}}},
      {"id": "old-chat", "name": "Old Chat", "model_picker_enabled": true,
       "capabilities": {"type": "chat", "limits": {"max_output_tokens": 4096}, "supports": {"tool_calls": true}}},
      {"id": "gpt-5.5", "name": "GPT-5.5", "model_picker_enabled": false, "supported_endpoints": ["/responses"],
       "capabilities": {"type": "chat", "supports": {"tool_calls": true}}},
      {"id": "switched-off", "name": "Off", "model_picker_enabled": true, "policy": {"state": "disabled"},
       "capabilities": {"type": "chat", "supports": {"tool_calls": true}}},
      {"id": "text-embedding-3-small", "name": "Embedding", "model_picker_enabled": true,
       "capabilities": {"type": "embeddings"}}
    ]}
    """#

    @Test("Copilot's list is the models its picker shows, at Copilot's limits")
    func copilotRows() throws {
        let models = try AccountModels.copilotModels(
            from: Data(Self.copilotList.utf8), baseURL: "https://api.business.githubcopilot.com"
        )
        #expect(models.map(\.id) == ["claude-sonnet-5", "gpt-5-mini", "claude-next-9", "old-chat"])
        #expect(models.allSatisfy { $0.baseURL == "https://api.business.githubcopilot.com" })
        #expect(models.allSatisfy { $0.provider == "github-copilot" })

        // A model the catalog knows keeps what the list cannot say, and
        // takes the list's limits over the vendor's native ones.
        let sonnet = models[0]
        let catalog = try #require(ModelsCatalog.model(provider: "github-copilot", id: "claude-sonnet-5"))
        #expect(sonnet.api == "anthropic-messages")
        #expect(sonnet.compat == catalog.compat)
        #expect(sonnet.thinkingLevelMap == catalog.thinkingLevelMap)
        #expect(sonnet.contextWindow == 264_000)
        #expect(sonnet.maxTokens == 64_000)

        // The window is the prompt Copilot takes plus the output it gives:
        // 264k is listed, but a prompt past 128k is refused.
        #expect(models[1].contextWindow == 192_000)
        #expect(models[1].api == "openai-responses")
    }

    @Test("A Copilot model the catalog has never seen is built from the list")
    func copilotUnknownRow() throws {
        let models = try AccountModels.copilotModels(from: Data(Self.copilotList.utf8), baseURL: "https://h")
        let next = try #require(models.first { $0.id == "claude-next-9" })
        #expect(next.name == "Claude Next 9")
        #expect(next.api == "anthropic-messages")
        #expect(next.reasoning)
        #expect(next.compat?.forceAdaptiveThinking == true)
        #expect(next.input == [.text])
        #expect(next.contextWindow == 300_000)
        #expect(next.maxTokens == 50_000)
        // No endpoints named: a chat-completions model.
        let old = try #require(models.first { $0.id == "old-chat" })
        #expect(old.api == "openai-completions")
        #expect(!old.reasoning)
        #expect(old.maxTokens == 4096)
    }

    @Test("The list is asked of the login's own host, as the editor asks it")
    func copilotFetch() async throws {
        let client = SequentialStubClient()
        client.queue.append((status: 200, body: Self.copilotList))
        let credentials = OAuthCredentials(
            access: "stale", refresh: "ghu", expires: .max,
            extras: ["endpoint": .string("https://api.business.githubcopilot.com/")]
        )
        let models = try await AccountModels.fetch(
            storeId: "github-copilot", token: "fresh", credentials: credentials, client: client
        )
        #expect(models?.count == 4)
        let request = try #require(client.recorded.first)
        #expect(request.url.absoluteString == "https://api.business.githubcopilot.com/models")
        #expect(request.method == "GET")
        #expect(request.headers["authorization"] == "Bearer fresh")
        #expect(request.headers["copilot-integration-id"] == "vscode-chat")
    }

    @Test("A provider with no list of its own answers nil without asking anyone")
    func noListing() async throws {
        let client = SequentialStubClient()
        let credentials = OAuthCredentials(access: "a", refresh: "", expires: .max)
        for storeId in ["anthropic", "openai-codex", "cursor", "zai"] {
            #expect(!AccountModels.lists(storeId: storeId))
            #expect(try await AccountModels.fetch(
                storeId: storeId, token: "t", credentials: credentials, client: client
            ) == nil)
        }
        #expect(client.recorded.isEmpty)
        #expect(AccountModels.lists(storeId: "kiro"))
        #expect(AccountModels.lists(storeId: "qoder-cn"))
    }

    @Test("A failed read keeps the list a session already has")
    func refreshKeepsLastAnswer() async throws {
        let lists = AccountModelLists()
        let credentials = OAuthCredentials(access: "a", refresh: "", expires: .max)
        #expect(lists.models(forStoreId: "github-copilot") == nil)

        let client = SequentialStubClient()
        client.queue.append((status: 200, body: Self.copilotList))
        client.queue.append((status: 500, body: "{}"))
        #expect(await lists.refresh(storeId: "github-copilot", token: "t", credentials: credentials, client: client))
        #expect(lists.models(forStoreId: "github-copilot")?.count == 4)
        #expect(await !lists.refresh(storeId: "github-copilot", token: "t", credentials: credentials, client: client))
        #expect(lists.models(forStoreId: "github-copilot")?.count == 4)

        lists.remove(storeId: "github-copilot")
        #expect(lists.models(forStoreId: "github-copilot") == nil)
    }
}
