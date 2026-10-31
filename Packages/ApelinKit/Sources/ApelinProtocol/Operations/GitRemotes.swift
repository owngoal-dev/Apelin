// A project repository's remotes (issue #32): listed, added or pointed at
// another address, and removed. A remote is a name and the HTTPS address it
// fetches from; nothing here quotes a user, password or token an address
// was configured with. Served by apelin-environment (ApelinGit), on one
// project as every git operation is: an agent's names its own session's.

import Foundation

/// One remote as `git remote -v` would show it, without any credential.
public struct GitRemoteSummary: Codable, Sendable, Equatable {
    public var name: String
    /// The address it fetches from, without a user, password, query or
    /// fragment (`GitRemoteURL.shown`).
    public var url: String?
    /// Where a push goes when that is not `url` — its `pushurl`, or an
    /// `insteadOf` rewrite —, shown the same way.
    public var pushURL: String?
    /// The configured address carried a user, password, query or fragment,
    /// which `url` and `pushURL` leave out.
    public var hidesCredential: Bool?

    public init(name: String, url: String?, pushURL: String? = nil, hidesCredential: Bool? = nil) {
        self.name = name
        self.url = url
        self.pushURL = pushURL
        self.hidesCredential = hidesCredential
    }
}

/// The repository's remotes, sorted by name. A project with no repository
/// is `notFound` with reason `notARepository`.
public struct GitRemoteListRequest: OperationRequest {
    public typealias Response = GitRemoteListResponse
    public static let operation = AppOperation.gitRemoteList
    public var projectID: String

    public init(projectID: String) {
        self.projectID = projectID
    }
}

public struct GitRemoteListResponse: Codable, Sendable, Equatable {
    public var remotes: [GitRemoteSummary]

    public init(remotes: [GitRemoteSummary]) {
        self.remotes = remotes
    }
}

/// Adds the remote `name` fetching from `url`, as `git remote add` does,
/// or, when the repository has it, points it at `url`, as `git remote
/// set-url` does, with no separate push address left beside it, so fetch
/// and push go to the one address named. The name is `GitRemoteName`'s,
/// the address `GitRemoteURL`'s: HTTPS with a host, and no user, password,
/// query or fragment. Nothing is fetched.
public struct GitRemoteSetRequest: OperationRequest {
    public typealias Response = GitRemoteSetResponse
    public static let operation = AppOperation.gitRemoteSet
    public var projectID: String
    public var name: String
    public var url: String

    public init(projectID: String, name: String, url: String) {
        self.projectID = projectID
        self.name = name
        self.url = url
    }
}

public struct GitRemoteSetResponse: Codable, Sendable, Equatable {
    public var remote: GitRemoteSummary
    /// Where it pointed before, shown as a summary's are; nil for a remote
    /// it added.
    public var previousURL: String?

    public init(remote: GitRemoteSummary, previousURL: String? = nil) {
        self.remote = remote
        self.previousURL = previousURL
    }
}

/// Removes the remote `name`, with its remote-tracking branches and any
/// branch's record of it as its upstream, as `git remote remove` does. A
/// remote the repository lacks is `notFound` with reason `noSuchRemote`.
public struct GitRemoteRemoveRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gitRemoteRemove
    public var projectID: String
    public var name: String

    public init(projectID: String, name: String) {
        self.projectID = projectID
        self.name = name
    }
}

/// What a remote may be called: letters, digits, `.`, `_` and `-`, at most
/// 64, starting with a letter or digit, with no `..` and not ending in `.`
/// or `.lock`, so a name is never a path, an option or an address.
public enum GitRemoteName {
    public static let maximumLength = 64

    /// Nil when `name` may name a remote, else why not.
    public static func problem(_ name: String) -> String? {
        if looksLikeAddress(name) {
            return "“\(name)” is an address, not a remote's name. A remote is a name such as origin: add one at that address first, then name it."
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard (1 ... maximumLength).contains(name.count), name.allSatisfy(allowed.contains),
              let first = name.first, first.isASCII, first.isLetter || first.isNumber,
              !name.contains(".."), !name.hasSuffix("."), !name.hasSuffix(".lock")
        else {
            return "A remote's name is letters, digits, periods, underscores and hyphens, at most \(maximumLength), starting with a letter or digit, such as origin or upstream."
        }
        return nil
    }

    /// Whether `name` is written as an address — a scheme, a user, an
    /// scp-style `host:path`, a path — rather than a name.
    public static func looksLikeAddress(_ name: String) -> Bool {
        name.contains("://") || name.contains("@") || name.contains(":")
            || name.hasPrefix("/") || name.hasPrefix("./") || name.hasPrefix("../") || name.hasPrefix("~")
    }

    /// Nil when `name` may name a remote the repository already has, else
    /// why not: never an address or an option, whatever else git takes.
    public static func existingProblem(_ name: String) -> String? {
        if looksLikeAddress(name) {
            return problem(name)
        }
        return name.isEmpty || name.hasPrefix("-") || name.contains("\0") ? "“\(name)” is not a remote's name." : nil
    }
}

/// The addresses a remote takes, and how one is shown.
public enum GitRemoteURL {
    public static let maximumLength = 2048

    /// Nil when `url` is an HTTPS address with a host and no user,
    /// password, query, fragment, space or control character; else why not.
    public static func problem(_ url: String) -> String? {
        guard url.count <= maximumLength,
              !url.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }),
              let components = URLComponents(string: url), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty
        else {
            return "Give the repository's HTTPS address, such as https://github.com/owner/name.git."
        }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            return "Give the address without a user, token, query or fragment: Apelin offers the saved credential for its host itself."
        }
        return nil
    }

    /// `url` without a user, password, query or fragment, and whether it
    /// had any. A path is shown as it is, an scp-style `user@host:path`
    /// and an address that does not read not at all.
    public static func shown(_ url: String) -> (url: String?, hidden: Bool) {
        guard var components = URLComponents(string: url), components.scheme != nil else {
            return url.contains("@") || url.contains("?") ? (nil, true) : (url, false)
        }
        let hidden = components.user != nil || components.password != nil
            || components.query != nil || components.fragment != nil
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return (components.string, hidden)
    }
}

public extension ApelinService {
    func gitRemoteList(projectID: String) async throws -> GitRemoteListResponse {
        try await send(GitRemoteListRequest(projectID: projectID))
    }

    func gitRemoteSet(projectID: String, name: String, url: String) async throws -> GitRemoteSetResponse {
        try await send(GitRemoteSetRequest(projectID: projectID, name: name, url: url))
    }

    func gitRemoteRemove(projectID: String, name: String) async throws {
        _ = try await send(GitRemoteRemoveRequest(projectID: projectID, name: name))
    }
}
