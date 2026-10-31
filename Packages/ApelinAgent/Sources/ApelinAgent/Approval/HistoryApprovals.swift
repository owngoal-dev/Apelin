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

/// What a git_squash card names, and the host matches its request to
/// (AgentSquashRules): the project and its branch, the base kept and the
/// head replaced, the commits combined and the new message, read by the
/// preview the tool made before asking, with how many of them the branch's
/// upstream has.
public struct SquashApproval: Sendable, Hashable, Codable {
    public var projectID: String
    public var branch: String
    public var base: String
    public var expectedHead: String
    public var message: String
    /// Newest first, the first fifty.
    public var commits: [GitCommitSummary]
    public var count: Int
    public var upstream: String?
    public var published: Int

    public init(
        projectID: String,
        branch: String,
        base: String,
        expectedHead: String,
        message: String,
        commits: [GitCommitSummary],
        count: Int,
        upstream: String?,
        published: Int,
    ) {
        self.projectID = projectID
        self.branch = branch
        self.base = base
        self.expectedHead = expectedHead
        self.message = message
        self.commits = commits
        self.count = count
        self.upstream = upstream
        self.published = published
    }
}

extension ApprovalPolicy {
    /// What it combines, onto what, and that the old commits stay in the
    /// reflog; a forced push when the upstream has some of them.
    static func squashReason(_ squash: SquashApproval) -> String {
        let named = squash.commits.prefix(10).map { "\(shortCommit($0.commit)) “\($0.subject)”" }
        let more = squash.count > named.count ? ", and \(squash.count - named.count) more" : ""
        let published: String
        if let upstream = squash.upstream, squash.published > 0 {
            let some = squash.published == squash.count ? "all of them" : "\(squash.published) of them"
            published = " \(upstream) already has \(some): publishing the squash will need a forced push, which asks on its own."
        } else {
            published = ""
        }
        return "Squashes \(squash.count) commits on \(squash.branch) into one with the message below, on \(shortCommit(squash.base)): \(named.joined(separator: ", "))\(more). The files stay as they are and nothing is pushed; the old commits stay in the branch's reflog.\(published) Each squash needs your approval."
    }

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
