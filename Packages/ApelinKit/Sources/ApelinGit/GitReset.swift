internal import GitKit
import Darwin
import Foundation

/// One commit, as a list names it.
public struct GitCommitLine: Sendable, Equatable {
    public var commit: String
    /// Its message's first line.
    public var subject: String
}

/// What making the branch `branch` exactly the remote's would change, read
/// after a fetch (`fetchBranch`) and before anything is touched.
public struct GitResetPlan: Sendable, Equatable {
    public var remote: String
    public var branch: String
    /// Where `<remote>/<branch>` is.
    public var remoteCommit: String
    public var remoteSubject: String?
    /// HEAD's commit; nil when it has none yet.
    public var head: String?
    /// The branch HEAD is on; nil when it is detached.
    public var currentBranch: String?
    /// HEAD and the remote's branch share no commit: the project's history
    /// and the remote's are two different ones.
    public var unrelatedHistories: Bool
    /// The commits that leave the branch — HEAD's, when HEAD is on `branch`
    /// or detached — newest first: every one, of which `lostCommits` has the
    /// first few.
    public var lostCommitCount: Int
    public var lostCommits: [GitCommitLine]
    /// Every tracked file whose index or work tree differs from HEAD.
    public var changedFiles: [GitStatusItem]
    /// Every file not in the index — untracked or ignored — that the
    /// remote's tree replaces, or that is in the way of a folder it has.
    public var overwrittenFiles: [String]
    /// HEAD is on `branch` at the remote's commit and nothing differs.
    public var upToDate: Bool
}

/// What a reset did.
public struct GitResetResult: Sendable, Equatable {
    public var branch: String
    public var commit: String
    /// Where HEAD was; nil when it had no commit.
    public var previousHead: String?
    /// The branch keeping what was there before; nil when there was nothing
    /// to keep.
    public var backupBranch: String?
}

/// "Remote wins" (issue #32): a branch and the work tree made exactly what
/// a remote's branch holds, as `git checkout -f -B <branch>
/// <remote>/<branch>` makes them, after everything it would lose is saved
/// on a branch of its own. Commits only on the old branch leave it, changes
/// to tracked files are replaced and the index matches; untracked and
/// ignored files the remote does not have are left alone, and one it has is
/// replaced. It works as well when the project's history and the remote's
/// have nothing in common.
public extension GitRepository {
    /// Fetches the remote's `branch` — nil: every branch, then the one its
    /// HEAD names — into `refs/remotes/<remote>/<branch>`, whatever refspecs
    /// the remote is configured with. Answers the branch.
    func fetchBranch(
        remote name: String,
        branch: String?,
        credentials: GitCredentialLookup? = nil,
        progress: @escaping (GitCloneProgress) -> Bool = { _ in true },
    ) throws -> String {
        if let branch {
            try Self.checkBranchName(branch)
        }
        let remote = try lookupRemote(name)
        defer { git_remote_free(remote) }
        let callbacks = RemoteCallbacks(credentials: credentials)
        callbacks.fetchProgress = progress
        var options = git_fetch_options()
        git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
        callbacks.install(&options.callbacks)
        let refspec = branch.map { "+refs/heads/\($0):refs/remotes/\(name)/\($0)" } ?? "+refs/heads/*:refs/remotes/\(name)/*"
        let code = withExtendedLifetime(callbacks) {
            Self.withStrings([refspec]) { refspecs in
                var refspecs = refspecs
                return git_remote_fetch(remote, &refspecs, &options, nil)
            }
        }
        guard code == 0 else { throw callbacks.failure(code, "fetch \(name)") }
        if let branch {
            return branch
        }
        // The list the fetch read stays readable after it disconnected.
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        guard git_remote_default_branch(&buffer, remote) == 0, let reference = buffer.ptr.map({ String(cString: $0) }),
              reference.hasPrefix("refs/heads/")
        else {
            throw GitError(.notFound, "\(name) names no default branch: name the branch")
        }
        let found = String(reference.dropFirst("refs/heads/".count))
        try Self.checkBranchName(found)
        return found
    }

