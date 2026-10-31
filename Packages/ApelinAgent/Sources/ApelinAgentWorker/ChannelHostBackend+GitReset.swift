import ApelinAgent
import ApelinCore
import ApelinProtocol
import Foundation

/// git_reset_to_remote → `gitResetPreview` before anyone is asked, then
/// `gitResetToRemote` with the remote's commit, HEAD and address the card
/// showed, each read to its end on the session's own project.
public extension ChannelHostBackend {
    func gitResetPreview(_ request: GitResetPreviewToolRequest) async throws -> GitResetPreviewToolResponse {
        let host = try? await remoteHost(request.remote)
        let json = try await gitTaskResult("git reset preview", host: host) {
            try await service.gitResetPreview(GitResetPreviewRequest(
                projectID: project.id,
                remote: request.remote,
                branch: request.branch,
            ))
        }
        guard let preview = try? json?.decode(GitResetPreview.self) else {
            throw GitToolFailure(message: "What a reset to \(request.remote) would discard could not be read.")
        }
        return GitResetPreviewToolResponse(approval: Self.approval(preview, projectID: project.id), upToDate: preview.upToDate)
    }

    func gitResetToRemote(_ request: GitResetToolRequest) async throws -> GitResetToolResponse {
        let card = request.approval
        let json = try await gitTaskResult("git reset to remote", host: URLComponents(string: card.url)?.host) {
            try await service.gitResetToRemote(GitResetToRemoteRequest(
                projectID: project.id,
                remote: card.remote,
                branch: card.branch,
                expectedRemoteCommit: card.remoteCommit,
                expectedHead: card.head,
                expectedURL: card.url,
            ))
        }
        let file = json?["projectFile"]?.stringValue.flatMap(GitProjectFile.init(rawValue:))
        return GitResetToolResponse(
            remote: card.remote,
            branch: json?["branch"]?.stringValue ?? card.branch,
            commit: json?["commit"]?.stringValue ?? card.remoteCommit,
            previousHead: json?["previousHead"]?.stringValue,
            backupBranch: json?["backupBranch"]?.stringValue,
            projectFile: file.flatMap(Self.projectFileNote),
        )
    }

    /// The card's facts from the host's preview, its lists cut to a few.
    internal static func approval(_ preview: GitResetPreview, projectID: String) -> ResetToRemoteApproval {
        let shown = 10
        return ResetToRemoteApproval(
            projectID: projectID,
            remote: preview.remote,
            url: preview.url,
            branch: preview.branch,
            remoteCommit: preview.remoteCommit,
            remoteSubject: preview.remoteSubject,
            head: preview.head,
            currentBranch: preview.currentBranch,
            unrelatedHistories: preview.unrelatedHistories,
            lostCommitCount: preview.lostCommitCount,
            lostCommits: preview.lostCommits.prefix(shown).map { .init(commit: $0.commit, subject: $0.subject) },
            changedFileCount: preview.changedFileCount,
            changedFiles: preview.changedFiles.prefix(shown).map(\.path),
            overwrittenFileCount: preview.overwrittenFileCount,
            overwrittenFiles: Array(preview.overwrittenFiles.prefix(shown)),
            projectFile: preview.projectFile.rawValue,
        )
    }

    /// The host of the remote's address, for a sign-in a failure names.
    private func remoteHost(_ remote: String) async throws -> String? {
        let remotes = try await service.gitRemoteList(projectID: project.id).remotes
        return remotes.first { $0.name == remote }?.url.flatMap { URLComponents(string: $0)?.host }
    }
}
