import Foundation

// MARK: - git remotes

/// git_remote_list, on the session's own project.
public struct GitRemoteListToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public init(context: HostCallContext) {
        self.context = context
    }
}

/// One remote, never with a credential in its address.
public struct GitRemoteToolEntry: Sendable, Hashable, Codable {
    public var name: String
    public var url: String?
    /// Where a push goes when that is not `url`.
    public var pushURL: String?
    /// The configured address carried a user, token, query or fragment,
    /// which is not shown.
    public var hidesCredential: Bool?
    public init(name: String, url: String?, pushURL: String? = nil, hidesCredential: Bool? = nil) {
        self.name = name
        self.url = url
        self.pushURL = pushURL
        self.hidesCredential = hidesCredential
    }
}

public struct GitRemoteListToolResponse: Sendable, Hashable, Codable {
    public var remotes: [GitRemoteToolEntry]
    public init(remotes: [GitRemoteToolEntry]) {
        self.remotes = remotes
    }
}

/// git_remote_set: the remote added at `url`, or pointed there.
public struct GitRemoteSetToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var name: String
    /// HTTPS, without a user, token, query or fragment.
    public var url: String
    public init(context: HostCallContext, name: String, url: String) {
        self.context = context
        self.name = name
        self.url = url
    }
}

public struct GitRemoteSetToolResponse: Sendable, Hashable, Codable {
    public var remote: GitRemoteToolEntry
    /// Where it pointed before; nil for one it added.
    public var previousURL: String?
    public init(remote: GitRemoteToolEntry, previousURL: String? = nil) {
        self.remote = remote
        self.previousURL = previousURL
    }
}

/// git_remote_remove; answers the remotes left.
public struct GitRemoteRemoveToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var name: String
    public init(context: HostCallContext, name: String) {
        self.context = context
        self.name = name
    }
}

/// A backend without a repository behind it (a test double, a live test).
public extension AgentHostBackend {
    func gitRemoteList(_: GitRemoteListToolRequest) async throws -> GitRemoteListToolResponse {
        throw ToolDeniedError(message: "remotes are not available here")
    }

    func gitRemoteSet(_: GitRemoteSetToolRequest) async throws -> GitRemoteSetToolResponse {
        throw ToolDeniedError(message: "remotes are not available here")
    }

    func gitRemoteRemove(_: GitRemoteRemoveToolRequest) async throws -> GitRemoteListToolResponse {
        throw ToolDeniedError(message: "remotes are not available here")
    }
}
