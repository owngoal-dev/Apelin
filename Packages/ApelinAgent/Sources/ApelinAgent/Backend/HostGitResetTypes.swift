import Foundation

// MARK: - git_reset_to_remote

/// The fetch and the reading of what a reset would lose, before anyone is
/// asked. A nil branch is the one the remote's HEAD names.
public struct GitResetPreviewToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var remote: String
    public var branch: String?
    public init(context: HostCallContext, remote: String, branch: String?) {
        self.context = context
        self.remote = remote
        self.branch = branch
    }
}

/// What the preview read: the card, and whether there is anything to do.
public struct GitResetPreviewToolResponse: Sendable, Hashable, Codable {
    public var approval: ResetToRemoteApproval
    /// The project is that branch already.
    public var upToDate: Bool
    public init(approval: ResetToRemoteApproval, upToDate: Bool) {
        self.approval = approval
        self.upToDate = upToDate
    }
}

/// The reset the card named, with the commits and address it was shown.
public struct GitResetToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var approval: ResetToRemoteApproval
    public init(context: HostCallContext, approval: ResetToRemoteApproval) {
        self.context = context
        self.approval = approval
    }
}

public struct GitResetToolResponse: Sendable, Hashable, Codable {
    public var remote: String
    public var branch: String
    public var commit: String
    public var previousHead: String?
    /// Where what was there before is kept, which the user is told.
    public var backupBranch: String?
    /// What became of apelin-project.json, in words.
    public var projectFile: String?
    public init(
        remote: String,
        branch: String,
        commit: String,
        previousHead: String?,
        backupBranch: String?,
        projectFile: String?,
    ) {
        self.remote = remote
        self.branch = branch
        self.commit = commit
        self.previousHead = previousHead
        self.backupBranch = backupBranch
        self.projectFile = projectFile
    }
}

/// A backend without a repository behind it (a test double, a live test).
public extension AgentHostBackend {
    func gitResetPreview(_: GitResetPreviewToolRequest) async throws -> GitResetPreviewToolResponse {
        throw ToolDeniedError(message: "resetting to a remote is not available here")
    }

    func gitResetToRemote(_: GitResetToolRequest) async throws -> GitResetToolResponse {
        throw ToolDeniedError(message: "resetting to a remote is not available here")
    }
}
