internal import GitKit
import Foundation

/// One remote as the repository's configuration has it.
public struct GitRemoteEntry: Sendable, Equatable {
    public var name: String
    /// The URL it fetches from.
    public var url: String?
    /// Where a push goes when that is not `url`: its `pushurl`, or a
    /// `pushInsteadOf` rewrite.
    public var pushURL: String?

    public init(name: String, url: String?, pushURL: String? = nil) {
        self.name = name
        self.url = url
        self.pushURL = pushURL
    }
}

/// The remotes of a repository, listed, pointed at an address and removed
/// (`addRemote` and `removeRemote` are beside fetch and push).
public extension GitRepository {
    /// Every remote, sorted by name.
    func remotes() throws -> [GitRemoteEntry] {
        var names = git_strarray()
        try GitError.check(git_remote_list(&names, pointer), "list the remotes")
        defer { git_strarray_dispose(&names) }
        var entries: [GitRemoteEntry] = []
        for position in 0 ..< names.count {
            guard let raw = names.strings[position] else { continue }
            let name = String(cString: raw)
            let url = remoteURL(name)
            let push = remotePushURL(name)
            entries.append(GitRemoteEntry(name: name, url: url, pushURL: push == url ? nil : push))
        }
        return entries.sorted { $0.name < $1.name }
    }

    /// Points the remote `name` at `url`, as `git remote set-url` does, and
    /// takes away a `pushurl` of its own, so a push goes where a fetch does.
    func setRemoteURL(_ name: String, url: String) throws {
        let remote = try lookupRemote(name)
        git_remote_free(remote)
        guard !url.utf8.contains(0) else { throw GitError(.invalid, "bad remote URL") }
        try GitError.check(git_remote_set_url(pointer, name, url), "point \(name) at the address")
        if localConfigValue("remote.\(name).pushurl") != nil {
            try GitError.check(git_remote_set_pushurl(pointer, name, nil), "clear \(name)'s push address")
        }
    }

    /// Whether libgit2 takes `name` for a remote's name.
    static func isValidRemoteName(_ name: String) -> Bool {
        GitLibrary.ensure()
        var valid: Int32 = 0
        return !name.utf8.contains(0) && !name.hasPrefix("-") && git_remote_name_is_valid(&valid, name) == 0 && valid != 0
    }
}
