internal import GitKit
import Darwin
import Foundation

/// How far the upload of a push has got.
public struct GitPushProgress: Sendable, Equatable {
    public var current: Int
    public var total: Int
    public var bytes: Int
}

/// One reference a fetch moved: `from` is nil for one it made.
public struct GitRefUpdate: Sendable, Equatable {
    public var ref: String
    public var from: String?
    public var to: String
}

public struct GitFetchResult: Sendable, Equatable {
    public var remote: String
    public var updated: [GitRefUpdate]
    /// The branch the fetch was asked to compare, beside what the remote
    /// had for it.
    public var comparison: GitRemoteComparison?
}

/// A commit as a list names it: its ID and the first line of its message.
public struct GitLogEntry: Sendable, Equatable {
    public var commit: String
    public var subject: String
}

/// A local branch beside the branch of the same name on a remote, as the
/// remote advertised it to a fetch.
public struct GitRemoteComparison: Sendable, Equatable {
    public var branch: String
    /// The local branch's commit, and the first line of its message.
    public var local: String
    public var localSubject: String
    /// The remote's branch's commit; nil when the remote has no such branch.
    public var remote: String?
    /// The commits on the remote's branch the local branch does not have,
    /// newest first, at most as many as were asked for: what a forced push
    /// takes off the branch. Empty when the remote's branch is part of the
    /// local one, so an ordinary push loses nothing.
    public var remoteOnly: [GitLogEntry] = []
    /// How many there are in all.
    public var remoteOnlyCount = 0
}

public struct GitPullResult: Sendable, Equatable {
    public var branch: String
    /// Where the branch was; nil when it had no commit yet.
    public var from: String?
    public var to: String
    public var upToDate: Bool
}

public struct GitPushResult: Sendable, Equatable {
    public var remote: String
    public var branch: String
    public var commit: String
    /// Where the remote's branch was before the push; nil when the push made
    /// it.
    public var from: String?
    /// Whether it went with a lease (`GitLease`), which held.
    public var forced = false
}

/// What a forced push replaces, as `git push --force-with-lease` takes it:
/// the remote's branch is overwritten only while it is at `expectedCommit`,
/// and, when `localCommit` is given, only while the local branch is at that
/// one, so what is pushed is what was approved.
public struct GitLease: Sendable, Equatable {
    public var expectedCommit: String
    public var localCommit: String?

    public init(expectedCommit: String, localCommit: String? = nil) {
        self.expectedCommit = expectedCommit
        self.localCommit = localCommit
    }
}

/// Talking to a remote: fetch, a fast-forward pull, and push. A remote is
/// named, never a URL, so what is fetched from or pushed to is what the
/// repository's configuration says; the caller checked that URL before.
public extension GitRepository {
    /// Fetches the remote's configured refspecs into its remote-tracking
    /// references, tags following as git's default does. The work tree, the
    /// index and every branch are left alone. `progress` stops the fetch by
    /// answering false; it then throws `cancelled`.
    ///
    /// With `comparing`, a local branch with a commit, the result also sets
    /// it beside the branch of that name the remote advertised to this
    /// fetch (`GitRemoteComparison`), listing at most `listing` of the
    /// commits only the remote's has.
    func fetch(
        remote name: String = "origin",
        comparing branch: String? = nil,
        listing: Int = 10,
        credentials: GitCredentialLookup? = nil,
        progress: @escaping (GitCloneProgress) -> Bool = { _ in true },
    ) throws -> GitFetchResult {
        var local: String?
        if let branch {
            try Self.checkBranchName(branch)
            local = commit(ofBranch: branch)
            guard local != nil else { throw GitError(.notFound, "no branch \(branch) with a commit") }
        }
        let remote = try lookupRemote(name)
        defer { git_remote_free(remote) }
        let callbacks = RemoteCallbacks(credentials: credentials)
        callbacks.fetchProgress = progress
        var options = git_fetch_options()
        git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
        callbacks.install(&options.callbacks)
        let code = withExtendedLifetime(callbacks) { git_remote_fetch(remote, nil, &options, nil) }
        guard code == 0 else { throw callbacks.failure(code, "fetch \(name)") }
        var result = GitFetchResult(remote: name, updated: callbacks.updates)
        if let branch, let local {
            result.comparison = try compare(
                branch: branch,
                local: local,
                remote: Self.advertised("refs/heads/" + branch, by: remote),
                remoteName: name,
                listing: listing,
            )
        }
        return result
    }

