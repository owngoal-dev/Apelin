// What changes a branch's history rather than adding to it (owner,
// 2026-10-31, issue #29): a forced push, which overwrites a remote's branch
// with the local one, protected by a lease. Never forced without one, and
// an agent's lease only on the user's approval of exactly it, in every mode
// (AgentForcePushRules). Served by apelin-environment with the rest of the
// git service (Git.swift).

/// A forced push's lease, as `git push --force-with-lease=<branch>:<commit>`
/// takes it: the remote's branch is overwritten only while it is at
/// `expectedCommit`, which the remote is held to on the connection that
/// pushes, and only by `localCommit` when it is given. A remote that says
/// another commit, or has no such branch, fails the push with `conflict`,
/// reason `remoteChanged`; a local branch elsewhere with reason
/// `localChanged`. Nothing is pushed either way.
public struct GitPushLease: Codable, Sendable, Hashable {
    /// The full commit the remote's branch must be at: what is overwritten.
    public var expectedCommit: String
    /// The full commit the local branch must be at: what is pushed in its
    /// place.
    public var localCommit: String?

    public init(expectedCommit: String, localCommit: String? = nil) {
        self.expectedCommit = expectedCommit
        self.localCommit = localCommit
    }

    /// Nil when both are full commit IDs, else why not.
    public var problem: String? {
        guard Self.isCommitID(expectedCommit), localCommit.map(Self.isCommitID) ?? true else {
            return "A lease names full commit IDs: 40 lowercase hexadecimal digits (64 in a SHA-256 repository)."
        }
        return nil
    }

    /// 40 lowercase hexadecimal digits, or 64 in a SHA-256 repository.
    public static func isCommitID(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64)
            && text.utf8.allSatisfy { (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }
    }
}

/// A commit as a list names it: its full ID and the first line of its
/// message, at most 200 characters of it.
public struct GitCommitSummary: Codable, Sendable, Hashable {
    public var commit: String
    public var subject: String

    public init(commit: String, subject: String) {
        self.commit = commit
        self.subject = subject
    }
}

/// A local branch beside the branch of the same name on a remote, as the
/// remote advertised it to a fetch (`GitFetchRequest.branch`): what a
/// forced push of the branch would take off the remote's.
public struct GitBranchComparison: Codable, Sendable, Hashable {
    public var branch: String
    /// The local branch's commit, and the first line of its message.
    public var local: String
    public var localSubject: String
    /// The remote's branch's commit; nil when the remote has no such branch.
    public var remote: String?
    /// Where a push to the remote goes, when it is an address Apelin pushes
    /// to.
    public var pushURL: String?
    /// The commits on the remote's branch the local branch does not have,
    /// newest first, the first ten: what a forced push takes off the
    /// branch. Empty when the remote's branch is part of the local one, so
    /// an ordinary push loses nothing.
    public var remoteOnly: [GitCommitSummary]
    /// How many there are in all.
    public var remoteOnlyCount: Int

    public init(
        branch: String,
        local: String,
        localSubject: String,
        remote: String?,
        pushURL: String? = nil,
        remoteOnly: [GitCommitSummary] = [],
        remoteOnlyCount: Int = 0,
    ) {
        self.branch = branch
        self.local = local
        self.localSubject = localSubject
        self.remote = remote
        self.pushURL = pushURL
        self.remoteOnly = remoteOnly
        self.remoteOnlyCount = remoteOnlyCount
    }
}

public extension ApelinError.Reason {
    /// `conflict`: a forced push's lease did not hold — the remote's branch
    /// is not at the commit it was to replace, or is gone. Nothing was
    /// pushed; what it is at now is a new question for the user.
    static let remoteChanged = Self(rawValue: "remoteChanged")
    /// `conflict`: a forced push's local branch is not at the commit it was
    /// to send. Nothing was pushed.
    static let localChanged = Self(rawValue: "localChanged")
}
