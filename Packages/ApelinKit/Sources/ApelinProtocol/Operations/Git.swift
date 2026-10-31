// The git service on a project: clone, init, status, diff, stage, unstage,
// local commit, fetch, a fast-forward pull and push, and the settings behind
// them — the commit author and one HTTPS credential per host —, an empty
// repository made on GitHub for a project to push to, and an issue opened on
// a repository the user chose. A project Apelin makes starts as a
// repository on `main` with no commit, whose `.git/info/exclude` keeps
// Apelin's own files out (the agent's `Attachments/`, temporary files); a
// repository made before gets it on a git call once the project has an
// `Attachments` folder. A project that is not a repository is `notFound`
// with reason `notARepository`.
// Served by apelin-environment (Workers/Environment; ApelinGit, libgit2).
//
// `projectID` is the `projectID` in a project's apelin-project.json, or, for
// a folder that has none yet (a fresh clone), the project's folder name.
// The worker resolves it to `~/Documents/wiki.qaq.apelin/Projects/<name>/`
// with realpath and a component compare, and every path is relative to it.
// A commit's author is the request's, else Settings/git.json in the data
// folder ({"authorName", "authorEmail"}), else the repository's own config.

public struct GitStatusEntry: Codable, Sendable, Equatable {
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

public struct GitStatusRequest: OperationRequest {
    public typealias Response = GitStatusResponse
    public static let operation = AppOperation.gitStatus
    public var projectID: String
    public init(projectID: String) {
        self.projectID = projectID
    }
}

public struct GitStatusResponse: Codable, Sendable, Equatable {
    public var branch: String?
    public var head: String?
    public var entries: [GitStatusEntry]

    public init(branch: String? = nil, head: String? = nil, entries: [GitStatusEntry] = []) {
        self.branch = branch
        self.head = head
        self.entries = entries
    }
}

public struct GitDiffRequest: OperationRequest {
    public typealias Response = GitDiffResponse
    public static let operation = AppOperation.gitDiff
    public var projectID: String
    /// Project-relative; nil diffs everything.
    public var path: String?
    /// The index against HEAD rather than the worktree against the index.
    public var staged: Bool

    public init(projectID: String, path: String? = nil, staged: Bool = false) {
        self.projectID = projectID
        self.path = path
        self.staged = staged
    }

    /// `staged` may be left out, and is then false.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        staged = try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false
    }
}

public struct GitDiffResponse: Codable, Sendable, Equatable {
    /// A unified diff.
    public var diff: String
    public init(diff: String) {
        self.diff = diff
    }
}

public struct GitStageRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gitStage
    public var projectID: String
    public var paths: [String]

    public init(projectID: String, paths: [String]) {
        self.projectID = projectID
        self.paths = paths
    }
}

public struct GitUnstageRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gitUnstage
    public var projectID: String
    public var paths: [String]

    public init(projectID: String, paths: [String]) {
        self.projectID = projectID
        self.paths = paths
    }
}

public struct GitCommitRequest: OperationRequest {
    public typealias Response = GitCommitResponse
    public static let operation = AppOperation.gitCommit
    public var projectID: String
    public var message: String
    public var authorName: String?
    public var authorEmail: String?
    /// Stages every change first, as `git add --all` does: new, changed and
    /// deleted files, ignored ones left out. Absent is false.
    public var all: Bool?

    public init(
        projectID: String,
        message: String,
        authorName: String? = nil,
        authorEmail: String? = nil,
        all: Bool? = nil,
    ) {
        self.projectID = projectID
        self.message = message
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.all = all
    }
}

public struct GitCommitResponse: Codable, Sendable, Equatable {
    public var commitID: String
    public init(commitID: String) {
        self.commitID = commitID
    }
}

/// Makes a repository in a project that has none: HEAD on `main`, no
/// commit, as `git init -b main` leaves it, with Apelin's own files in
/// `.git/info/exclude`. A project with a `.git` already is `conflict`.
public struct GitInitRequest: OperationRequest {
    public typealias Response = GitInitResponse
    public static let operation = AppOperation.gitInit
    public var projectID: String

    public init(projectID: String) {
        self.projectID = projectID
    }
}

public struct GitInitResponse: Codable, Sendable, Equatable {
    public var branch: String

    public init(branch: String) {
        self.branch = branch
    }
}

/// Starts a project from a repository: a shallow clone (depth 1, no tags)
/// of one branch over HTTPS into `Projects/<projectName>/`, which must not
/// exist yet. A task of kind `environment`; its events are `progress`
/// {stage: "fetching", completed, total, detail} and, before the final
/// `state`, `result` {projectName, branch, commit}.
public struct GitCloneRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitClone
    public var url: String
    public var branch: String
    public var projectName: String

    public init(url: String, branch: String, projectName: String) {
        self.url = url
        self.branch = branch
        self.projectName = projectName
    }
}

