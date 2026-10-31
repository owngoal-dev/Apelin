import struct ApelinProtocol.GitCommitSummary

/// What a forced git_push card names (issue #29), and the host matches its
/// request to (AgentForcePushRules): the project, the remote and the address
/// it pushes to, the branch, and the lease — the remote's commit it replaces
/// and the local one it sends —, read by the fetch the tool made before
/// asking, with the commits only the remote's branch has, which leave it.
public struct ForcePushApproval: Sendable, Hashable, Codable {
    public var projectID: String
    public var remote: String
    /// Where the push goes, as the request names it.
    public var url: String?
    public var branch: String
    /// The remote's branch as the fetch found it: what is overwritten.
    public var expectedCommit: String
    /// The local branch: what is pushed in its place.
    public var localCommit: String
    public var localSubject: String
    /// The commits on the remote's branch the local one lacks, newest
    /// first, the first ten.
    public var overwritten: [GitCommitSummary]
    public var overwrittenCount: Int

    public init(
        projectID: String,
        remote: String,
        url: String?,
        branch: String,
        expectedCommit: String,
        localCommit: String,
        localSubject: String,
        overwritten: [GitCommitSummary],
        overwrittenCount: Int,
    ) {
        self.projectID = projectID
        self.remote = remote
        self.url = url
        self.branch = branch
        self.expectedCommit = expectedCommit
        self.localCommit = localCommit
        self.localSubject = localSubject
        self.overwritten = overwritten
        self.overwrittenCount = overwrittenCount
    }
}

extension ApprovalPolicy {
    /// Where it goes, what replaces what, what leaves the branch, and that
    /// it is for good.
    static func forcePushReason(_ force: ForcePushApproval) -> String {
        let place = force.url.map { "\(force.remote) (\($0))" } ?? force.remote
        let named = force.overwritten.prefix(5).map { "\(shortCommit($0.commit)) “\($0.subject)”" }
        let more = force.overwrittenCount > named.count ? ", and \(force.overwrittenCount - named.count) more" : ""
        let commits = force.overwrittenCount == 1 ? "1 commit" : "\(force.overwrittenCount) commits"
        let replaced = "the remote's \(force.branch), at \(shortCommit(force.expectedCommit))"
        let replacement = "this project's \(shortCommit(force.localCommit)) “\(force.localSubject)”"
        return "Force-pushes \(force.branch) to \(place), overwriting its history there: \(replaced), is replaced by \(replacement), and \(commits) on the remote will no longer be on \(force.branch): \(named.joined(separator: ", "))\(more). This cannot be undone from Apelin. If the remote's \(force.branch) changes before the push, nothing is pushed. Each forced push needs your approval, in every mode."
    }

    /// The first seven digits, as git abbreviates a commit.
    static func shortCommit(_ commit: String) -> String {
        String(commit.prefix(7))
    }
}
