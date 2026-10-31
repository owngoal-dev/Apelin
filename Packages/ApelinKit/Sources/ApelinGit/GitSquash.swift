internal import GitKit
import Foundation

/// Where a squash starts: the commit it keeps as the parent, or how many
/// commits back from HEAD, along first parents.
public enum GitSquashBase: Sendable, Equatable {
    case commit(String)
    case count(Int)
}

/// What a squash of the checked-out branch combines: the commits after
/// `base` up to `head`, newest first, and how many of them the branch's
/// upstream already has as last fetched, which a squash would take off
/// what is published.
public struct GitSquashPlan: Sendable, Equatable {
    public var branch: String
    public var head: String
    public var base: String
    /// Newest first, at most as many as were asked for.
    public var commits: [GitLogEntry]
    public var count: Int
    /// `<remote>/<branch>` the branch tracks, when it has one fetched.
    public var upstream: String?
    /// How many of the commits the upstream has.
    public var published: Int
}

public struct GitSquashResult: Sendable, Equatable {
    public var plan: GitSquashPlan
    /// The one commit in their place, on `plan.base`, with `plan.head`'s tree.
    public var commit: String
}

/// Combining a run of commits into one (owner, 2026-10-31): on the
/// checked-out branch only, the work tree and the index left as they are,
/// nothing pushed, the old head kept in the branch's reflog.
public extension GitRepository {
    /// What a squash after `base` would combine, read without changing
    /// anything. Refuses what `squash` refuses: HEAD not on a branch with a
    /// commit, a base that is not an ancestor of HEAD, fewer than two
    /// commits after it, and a tracked change in the work tree or the index.
    func squashPlan(_ base: GitSquashBase, listing: Int = 50) throws -> GitSquashPlan {
        guard let branch = head().branch, let headID = head().commit else {
            throw GitError(.invalid, "HEAD is not on a branch with a commit: switch to the branch to squash")
        }
        var tip = git_oid()
        try GitError.check(git_oid_fromstr(&tip, headID), "read HEAD")
        var parent = try resolveBase(base, from: &tip)
        let baseID = Self.hex(&parent)
        if git_oid_equal(&parent, &tip) == 0, git_graph_descendant_of(pointer, &tip, &parent) != 1 {
            throw GitError(.conflict, "\(baseID) is not an ancestor of \(branch)'s \(headID): nothing was squashed")
        }

        var range: [git_oid] = []
        var walk: OpaquePointer?
        try GitError.check(git_revwalk_new(&walk, pointer), "walk the history")
        defer { git_revwalk_free(walk) }
        try GitError.check(git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue), "walk the history")
        try GitError.check(git_revwalk_push(walk, &tip), "walk \(branch)")
        try GitError.check(git_revwalk_hide(walk, &parent), "walk \(branch)")
        var next = git_oid()
        while git_revwalk_next(&next, walk) == 0 {
            range.append(next)
        }
        guard range.count >= 2 else {
            throw GitError(.conflict, "\(branch) has \(range.count == 0 ? "no commit" : "one commit") after \(baseID): a squash combines two or more, so nothing was squashed")
        }
        let changed = try status().filter { $0.index != "?" }
        guard changed.isEmpty else {
            let shown = changed.prefix(5).map(\.path).joined(separator: ", ")
            let more = changed.count > 5 ? " and \(changed.count - 5) more" : ""
            throw GitError(.conflict, "\(branch) has changes not committed (\(shown)\(more)): commit them or set them aside first; nothing was squashed")
        }
        var commits: [GitLogEntry] = []
        for var oid in range.prefix(listing) {
            try commits.append(summary(of: &oid))
        }
        let (upstream, published) = try publishedCount(branch: branch, base: &parent, range: range)
        return GitSquashPlan(
            branch: branch, head: headID, base: baseID, commits: commits, count: range.count,
            upstream: upstream, published: published,
        )
    }

    /// Replaces the commits after `base` on the checked-out branch with one
    /// commit on `base` whose tree is HEAD's, with `message` and `author`,
    /// as long as HEAD is still at `expectedHead`: else `headChanged` and
    /// nothing changes. The branch moves only from `expectedHead`, and its
    /// reflog keeps where it was. Both IDs are full ones.
    func squash(base: String, expectedHead: String, message: String, author: GitSignature) throws -> GitSquashResult {
        guard Self.isCommitID(base), Self.isCommitID(expectedHead) else {
            throw GitError(.invalid, "a squash names full commit IDs")
        }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw GitError(.invalid, "the commit message is empty") }
        guard !author.name.isEmpty, !author.email.isEmpty else {
            throw GitError(.invalid, "the author has no name or email")
        }
        if let current = head().commit, current != expectedHead {
            throw GitError(.headChanged, "\(head().branch ?? "HEAD") is at \(current) now, not \(expectedHead): nothing was squashed")
        }
        let plan = try squashPlan(.commit(base))

        var tip = git_oid()
        var parent = git_oid()
        try GitError.check(git_oid_fromstr(&tip, plan.head), "read HEAD")
        try GitError.check(git_oid_fromstr(&parent, plan.base), "read \(plan.base)")
        var headCommit: OpaquePointer?
        try GitError.check(git_commit_lookup(&headCommit, pointer, &tip), "read HEAD")
        defer { git_commit_free(headCommit) }
        var tree: OpaquePointer?
        try GitError.check(git_commit_tree(&tree, headCommit), "read HEAD's tree")
        defer { git_tree_free(tree) }
        var baseCommit: OpaquePointer?
        try GitError.check(git_commit_lookup(&baseCommit, pointer, &parent), "read \(plan.base)")
        defer { git_commit_free(baseCommit) }

        var signature: UnsafeMutablePointer<git_signature>?
        try GitError.check(git_signature_now(&signature, author.name, author.email), "make the signature")
        defer { git_signature_free(signature) }
        var commitID = git_oid()
        var parents: [OpaquePointer?] = [baseCommit]
        let code = parents.withUnsafeMutableBufferPointer { buffer in
            git_commit_create(&commitID, pointer, nil, signature, signature, nil, message + "\n", tree, 1, buffer.baseAddress)
        }
        try GitError.check(code, "commit")

        // From the head the plan read only: anything that moved it since
        // is refused here, and the reflog keeps the old head.
        var moved: OpaquePointer?
        defer { git_reference_free(moved) }
        let log = "squash: \(plan.count) commits after \(String(plan.base.prefix(7))) into one"
        let update = git_reference_create_matching(
            &moved, pointer, "refs/heads/" + plan.branch, &commitID, 1, &tip, log,
        )
        if update == GIT_EMODIFIED.rawValue {
            throw GitError(.headChanged, "\(plan.branch) moved while it was squashed: nothing was squashed")
        }
        try GitError.check(update, "move \(plan.branch)")
        return GitSquashResult(plan: plan, commit: Self.hex(&commitID))
    }

    /// The commit `base` names: a commit ID, whole or at least seven of its
    /// digits, or `count` commits back from `tip` along first parents.
    private func resolveBase(_ base: GitSquashBase, from tip: inout git_oid) throws -> git_oid {
        switch base {
        case let .commit(text):
            guard text.utf8.count >= 7, text.utf8.count <= 64,
                  text.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) })
            else {
                throw GitError(.invalid, "\(text.debugDescription) is not a commit ID: give at least seven of its digits")
            }
            var prefix = git_oid()
            try GitError.check(git_oid_fromstrn(&prefix, text, text.utf8.count), "read \(text)")
            var object: OpaquePointer?
            let code = git_object_lookup_prefix(&object, pointer, &prefix, text.utf8.count, GIT_OBJECT_COMMIT)
            guard code == 0, let object else {
                throw code == GIT_EAMBIGUOUS.rawValue
                    ? GitError(.invalid, "\(text) names more than one commit: give more of its digits")
                    : GitError(.notFound, "no commit \(text)")
            }
            defer { git_object_free(object) }
            return git_object_id(object).pointee
        case let .count(count):
            guard count >= 2 else {
                throw GitError(.conflict, "a squash combines two or more commits, not \(count): nothing was squashed")
            }
            var headCommit: OpaquePointer?
            try GitError.check(git_commit_lookup(&headCommit, pointer, &tip), "read HEAD")
            defer { git_commit_free(headCommit) }
            var ancestor: OpaquePointer?
            guard git_commit_nth_gen_ancestor(&ancestor, headCommit, UInt32(count)) == 0, let ancestor else {
                throw GitError(.conflict, "the branch has no commit \(count) back from HEAD: a squash keeps the commit before the ones it combines, so name fewer; nothing was squashed")
            }
            defer { git_commit_free(ancestor) }
            return git_commit_id(ancestor).pointee
        }
    }

    /// The branch's upstream and how many of `range` it has, as last
    /// fetched; nil and none when it has no upstream fetched.
    private func publishedCount(branch: String, base: inout git_oid, range: [git_oid]) throws -> (String?, Int) {
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        guard git_branch_upstream_name(&buffer, pointer, "refs/heads/" + branch) == 0, let name = buffer.ptr else {
            return (nil, 0)
        }
        let ref = String(cString: name)
        var upstream = git_oid()
        guard git_reference_name_to_id(&upstream, pointer, ref) == 0 else { return (nil, 0) }
        let shown = ref.hasPrefix("refs/remotes/") ? String(ref.dropFirst("refs/remotes/".count)) : ref
        var walk: OpaquePointer?
        try GitError.check(git_revwalk_new(&walk, pointer), "walk the history")
        defer { git_revwalk_free(walk) }
        try GitError.check(git_revwalk_push(walk, &upstream), "walk \(shown)")
        try GitError.check(git_revwalk_hide(walk, &base), "walk \(shown)")
        let wanted = Set(range.map { oid in withUnsafePointer(to: oid) { Self.hex($0) } })
        var published = 0
        var next = git_oid()
        while git_revwalk_next(&next, walk) == 0 {
            if wanted.contains(Self.hex(&next)) {
                published += 1
            }
        }
        return (shown, published)
    }
}
