import ApelinAgent
@testable import ApelinAgentWorker
import ApelinProtocol
import KWWKAI
import Testing

struct ProviderModelsTests {
    @Test
    func `OpenCode Go offers kwwk's catalog and its own discovery endpoint`() throws {
        let key = OAuthCredentials(access: "key", refresh: "", expires: .max)
        let models = ProviderModels.list(.openCodeGo, credentials: key)
        #expect(models.contains("glm-5.2"))
        #expect(models.contains("claude-haiku-5-5"))
        #expect(models.contains("deepseek-v4.1-flash"))
        #expect(ProviderModels.reasoningEfforts(.openCodeGo, credentials: key)["glm-5.2"]?.contains(.high) == true)
        let request = try #require(ProviderModels.modelRequest(.openCodeGo, credentials: key))
        #expect(request.url?.absoluteString == "https://opencode.ai/inference/go/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
        #expect(request.url?.query == nil)
        #expect(try AgentWorker.provider(.init(provider: .openCodeGo))
            == .stored(storeID: CredentialProviderID.openCodeGo, model: nil))
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
