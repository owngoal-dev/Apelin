import Foundation

/// Reads every credential file in `console/inbox/credentials/` once, stores
/// each in the keychain (service `wiki.qaq.apelin.agent`) and deletes the
/// file. A file is `<provider-store-id>.json` holding kwwk's credential
/// shape, or a kwwk `auth.json` map of store id to credential. Contents are
/// never logged or answered.
public struct AgentCredentialImportRequest: OperationRequest {
    public typealias Response = AgentCredentialImportResponse
    public static let operation = AppOperation.agentCredentialImport
    public init() {}
}

public struct AgentCredentialImportResponse: Codable, Sendable, Equatable {
    /// kwwk store ids now in the keychain, from this import.
    public var stored: [String]
    /// One line per file that could not be used: its name and why.
    public var rejected: [String]
    /// Every store id the keychain holds after the import.
    public var available: [String]

    public init(stored: [String] = [], rejected: [String] = [], available: [String] = []) {
        self.stored = stored
        self.rejected = rejected
        self.available = available
    }
}

// MARK: - Sign-in

//
// Signing in to a provider runs kwwk's own flow in apelin-agent's
// `credential-import` instance, the one executable that holds the keychain
// group the sessions read; the app only shows what the flow asks for and
// hands back what the user supplies. Sign-in events never return secrets.
// The app-only configuration editor reads saved API fields in a direct reply.
// AGENTS.md ▸ Decisions ▸ Agent sign-in.

/// How a provider's sign-in reaches the user.
public enum AgentSignInMethod: String, Codable, Sendable {
    /// A one-time code the user confirms or enters on the provider's page
    /// (an RFC 8628 device flow: GitHub, Kimi, xAI): a `deviceCode` event.
    case deviceCode
    /// The provider's page in the browser: an `authorize` event. The page
    /// either redirects to a loopback listener in apelin-agent
    /// (`acceptsCallbackURL` when a pasted address can stand in for it) or
    /// the flow asks the provider until the user has signed in.
    case browser
    /// A key the user types: an `input` event, answered by
    /// `agentSignInRespond`.
    case apiKey
}

/// The values `agentSignInRespond` carries, by their wire names.
public enum AgentSignInField: String, Codable, Sendable, CaseIterable {
    /// The key itself (kwwk's `access`).
    case apiKey
    /// An API endpoint (kwwk's `baseUrl` extra).
    case baseURL = "baseUrl"
    /// The model an OpenAI-compatible endpoint serves by default (kwwk's
    /// `defaultModel` extra).
    case defaultModel
    /// The address the browser was sent back to, pasted by the user when
    /// the loopback listener could not be reached.
    case callbackURL
}

/// One provider as the sign-in screen lists it. Never a secret: no token,
/// no key, not even part of one.
public struct AgentAccount: Codable, Sendable, Equatable {
    public var provider: AgentProvider
    /// How `agentSignIn` signs in when it names no method.
    public var method: AgentSignInMethod
    /// The other methods `agentSignIn` takes for this provider (OpenRouter's
    /// typed key beside its browser sign-in). Absent when there are none.
    public var alternativeMethods: [AgentSignInMethod]?
    public var signedIn: Bool
    /// What tells the account apart without a secret: an API key's
    /// endpoint host. Absent for a subscription sign-in.
    public var account: String?
    /// When a sign-in that cannot renew itself lapses. Absent when it
    /// renews (a refresh token) or never lapses (an API key).
    public var expiresAt: Date?
    /// Model identifiers from this signed-in provider, never credentials.
    public var models: [String]?
    /// The completed sign-in used a typed API key, including alternate methods.
    public var usesAPIKey: Bool?
    /// Known reasoning levels from the provider catalog, keyed by model ID.
    public var reasoningEfforts: [String: [AgentReasoningEffort]]?
    /// Processing tiers the provider catalog lists, keyed by model ID; a
    /// model it does not name is offered none.
    public var serviceTiers: [String: [AgentServiceTier]]?
    public var isAPIKeyAccount: Bool {
        usesAPIKey ?? (method == .apiKey)
    }

    public init(
        provider: AgentProvider,
        method: AgentSignInMethod,
        alternativeMethods: [AgentSignInMethod]? = nil,
        signedIn: Bool,
        account: String? = nil,
        expiresAt: Date? = nil,
        models: [String]? = nil,
        usesAPIKey: Bool? = nil,
        reasoningEfforts: [String: [AgentReasoningEffort]]? = nil,
        serviceTiers: [String: [AgentServiceTier]]? = nil,
    ) {
        self.provider = provider
        self.method = method
        self.alternativeMethods = alternativeMethods
        self.signedIn = signedIn
        self.account = account
        self.expiresAt = expiresAt
        self.models = models
        self.usesAPIKey = usesAPIKey
        self.reasoningEfforts = reasoningEfforts
        self.serviceTiers = serviceTiers
    }
}

/// Every provider Apelin's sessions can use, signed in or not, in the
/// order kwwk lists its logins: subscriptions, then keys.
public struct AgentAccountListRequest: OperationRequest {
    public typealias Response = AgentAccountListResponse
    public static let operation = AppOperation.agentAccountList
    public init() {}
}

public struct AgentAccountListResponse: Codable, Sendable, Equatable {
    public var accounts: [AgentAccount]
    public init(accounts: [AgentAccount] = []) {
        self.accounts = accounts
    }
}

/// Reads a saved API-key configuration only for the app's editing form.
/// This direct reply is never an account-list field or a persisted task event.
public struct AgentAPIConfigurationRequest: OperationRequest {
    public typealias Response = AgentAPIConfigurationResponse
    public static let operation = AppOperation.agentAPIConfiguration
    public var provider: AgentProvider
    public init(provider: AgentProvider) {
        self.provider = provider
    }
}

