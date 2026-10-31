import ApelinCore
import ApelinGit
import ApelinProject
import ApelinProtocol
import Foundation

/// "Remote wins" (issue #32): what a reset of a project to a remote's branch
/// would lose, read after a fetch, and the reset itself, held to exactly
/// the state that was shown. Apelin's own files (`apelin-project.json`, the
/// icon) are settled as an import settles them: the remote's when it has
/// them, the project's identity kept in the manifest; the project's own,
/// kept out of the repository, when it has not.
public extension GitService {
    /// A project's repository and the remote a preview or a reset fetches,
    /// checked when the request was accepted.
    struct ResetTarget: Sendable {
        let project: ProjectLocator.Project
        let repository: GitRepository
        let remote: String
        let branch: String?
        /// The remote's address as a preview shows it.
        let url: String
    }

    /// Validates a preview before the task is accepted.
    func prepareResetPreview(_ request: GitResetPreviewRequest) throws -> ResetTarget {
        try resetTarget(request.projectID, remote: request.remote, branch: request.branch)
    }

    /// Validates a reset before the task is accepted: the remote is still at
    /// the address shown, and the commits are commits.
    func prepareReset(_ request: GitResetToRemoteRequest) throws -> ResetTarget {
        let target = try resetTarget(request.projectID, remote: request.remote, branch: request.branch)
        guard Self.isCommitID(request.expectedRemoteCommit), request.expectedHead.map(Self.isCommitID) ?? true else {
            throw ApelinError(.badRequest, "expectedRemoteCommit and expectedHead are commit IDs")
        }
        if let expected = request.expectedURL, expected != target.url {
            throw ApelinError(
                .conflict,
                "\(request.remote) points to \(target.url) now, not \(expected) as shown: nothing was changed",
            )
        }
        return target
    }

    /// `progress` while it fetches, then the `GitResetPreview`.
    func resetPreview(_ target: ResetTarget, reporter: TaskReporter) throws -> JSONValue {
        reporter.stage("fetching")
        let branch = try mapped {
            try target.repository.fetchBranch(
                remote: target.remote,
                branch: target.branch,
                credentials: credentialLookup,
                progress: Self.fetchProgress(reporter),
            )
        }
        let plan = try mapped { try target.repository.resetPlan(remote: target.remote, branch: branch) }
        let files = try settledFiles(target, remoteCommit: plan.remoteCommit)
        let listed = GitResetPreview.listed
        let preview = GitResetPreview(
            remote: target.remote,
            url: target.url,
            branch: branch,
            remoteCommit: plan.remoteCommit,
            remoteSubject: plan.remoteSubject,
            head: plan.head,
            currentBranch: plan.currentBranch,
            unrelatedHistories: plan.unrelatedHistories,
            lostCommitCount: plan.lostCommitCount,
            lostCommits: plan.lostCommits.prefix(listed).map { GitCommitLine(commit: $0.commit, subject: $0.subject) },
            changedFileCount: plan.changedFiles.count,
            changedFiles: plan.changedFiles.prefix(listed).map {
                GitStatusEntry(path: $0.path, index: $0.index, worktree: $0.worktree)
            },
            overwrittenFileCount: plan.overwrittenFiles.count,
            overwrittenFiles: Array(plan.overwrittenFiles.prefix(listed)),
            projectFile: files.file,
            upToDate: plan.upToDate,
        )
        return try JSONValue(encoding: preview)
    }

    /// `progress` {stage: fetching, then resetting}, then {remote, branch,
    /// commit, previousHead?, backupBranch?, projectFile}.
    func reset(_ target: ResetTarget, _ request: GitResetToRemoteRequest, reporter: TaskReporter) throws -> JSONValue {
        reporter.stage("fetching")
        _ = try mapped {
            try target.repository.fetchBranch(
                remote: target.remote,
                branch: request.branch,
                credentials: credentialLookup,
                progress: Self.fetchProgress(reporter),
            )
        }
        try reporter.checkCancelled()
        let files = try settledFiles(target, remoteCommit: request.expectedRemoteCommit)
        reporter.stage("resetting")
        let backupAuthor = (try? author(name: nil, email: nil, repository: target.repository))
            ?? GitSignature(name: "Apelin", email: "apelin@localhost.invalid")
        let result = try mapped {
            try target.repository.reset(
                toRemote: target.remote,
                branch: request.branch,
                expectedRemoteCommit: request.expectedRemoteCommit,
                expectedHead: request.expectedHead,
                backupAuthor: backupAuthor,
                settled: files.settled,
                excluding: files.excluded,
            )
        }
        var payload: [String: JSONValue] = [
            "remote": .string(target.remote),
            "branch": .string(result.branch),
            "commit": .string(result.commit),
            "projectFile": .string(files.file.rawValue),
        ]
        if let previous = result.previousHead {
            payload["previousHead"] = .string(previous)
        }
        if let backup = result.backupBranch {
            payload["backupBranch"] = .string(backup)
        }
        return .object(payload)
    }

    // MARK: Helpers

    private func resetTarget(_ projectID: String, remote: String, branch: String?) throws -> ResetTarget {
        let (project, repository) = try open(projectID)
        if let problem = GitRemoteName.existingProblem(remote) {
            throw ApelinError(.badRequest, problem)
        }
        if let branch, !GitRepository.isValidBranchName(branch) {
            throw ApelinError(.badRequest, "\(branch.debugDescription) is not a branch name")
        }
        guard let url = repository.remoteURL(remote) else {
            throw ApelinError(.notFound, "no remote \(remote.debugDescription)", reason: .noSuchRemote)
        }
        try checkRemoteURL(url)
        return ResetTarget(
            project: project,
            repository: repository,
            remote: remote,
            branch: branch,
            url: GitRemoteURL.shown(url).url ?? url,
        )
    }

    /// What Apelin's own files hold after a reset to `remoteCommit`: the
    /// remote's manifest with this project's ID (refused when it does not
    /// read as one), else this project's own, and the icon likewise; and
    /// the files the remote lacks, which are kept out of the repository.
    private func settledFiles(
        _ target: ResetTarget,
        remoteCommit: String,
    ) throws -> (settled: [String: Data], excluded: [String], file: GitProjectFile) {
        var settled: [String: Data] = [:]
        var excluded: [String] = []
        var file = GitProjectFile.project
        for name in [RepositoryManifest.fileName, Self.iconFileName] {
            let theirs = try mapped { try target.repository.fileContents(name, inCommit: remoteCommit) }
            if let theirs, name == RepositoryManifest.fileName {
                let manifest = RepositoryManifest(
                    ownID: target.project.projectID,
                    mayTakeTheirs: target.project.projectID == nil,
                    root: target.project.root,
                    projects: projects,
                )
                settled[name] = try manifest.settle(theirs)
                file = manifest.file
            } else if theirs == nil, let ours = try? ProjectFiles.read(name, in: target.project.root) {
                settled[name] = ours
                excluded.append("/" + name)
            }
        }
        return (settled, excluded, file)
    }

    private static let iconFileName = "apelin-icon.png"

    /// A full commit ID, SHA-1 or SHA-256, in lowercase hex.
    private static func isCommitID(_ id: String) -> Bool {
        (id.count == 40 || id.count == 64) && id.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }
}
