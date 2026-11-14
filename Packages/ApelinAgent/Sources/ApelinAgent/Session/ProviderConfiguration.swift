import ApelinProtocol
import Foundation
import KWWKAI

/// Which model a session talks to. Credentials are not part of this value:
/// they come from the session's `CredentialSource`, by kwwk store id.
public enum ProviderConfiguration: Sendable, Hashable, Codable {
    /// Anthropic's native Messages API with an API key
    /// (`anthropic-api-key`), or with an Anthropic OAuth sign-in
    /// (`anthropic`) when `oauth` is set.
    case anthropic(model: String, oauth: Bool = false)
    /// Any OpenAI-compatible Chat Completions endpoint. The base URL lives
    /// with the credential (kwwk's `baseUrl` extra) so an endpoint and its
    /// key cannot be mismatched.
    case openAICompatible(model: String)
    /// GitHub Copilot, through kwwk's Copilot provider: kwwk exchanges the
    /// stored GitHub token for a Copilot session token and routes each model
    /// to its wire format.
    case githubCopilot(model: String)
    /// Any other login kwwk stores, by its store id (`openai-codex`,
    /// `kimi-coding`, `google-api-key`, …), registered by kwwk's own
    /// `registerStored`, or Apelin's DeepSeek registration. A nil model is
    /// the provider's own default.
    case stored(storeID: String, model: String?)
    /// A model already registered on kwwk's `APIRegistry` (tests and
    /// in-process fakes). Needs no credential.
    case registered(Model)

    var storeID: String? {
        switch self {
        case let .anthropic(_, oauth):
            oauth ? CredentialProviderID.anthropicOAuth : CredentialProviderID.anthropicAPIKey
        case .openAICompatible: CredentialProviderID.openAICompatible
        case .githubCopilot: CredentialProviderID.githubCopilot
        case let .stored(storeID, _): storeID
        case .registered: nil
        }
    }

    var modelID: String? {
        switch self {
        case let .anthropic(model, _), let .openAICompatible(model), let .githubCopilot(model): model
        case let .stored(_, model): model
        case let .registered(model): model.id
        }
    }
}

public enum ProviderResolutionError: Error, Equatable, LocalizedError {
    /// No credential for this provider; the session waits for the app to
    /// deliver or sign in again. Nothing is read from the environment.
    case missingCredentials(String)
    /// The sign-in is saved, and could not be exchanged or renewed for a
    /// session: the request for it failed, in these words and, where it
    /// can be told, for this reason.
    case unresolved(message: String, reason: ApelinError.Reason?)

    public var errorDescription: String? {
        switch self {
        case let .missingCredentials(id): "No saved sign-in for \(id). Sign in again in Apelin."
        case let .unresolved(message, _): message
        }
    }
}

struct ResolvedProvider: Sendable {
    var model: Model
    var authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
    /// The stored sign-in it was resolved from; nil for one that needs none.
    var credentials: OAuthCredentials?
}

enum ProviderResolver {
    /// How long a sign-in's exchange or renewal may take. A session's open
    /// and a message that changes its provider wait on it, with the app's
    /// send behind them, and kwwk's own request gives a connection that
    /// answers nothing five minutes.
    static let exchangeWait: Duration = .seconds(20)

    /// Registers the provider on kwwk's registry from `credentials`, with
    /// the same model capabilities used when verifying the account. A
    /// sign-in that is saved and cannot be exchanged or renewed within
    /// `wait` is `ProviderResolutionError.unresolved`, with the reason
    /// `network` explains: no route, or a provider out of reach.
    static func resolve(
        _ configuration: ProviderConfiguration,
        credentials: any CredentialSource,
        network: NetworkPath = .system,
        wait: Duration = exchangeWait,
    ) async throws -> ResolvedProvider {
        let stored = try await storedCredentials(configuration, in: credentials)
        guard let storeID = configuration.storeID else {
            if case let .registered(model) = configuration {
                return ResolvedProvider(model: model, authResolver: nil)
            }
            preconditionFailure("unreachable")
        }
        // OAuthManager(source:) keeps refreshed tokens in its own memory and
        // never writes them anywhere. Its refreshers are kwwk's own, with
        // Kimi's given an identity so that it never reaches for ~/.kwwk.
        let manager = OAuthManager(source: credentials, providers: KimiIdentity.refreshers())
        let modelID = configuration.modelID
        let resolved: ResolvedAuth?
        do {
            resolved = try await Deadline.within(wait) {
                try await ProviderRegistration.resolve(storeID: storeID, manager: manager, modelOverride: modelID)
            }
        } catch is Deadline.Exceeded {
            throw ProviderResolutionError.unresolved(
                message: "The model provider did not answer in time.",
                reason: network.isSatisfied() ? .timeout : .offline,
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderResolutionError.unresolved(
                message: ErrorDescription.localized(error.localizedDescription),
                reason: FailureReason.of(error, hasRoute: network.isSatisfied()),
            )
        }
        guard let resolved else {
            throw ProviderResolutionError.missingCredentials(storeID)
        }
        return ResolvedProvider(model: resolved.model, authResolver: resolved.authResolver, credentials: stored)
    }

    /// The stored sign-in `configuration` needs, nil for one that needs
    /// none; missing, it is an error.
    static func storedCredentials(
        _ configuration: ProviderConfiguration,
        in credentials: any CredentialSource,
    ) async throws -> OAuthCredentials? {
        guard let storeID = configuration.storeID else { return nil }
        guard let stored = try await credentials.credentials(for: storeID) else {
            throw ProviderResolutionError.missingCredentials(storeID)
        }
        return stored
    }
}