public struct AgentAPIConfigurationResponse: Codable, Sendable {
    public var values: [String: String]
    public init(values: [String: String]) {
        self.values = values
    }
}

public struct AgentModelListRequest: OperationRequest {
    public typealias Response = AgentModelListResponse
    public static let operation = AppOperation.agentModelList
    public var provider: AgentProvider
    /// Models besides those the provider lists whose automatic limits to
    /// answer: the ones the user added by hand or enabled. At most
    /// `maximumLimitsAsked` are read.
    public var limitsFor: [String]?
    public static let maximumLimitsAsked = 256

    public init(provider: AgentProvider, limitsFor: [String]? = nil) {
        self.provider = provider
        self.limitsFor = limitsFor
    }
}

public struct AgentModelListResponse: Codable, Sendable {
    public var models: [String]
    /// For an API-key account, the limits each listed or asked model has
    /// when the user sets none (`AgentModelLimits`, every field automatic):
    /// its window, and the largest reply kwwk sends on its own, absent
    /// where it sends none. A model whose limits could not be read is left
    /// out; absent for a subscription.
    public var limits: [String: AgentModelLimits]?

    public init(models: [String], limits: [String: AgentModelLimits]? = nil) {
        self.models = models
        self.limits = limits
    }
}

/// A cancellable provider task. Only model IDs and progress cross the wire.
public struct AgentModelActivateRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.agentModelActivate
    public var provider: AgentProvider
    public var models: [String]
    public init(provider: AgentProvider, models: [String]) {
        self.provider = provider; self.models = models
    }
}

/// Starts a sign-in: a task of kind `signIn`, read with `agentAttach`.
/// Its events are `deviceCode` {code, verificationURL, pageHoldsCode},
/// `authorize` {url, acceptsCallbackURL} or `input` {fields: [{key,
/// required, secure, defaultValue?, placeholder?}]}, then `state`. A new
/// sign-in ends the one still running, which ends `cancelled`; one left
/// alone ends `failed` after `AgentSignInRequest.timeoutSeconds`.
public struct AgentSignInRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.agentSignIn
    /// How long a sign-in waits for the user: GitHub's device code lasts
    /// fifteen minutes, and so does every other flow here.
    public static let timeoutSeconds = 15 * 60

    public var provider: AgentProvider
    /// One of the account's `alternativeMethods`; nil is its `method`. Any
    /// other is refused `badRequest` before the task is accepted.
    public var method: AgentSignInMethod?

    public init(provider: AgentProvider, method: AgentSignInMethod? = nil) {
        self.provider = provider
        self.method = method
    }
}

/// What the user supplied for a running sign-in: the fields its `input`
/// event asked for, or `callbackURL` for a browser flow. Sent once; the
/// worker keeps it only as long as the flow needs it and never repeats it,
/// in a reply, an event or a log. A value that will not do is refused with
/// `badRequest` naming the field, and the sign-in goes on waiting.
public struct AgentSignInRespondRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentSignInRespond
    public var taskID: TaskID
    /// Keyed by `AgentSignInField` raw values.
    public var values: [String: String]
    /// False when setup proceeds to model selection before verification.
    /// Absent preserves the original verify-before-save behavior.
    public var verifyModel: Bool?

    public init(taskID: TaskID, values: [String: String], verifyModel: Bool? = nil) {
        self.taskID = taskID
        self.values = values
        self.verifyModel = verifyModel
    }

    public init(taskID: TaskID, fields: [AgentSignInField: String], verifyModel: Bool? = nil) {
        self.init(
            taskID: taskID,
            values: Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) }),
            verifyModel: verifyModel,
        )
    }
}

public struct AgentSignInCancelRequest: TaskCancelRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentSignInCancel
    public var taskID: TaskID
    public init(taskID: TaskID) {
        self.taskID = taskID
    }
}

/// Forgets the provider's keychain item. Signing out of a provider that is
/// not signed in is no error.
public struct AgentSignOutRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentSignOut
    public var provider: AgentProvider
    public init(provider: AgentProvider) {
        self.provider = provider
    }
}

public extension ApelinService {
    func agentAccountList() async throws -> AgentAccountListResponse {
        try await send(AgentAccountListRequest())
    }

    func agentAPIConfiguration(provider: AgentProvider) async throws -> AgentAPIConfigurationResponse {
        try await send(AgentAPIConfigurationRequest(provider: provider))
    }

    func agentModelList(provider: AgentProvider, limitsFor: [String]? = nil) async throws -> AgentModelListResponse {
        try await send(AgentModelListRequest(provider: provider, limitsFor: limitsFor))
    }

    func agentModelActivate(provider: AgentProvider, models: [String]) async throws -> TaskHandle {
        try await send(AgentModelActivateRequest(provider: provider, models: models))
    }

    func agentSignIn(provider: AgentProvider, method: AgentSignInMethod? = nil) async throws -> TaskHandle {
        try await send(AgentSignInRequest(provider: provider, method: method))
    }

    func agentSignInRespond(taskID: TaskID, fields: [AgentSignInField: String], verifyModel: Bool? = nil) async throws {
        _ = try await send(AgentSignInRespondRequest(taskID: taskID, fields: fields, verifyModel: verifyModel))
    }

    func agentSignInCancel(taskID: TaskID) async throws {
        _ = try await send(AgentSignInCancelRequest(taskID: taskID))
    }

    func agentSignOut(provider: AgentProvider) async throws {
        _ = try await send(AgentSignOutRequest(provider: provider))
    }
}

public extension ApelinService {
    func agentCredentialImport() async throws -> AgentCredentialImportResponse {
        try await send(AgentCredentialImportRequest())
    }
}
