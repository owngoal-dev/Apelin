import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI

/// How each provider is signed in to, and the store id its credential
/// is kept under — the one `ProviderConfiguration` reads it back by.
///
/// The list covers every kwwk login plus Apelin's DeepSeek and OpenCode Go
/// API accounts. Display order is a product choice, independent of
/// registration priority.
public extension AgentProvider {
    /// Settings groups signed-in accounts, account sign-ins and API keys,
    /// preserving this order within each group.
    static let signInOrder: [AgentProvider] = {
        let order: [AgentProvider] = [
            .openAICodex, .anthropicOAuth, .githubCopilot, .cursor,
            .workBuddyAI, .workBuddy, .kimiCoding, .xai, .openRouter,
            .zai, .zaiCodingCN, .qoder, .qoderCN, .kiro, .devin,
            .openAI, .deepSeek, .openCodeGo, .google, .anthropic, .openAICompatible,
        ]
        // New providers remain reachable until their position is chosen.
        return order + allCases.filter { !order.contains($0) }
    }()

    var storeID: String {
        switch self {
        case .githubCopilot: CredentialProviderID.githubCopilot
        case .anthropicOAuth: CredentialProviderID.anthropicOAuth
        case .anthropic: CredentialProviderID.anthropicAPIKey
        case .openAICompatible: CredentialProviderID.openAICompatible
        case .openAICodex: "openai-codex"
        case .cursor: "cursor"
        case .devin: "devin"
        case .kiro: "kiro"
        case .qoder: QoderSite.global.id
        case .qoderCN: QoderSite.cn.id
        case .workBuddy: WorkBuddySite.china.id
        case .workBuddyAI: WorkBuddySite.international.id
        case .kimiCoding: "kimi-coding"
        case .xai: "xai"
        case .zai: ZaiSite.global.id
        case .zaiCodingCN: ZaiSite.china.id
        case .openRouter: "openrouter"
        case .openAI: "openai-api-key"
        case .google: "google-api-key"
        case .deepSeek: CredentialProviderID.deepSeek
        case .openCodeGo: CredentialProviderID.openCodeGo
        }
    }

    /// What `agentSignIn` runs when it names no method. A subscription's
    /// flow is kwwk's: a device code where kwwk's login announces one (RFC
    /// 8628), otherwise its page in the browser.
    var signInMethod: AgentSignInMethod {
        switch self {
        case .githubCopilot, .kimiCoding, .xai:
            .deviceCode
        case .anthropicOAuth, .openAICodex, .cursor, .devin, .kiro, .qoder, .qoderCN, .workBuddy, .workBuddyAI,
             .zai, .zaiCodingCN, .openRouter:
            .browser
        case .anthropic, .openAICompatible, .openAI, .google, .deepSeek, .openCodeGo:
            .apiKey
        }
    }

    /// Every method `agentSignIn` takes for this provider, its own first:
    /// kwwk offers OpenRouter both ways, a browser sign-in that mints a key
    /// and a key typed in, kept under the same store id.
    var signInMethods: [AgentSignInMethod] {
        var methods = [signInMethod]
        if signInMethod != .apiKey, SignInKeyForms.fields(for: self) != nil {
            methods.append(.apiKey)
        }
        return methods
    }

    /// The fields a typed-key sign-in asks for; empty for a provider that
    /// takes no key.
    internal var keyFields: [KeyField] {
        SignInKeyForms.fields(for: self) ?? []
    }
}

struct KeyField: Sendable, Equatable {
    var field: AgentSignInField
    var required: Bool
    var defaultValue: String?
    /// What the empty field shows, as kwwk's form does: never a real key.
    var placeholder: String?

    var secure: Bool {
        field == .apiKey
    }
}

/// KWWKCli's API-key login forms (`loginProviders`, the `.apiKey` entries),
/// field for field: what each asks for, what it may leave out, and its
/// defaults. KWWKCli is an executable target, not a library, so this is the
/// one copy, with Apelin's DeepSeek and OpenCode Go forms added.
/// `extrasKeys` there is every field but the key, which
/// `AccountDesk.apiKeyCredentials` keeps as extras.
enum SignInKeyForms {
    struct Form: Sendable {
        var provider: AgentProvider
        var fields: [KeyField]
    }

