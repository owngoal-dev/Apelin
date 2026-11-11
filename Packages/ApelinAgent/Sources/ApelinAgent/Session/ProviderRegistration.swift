import Foundation
import KWWKAI

/// The same registration for account verification and conversation requests.
/// kwwk owns the transports; Apelin adds DeepSeek's separate credential and
/// restores the catalog capabilities its generic Chat Completions login loses.
public enum ProviderRegistration {
    public static func resolve(
        storeID: String,
        manager: OAuthManager,
        modelOverride: String? = nil,
    ) async throws -> ResolvedAuth? {
        guard let credentials = try await manager.credentials(for: storeID) else { return nil }
        if storeID == CredentialProviderID.deepSeek {
            let id = modelOverride ?? DeepSeekProvider.extra("defaultModel", in: credentials) ?? DeepSeekProvider.defaultModel
            let base = DeepSeekProvider.extra("baseUrl", in: credentials) ?? DeepSeekProvider.baseURL
            let fallback = Model(id: id, api: "openai-completions", provider: "deepseek", baseURL: base)
            let model = DeepSeekProvider.applyingCatalog(to: fallback)
            await APIRegistry.shared.register(OpenAICompletionsProvider(), scope: model.provider)
            return ResolvedAuth(model: model, modelLabel: "\(model.name) from DeepSeek", authResolver: { _, _ in
                ResolvedProviderAuth(token: credentials.access, scheme: .bearer)
            })
        }
        guard let resolved = try await registerStored(storeId: storeID, manager: manager, modelOverride: modelOverride) else {
            return nil
        }
        guard storeID == CredentialProviderID.openAICompatible else {
            return resolved
        }
        // The registry's transport is shared. Bind the key to this resolution
        // so another account verification cannot replace an in-flight key.
        return ResolvedAuth(
            model: DeepSeekProvider.isOfficial(credentials) ? DeepSeekProvider.applyingCatalog(to: resolved.model) : resolved.model,
            modelLabel: resolved.modelLabel,
            authResolver: { _, _ in ResolvedProviderAuth(token: credentials.access, scheme: .bearer) },
            providerSlots: resolved.providerSlots,
            authResolvers: resolved.authResolvers,
        )
    }
}

public enum DeepSeekProvider {
    public static let baseURL = "https://api.deepseek.com"
    public static let defaultModel = "deepseek-flash"

    public static func isOfficial(_ credentials: OAuthCredentials) -> Bool {
        guard let base = extra("baseUrl", in: credentials) else { return false }
        return URLComponents(string: base)?.host?.lowercased() == "api.deepseek.com"
    }

    /// Only documented aliases inherit Flash's capabilities. Unknown IDs keep
    /// their original configuration, and the selected wire ID is never renamed.
    static func applyingCatalog(to original: Model) -> Model {
        let catalogID: String = switch original.id {
        case "deepseek-v4-flash", "deepseek-v4-flash-vision-exp": defaultModel
        default: original.id
        }
        guard var model = ModelsCatalog.model(provider: "deepseek", id: catalogID) else { return original }
        model.id = original.id
        model.api = original.api
        model.provider = original.provider
        model.baseURL = original.baseURL
        model.headers = original.headers
        return model
    }

    static func extra(_ key: String, in credentials: OAuthCredentials) -> String? {
        guard case let .string(value)? = credentials.extras[key], !value.isEmpty else { return nil }
        return value
    }
}