    /// What `reset` would change, from what the last fetch left in
    /// `refs/remotes/<remote>/<branch>`. A local `branch` that is not the
    /// checked-out one and has commits the remote's does not throws
    /// `conflict`: they would leave every branch, and the backup keeps HEAD.
    func resetPlan(remote: String, branch: String) throws -> GitResetPlan {
        try Self.checkBranchName(branch)
        var target = git_oid()
        guard git_reference_name_to_id(&target, pointer, "refs/remotes/\(remote)/\(branch)") == 0 else {
            throw GitError(.notFound, "\(remote) has no branch \(branch)")
        }
        let remoteCommit = Self.hex(&target)
        let current = head()
        let onBranch = current.branch == branch
        var local = git_oid()
        if !onBranch, git_reference_name_to_id(&local, pointer, "refs/heads/\(branch)") == 0,
           git_oid_equal(&local, &target) == 0, git_graph_descendant_of(pointer, &target, &local) != 1
        {
            throw GitError(
                .conflict,
                "the branch \(branch) is not the one checked out (\(current.branch ?? "HEAD is detached")) and has commits \(remote)/\(branch) does not: they would be lost",
            )
        }

        var unrelated = false
        var lost: (count: Int, shown: [GitCommitLine]) = (0, [])
        if let commit = current.commit, commit != remoteCommit {
            var headID = git_oid()
            try GitError.check(git_oid_fromstr(&headID, commit), "read HEAD")
            var base = git_oid()
            let related = git_merge_base(&base, pointer, &headID, &target) == 0
            unrelated = !related
            if onBranch || current.branch == nil {
                lost = try commits(from: &headID, hiding: related ? remoteCommit : nil)
            }
        }
        let changed = try status().filter { !($0.index == "?" && $0.worktree == "?") }
        let overwritten = try untrackedFilesReplaced(by: &target)
        return GitResetPlan(
            remote: remote,
            branch: branch,
            remoteCommit: remoteCommit,
            remoteSubject: try? subject(of: &target),
            head: current.commit,
            currentBranch: current.branch,
            unrelatedHistories: unrelated,
            lostCommitCount: lost.count,
            lostCommits: lost.shown,
            changedFiles: changed,
            overwrittenFiles: overwritten,
            upToDate: onBranch && current.commit == remoteCommit && changed.isEmpty && overwritten.isEmpty,
        )
    }

