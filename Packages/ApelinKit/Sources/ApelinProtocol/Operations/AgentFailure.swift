import Foundation

/// Why a model request failed, where the agent can tell: the `reason` an
/// agent session's `error` event carries beside the provider's own words,
/// and the reason `agentOpen` or `agentPrompt` answers when a saved sign-in
/// could not be exchanged or renewed. The app says each in a line of its
/// own (`ChatFailure`); a failure with none, or with one a peer does not
/// know, is shown in the words it came with.
public extension ApelinError.Reason {
    /// The device has no route to the network.
    static let offline = Self(rawValue: "offline")
    /// There is a route, and the provider could not be reached over it: a
    /// name that does not resolve, a connection refused, dropped or not
    /// made securely.
    static let network = Self(rawValue: "network")
    /// The provider did not answer in time.
    static let timeout = Self(rawValue: "timeout")
    /// The provider refused the saved sign-in or key.
    static let authentication = Self(rawValue: "authentication")
    /// The account's credit or plan allowance is spent.
    static let quota = Self(rawValue: "quota")
    /// Too many requests in a short time.
    static let rateLimit = Self(rawValue: "rateLimit")
    /// The provider failed on its own side.
    static let server = Self(rawValue: "server")
    /// The conversation no longer fits the model's context.
    static let contextOverflow = Self(rawValue: "contextOverflow")
}