    /// The commit of the local `branch`, or nil when it has none.
    func commit(ofBranch branch: String) -> String? {
        var commit = git_oid()
        guard Self.isValidBranchName(branch),
              git_reference_name_to_id(&commit, pointer, "refs/heads/" + branch) == 0
        else { return nil }
        return Self.hex(&commit)
    }

    /// The commit a remote advertised for `ref` on its last connection,
    /// which libgit2 keeps after it disconnects; nil when it has no such
    /// reference.
    private static func advertised(_ ref: String, by remote: OpaquePointer) throws -> String? {
        var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
        var count = 0
        try GitError.check(git_remote_ls(&heads, &count, remote), "read what the remote has")
        for index in 0 ..< count {
            guard let head = heads?[index], String(cString: head.pointee.name) == ref else { continue }
            var oid = head.pointee.oid
            return hex(&oid)
        }
        return nil
    }

    /// `local`, the commit of `branch`, beside `remote`, what the remote has
    /// for it, which the fetch brought in.
    private func compare(
        branch: String,
        local: String,
        remote: String?,
        remoteName: String,
        listing: Int,
    ) throws -> GitRemoteComparison {
        var base = git_oid()
        try GitError.check(git_oid_fromstr(&base, local), "read \(branch)")
        var comparison = try GitRemoteComparison(
            branch: branch,
            local: local,
            localSubject: summary(of: &base).subject,
            remote: remote,
        )
        guard let remote, remote != local else { return comparison }
        var walk: OpaquePointer?
        try GitError.check(git_revwalk_new(&walk, pointer), "walk the history")
        defer { git_revwalk_free(walk) }
        try GitError.check(
            git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue),
            "walk the history",
        )
        var tip = git_oid()
        try GitError.check(git_oid_fromstr(&tip, remote), "read \(remoteName)'s \(branch)")
        guard git_revwalk_push(walk, &tip) == 0 else {
            throw GitError(.notFound, "the fetch did not bring \(remoteName)'s \(branch): its refspec leaves it out")
        }
        try GitError.check(git_revwalk_hide(walk, &base), "walk \(branch)")
        var next = git_oid()
        while git_revwalk_next(&next, walk) == 0 {
            comparison.remoteOnlyCount += 1
            if comparison.remoteOnly.count < listing {
                try comparison.remoteOnly.append(summary(of: &next))
            }
        }
        return comparison
    }

    /// The commit `oid` with the first line of its message, at most 200
    /// characters of it.
    private func summary(of oid: inout git_oid) throws -> GitLogEntry {
        var commit: OpaquePointer?
        try GitError.check(git_commit_lookup(&commit, pointer, &oid), "read a commit")
        defer { git_commit_free(commit) }
        let subject = git_commit_summary(commit).map { String(cString: $0) } ?? ""
        return GitLogEntry(
            commit: Self.hex(&oid),
            subject: subject.count > 200 ? String(subject.prefix(200)) + "…" : subject,
        )
    }

    /// Fetches, then moves the checked-out branch forward to its upstream:
    /// `branch.<name>.merge` when `branch.<name>.remote` is the remote
    /// fetched, else `<remote>/<name>`. `remote` nil is the branch's own
    /// remote, else `origin`.
    ///
    /// Only a fast-forward: a branch with commits its upstream does not have
    /// throws `notFastForward`, and a change in the work tree or the index
    /// the new commit would overwrite (an untracked or ignored file in the
    /// way included) `conflict`. Either way nothing is changed but the remote-tracking
    /// references the fetch moved.
    func pull(
        remote: String? = nil,
        credentials: GitCredentialLookup? = nil,
        progress: @escaping (GitCloneProgress) -> Bool = { _ in true },
    ) throws -> GitPullResult {
        guard let branch = head().branch else { throw GitError(.invalid, "HEAD is not on a branch") }
        let local = "refs/heads/" + branch
        let configured = localConfigValue("branch.\(branch).remote")
        let remoteName = remote ?? configured ?? "origin"
        let upstream: String
        if configured == remoteName, localConfigValue("branch.\(branch).merge") != nil {
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            try GitError.check(git_branch_upstream_name(&buffer, pointer, local), "find \(branch)'s upstream")
            upstream = String(cString: buffer.ptr)
        } else {
            upstream = "refs/remotes/\(remoteName)/\(branch)"
        }

        _ = try fetch(remote: remoteName, credentials: credentials, progress: progress)

        var target = git_oid()
        guard git_reference_name_to_id(&target, pointer, upstream) == 0 else {
            throw GitError(.notFound, "\(remoteName) has no branch for \(branch) (\(upstream))")
        }
        let to = Self.hex(&target)
        let from = head().commit
        if from == to {
            return GitPullResult(branch: branch, from: from, to: to, upToDate: true)
        }

        var annotated: OpaquePointer?
        try GitError.check(git_annotated_commit_lookup(&annotated, pointer, &target), "read \(upstream)")
        defer { git_annotated_commit_free(annotated) }
        var analysis = git_merge_analysis_t(rawValue: 0)
        var preference = git_merge_preference_t(rawValue: 0)
        var heads: [OpaquePointer?] = [annotated]
        try GitError.check(
            git_merge_analysis(&analysis, &preference, pointer, &heads, 1),
            "compare \(branch) with \(upstream)",
        )
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return GitPullResult(branch: branch, from: from, to: from ?? to, upToDate: true)
        }
        let fastForward = GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue | GIT_MERGE_ANALYSIS_UNBORN.rawValue
        guard analysis.rawValue & fastForward != 0 else {
            throw GitError(
                .notFastForward,
                "\(branch) and \(upstream) have diverged: a pull only fast-forwards, so merge or rebase them first",
            )
        }

        var commit: OpaquePointer?
        try GitError.check(git_commit_lookup(&commit, pointer, &target), "read \(upstream)'s commit")
        defer { git_commit_free(commit) }
        let checkout = CheckoutRecord()
        let code = checkout.run { options in git_checkout_tree(pointer, commit, &options) }
        guard code == 0 else { throw checkout.failure(code, "fast-forward \(branch)") }

        var moved: OpaquePointer?
        defer { git_reference_free(moved) }
        let message = "pull: fast-forward to \(upstream)"
        if let from {
            var current = git_oid()
            try GitError.check(git_oid_fromstr(&current, from), "read \(branch)")
            try GitError.check(
                git_reference_create_matching(&moved, pointer, local, &target, 1, &current, message),
                "move \(branch)",
            )
        } else {
            try GitError.check(git_reference_create(&moved, pointer, local, &target, 0, message), "make \(branch)")
        }
        return GitPullResult(branch: branch, from: from, to: to, upToDate: false)
    }

    /// Pushes `branch` (nil: the checked-out one) to the branch of the same
    /// name on `remote`, then records it as the branch's upstream
    /// (`branch.<name>.remote` and `.merge`). An update the remote refuses —
    /// one that is not a fast-forward, or a hook's no — throws `rejected`
    /// and records nothing.
    ///
    /// Never forced without a `lease`. With one, the remote's branch is
    /// overwritten (`+refs/heads/<branch>`) only when the remote, on the
    /// connection that pushes, says it is at `expectedCommit`: libgit2 sends
    /// the commit the remote said as the update's old value, and the
    /// remote's own compare-and-swap holds it to that (git's receive-pack
    /// and GitHub refuse an update whose old value the branch no longer
    /// has), so a change made after the check is refused there too. A
    /// remote that says another commit, or has no such branch, throws
    /// `remoteChanged`, and a local branch that is not at `localCommit`
    /// `localChanged`; nothing is pushed. `remoteCommit` is told what the
    /// remote's branch was at as soon as the remote says, before anything
    /// is sent.
    func push(
        remote name: String = "origin",
        branch: String? = nil,
        lease: GitLease? = nil,
        credentials: GitCredentialLookup? = nil,
        remoteCommit: @escaping (String?) -> Void = { _ in },
        progress: @escaping (GitPushProgress) -> Bool = { _ in true },
    ) throws -> GitPushResult {
        guard let branch = branch ?? head().branch else {
            throw GitError(.invalid, "HEAD is not on a branch: name the branch to push")
        }
        try Self.checkBranchName(branch)
        let local = "refs/heads/" + branch
        guard let commit = commit(ofBranch: branch) else {
            throw GitError(.notFound, "no branch \(branch) with a commit to push")
        }
        if let lease {
            guard Self.isCommitID(lease.expectedCommit), lease.localCommit.map(Self.isCommitID) ?? true else {
                throw GitError(.invalid, "a lease names full commit IDs")
            }
            if let approved = lease.localCommit, approved != commit {
                throw GitError(
                    .localChanged,
                    "\(branch) is at \(commit) now, not \(approved), the commit this push was to send: nothing was pushed",
                )
            }
        }
        let remote = try lookupRemote(name)
        defer { git_remote_free(remote) }
        let callbacks = RemoteCallbacks(credentials: credentials)
        callbacks.pushProgress = progress
        callbacks.lease = lease.map { (ref: local, expectedCommit: $0.expectedCommit) }
        callbacks.remoteCommit = { ref, found in
            if ref == local {
                remoteCommit(found)
            }
        }
        var options = git_push_options()
        git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
        callbacks.install(&options.callbacks)
        let refspec = (lease == nil ? "" : "+") + "\(local):\(local)"
        let code = withExtendedLifetime(callbacks) {
            Self.withStrings([refspec]) { refspecs in
                var refspecs = refspecs
                return git_remote_push(remote, &refspecs, &options)
            }
        }
        if let lease, let refusal = callbacks.leaseRefusal {
            let state = refusal.found.map { "is at \($0) now, not \(lease.expectedCommit)" }
                ?? "is gone, so it is not at \(lease.expectedCommit)"
            throw GitError(
                .remoteChanged,
                "\(name)'s \(branch) \(state), the commit this push was to replace: it changed since, so nothing was pushed",
            )
        }
        if code == GIT_ENONFASTFORWARD.rawValue {
            throw GitError(.rejected, "\(name)'s \(branch) has commits this one does not: pull first")
        }
        guard code == 0 else { throw callbacks.failure(code, "push \(branch) to \(name)") }
        if let rejected = callbacks.rejections.first {
            throw GitError(.rejected, "\(name) refused \(rejected.ref): \(rejected.status)")
        }
        try setLocalConfigValue(name, for: "branch.\(branch).remote")
        try setLocalConfigValue(local, for: "branch.\(branch).merge")
        let from = callbacks.negotiated.first { $0.ref == local }?.from
        return GitPushResult(remote: name, branch: branch, commit: commit, from: from, forced: lease != nil)
    }

    /// Adds each pattern not already there to `.git/info/exclude`, the
    /// repository's own ignore list, which is never committed or pushed.
    func addExcludes(_ patterns: [String]) throws {
        guard !patterns.contains(where: { $0.isEmpty || $0.contains("\n") || $0.utf8.contains(0) }) else {
            throw GitError(.invalid, "bad exclude pattern")
        }
        guard let path = git_repository_path(pointer) else { throw GitError(.notFound, "no git directory") }
        let info = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("info", isDirectory: true)
        if mkdir(info.path, 0o755) != 0, errno != EEXIST {
            throw GitError(.failed, "make .git/info: \(String(cString: strerror(errno)))")
        }
        let file = info.appendingPathComponent("exclude")
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let present = Set(text.split(separator: "\n").map(String.init))
        let missing = patterns.filter { !present.contains($0) }
        guard !missing.isEmpty else { return }
        if !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
        }
        text += missing.joined(separator: "\n") + "\n"
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            throw GitError(.failed, "write .git/info/exclude: \(error)")
        }
    }

    // MARK: Helpers

    /// Makes a bare repository at `url`, whose HEAD names `initialBranch`:
    /// the remote the tests fetch from and push to.
    internal static func createBare(at url: URL, initialBranch: String = "main") throws {
        GitLibrary.ensure()
        var options = git_repository_init_options()
        git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        options.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue | GIT_REPOSITORY_INIT_NO_REINIT.rawValue
            | GIT_REPOSITORY_INIT_BARE.rawValue
        var repository: OpaquePointer?
        let code = initialBranch.withCString { branch -> Int32 in
            options.initial_head = branch
            return git_repository_init_ext(&repository, url.path, &options)
        }
        try GitError.check(code, "create a bare repository at \(url.lastPathComponent)")
        git_repository_free(repository)
    }

    /// Makes the branch `name` at `commit`, for the tests: a branch beside
    /// the checked-out one.
    internal func createBranch(_ name: String, at commit: String) throws {
        try Self.checkBranchName(name)
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, commit), "read \(commit)")
        var target: OpaquePointer?
        try GitError.check(git_commit_lookup(&target, pointer, &oid), "read \(commit)")
        defer { git_commit_free(target) }
        var branch: OpaquePointer?
        try GitError.check(git_branch_create(&branch, pointer, name, target, 0), "make \(name)")
        git_reference_free(branch)
    }

    /// Adds the remote `name` fetching from `url` with git's default refspec.
    func addRemote(_ name: String, url: String) throws {
        guard !name.utf8.contains(0), !url.utf8.contains(0) else { throw GitError(.invalid, "bad remote") }
        var remote: OpaquePointer?
        try GitError.check(git_remote_create(&remote, pointer, name, url), "add the remote \(name)")
        git_remote_free(remote)
    }

    /// Removes the remote `name`, with its remote-tracking references.
    func removeRemote(_ name: String) throws {
        guard !name.utf8.contains(0) else { throw GitError(.invalid, "\(name.debugDescription) is not a remote name") }
        try GitError.check(git_remote_delete(pointer, name), "remove the remote \(name)")
    }

    /// The remote `name`. The caller frees it.
    internal func lookupRemote(_ name: String) throws -> OpaquePointer {
        var valid: Int32 = 0
        guard !name.utf8.contains(0), git_remote_name_is_valid(&valid, name) == 0, valid != 0 else {
            throw GitError(.invalid, "\(name.debugDescription) is not a remote name")
        }
        var remote: OpaquePointer?
        let code = git_remote_lookup(&remote, pointer, name)
        guard code == 0, let remote else {
            if code == GIT_ENOTFOUND.rawValue {
                throw GitError(.notFound, "no remote \(name)")
            }
            throw GitError.last(code, "read the remote \(name)")
        }
        return remote
    }

    /// Whether libgit2 takes `name` for a branch, and it cannot be read as
    /// an option.
    static func isValidBranchName(_ name: String) -> Bool {
        GitLibrary.ensure()
        var valid: Int32 = 0
        return !name.utf8.contains(0)
            && !name.hasPrefix("-")
            && git_branch_name_is_valid(&valid, name) == 0
            && valid != 0
    }

    /// A full commit ID as libgit2 writes one: 40 lowercase hexadecimal
    /// digits, or 64 in a SHA-256 repository.
    static func isCommitID(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64)
            && text.utf8.allSatisfy { (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }
    }

    internal static func checkBranchName(_ name: String) throws {
        guard isValidBranchName(name) else { throw GitError(.invalid, "\(name.debugDescription) is not a branch name") }
    }
}

