import Foundation

/// What a git_reset_to_remote card names (issue #32), read from the fetch
/// just before it asked, and the host matches the reset to
/// (AgentResetToRemoteRules): the project, the remote and its address, the
/// branch, the remote's commit and where HEAD was. The rest is what the
/// user loses, which the card shows and the backup branch keeps.
public struct ResetToRemoteApproval: Sendable, Hashable, Codable {
    public struct Commit: Sendable, Hashable, Codable {
        public var commit: String
        public var subject: String
        public init(commit: String, subject: String) {
            self.commit = commit
            self.subject = subject
        }
    }

    public var projectID: String
    public var remote: String
    /// The address it fetches from, without a credential.
    public var url: String
    public var branch: String
    public var remoteCommit: String
    public var remoteSubject: String?
    /// Where HEAD is; nil when it has no commit.
    public var head: String?
    /// The branch HEAD is on; nil when detached.
    public var currentBranch: String?
    public var unrelatedHistories: Bool
    public var lostCommitCount: Int
    /// The first few, newest first.
    public var lostCommits: [Commit]
    public var changedFileCount: Int
    /// The first few, by path.
    public var changedFiles: [String]
    public var overwrittenFileCount: Int
    public var overwrittenFiles: [String]
    /// What `apelin-project.json` becomes: `repository`,
    /// `repositoryWithProjectID` or `project` (ApelinProtocol's
    /// `GitProjectFile`).
    public var projectFile: String

    public init(
        projectID: String,
        remote: String,
        url: String,
        branch: String,
        remoteCommit: String,
        remoteSubject: String?,
        head: String?,
        currentBranch: String?,
        unrelatedHistories: Bool,
        lostCommitCount: Int,
        lostCommits: [Commit],
        changedFileCount: Int,
        changedFiles: [String],
        overwrittenFileCount: Int,
        overwrittenFiles: [String],
        projectFile: String,
    ) {
        self.projectID = projectID
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
    }

    /// What the card says it does and loses, in a few sentences.
    var reason: String {
        func short(_ commit: String) -> String {
            String(commit.prefix(7))
        }
        func list(_ items: [String], of count: Int) -> String {
            let shown = items.prefix(5).joined(separator: ", ")
            return count > 5 ? "\(shown) and \(count - 5) more" : shown
        }
        // The remote's words: one line, and short, so they cannot pass for
        // the card's own.
        let subject = remoteSubject.map { text in
            let line = text.components(separatedBy: .newlines).joined(separator: " ")
            return " “\(line.count > 100 ? String(line.prefix(100)) + "…" : line)”"
        } ?? ""
        var parts = ["Makes this project exactly \(remote)/\(branch) (\(url)) at \(short(remoteCommit))\(subject)."]
        if let currentBranch, currentBranch != branch {
            parts.append("The project switches from the branch \(currentBranch), which stays as it is, to \(branch).")
        } else if currentBranch == nil, let head {
            parts.append("HEAD moves from \(short(head)), where it was detached, to the branch \(branch).")
        } else if let head {
            parts.append("The branch \(branch) moves there from \(short(head)).")
        }
        if unrelatedHistories {
            parts.append("The project's history and the remote's have nothing in common.")
        }
        if lostCommitCount > 0 {
            let subjects = lostCommits.prefix(5).map { "“\($0.subject)”" }.joined(separator: ", ")
            let more = lostCommitCount > 5 ? " and \(lostCommitCount - 5) more" : ""
            parts.append("\(lostCommitCount) local commit\(lostCommitCount == 1 ? "" : "s") leave\(lostCommitCount == 1 ? "s" : "") the branch: \(subjects)\(more).")
        }
        if changedFileCount > 0 {
            parts.append("Uncommitted changes to \(changedFileCount) file\(changedFileCount == 1 ? " is" : "s are") replaced: \(list(changedFiles, of: changedFileCount)).")
        }
        if overwrittenFileCount > 0 {
            parts.append("\(overwrittenFileCount) untracked file\(overwrittenFileCount == 1 ? " the remote also has is" : "s the remote also has are") overwritten: \(list(overwrittenFiles, of: overwrittenFileCount)).")
        }
        switch projectFile {
        case "repositoryWithProjectID":
            parts.append("apelin-project.json becomes the remote's, with this project's own projectID.")
        case "project":
            parts.append("apelin-project.json stays this project's, since the remote has none.")
        default:
            break
        }
        let saved = head == nil && changedFileCount == 0 && overwrittenFileCount == 0
            ? "" : " All of it is saved first on a new branch named apelin-backup/ and the time, which is the only way back."
        parts.append("Untracked files the remote does not have stay.\(saved) Each reset needs your approval, in every mode.")
        return parts.joined(separator: " ")
    }
}