    /// Makes `branch` the remote's, as the plan says, once the remote's
    /// commit is still `expectedRemoteCommit` and HEAD still
    /// `expectedHead` (nil: no commit), else throws `conflict` and changes
    /// nothing: the state moved since the user was shown it. What it would
    /// lose goes first onto a new branch `apelin-backup/<yyyyMMdd-HHmmss>`:
    /// HEAD's commit, with, when anything is uncommitted or replaced, a
    /// commit on top of it holding the work tree's tracked files and the
    /// files the remote's replace. Then the remote's tree is checked out
    /// over the work tree, `branch` made the remote's commit, HEAD put on
    /// it, the index matched to it and its upstream recorded.
    ///
    /// `settled` is written over the result afterwards, for the files the
    /// caller keeps its own way (the project's identity), and `excluding`
    /// goes into `.git/info/exclude`.
    func reset(
        toRemote remote: String,
        branch: String,
        expectedRemoteCommit: String,
        expectedHead: String?,
        backupAuthor: GitSignature,
        now: Date = Date(),
        settled: [String: Data] = [:],
        excluding patterns: [String] = [],
    ) throws -> GitResetResult {
        let plan = try resetPlan(remote: remote, branch: branch)
        guard plan.remoteCommit == expectedRemoteCommit else {
            throw GitError(
                .conflict,
                "\(remote)/\(branch) is at \(plan.remoteCommit.prefix(7)) now, not \(expectedRemoteCommit.prefix(7)) as shown: it moved, and nothing was changed",
            )
        }
        guard plan.head == expectedHead else {
            throw GitError(
                .conflict,
                "HEAD is at \(plan.head.map { String($0.prefix(7)) } ?? "no commit") now, not \(expectedHead.map { String($0.prefix(7)) } ?? "no commit") as shown: it moved, and nothing was changed",
            )
        }
        let saved = try backupCommit(plan, author: backupAuthor)
        let backupBranch = try saved.map { try makeBackupBranch($0, now: now) }

        var target = git_oid()
        try GitError.check(git_oid_fromstr(&target, plan.remoteCommit), "read \(remote)/\(branch)")
        var commit: OpaquePointer?
        try GitError.check(git_commit_lookup(&commit, pointer, &target), "read \(remote)/\(branch)'s commit")
        defer { git_commit_free(commit) }
        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        let kept = backupBranch.map { " (what was there is on \($0))" } ?? ""
        try GitError.check(git_checkout_tree(pointer, commit, &options), "check out \(remote)/\(branch)\(kept)")

        var moved: OpaquePointer?
        try GitError.check(
            git_reference_create(&moved, pointer, "refs/heads/\(branch)", &target, 1, "reset: moving to \(remote)/\(branch)"),
            "move \(branch)\(kept)",
        )
        git_reference_free(moved)
        try GitError.check(git_repository_set_head(pointer, "refs/heads/\(branch)"), "point HEAD at \(branch)\(kept)")
        var tree: OpaquePointer?
        try GitError.check(git_commit_tree(&tree, commit), "read \(remote)/\(branch)'s tree")
        defer { git_tree_free(tree) }
        var index: OpaquePointer?
        try GitError.check(git_repository_index(&index, pointer), "open the index")
        defer { git_index_free(index) }
        try GitError.check(git_index_read_tree(index, tree), "match the index\(kept)")
        try GitError.check(git_index_write(index), "write the index\(kept)")
        git_repository_state_cleanup(pointer)
        try setLocalConfigValue(remote, for: "branch.\(branch).remote")
        try setLocalConfigValue("refs/heads/\(branch)", for: "branch.\(branch).merge")
        try addExcludes(patterns)
        for (path, bytes) in settled.sorted(by: { $0.key < $1.key }) {
            let file = try workdir.appendingPathComponent(Self.checked([path])[0])
            guard FileManager.default.contents(atPath: file.path) != bytes else { continue }
            do {
                try bytes.write(to: file, options: .atomic)
            } catch {
                throw GitError(.failed, "write \(path)\(kept): \(error)")
            }
        }
        return GitResetResult(branch: branch, commit: plan.remoteCommit, previousHead: plan.head, backupBranch: backupBranch)
    }

    // MARK: Helpers

    /// The commits reachable from `start` and not from `hidden`, newest
    /// first: all of them counted, the first few listed.
    private func commits(from start: inout git_oid, hiding hidden: String?, shown limit: Int = 10) throws -> (count: Int, shown: [GitCommitLine]) {
        var walk: OpaquePointer?
        try GitError.check(git_revwalk_new(&walk, pointer), "walk the history")
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
        try GitError.check(git_revwalk_push(walk, &start), "walk the history")
        if let hidden {
            var oid = git_oid()
            try GitError.check(git_oid_fromstr(&oid, hidden), "walk the history")
            try GitError.check(git_revwalk_hide(walk, &oid), "walk the history")
        }
        var count = 0
        var shown: [GitCommitLine] = []
        var next = git_oid()
        while git_revwalk_next(&next, walk) == 0 {
            count += 1
            if shown.count < limit {
                shown.append(GitCommitLine(commit: Self.hex(&next), subject: (try? subject(of: &next)) ?? ""))
            }
        }
        return (count, shown)
    }

