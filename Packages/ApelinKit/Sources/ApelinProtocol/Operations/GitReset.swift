// "Remote wins" (issue #32): a project made exactly what a remote's branch
// holds, when the user asks for it. What that would lose is worked out
// first and shown (`gitResetPreview`); the reset itself
// (`gitResetToRemote`) runs only against exactly the state that was shown,
// and saves everything it would lose on a branch of its own before it
// touches anything. Served by apelin-environment (ApelinGit), on one
// project; an agent's names its own session's, and spends, in every mode,
// one approval the user gave for exactly that reset
// (AgentResetToRemoteRules).

/// One commit as a list names it.
public struct GitCommitLine: Codable, Sendable, Equatable {
    public var commit: String
    /// Its message's first line.
    public var subject: String

    public init(commit: String, subject: String) {
        self.commit = commit
        self.subject = subject
    }
}

/// Fetches `branch` of `remote` (nil: the branch the remote's HEAD names)
/// and works out what making the project that branch would change; nothing
/// but the remote-tracking branch moves. A task of kind `environment`, not
/// resumed; `progress` {stage: "fetching", …}, then `result`, a
/// `GitResetPreview`, also in the final `state`.
public struct GitResetPreviewRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitResetPreview
    public var projectID: String
    public var remote: String
    public var branch: String?

    public init(projectID: String, remote: String, branch: String? = nil) {
        self.projectID = projectID
        self.remote = remote
        self.branch = branch
    }
}

/// What a reset to `remote`'s `branch` would do, from the fetch it was
/// read after.
public struct GitResetPreview: Codable, Sendable, Equatable {
    /// The longest list each of the lists below holds; their counts are the
    /// whole.
    public static let listed = 50

    public var remote: String
    /// The address it fetched from, without a credential.
    public var url: String
    public var branch: String
    public var remoteCommit: String
    public var remoteSubject: String?
    /// HEAD's commit; nil when it has none.
    public var head: String?
    /// The branch HEAD is on; nil when detached. When it is not `branch`, it
    /// stays as it is and HEAD moves to `branch`.
    public var currentBranch: String?
    /// The project's history and the remote's share no commit.
    public var unrelatedHistories: Bool
    /// The commits that leave the branch, newest first.
    public var lostCommitCount: Int
    public var lostCommits: [GitCommitLine]
    /// Tracked files whose uncommitted changes, staged or not, are replaced.
    public var changedFileCount: Int
    public var changedFiles: [GitStatusEntry]
    /// Untracked or ignored files the remote's tree replaces.
    public var overwrittenFileCount: Int
    public var overwrittenFiles: [String]
    /// What `apelin-project.json` becomes.
    public var projectFile: GitProjectFile
    /// The project is that branch already: nothing to do.
    public var upToDate: Bool

    public init(
        remote: String,
        url: String,
        branch: String,
        remoteCommit: String,
        remoteSubject: String? = nil,
        head: String? = nil,
        currentBranch: String? = nil,
        unrelatedHistories: Bool = false,
        lostCommitCount: Int = 0,
        lostCommits: [GitCommitLine] = [],
        changedFileCount: Int = 0,
        changedFiles: [GitStatusEntry] = [],
        overwrittenFileCount: Int = 0,
        overwrittenFiles: [String] = [],
        projectFile: GitProjectFile = .project,
        upToDate: Bool = false,
    ) {
        self.remote = remote
        self.url = url
        self.branch = branch
        self.remoteCommit = remoteCommit
        self.remoteSubject = remoteSubject
        self.head = head
        self.currentBranch = currentBranch
        self.unrelatedHistories = unrelatedHistories
        self.lostCommitCount = lostCommitCount
        self.lostCommits = lostCommits
        self.changedFileCount = changedFileCount
        self.changedFiles = changedFiles
        self.overwrittenFileCount = overwrittenFileCount
        self.overwrittenFiles = overwrittenFiles
        self.projectFile = projectFile
        self.upToDate = upToDate
    }
}

/// Fetches `branch` of `remote` again and, while it is still at
/// `expectedRemoteCommit`, HEAD still at `expectedHead` (nil: HEAD has no
/// commit) and the remote still at `expectedURL` (when given, as a preview
/// shows it), makes the project exactly that branch: the local branch of
/// that name moved to it and checked out, the work tree's tracked files and
/// the index made the remote's, untracked and ignored files it does not
/// have left alone. First it saves what would be lost on a new branch
/// `apelin-backup/<yyyyMMdd-HHmmss>`: the commit HEAD was at and, with
/// anything uncommitted or replaced, a commit of it on top. Anything else
/// is `conflict` with nothing changed. `apelin-project.json` keeps the
/// project's own `projectID` (`GitProjectFile`), and stays as it was when
/// the remote has none. A task of kind `environment`, not resumed;
/// `progress` {stage: "fetching" | "saving" | "resetting"}, then `result`
/// {remote, branch, commit, previousHead?, backupBranch?, projectFile}, also
/// in the final `state`.
public struct GitResetToRemoteRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitResetToRemote
    public var projectID: String
    public var remote: String
    public var branch: String
    public var expectedRemoteCommit: String
    public var expectedHead: String?
    public var expectedURL: String?

    public init(
        projectID: String,
        remote: String,
        branch: String,
        expectedRemoteCommit: String,
        expectedHead: String?,
        expectedURL: String? = nil,
    ) {
        self.projectID = projectID
        self.remote = remote
        self.branch = branch
        self.expectedRemoteCommit = expectedRemoteCommit
        self.expectedHead = expectedHead
        self.expectedURL = expectedURL
    }
}

public extension ApelinService {
    /// Starts a preview; follow it with `events(of:)`.
    func gitResetPreview(_ request: GitResetPreviewRequest) async throws -> TaskHandle {
        try await send(request)
    }

    /// Starts a reset; follow it with `events(of:)`.
    func gitResetToRemote(_ request: GitResetToRemoteRequest) async throws -> TaskHandle {
        try await send(request)
    }
}
