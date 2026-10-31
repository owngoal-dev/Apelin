import struct ApelinProtocol.GitBranchComparison
import struct ApelinProtocol.GitPushLease
import enum ApelinProtocol.GitRepositoryVisibility
import Foundation

// MARK: - git

/// Every git call acts on the session's own project, which the host checks
/// again: `context.project` is the only project a request names.
public struct GitStatusToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public init(context: HostCallContext) {
        self.context = context
    }
}

public struct GitStatusToolEntry: Sendable, Hashable, Codable {
    public var path: String
    /// One-letter states as `git status --porcelain` spells them.
    public var index: String
    public var worktree: String
    public init(path: String, index: String, worktree: String) {
        self.path = path
        self.index = index
        self.worktree = worktree
    }
}

public struct GitStatusToolResponse: Sendable, Hashable, Codable {
    /// nil on a detached HEAD or before the first commit.
    public var branch: String?
    public var head: String?
    public var entries: [GitStatusToolEntry]
    public init(branch: String? = nil, head: String? = nil, entries: [GitStatusToolEntry] = []) {
        self.branch = branch
        self.head = head
        self.entries = entries
    }
}

public struct GitDiffToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// Project-relative; nil diffs everything.
    public var path: String?
    /// The index against HEAD rather than the worktree against the index.
    public var staged: Bool
    public init(context: HostCallContext, path: String? = nil, staged: Bool = false) {
        self.context = context
        self.path = path
        self.staged = staged
    }
}

public struct GitDiffToolResponse: Sendable, Hashable, Codable {
    public var diff: String
    /// The diff was cut to a bound; a path narrows it.
    public var truncated: Bool
    public init(diff: String, truncated: Bool = false) {
        self.diff = diff
        self.truncated = truncated
    }
}

public struct GitPathsToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// Project-relative, literal (never a pathspec glob).
    public var paths: [String]
    public init(context: HostCallContext, paths: [String]) {
        self.context = context
        self.paths = paths
    }
}

public struct GitPathsToolResponse: Sendable, Hashable, Codable {
    public var paths: [String]
    public init(paths: [String]) {
        self.paths = paths
    }
}

public struct GitCommitToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var message: String
    /// Stage every change first, as `git add --all` does.
    public var all: Bool
    public init(context: HostCallContext, message: String, all: Bool = false) {
        self.context = context
        self.message = message
        self.all = all
    }
}

public struct GitInitToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public init(context: HostCallContext) {
        self.context = context
    }
}

public struct GitInitToolResponse: Sendable, Hashable, Codable {
    public var branch: String
    public init(branch: String) {
        self.branch = branch
    }
}

public struct GitCommitToolResponse: Sendable, Hashable, Codable {
    public var commitID: String
    public init(commitID: String) {
        self.commitID = commitID
    }
}

/// fetch, pull and push. A nil remote is `origin`; a nil branch is, for a
/// push, the checked-out one, and a branch on a fetch is compared with the
/// remote's; a URL (push only) adds the remote when the project does not
/// have it yet; a lease (push only) forces the push as it allows, and only
/// as the user approved it.
public struct GitRemoteToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var remote: String?
    public var branch: String?
    public var url: String?
    public var lease: GitPushLease?
    public init(
        context: HostCallContext,
        remote: String? = nil,
        branch: String? = nil,
        url: String? = nil,
        lease: GitPushLease? = nil,
    ) {
        self.context = context
        self.remote = remote
        self.branch = branch
        self.url = url
        self.lease = lease
    }
}

public struct GitCloneToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// HTTPS, without a user, password, query or fragment.
    public var url: String
    /// nil: the remote's default branch.
    public var branch: String?
    public init(context: HostCallContext, url: String, branch: String? = nil) {
        self.context = context
        self.url = url
        self.branch = branch
    }
}

public struct GitRefUpdate: Sendable, Hashable, Codable {
    public var ref: String
    public var from: String?
    public var to: String
    public init(ref: String, from: String? = nil, to: String) {
        self.ref = ref
        self.from = from
        self.to = to
    }
}