    static let all: [Form] = [
        Form(provider: .anthropic, fields: [
            KeyField(field: .apiKey, required: true, placeholder: "sk-ant-api03-…"),
            KeyField(field: .baseURL, required: false, defaultValue: "https://api.anthropic.com"),
        ]),
        Form(provider: .openAI, fields: [
            KeyField(field: .apiKey, required: true, placeholder: "sk-proj-…"),
            KeyField(field: .baseURL, required: false, defaultValue: "https://api.openai.com"),
        ]),
        Form(provider: .google, fields: [
            KeyField(field: .apiKey, required: true, placeholder: "AIza…"),
            KeyField(field: .baseURL, required: false, defaultValue: "https://generativelanguage.googleapis.com"),
        ]),
        Form(provider: .deepSeek, fields: [
            KeyField(field: .apiKey, required: true, placeholder: "sk-…"),
            KeyField(field: .baseURL, required: false, defaultValue: DeepSeekProvider.baseURL),
        ]),
        Form(provider: .openCodeGo, fields: [
            KeyField(field: .apiKey, required: true, placeholder: "oc_sk_…"),
        ]),
        Form(provider: .openRouter, fields: [
            KeyField(field: .apiKey, required: true, placeholder: "sk-or-v1-…"),
            KeyField(field: .defaultModel, required: false, placeholder: "anthropic/claude-sonnet-5"),
        ]),
        Form(provider: .openAICompatible, fields: [
            KeyField(field: .apiKey, required: true),
            KeyField(field: .baseURL, required: true, placeholder: "https://…"),
            KeyField(field: .defaultModel, required: true),
        ]),
    ]

    static func fields(for provider: AgentProvider) -> [KeyField]? {
        all.first { $0.provider == provider }?.fields
    }
}

/// What a sign-in passes kwwk's login beyond its callbacks.
public struct SignInOptions: Sendable, Equatable {
    /// The device Kimi binds its grant to: the id the last Kimi sign-in
    /// recorded, else a new one. Nil for every other provider.
    public var kimiIdentity: KimiDeviceIdentity?

    public init(kimiIdentity: KimiDeviceIdentity? = nil) {
        self.kimiIdentity = kimiIdentity
    }
}

/// kwwk's sign-in for a provider whose credential is not typed in — a
/// device flow, a PKCE flow with a loopback redirect, or a page the flow
/// polls — exactly as kwwk runs it, through the callbacks the desk
/// supplies. A test passes its own.
public typealias SignInLogin = @Sendable (
    AgentProvider,
    OAuthLogin.Callbacks,
    SignInOptions,
) async throws -> OAuthCredentials

public enum KWWKSignIn {
    /// OAuth login is independent of which models the user enables afterward.
    public static let login: SignInLogin = { provider, callbacks, options in
        try await OAuthSubscriptions.login(
            providerId: provider.storeID,
            callbacks: callbacks,
            kimiIdentity: options.kimiIdentity,
        )
    }

    /// The Copilot exchange stores the session token as `access` and the
    /// account's API host as the `endpoint` extra (Business and Enterprise
    /// accounts have their own).
    static func enableCopilotModels(_ credentials: OAuthCredentials, models: [String]) async throws {
        var baseURL = URL(string: "https://api.individual.githubcopilot.com")!
        if case let .string(endpoint)? = credentials.extras["endpoint"], let url = URL(string: endpoint) {
            baseURL = url
        }
        // The same policy request as kwwk's enableCopilotModels, but its
        // best-effort CLI helper swallows failures. Settings must not save
        // a checked model when the account refused its activation.
        for model in models {
            let url = baseURL
                .appendingPathComponent("models")
                .appendingPathComponent(model)
                .appendingPathComponent("policy")
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"state":"enabled"}"#.utf8)
            request.allHTTPHeaderFields = [
                "content-type": "application/json",
                "authorization": "Bearer \(credentials.access)",
                "editor-version": "vscode/1.107.0",
                "editor-plugin-version": "copilot-chat/0.35.0",
                "user-agent": "GitHubCopilotChat/0.35.0",
                "copilot-integration-id": "vscode-chat",
                "openai-intent": "chat-policy",
                "x-interaction-type": "chat-policy",
            ]
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
                throw ApelinError(.unavailable, "The Copilot account did not allow this model to be enabled.")
            }
        }
    }
}
