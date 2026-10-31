import ApelinAgent
import ApelinProtocol
import Foundation

/// git_remote_list, git_remote_set and git_remote_remove → `gitRemoteList`,
/// `gitRemoteSet` and `gitRemoteRemove` on the session's own project, which
/// the host checks again.
public extension ChannelHostBackend {
    func gitRemoteList(_: GitRemoteListToolRequest) async throws -> GitRemoteListToolResponse {
        let response = try await git("git remote list") { try await service.gitRemoteList(projectID: project.id) }
        return GitRemoteListToolResponse(remotes: response.remotes.map(Self.remote))
    }

    func gitRemoteSet(_ request: GitRemoteSetToolRequest) async throws -> GitRemoteSetToolResponse {
        let response = try await git("git remote set") {
            try await service.gitRemoteSet(projectID: project.id, name: request.name, url: request.url)
        }
        return GitRemoteSetToolResponse(remote: Self.remote(response.remote), previousURL: response.previousURL)
    }

    /// Answers the remotes that are left.
    func gitRemoteRemove(_ request: GitRemoteRemoveToolRequest) async throws -> GitRemoteListToolResponse {
        try await git("git remote remove") { try await service.gitRemoteRemove(projectID: project.id, name: request.name) }
        return try await gitRemoteList(GitRemoteListToolRequest(context: request.context))
    }

    internal static func remote(_ summary: GitRemoteSummary) -> GitRemoteToolEntry {
        GitRemoteToolEntry(
            name: summary.name,
            url: summary.url,
            pushURL: summary.pushURL,
            hidesCredential: summary.hidesCredential,
        )
    }
}