    private func subject(of oid: inout git_oid) throws -> String {
        var commit: OpaquePointer?
        try GitError.check(git_commit_lookup(&commit, pointer, &oid), "read a commit")
        defer { git_commit_free(commit) }
        return git_commit_summary(commit).map { String(cString: $0) } ?? ""
    }

    /// The files not in the index that a checkout of `commit`'s tree
    /// replaces: one at a path the tree has a file at (every file in a
    /// folder there), and one where the tree has a folder.
    private func untrackedFilesReplaced(by commit: inout git_oid) throws -> [String] {
        var index: OpaquePointer?
        try GitError.check(git_repository_index(&index, pointer), "open the index")
        defer { git_index_free(index) }
        var tracked: Set<String> = []
        for position in 0 ..< git_index_entrycount(index) {
            if let entry = git_index_get_byindex(index, position) {
                tracked.insert(String(cString: entry.pointee.path))
            }
        }
        var replaced: Set<String> = []
        for path in try treeFiles(of: &commit) where !tracked.contains(path) {
            var folder = ""
            for component in path.split(separator: "/").dropLast() {
                folder = folder.isEmpty ? String(component) : folder + "/" + component
                var metadata = stat()
                if !tracked.contains(folder), lstat(workdir.appendingPathComponent(folder).path, &metadata) == 0,
                   metadata.st_mode & S_IFMT != S_IFDIR
                {
                    replaced.insert(folder)
                }
            }
            var metadata = stat()
            guard lstat(workdir.appendingPathComponent(path).path, &metadata) == 0 else { continue }
            if metadata.st_mode & S_IFMT == S_IFDIR {
                replaced.formUnion(untrackedFiles(under: path, tracked: tracked))
            } else {
                replaced.insert(path)
            }
        }
        return replaced.sorted()
    }