/// Imports a repository into a project that already exists — an empty
/// workspace — rather than making a new folder: the repository is
/// initialised in the project folder, `origin` set to `url`, fetched in
/// full, and `branch` (nil: the remote's default) checked out over it
/// without overwriting anything already there, so a repository that has a
/// file of the same name as one in the folder fails and leaves the folder
/// as it was. `apelin-project.json` is kept out of the repository through
/// `.git/info/exclude`. HTTPS only; a credential saved for the URL's host
/// is used. A task of kind `environment`; events `progress` {stage:
/// "fetching", …}, then `result` {branch, commit} before the final `state`.
public struct GitCloneIntoRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitCloneInto
    public var projectID: String
    public var url: String
    public var branch: String?

    public init(projectID: String, url: String, branch: String? = nil) {
        self.projectID = projectID
        self.url = url
        self.branch = branch
    }
}

/// Fetches a remote's branches (nil: `origin`) into its remote-tracking
/// refs; the worktree and the branches are left alone. A task of kind
/// `environment`; `progress` {stage: "fetching", …}, then `result` {remote,
/// updated: [{ref, from?, to}]}. With `branch`, a local branch with a
/// commit, the result also sets it beside the branch of that name the
/// remote advertised, as `comparison` (`GitBranchComparison`): what a forced
/// push of it would take off the remote's.
public struct GitFetchRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitFetch
    public var projectID: String
    public var remote: String?
    public var branch: String?

    public init(projectID: String, remote: String? = nil, branch: String? = nil) {
        self.projectID = projectID
        self.remote = remote
        self.branch = branch
    }
}

/// Fetches, then fast-forwards the checked-out branch to its upstream
/// (`branch.<name>.remote`/`merge`, else `<remote>/<name>`). Never merges
/// or rebases: a branch that has diverged, or a worktree change the
/// fast-forward would overwrite, fails with `conflict` and changes nothing.
/// A task of kind `environment`; `result` {branch, from, to, upToDate}.
public struct GitPullRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitPull
    public var projectID: String
    public var remote: String?

    public init(projectID: String, remote: String? = nil) {
        self.projectID = projectID
        self.remote = remote
    }
}

/// Pushes a local branch (nil: the checked-out one) to the branch of the
/// same name on a remote (nil: `origin`), and records it as the branch's
/// upstream. Never forced without `forceWithLease`: a rejected update fails
/// with `conflict`. With it, the remote's branch is overwritten only as the
/// lease allows (`GitPushLease`), and a `lease` event {branch,
/// expectedCommit, localCommit?, found?, held} says what the remote had
/// when it answered, before anything is sent. HTTPS only, with the
/// credential saved for the remote's host. With `url`, a remote the
/// repository does not have yet is added first, fetching from that URL, as
/// `git remote add` does; one it has must already have that URL, else
/// `conflict` with reason `remoteURLDiffers`. A remote not there without
/// `url` is `notFound` with reason `noSuchRemote`. A task of kind
/// `environment`; `progress` {stage: "pushing", …}, then `result` {remote,
/// branch, commit, from?, forced?}: `from` the commit the remote's branch
/// was at, absent when the push made it, and `forced` true for a push with
/// a lease.
public struct GitPushRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitPush
    public var projectID: String
    public var remote: String?
    public var branch: String?
    /// HTTPS, without a user or password.
    public var url: String?
    /// Absent: an ordinary push, never forced.
    public var forceWithLease: GitPushLease?

    public init(
        projectID: String,
        remote: String? = nil,
        branch: String? = nil,
        url: String? = nil,
        forceWithLease: GitPushLease? = nil,
    ) {
        self.projectID = projectID
        self.remote = remote
        self.branch = branch
        self.url = url
        self.forceWithLease = forceWithLease
    }
}

/// What a git refusal names beyond its code, for the agent to act on.
public extension ApelinError.Reason {
    /// `notFound`: the project has no repository; `gitInit` makes one.
    static let notARepository = Self(rawValue: "notARepository")
    /// `notFound`: the repository has no remote of the name asked for; a
    /// push with `url` adds it.
    static let noSuchRemote = Self(rawValue: "noSuchRemote")
    /// `conflict`: a push's `url` is not the URL its remote already has.
    static let remoteURLDiffers = Self(rawValue: "remoteURLDiffers")
}

// MARK: Settings and credentials (the app's only)

/// A saved HTTPS credential as the settings list shows it; the token never
/// leaves apelin-environment's keychain item.
public struct GitCredentialSummary: Codable, Sendable, Equatable, Hashable {
    /// Lowercased, with `:port` when the URL names one: what a remote's
    /// host must equal for the credential to be offered to it.
    public var host: String
    public var username: String

    public init(host: String, username: String) {
        self.host = host
        self.username = username
    }
}

