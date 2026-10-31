import ApelinCore
import ApelinGit
import ApelinProtocol
import Foundation

/// A project repository's remotes (issue #32): what `git remote -v` shows,
/// with no credential in it, and `git remote add`, `set-url` and `remove`.
/// Nothing here talks to a remote.
public extension GitService {
    func remotes(_ request: GitRemoteListRequest) throws -> GitRemoteListResponse {
        let repository = try open(request.projectID).repository
        return try GitRemoteListResponse(remotes: mapped { try repository.remotes() }.map(Self.summary))
    }

    /// Adds the remote, or points the one of that name at `url`: an HTTPS
    /// address with nothing secret in it, so none is ever written into the
    /// repository's configuration.
    func setRemote(_ request: GitRemoteSetRequest) throws -> GitRemoteSetResponse {
        let repository = try open(request.projectID).repository
        try Self.checkRemoteName(request.name)
        if !(acceptsLocalRemotes && request.url.hasPrefix("/")), let problem = GitRemoteURL.problem(request.url) {
            throw ApelinError(.badRequest, problem)
        }
        try checkRemoteURL(request.url)
        let previous = repository.remoteURL(request.name)
        try mapped {
            if previous == nil {
                try repository.addRemote(request.name, url: request.url)
            } else {
                try repository.setRemoteURL(request.name, url: request.url)
            }
        }
        let entry = try mapped { try repository.remotes() }.first { $0.name == request.name }
            ?? GitRemoteEntry(name: request.name, url: request.url)
        return GitRemoteSetResponse(remote: Self.summary(entry), previousURL: previous.flatMap { GitRemoteURL.shown($0).url })
    }

    /// Any remote the repository has, whatever made it, so long as its name
    /// is no address or option.
    func removeRemote(_ request: GitRemoteRemoveRequest) throws -> Acknowledged {
        let repository = try open(request.projectID).repository
        if let problem = GitRemoteName.existingProblem(request.name) {
            throw ApelinError(.badRequest, problem)
        }
        guard GitRepository.isValidRemoteName(request.name), repository.remoteURL(request.name) != nil else {
            throw ApelinError(.notFound, "no remote \(request.name.debugDescription)", reason: .noSuchRemote)
        }
        try mapped { try repository.removeRemote(request.name) }
        return Acknowledged()
    }

    /// A remote's name as `GitRemoteName` and libgit2 both take it.
    internal static func checkRemoteName(_ name: String) throws {
        if let problem = GitRemoteName.problem(name) {
            throw ApelinError(.badRequest, problem)
        }
        guard GitRepository.isValidRemoteName(name) else {
            throw ApelinError(.badRequest, "\(name.debugDescription) is not a remote name")
        }
    }

    /// An entry as the wire shows it: its addresses without a user,
    /// password, query or fragment.
    internal static func summary(_ entry: GitRemoteEntry) -> GitRemoteSummary {
        let fetch = entry.url.map(GitRemoteURL.shown)
        let push = entry.pushURL.map(GitRemoteURL.shown)
        let hidden = fetch?.hidden == true || push?.hidden == true
        return GitRemoteSummary(
            name: entry.name,
            url: fetch?.url,
            pushURL: push?.url,
            hidesCredential: hidden ? true : nil,
        )
    }
}