/// One checkout over the work tree that overwrites nothing: `GIT_CHECKOUT_SAFE`
/// and no ignored file replaced either. libgit2 finds every conflict before
/// it writes, so a refused checkout leaves the folder as it was; the
/// conflicting paths are kept for the message, and the paths it wrote for a
/// caller that has to undo a checkout that failed part way.
final class CheckoutRecord {
    private(set) var conflicts: [String] = []
    private(set) var written: [String] = []

    func run(_ body: (inout git_checkout_options) -> Int32) -> Int32 {
        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED.rawValue
        options.notify_flags = GIT_CHECKOUT_NOTIFY_CONFLICT.rawValue
        let payload = Unmanaged.passUnretained(self).toOpaque()
        options.notify_payload = payload
        options.notify_cb = { _, path, _, _, _, payload in
            if let path, let payload {
                Unmanaged<CheckoutRecord>.fromOpaque(payload).takeUnretainedValue()
                    .conflicts.append(String(cString: path))
            }
            return 0
        }
        options.progress_payload = payload
        options.progress_cb = { path, _, _, payload in
            if let path, let payload {
                Unmanaged<CheckoutRecord>.fromOpaque(payload).takeUnretainedValue()
                    .written.append(String(cString: path))
            }
        }
        return withExtendedLifetime(self) { body(&options) }
    }

    func failure(_ code: Int32, _ what: String) -> GitError {
        guard code == GIT_ECONFLICT.rawValue || !conflicts.isEmpty else { return GitError.last(code, what) }
        let shown = conflicts.prefix(5).joined(separator: ", ")
        let more = conflicts.count > 5 ? " and \(conflicts.count - 5) more" : ""
        let paths = conflicts.isEmpty ? "" : ": \(shown)\(more)"
        return GitError(.conflict, "\(what) would overwrite what is in the folder\(paths)")
    }
}
