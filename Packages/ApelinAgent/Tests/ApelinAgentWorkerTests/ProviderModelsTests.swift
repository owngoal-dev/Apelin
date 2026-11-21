import ApelinAgent
@testable import ApelinAgentWorker
import ApelinProtocol
import KWWKAI
import Testing

struct ProviderModelsTests {
    @Test(arguments: [(AgentProvider.openCodeGo, OpenCodePlan.go), (AgentProvider.openCodeZen, OpenCodePlan.zen)])
    func `OpenCode lists its plan's catalog and discovers at the plan's root`(provider: AgentProvider, plan: OpenCodePlan) throws {
        let key = OAuthCredentials(access: "key", refresh: "", expires: .max)
        #expect(ProviderModels.list(provider, credentials: key).contains(plan.defaultModel))
        let request = try #require(ProviderModels.modelRequest(provider, credentials: key))
        #expect(request.url?.absoluteString == plan.rootURL + "/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
        // the key goes to opencode.ai alone, whatever an imported credential names
        let imported = OAuthCredentials(access: "key", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://example.com/v1"),
        ])
        #expect(ProviderModels.modelRequest(provider, credentials: imported)?.url?.absoluteString
            == plan.rootURL + "/v1/models")
        #expect(try AgentWorker.provider(.init(provider: provider)) == .stored(storeID: plan.id, model: nil))
    }

    /// Antigravity's models are kwwk's list for it, as every subscription's
    /// are: nothing to discover, and its session is kwwk's stored provider.
    @Test
    func `Antigravity lists kwwk's catalog for it and is kwwk's stored provider`() throws {
        let subscription = OAuthCredentials(access: "token", refresh: "refresh", expires: 1)
        let models = ProviderModels.list(.antigravity, credentials: subscription)
        #expect(models.contains("gemini-4-argon"))
        #expect(models.contains("claude-opus-5-5"))
        #expect(ProviderModels.reasoningEfforts(.antigravity, credentials: subscription)["gemini-4-argon"]?.isEmpty == false)
        #expect(!ProviderModels.usesAPIKey(.antigravity, credentials: subscription))
        #expect(ProviderModels.modelRequest(.antigravity, credentials: subscription) == nil)
        #expect(try AgentWorker.provider(.init(provider: .antigravity)) == .stored(storeID: "antigravity", model: nil))
        #expect(try AgentWorker.provider(.init(provider: .antigravity, model: "gemini-4-argon"))
            == .stored(storeID: "antigravity", model: "gemini-4-argon"))
    }

    /// What Settings shows beside an empty limit field (#68): each model as
    /// a session resolves it, from the stored key, with no request.
    @Test
    func `the automatic limits are each model's as a session resolves it`() async {
        let relay = OAuthCredentials(access: "key", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://relay.example/v1"),
            "defaultModel": .string("relay-model"),
        ])
        let relayed = await ProviderModels.automaticLimits(.openAICompatible, credentials: relay, models: ["relay-model", "other"])
        // kwwk assumes one window and reply for every model behind an endpoint
        #expect(relayed["relay-model"] == AgentModelLimits(contextWindow: 131_072, maxOutputTokens: 32000))
        #expect(relayed["other"] == AgentModelLimits(contextWindow: 131_072, maxOutputTokens: 32000))
        let official = OAuthCredentials(access: "key", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://api.deepseek.com"),
            "defaultModel": .string("deepseek-v4-pro"),
        ])
        let deepSeek = await ProviderModels.automaticLimits(.openAICompatible, credentials: official, models: ["deepseek-v4-pro"])
        // DeepSeek's catalog row, the reply at kwwk's ceiling for an OpenAI wire
        #expect(deepSeek["deepseek-v4-pro"] == AgentModelLimits(
            contextWindow: 1_000_000,
            maxOutputTokens: OutputTokenPolicy.openAIMaximumOutputTokens,
        ))
        let key = OAuthCredentials(access: "key", refresh: "", expires: .max)
        #expect(await ProviderModels.automaticLimits(.anthropic, credentials: key, models: ["unknown-claude"])["unknown-claude"]
            == AgentModelLimits(contextWindow: 200_000, maxOutputTokens: 128_000))
    }

    @Test
    func `DeepSeek offers its own models and discovery with only an API key`() throws {
        let key = OAuthCredentials(access: "key", refresh: "", expires: .max)
        #expect(ProviderModels.list(.deepSeek, credentials: key) == ["deepseek-flash", "deepseek-v4-pro"])
        #expect(ProviderModels.reasoningEfforts(.deepSeek, credentials: key)["deepseek-flash"]?.contains(.high) == true)
        let request = try #require(ProviderModels.modelRequest(.deepSeek, credentials: key))
        #expect(request.url?.absoluteString == "https://api.deepseek.com/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
        #expect(try AgentWorker.provider(.init(provider: .deepSeek)) == .stored(storeID: CredentialProviderID.deepSeek, model: nil))
    }

    @Test
    func `DeepSeek's Anthropic endpoint lists its real models, not Claude aliases`() {
        let credentials = OAuthCredentials(access: "test", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://api.deepseek.com/anthropic"),
        ])
        #expect(ProviderModels.list(.anthropic, credentials: credentials) == ["deepseek-flash", "deepseek-v4-pro"])
    }

    @Test
    func `DeepSeek reasoning levels come from kwwk, while unknown models have no guessed capability`() {
        let credentials = OAuthCredentials(access: "test", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://api.deepseek.com/anthropic"),
        ])
        let efforts = ProviderModels.reasoningEfforts(.anthropic, credentials: credentials)
        #expect(efforts["deepseek-v4-pro"]?.contains(.high) == true)
        #expect(efforts["custom-unknown"] == nil)
    }

    @Test
    func `Codex models offer the tiers kwwk's catalog lists, and other providers none`() {
        let subscription = OAuthCredentials(access: "test", refresh: "", expires: .max)
        let tiers = ProviderModels.serviceTiers(.openAICodex, credentials: subscription)
        #expect(tiers["gpt-6.1-sol"] == [.priority, .ultrafast])
        #expect(tiers["gpt-6-sol"] == [.priority])
        let deepSeek = OAuthCredentials(access: "test", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://api.deepseek.com/anthropic"),
        ])
        #expect(ProviderModels.serviceTiers(.anthropic, credentials: deepSeek).isEmpty)
    }

    @Test
    func `a similarly named host does not receive DeepSeek's mapping`() {
        let credentials = OAuthCredentials(access: "test", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://api.deepseek.com.example.org/anthropic"),
        ])
        #expect(!ProviderModels.isDeepSeek(credentials))
    }

    @Test
    func `a configured custom model remains selectable`() {
        let credentials = OAuthCredentials(access: "test", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://example.invalid/v1"), "defaultModel": .string("custom-model"),
        ])
        #expect(ProviderModels.list(.openAICompatible, credentials: credentials) == ["custom-model"])
    }

    @Test
    func `model discovery uses the endpoint's list path and keeps the key out of the URL`() throws {
        let credentials = OAuthCredentials(access: "secret", refresh: "", expires: .max, extras: ["baseUrl": .string("https://api.deepseek.com/anthropic")])
        let request = try #require(ProviderModels.modelRequest(.anthropic, credentials: credentials))
        #expect(request.url?.absoluteString == "https://api.deepseek.com/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.url?.query == nil)
    }

    @Test
    func `OAuth accounts remain outside API-key configuration`() {
        let credentials = OAuthCredentials(access: "session", refresh: "refresh", expires: 123_456)
        #expect(!ProviderModels.usesAPIKey(.githubCopilot, credentials: credentials))
        #expect(ProviderModels.usesAPIKey(.anthropic, credentials: credentials))
    }
}