/// The commit author and the saved credentials.
public struct GitSettingsRequest: OperationRequest {
    public typealias Response = GitSettingsResponse
    public static let operation = AppOperation.gitSettings
    public init() {}
}

public struct GitSettingsResponse: Codable, Sendable, Equatable {
    public var authorName: String?
    public var authorEmail: String?
    /// Sorted by host.
    public var credentials: [GitCredentialSummary]

    public init(authorName: String? = nil, authorEmail: String? = nil, credentials: [GitCredentialSummary] = []) {
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.credentials = credentials
    }
}

/// Writes `Settings/git.json`; a nil or empty field is removed.
public struct GitAuthorSetRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gitAuthorSet
    public var authorName: String?
    public var authorEmail: String?

    public init(authorName: String?, authorEmail: String?) {
        self.authorName = authorName
        self.authorEmail = authorEmail
    }
}

/// Saves, or replaces, the credential for one host: a username and a token
/// (a personal access token, used as the HTTPS password). Kept in
/// apelin-environment's keychain group, this device only, never
/// synchronised; no reply, event or log carries the token, and the console
/// refuses this operation before sending it.
public struct GitCredentialSetRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gitCredentialSet
    /// A host name, optionally `:port`; no scheme, path or user. Compared
    /// lowercased.
    public var host: String
    public var username: String
    public var token: String

    public init(host: String, username: String, token: String) {
        self.host = host
        self.username = username
        self.token = token
    }
}

public struct GitCredentialRemoveRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gitCredentialRemove
    public var host: String

    public init(host: String) {
        self.host = host
    }
}

// MARK: A repository on GitHub

/// Who can see a repository made on GitHub. A request always names it.
public enum GitRepositoryVisibility: String, Codable, Sendable, CaseIterable {
    case `public`
    case `private`
}

/// Makes an empty repository on GitHub — no README, licence or
/// `.gitignore`, so a project's first push lays down its history — on the
/// account of the github.com sign-in, or in the organization `owner` names,
/// with the visibility the request names. Not a task: one request to
/// GitHub. The app's, and an agent's as the host allows it
/// (AgentRepositoryCreateRules). `problem` is checked before the sign-in is
/// read; without one, `denied` with reason `authenticationRequired`.
/// GitHub's refusals keep its words: a name the owner already has is
/// `conflict`, an organization the account may not create in `denied`, one
/// it cannot see `notFound`.
public struct GitRepositoryCreateRequest: OperationRequest {
    public typealias Response = GitRepositoryCreateResponse
    public static let operation = AppOperation.gitRepositoryCreate
    public var name: String
    public var visibility: GitRepositoryVisibility
    /// An organization's login; nil, or the account's own, for the account.
    public var owner: String?
    public var description: String?

    /// GitHub's own limit.
    public static let maximumDescriptionLength = 350

    public init(name: String, visibility: GitRepositoryVisibility, owner: String? = nil, description: String? = nil) {
        self.name = name
        self.visibility = visibility
        self.owner = owner
        self.description = description
    }

    /// Nil when GitHub could take it, else why not, naming the field.
    public var problem: String? {
        guard GitHubName.isRepository(name) else {
            return "Use letters, digits, hyphens, underscores and periods for the repository's name, at most 100."
        }
        if let owner, !GitHubName.isLogin(owner) {
            return "Name the owner by its GitHub login: letters, digits and single hyphens, at most 39."
        }
        if let description, description.contains(where: \.isNewline) || description.count > Self.maximumDescriptionLength {
            return "The description is one line of at most \(Self.maximumDescriptionLength) characters."
        }
        return nil
    }
}

public struct GitRepositoryCreateResponse: Codable, Sendable, Equatable {
    /// `owner/name`, as GitHub spells it.
    public var fullName: String
    /// The HTTPS address a remote takes, `https://github.com/owner/name.git`.
    public var cloneURL: String
    /// Its page on GitHub.
    public var url: String

    public init(fullName: String, cloneURL: String, url: String) {
        self.fullName = fullName
        self.cloneURL = cloneURL
        self.url = url
    }
}

/// Opens an issue on a GitHub repository the user chose, `owner/name`, with
/// the github.com sign-in (owner, 2026-10-30): the title and body are
/// checked by `FeedbackRules.problem` — the shapes of a device's private
/// data, with this device's own paths and name — before the sign-in is
/// read, and below the body goes the footer feedback carries, Apelin's
/// version, the iOS version and the bootstrap. Apelin's own feedback is
/// `FeedbackSendRequest`. Not a task: one request to GitHub. The app's,
/// and an agent's as the host allows it (AgentIssueCreateRules). Without a
/// sign-in, `denied` with reason `authenticationRequired`. GitHub's
/// refusals keep its words and say what blocks it: a repository the
/// account cannot see `notFound`, issues turned off there or no permission
/// `denied`, GitHub's validation `conflict`.
public struct GitIssueCreateRequest: OperationRequest {
    public typealias Response = GitIssueCreateResponse
    public static let operation = AppOperation.gitIssueCreate
    /// `owner/name`, as the user named it.
    public var repository: String
    public var title: String
    public var body: String

