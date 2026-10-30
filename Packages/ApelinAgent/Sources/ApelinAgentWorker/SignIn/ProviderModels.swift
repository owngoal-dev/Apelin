import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI

/// The endpoint's model family is distinct from its wire format. DeepSeek's
/// Anthropic endpoint accepts Claude aliases but still runs DeepSeek models.
enum ProviderModels {
    /// The extra a sign-in records its method in, where the provider offers more than one.
    static let signInMethodExtra = "apelinSignInMethod"

    static func usesAPIKey(_ provider: AgentProvider, credentials: OAuthCredentials) -> Bool {
        if case let .string(method)? = credentials.extras[signInMethodExtra] {
            return method == AgentSignInMethod.apiKey.rawValue
        }
        return provider.signInMethod == .apiKey
    }

    static func isDeepSeek(_ credentials: OAuthCredentials) -> Bool {
        DeepSeekProvider.isOfficial(credentials)
    }

    /// The kwwk model catalog the account's models come from.
    private static func catalogKey(_ provider: AgentProvider, credentials: OAuthCredentials) -> String? {
        // kwwk's providerDirectory has no OpenCode Go entry yet, but its
        // catalog carries the models.
        if provider == .openCodeGo { return OpenCodeGoProvider.catalogKey }
        return provider == .deepSeek || isDeepSeek(credentials) ? "deepseek" : providerDescriptor(forStoreId: provider.storeID)?.catalogKey
    }

    static func list(_ provider: AgentProvider, credentials: OAuthCredentials) -> [String] {
        let catalog = catalogKey(provider, credentials: credentials)
        var models = catalog.map { ModelsCatalog.models(for: $0).map(\.id) } ?? []
        if case let .string(model)? = credentials.extras[AgentSignInField.defaultModel.rawValue], !model.isEmpty {
            models.removeAll { $0 == model }
            models.insert(model, at: 0)
        }
        return models
    }

    static func reasoningEfforts(
        _ provider: AgentProvider,
        credentials: OAuthCredentials,
    ) -> [String: [AgentReasoningEffort]] {
        guard let catalog = catalogKey(provider, credentials: credentials) else { return [:] }
        return Dictionary(uniqueKeysWithValues: ModelsCatalog.models(for: catalog).filter(\.reasoning).map { model in
            (model.id, supportedThinkingLevels(model).compactMap { AgentReasoningEffort(rawValue: $0.rawValue) })
        })
    }

    /// The tiers Apelin offers that the catalog lists for each of the
    /// provider's models (only ChatGPT Codex's, today); a model with none is
    /// left out.
    static func serviceTiers(
        _ provider: AgentProvider,
        credentials: OAuthCredentials,
    ) -> [String: [AgentServiceTier]] {
        guard let catalog = catalogKey(provider, credentials: credentials) else { return [:] }
        return Dictionary(uniqueKeysWithValues: ModelsCatalog.models(for: catalog).compactMap { model in
            let tiers = (model.compat?.serviceTiers ?? []).compactMap { AgentServiceTier(rawValue: $0.rawValue) }
            return tiers.isEmpty ? nil : (model.id, tiers)
        })
    }

    static func fetch(_ provider: AgentProvider, credentials: OAuthCredentials) async throws -> [String] {
        guard usesAPIKey(provider, credentials: credentials),
              let request = modelRequest(provider, credentials: credentials)
        else { return list(provider, credentials: credentials) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count <= 4 * 1024 * 1024,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = (root["data"] ?? root["models"]) as? [[String: Any]]
            else { throw ApelinError(.unavailable, "The provider did not return a model list.") }
            let ids = models.compactMap { ($0["id"] ?? $0["name"]) as? String }
                .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
                .filter { !$0.isEmpty && $0.count <= 256 }
            return Array(Set(ids)).sorted()
        } catch is CancellationError { throw CancellationError() }
        catch { throw ApelinError(.unavailable, "Unable to fetch models. You can retry or add a model ID manually.") }
    }

    static func modelRequest(_ provider: AgentProvider, credentials: OAuthCredentials) -> URLRequest? {
        let configured: String? = if case let .string(value)? = credentials.extras[AgentSignInField.baseURL.rawValue] {
            value
        } else {
            nil
        }
        let defaultURL = provider.keyFields.first { $0.field == .baseURL }?.defaultValue
            ?? (provider == .openRouter ? "https://openrouter.ai/api/v1" : nil)
            ?? (provider == .openCodeGo ? OpenCodeGoProvider.modelListBaseURL : nil)
        guard let base = configured ?? defaultURL, var url = URLComponents(string: base) else { return nil }
        if url.host?.lowercased() == "api.deepseek.com" {
            url.path = "/models"
        } else if provider == .anthropic {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            url.path = "/" + path + (path.hasSuffix("v1") ? "/models" : "/v1/models")
            url.path = url.path.replacingOccurrences(of: "//", with: "/")
        } else if provider == .openAI || provider == .openAICompatible || provider == .openRouter || provider == .deepSeek
            || provider == .openCodeGo {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            url.path = "/" + (path.isEmpty ? "v1" : path) + "/models"
        } else if provider == .google {
            url.path = "/v1beta/models"
        } else {
            return nil
        }
        guard let endpoint = url.url else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        if provider == .anthropic, !isDeepSeek(credentials) {
            request.setValue(credentials.access, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if provider == .google {
            request.setValue(credentials.access, forHTTPHeaderField: "x-goog-api-key")
        } else {
            request.setValue("Bearer \(credentials.access)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
