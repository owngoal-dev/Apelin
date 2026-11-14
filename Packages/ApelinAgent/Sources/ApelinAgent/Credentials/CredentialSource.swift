import Foundation
import KWWKAI

/// Where a session's provider credentials come from.
///
/// It is kwwk's `OAuthCredentialSource`, so kwwk's own registration and
/// refresh code (the Copilot token exchange, Anthropic OAuth refresh) runs
/// over it unchanged. Entries are keyed by kwwk's store ids —
/// `anthropic-api-key`, `anthropic`, `openai-compatible`, `github-copilot` —
/// and hold kwwk's `OAuthCredentials` shape, so a credential signed in with
/// kwwk's flows can be stored here as is.
///
/// Credentials never travel in argv, the environment, a log line or a
/// session file. The two implementations are the keychain (this device only,
/// never synced, Apelin's own items) and an in-memory source the app fills
/// over the authenticated channel when a shared keychain is not available.
public protocol CredentialSource: OAuthCredentialSource {
    /// Store or replace the credentials for `providerID`.
    func store(_ credentials: OAuthCredentials, for providerID: String) async throws
    /// Forget the credentials for `providerID`.
    func remove(_ providerID: String) async throws
}

/// Credential store ids, including Apelin's independent DeepSeek account.
public enum CredentialProviderID {
    public static let anthropicAPIKey = "anthropic-api-key"
    public static let anthropicOAuth = "anthropic"
    public static let openAICompatible = "openai-compatible"
    public static let githubCopilot = "github-copilot"
    public static let deepSeek = "deepseek-api-key"

    /// The numbers a further OpenAI-compatible endpoint takes; the first
    /// endpoint is `openAICompatible` itself.
    public static let endpointNumbers = 2 ... 99

    /// A further OpenAI-compatible endpoint's item: `openai-compatible.<number>`.
    public static func openAICompatibleEndpoint(_ number: Int) -> String {
        "\(openAICompatible).\(number)"
    }

    /// The number of the further endpoint `storeID` names, in its one
    /// spelling; nil for any other id, the first endpoint's included.
    public static func endpointNumber(_ storeID: String) -> Int? {
        let prefix = openAICompatible + "."
        guard storeID.hasPrefix(prefix), let number = Int(storeID.dropFirst(prefix.count)),
              endpointNumbers.contains(number), openAICompatibleEndpoint(number) == storeID
        else { return nil }
        return number
    }

    /// Whether `storeID` is an OpenAI-compatible endpoint's, the first or a
    /// further one.
    public static func isOpenAICompatible(_ storeID: String) -> Bool {
        storeID == openAICompatible || endpointNumber(storeID) != nil
    }
}

/// Credentials delivered by the app for this session, held in memory only.
/// Nothing is written anywhere; the process forgets them when it exits.
public actor DeliveredCredentialSource: CredentialSource {
    private var entries: [String: OAuthCredentials]

    public init(_ entries: [String: OAuthCredentials] = [:]) {
        self.entries = entries
    }

    public func providerIds() -> [String] {
        entries.keys.sorted()
    }

    public func credentials(for providerId: String) -> OAuthCredentials? {
        entries[providerId]
    }

    public func store(_ credentials: OAuthCredentials, for providerID: String) {
        entries[providerID] = credentials
    }

    public func remove(_ providerID: String) {
        entries.removeValue(forKey: providerID)
    }
}