    public init(repository: String, title: String, body: String) {
        self.repository = repository
        self.title = title
        self.body = body
    }

    /// Nil when the repository is one GitHub could have, else why not; the
    /// title and body are `FeedbackRules`'.
    public var problem: String? {
        GitHubName.isFullName(repository)
            ? nil
            : "Name the repository as owner/name, its owner's login and its name as GitHub spells them, such as octocat/hello-world."
    }
}

public struct GitIssueCreateResponse: Codable, Sendable, Equatable {
    /// The issue's number in `repository`.
    public var number: Int
    /// Its page on GitHub.
    public var url: String
    /// `owner/name`, as the request named it.
    public var repository: String

    public init(number: Int, url: String, repository: String) {
        self.number = number
        self.url = url
        self.repository = repository
    }
}

/// What GitHub takes for a login and for a repository's name, checked
/// before GitHub is asked.
public enum GitHubName {
    /// `owner/name`: a login, then a repository's name.
    public static func isFullName(_ fullName: String) -> Bool {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 2 && isLogin(parts[0]) && isRepository(parts[1])
    }

    /// An account's or organization's login: letters, digits and single
    /// hyphens, at most 39, no hyphen at either end.
    public static func isLogin(_ name: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        return (1 ... 39).contains(name.count) && name.allSatisfy(allowed.contains)
            && !name.hasPrefix("-") && !name.hasSuffix("-") && !name.contains("--")
    }

    /// Letters, digits, hyphens, underscores and periods, at most 100; not
    /// `.` or `..`, and not ending in `.git`.
    public static func isRepository(_ name: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        return (1 ... 100).contains(name.count) && name.allSatisfy(allowed.contains)
            && name != "." && name != ".." && !name.lowercased().hasSuffix(".git")
    }
}

public extension ApelinService {
    func gitStatus(projectID: String) async throws -> GitStatusResponse {
        try await send(GitStatusRequest(projectID: projectID))
    }

    func gitDiff(projectID: String, path: String? = nil, staged: Bool = false) async throws -> GitDiffResponse {
        try await send(GitDiffRequest(projectID: projectID, path: path, staged: staged))
    }

    func gitStage(projectID: String, paths: [String]) async throws {
        _ = try await send(GitStageRequest(projectID: projectID, paths: paths))
    }

    func gitUnstage(projectID: String, paths: [String]) async throws {
        _ = try await send(GitUnstageRequest(projectID: projectID, paths: paths))
    }

    func gitCommit(_ request: GitCommitRequest) async throws -> GitCommitResponse {
        try await send(request)
    }

    func gitInit(projectID: String) async throws -> GitInitResponse {
        try await send(GitInitRequest(projectID: projectID))
    }

    /// Starts a clone; follow it with `events(of:)`.
    func gitClone(url: String, branch: String, projectName: String) async throws -> TaskHandle {
        try await send(GitCloneRequest(url: url, branch: branch, projectName: projectName))
    }

    /// Starts an import into an existing project; follow it with `events(of:)`.
    func gitCloneInto(_ request: GitCloneIntoRequest) async throws -> TaskHandle {
        try await send(request)
    }

    func gitFetch(projectID: String, remote: String? = nil, branch: String? = nil) async throws -> TaskHandle {
        try await send(GitFetchRequest(projectID: projectID, remote: remote, branch: branch))
    }

    func gitPull(projectID: String, remote: String? = nil) async throws -> TaskHandle {
        try await send(GitPullRequest(projectID: projectID, remote: remote))
    }

    func gitPush(_ request: GitPushRequest) async throws -> TaskHandle {
        try await send(request)
    }

    func gitSettings() async throws -> GitSettingsResponse {
        try await send(GitSettingsRequest())
    }

    func gitAuthorSet(name: String?, email: String?) async throws {
        _ = try await send(GitAuthorSetRequest(authorName: name, authorEmail: email))
    }

    func gitCredentialSet(_ request: GitCredentialSetRequest) async throws {
        _ = try await send(request)
    }

    func gitCredentialRemove(host: String) async throws {
        _ = try await send(GitCredentialRemoveRequest(host: host))
    }

    func gitRepositoryCreate(_ request: GitRepositoryCreateRequest) async throws -> GitRepositoryCreateResponse {
        try await send(request)
    }

    func gitIssueCreate(repository: String, title: String, body: String) async throws -> GitIssueCreateResponse {
        try await send(GitIssueCreateRequest(repository: repository, title: title, body: body))
    }
}