/// What a finished fetch, pull, push or clone reports; each fills the
/// fields its operation has. A failure is thrown, never answered here.
public struct GitTaskToolResponse: Sendable, Hashable, Codable {
    public var remote: String?
    public var branch: String?
    public var commit: String?
    /// pull: where the branch was and where it is now. push: `from` is the
    /// commit the remote's branch was at, absent when the push made it, and
    /// `commit` the one it is at now.
    public var from: String?
    public var to: String?
    public var upToDate: Bool?
    /// fetch: the remote-tracking refs it moved.
    public var updated: [GitRefUpdate]?
    /// fetch with a branch: it beside the remote's.
    public var comparison: GitBranchComparison?
    /// push: true when it overwrote the remote's branch, with a lease.
    public var forced: Bool?
    /// What the model is told besides, in words.
    public var note: String?

    public init(
        remote: String? = nil,
        branch: String? = nil,
        commit: String? = nil,
        from: String? = nil,
        to: String? = nil,
        upToDate: Bool? = nil,
        updated: [GitRefUpdate]? = nil,
        comparison: GitBranchComparison? = nil,
        forced: Bool? = nil,
        note: String? = nil,
    ) {
        self.remote = remote
        self.branch = branch
        self.commit = commit
        self.from = from
        self.to = to
        self.upToDate = upToDate
        self.updated = updated
        self.comparison = comparison
        self.forced = forced
        self.note = note
    }
}

/// The device's git settings as the agent may see them: no token.
public struct GitSettingsToolResponse: Sendable, Hashable, Codable {
    public struct Credential: Sendable, Hashable, Codable {
        public var host: String
        public var username: String
        public init(host: String, username: String) {
            self.host = host
            self.username = username
        }
    }

    public var authorName: String?
    public var authorEmail: String?
    public var credentials: [Credential]
    public init(authorName: String? = nil, authorEmail: String? = nil, credentials: [Credential] = []) {
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.credentials = credentials
    }
}

public struct GitAuthorToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// nil or empty clears the field.
    public var name: String?
    public var email: String?
    public init(context: HostCallContext, name: String?, email: String?) {
        self.context = context
        self.name = name
        self.email = email
    }
}

public struct GitCredentialToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var host: String
    public var username: String
    public var token: String
    public init(context: HostCallContext, host: String, username: String, token: String) {
        self.context = context
        self.host = host
        self.username = username
        self.token = token
    }
}

public struct GitCredentialRemoveToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var host: String
    public init(context: HostCallContext, host: String) {
        self.context = context
        self.host = host
    }
}

/// An empty repository apelin_git_create_repository makes on GitHub: what
/// its card named, nothing else. A nil owner is the signed-in account.
public struct RepositoryCreateToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var owner: String?
    public var name: String
    public var visibility: GitRepositoryVisibility
    public var description: String?
    public init(
        context: HostCallContext,
        owner: String?,
        name: String,
        visibility: GitRepositoryVisibility,
        description: String?,
    ) {
        self.context = context
        self.owner = owner
        self.name = name
        self.visibility = visibility
        self.description = description
    }
}

public struct RepositoryCreateToolResponse: Sendable, Hashable, Codable {
    /// `owner/name`.
    public var fullName: String
    /// What git_push's url takes.
    public var cloneURL: String
    /// Its page on GitHub, which the user is given.
    public var url: String
    /// What the model does next, in words.
    public var next: String
    public init(fullName: String, cloneURL: String, url: String, next: String) {
        self.fullName = fullName
        self.cloneURL = cloneURL
        self.url = url
        self.next = next
    }
}

/// An issue apelin_git_create_issue opens on a repository the user chose:
/// what its card named, nothing else. The footer is apelin-environment's.
public struct IssueCreateToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// `owner/name`.
    public var repository: String
    public var title: String
    public var body: String
    public init(context: HostCallContext, repository: String, title: String, body: String) {
        self.context = context
        self.repository = repository
        self.title = title
        self.body = body
    }
}

public struct IssueCreateToolResponse: Sendable, Hashable, Codable {
    public var repository: String
    /// The issue's number there.
    public var issue: Int
    /// Its page on GitHub, which the user is given.
    public var url: String
    public init(repository: String, issue: Int, url: String) {
        self.repository = repository
        self.issue = issue
        self.url = url
    }
}

/// A git call that did not happen, with what to do about it, in words the
/// model can pass on.
public struct GitToolFailure: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var errorDescription: String? {
        message
    }

    public init(message: String) {
        self.message = message
    }
}