    /// The path of every file and link in `commit`'s tree.
    private func treeFiles(of commit: inout git_oid) throws -> [String] {
        var object: OpaquePointer?
        try GitError.check(git_commit_lookup(&object, pointer, &commit), "read a commit")
        defer { git_commit_free(object) }
        var tree: OpaquePointer?
        try GitError.check(git_commit_tree(&tree, object), "read a commit's tree")
        defer { git_tree_free(tree) }
        let paths = TreePaths()
        let code = withExtendedLifetime(paths) {
            git_tree_walk(tree, GIT_TREEWALK_PRE, { root, entry, payload in
                guard let root, let entry, let payload, git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return 0 }
                Unmanaged<TreePaths>.fromOpaque(payload).takeUnretainedValue().all
                    .append(String(cString: root) + String(cString: git_tree_entry_name(entry)))
                return 0
            }, Unmanaged.passUnretained(paths).toOpaque())
        }
        try GitError.check(code, "read a commit's tree")
        return paths.all
    }

    /// Every file and link below the folder `path` that is not in the index,
    /// without following a link.
    private func untrackedFiles(under path: String, tracked: Set<String>) -> [String] {
        guard let walk = FileManager.default.enumerator(atPath: workdir.appendingPathComponent(path).path) else { return [] }
        var files: [String] = []
        while let relative = walk.nextObject() as? String {
            let type = walk.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                if (relative as NSString).lastPathComponent.lowercased() == ".git" {
                    walk.skipDescendants()
                }
                continue
            }
            let full = path + "/" + relative
            if !tracked.contains(full) {
                files.append(full)
            }
        }
        return files
    }

    /// The commit the backup branch points at: HEAD's when nothing is
    /// uncommitted or replaced, else a commit on top of it of the work
    /// tree's tracked files and the files the reset replaces; nil when there
    /// is nothing at all to keep.
    private func backupCommit(_ plan: GitResetPlan, author: GitSignature) throws -> String? {
        guard !plan.changedFiles.isEmpty || !plan.overwrittenFiles.isEmpty else { return plan.head }
        var current: OpaquePointer?
        try GitError.check(git_repository_index(&current, pointer), "open the index")
        defer { git_index_free(current) }
        var saved: OpaquePointer?
        try GitError.check(git_index_new(&saved), "make the backup's index")
        defer { git_index_free(saved) }
        let fromWorkTree = Set(plan.changedFiles.map(\.path)).union(plan.overwrittenFiles)
        for position in 0 ..< git_index_entrycount(current) {
            guard var entry = git_index_get_byindex(current, position)?.pointee,
                  !fromWorkTree.contains(String(cString: entry.path)),
                  (entry.flags & UInt16(GIT_INDEX_ENTRY_STAGEMASK)) == 0
            else { continue }
            try GitError.check(git_index_add(saved, &entry), "save the index")
        }
        for path in fromWorkTree.sorted() {
            try addWorkTreeFile(path, to: saved)
        }
        var treeID = git_oid()
        try GitError.check(git_index_write_tree_to(&treeID, saved, pointer), "save the work tree")
        var tree: OpaquePointer?
        try GitError.check(git_tree_lookup(&tree, pointer, &treeID), "save the work tree")
        defer { git_tree_free(tree) }

        var parent: OpaquePointer?
        if let head = plan.head {
            var headID = git_oid()
            try GitError.check(git_oid_fromstr(&headID, head), "read HEAD")
            try GitError.check(git_commit_lookup(&parent, pointer, &headID), "read HEAD's commit")
        }
        defer { git_commit_free(parent) }
        var signature: UnsafeMutablePointer<git_signature>?
        try GitError.check(git_signature_now(&signature, author.name, author.email), "make the signature")
        defer { git_signature_free(signature) }
        let message = "Saved by Apelin before resetting to \(plan.remote)/\(plan.branch)\n\nThe uncommitted changes and the files the reset replaced, on top of the commit HEAD was at.\n"
        var commitID = git_oid()
        var parents: [OpaquePointer?] = parent.map { [$0] } ?? []
        let code = parents.withUnsafeMutableBufferPointer { buffer in
            git_commit_create(&commitID, pointer, nil, signature, signature, nil, message, tree, buffer.count, buffer.baseAddress)
        }
        try GitError.check(code, "save the work tree")
        return Self.hex(&commitID)
    }

    /// Adds the work tree's file or link at `path` to `index`; one that is
    /// gone, or a folder now, is not.
    private func addWorkTreeFile(_ path: String, to index: OpaquePointer?) throws {
        var metadata = stat()
        guard lstat(workdir.appendingPathComponent(path).path, &metadata) == 0 else { return }
        let kind = metadata.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFLNK else { return }
        var blob = git_oid()
        try GitError.check(git_blob_create_from_workdir(&blob, pointer, path), "save \(path)")
        var entry = git_index_entry()
        entry.mode = kind == S_IFLNK ? 0o120000 : (metadata.st_mode & 0o111 != 0 ? 0o100755 : 0o100644)
        entry.id = blob
        entry.file_size = UInt32(truncatingIfNeeded: metadata.st_size)
        try path.withCString { name in
            entry.path = name
            try GitError.check(git_index_add(index, &entry), "save \(path)")
        }
    }

    /// `refs/heads/apelin-backup/<yyyyMMdd-HHmmss>` at `commit`, a number
    /// after it when that is taken. Answers the branch's name.
    private func makeBackupBranch(_ commit: String, now: Date) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = "apelin-backup/" + formatter.string(from: now)
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, commit), "read the backup")
        for attempt in 1 ... 100 {
            let name = attempt == 1 ? stamp : "\(stamp)-\(attempt)"
            var reference: OpaquePointer?
            let code = git_reference_create(&reference, pointer, "refs/heads/" + name, &oid, 0, "reset: saved before it")
            git_reference_free(reference)
            if code == 0 {
                return name
            }
            guard code == GIT_EEXISTS.rawValue else { throw GitError.last(code, "make the backup branch") }
        }
        throw GitError(.conflict, "no free name for the backup branch \(stamp)")
    }
}

/// The paths a tree walk collects.
private final class TreePaths {
    var all: [String] = []
}
