internal import GitKit
import ApelinCore
import Darwin
import Foundation

/// Who a commit is by.
public struct GitSignature: Sendable, Equatable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

/// One changed path, with one-letter states spelled as
/// `git status --porcelain` spells them: `index` is HEAD against the index,
/// `worktree` the index against the work tree. An untracked file is `?` `?`.
public struct GitStatusItem: Sendable, Equatable {
    public var path: String
    public var index: String
    public var worktree: String

    public init(path: String, index: String, worktree: String) {
        self.path = path
        self.index = index
        self.worktree = worktree
    }
}

/// Where HEAD is.
public struct GitHead: Sendable, Equatable {
    /// The branch HEAD names, also when it has no commit yet; nil when detached.
    public var branch: String?
    /// The commit HEAD points at; nil on an unborn branch.
    public var commit: String?
}

/// A repository whose work tree is a folder Apelin already decided it may
/// touch. The caller resolves and checks that folder; this type only refuses
/// to search upwards from it, so a project without a repository of its own
/// never reaches one in a folder above.
///
/// Every path passed in is relative to the work tree, checked with
/// `CanonicalPath.isPlainRelative`, and taken literally — never as a glob.
public final class GitRepository: @unchecked Sendable {
    let pointer: OpaquePointer
    public let workdir: URL

    /// Opens the repository whose work tree is exactly `url`.
    public init(at url: URL) throws {
        GitLibrary.ensure()
        var repository: OpaquePointer?
        let flags = GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue
        try GitError.check(git_repository_open_ext(&repository, url.path, flags, nil), "open \(url.lastPathComponent)")
        guard let repository else { throw GitError(.notFound, "no repository at \(url.lastPathComponent)") }
        guard git_repository_is_bare(repository) == 0, let workdir = git_repository_workdir(repository) else {
            git_repository_free(repository)
            throw GitError(.invalid, "\(url.lastPathComponent) is a bare repository")
        }
        let opened = URL(fileURLWithPath: String(cString: workdir), isDirectory: true)
        guard CanonicalPath.resolve(opened.path) == CanonicalPath.resolve(url.path) else {
            git_repository_free(repository)
            throw GitError(.invalid, "\(url.lastPathComponent) is not the root of its repository")
        }
        pointer = repository
        self.workdir = url
    }

    /// Makes a new, empty repository with its work tree at `url`.
    public static func create(at url: URL, initialBranch: String = "main") throws -> GitRepository {
        GitLibrary.ensure()
        var options = git_repository_init_options()
        git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        options.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue | GIT_REPOSITORY_INIT_NO_REINIT.rawValue
        var repository: OpaquePointer?
        let code = initialBranch.withCString { branch -> Int32 in
            options.initial_head = branch
            return git_repository_init_ext(&repository, url.path, &options)
        }
        try GitError.check(code, "create a repository at \(url.lastPathComponent)")
        git_repository_free(repository)
        return try GitRepository(at: url)
    }

    deinit {
        git_repository_free(pointer)
    }

    // MARK: HEAD

    public func head() -> GitHead {
        var reference: OpaquePointer?
        let code = git_repository_head(&reference, pointer)
        defer { git_reference_free(reference) }
        if code == 0, let reference {
            let branch = git_reference_is_branch(reference) != 0
                ? String(cString: git_reference_shorthand(reference))
                : nil
            let commit = git_reference_target(reference).map { Self.hex($0) }
            return GitHead(branch: branch, commit: commit)
        }
        if code == GIT_EUNBORNBRANCH.rawValue {
            // HEAD names a branch with no commit yet: read the name off HEAD itself.
            var symbolic: OpaquePointer?
            defer { git_reference_free(symbolic) }
            if git_reference_lookup(&symbolic, pointer, "HEAD") == 0,
               let target = git_reference_symbolic_target(symbolic)
            {
                let name = String(cString: target)
                return GitHead(
                    branch: name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name,
                    commit: nil,
                )
            }
        }
        return GitHead(branch: nil, commit: nil)
    }

    // MARK: Status

    public func status() throws -> [GitStatusItem] {
        var options = git_status_options()
        git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_SORT_CASE_SENSITIVELY.rawValue
        var list: OpaquePointer?
        try GitError.check(git_status_list_new(&list, pointer, &options), "read the status")
        defer { git_status_list_free(list) }

        var items: [GitStatusItem] = []
        for position in 0 ..< git_status_list_entrycount(list) {
            guard let entry = git_status_byindex(list, position)?.pointee else { continue }
            let flags = entry.status.rawValue
            if flags & GIT_STATUS_IGNORED.rawValue != 0 {
                continue
            }
            let delta = entry.index_to_workdir ?? entry.head_to_index
            guard let delta, let path = delta.pointee.new_file.path ?? delta.pointee.old_file.path else { continue }
            items.append(GitStatusItem(
                path: String(cString: path),
                index: Self.indexLetter(flags),
                worktree: Self.worktreeLetter(flags),
            ))
        }
        return items
    }

    @objc private static dynamic func indexLetter(_ flags: UInt32) -> String {
        if flags & GIT_STATUS_CONFLICTED.rawValue != 0 {
            return "U"
        }
        if flags & GIT_STATUS_WT_NEW.rawValue != 0, flags & GIT_STATUS_INDEX_NEW.rawValue == 0 {
            return "?"
        }
        if flags & GIT_STATUS_INDEX_NEW.rawValue != 0 {
            return "A"
        }
        if flags & GIT_STATUS_INDEX_MODIFIED.rawValue != 0 {
            return "M"
        }
        if flags & GIT_STATUS_INDEX_DELETED.rawValue != 0 {
            return "D"
        }
        if flags & GIT_STATUS_INDEX_RENAMED.rawValue != 0 {
            return "R"
        }
        if flags & GIT_STATUS_INDEX_TYPECHANGE.rawValue != 0 {
            return "T"
        }
        return " "
    }

    @objc private static dynamic func worktreeLetter(_ flags: UInt32) -> String {
        if flags & GIT_STATUS_CONFLICTED.rawValue != 0 {
            return "U"
        }
        if flags & GIT_STATUS_WT_NEW.rawValue != 0 {
            return "?"
        }
        if flags & GIT_STATUS_WT_MODIFIED.rawValue != 0 {
            return "M"
        }
        if flags & GIT_STATUS_WT_DELETED.rawValue != 0 {
            return "D"
        }
        if flags & GIT_STATUS_WT_RENAMED.rawValue != 0 {
            return "R"
        }
        if flags & GIT_STATUS_WT_TYPECHANGE.rawValue != 0 {
            return "T"
        }
        return " "
    }

    // MARK: Diff

    /// A unified diff: the work tree against the index (untracked files
    /// included, with their content), or with `staged` the index against
    /// HEAD. `path` limits it to one path, matched literally. Longer than
    /// `limit` bytes, the text is cut and says so on its last line.
    @objc public dynamic func diff(path: String? = nil, staged: Bool = false, limit: Int = 8 << 20) throws -> String {
        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        options.flags = GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue
        if !staged {
            options.flags |= GIT_DIFF_INCLUDE_UNTRACKED.rawValue
                | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
                | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue
        }
        let paths = try path.map { try Self.checked([$0]) } ?? []
        var diff: OpaquePointer?
        try Self.withStrings(paths) { pathspec in
            options.pathspec = pathspec
            if staged {
                let tree = try headTree()
                defer { git_tree_free(tree) }
                try GitError.check(git_diff_tree_to_index(&diff, pointer, tree, nil, &options), "diff the index")
            } else {
                try GitError.check(git_diff_index_to_workdir(&diff, pointer, nil, &options), "diff the work tree")
            }
        }
        defer { git_diff_free(diff) }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try GitError.check(git_diff_to_buf(&buffer, diff, GIT_DIFF_FORMAT_PATCH), "format the diff")
        guard let bytes = buffer.ptr, buffer.size > 0 else { return "" }
        let count = min(buffer.size, limit)
        let text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
        return count < buffer.size ? text + "\n… diff cut at \(limit) bytes of \(buffer.size)\n" : text
    }

    // MARK: Stage and unstage

    /// Adds each path's work-tree state to the index: its content when the
    /// file is there, its removal when it is not.
    @objc public dynamic func stage(_ paths: [String]) throws {
        let paths = try Self.checked(paths)
        var index: OpaquePointer?
        try GitError.check(git_repository_index(&index, pointer), "open the index")
        defer { git_index_free(index) }
        for path in paths {
            var metadata = stat()
            if lstat(workdir.appendingPathComponent(path).path, &metadata) == 0 {
                try GitError.check(git_index_add_bypath(index, path), "stage \(path)")
            } else {
                try GitError.check(git_index_remove_bypath(index, path), "stage the removal of \(path)")
            }
        }
        try GitError.check(git_index_write(index), "write the index")
    }

    /// Stages every change in the work tree, as `git add --all` does: new
    /// and changed files no ignore rule names (`.gitignore`,
    /// `.git/info/exclude`), and the removal of deleted ones.
    @objc public dynamic func stageAll() throws {
        var index: OpaquePointer?
        try GitError.check(git_repository_index(&index, pointer), "open the index")
        defer { git_index_free(index) }
        try GitError.check(
            git_index_add_all(index, nil, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil),
            "stage every change",
        )
        try GitError.check(git_index_update_all(index, nil, nil, nil), "stage the removed files")
        try GitError.check(git_index_write(index), "write the index")
    }

    /// Whether the repository is as a new project's was made: HEAD on a
    /// branch with no commit, no reference, no remote and nothing staged.
    @objc public dynamic var isUntouched: Bool {
        guard git_repository_head_unborn(pointer) == 1 else { return false }
        var references = git_strarray()
        defer { git_strarray_dispose(&references) }
        guard git_reference_list(&references, pointer) == 0, references.count == 0 else { return false }
        var remotes = git_strarray()
        defer { git_strarray_dispose(&remotes) }
        guard git_remote_list(&remotes, pointer) == 0, remotes.count == 0 else { return false }
        var index: OpaquePointer?
        guard git_repository_index(&index, pointer) == 0 else { return false }
        defer { git_index_free(index) }
        return git_index_entrycount(index) == 0
    }

    /// Puts each path's index entry back to HEAD's (or drops it, before the
    /// first commit). The work tree is not touched.
    @objc public dynamic func unstage(_ paths: [String]) throws {
        let paths = try Self.checked(paths)
        let commit = try headCommit()
        defer { git_commit_free(commit) }
        try Self.withStrings(paths) { pathspec in
            var spec = pathspec
            try GitError.check(git_reset_default(pointer, commit, &spec), "unstage")
        }
    }

    // MARK: Commit

    /// Commits the index on HEAD's branch. Refuses an empty message and an
    /// index that matches HEAD.
    @discardableResult
    public func commit(message: String, author: GitSignature) throws -> String {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw GitError(.invalid, "the commit message is empty") }
        guard !author.name.isEmpty, !author.email.isEmpty else {
            throw GitError(.invalid, "the author has no name or email")
        }

        var index: OpaquePointer?
        try GitError.check(git_repository_index(&index, pointer), "open the index")
        defer { git_index_free(index) }
        var treeID = git_oid()
        try GitError.check(git_index_write_tree(&treeID, index), "write the tree")
        var tree: OpaquePointer?
        try GitError.check(git_tree_lookup(&tree, pointer, &treeID), "read the tree")
        defer { git_tree_free(tree) }

        let parent = try headCommit()
        defer { git_commit_free(parent) }
        if let parent, git_oid_equal(git_commit_tree_id(parent), &treeID) != 0 {
            throw GitError(.invalid, "nothing to commit: the index matches HEAD")
        }
        if parent == nil, git_index_entrycount(index) == 0 {
            throw GitError(.invalid, "nothing to commit: the index is empty")
        }

        var signature: UnsafeMutablePointer<git_signature>?
        try GitError.check(git_signature_now(&signature, author.name, author.email), "make the signature")
        defer { git_signature_free(signature) }

        var commitID = git_oid()
        var parents: [OpaquePointer?] = parent.map { [$0] } ?? []
        let code = parents.withUnsafeMutableBufferPointer { buffer in
            git_commit_create(
                &commitID,
                pointer,
                "HEAD",
                signature,
                signature,
                nil,
                message + "\n",
                tree,
                buffer.count,
                buffer.baseAddress,
            )
        }
        try GitError.check(code, "commit")
        return Self.hex(&commitID)
    }

    /// `user.name` and `user.email` from the repository's configuration
    /// (and the ones it inherits), when both are set.
    public func configuredSignature() -> GitSignature? {
        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&signature, pointer) == 0, let signature else { return nil }
        defer { git_signature_free(signature) }
        return GitSignature(
            name: String(cString: signature.pointee.name),
            email: String(cString: signature.pointee.email),
        )
    }

    /// The URL the remote `name` fetches from, or nil when there is no such
    /// remote.
    @objc public dynamic func remoteURL(_ name: String = "origin") -> String? {
        var remote: OpaquePointer?
        guard !name.utf8.contains(0), git_remote_lookup(&remote, pointer, name) == 0, let remote else { return nil }
        defer { git_remote_free(remote) }
        return git_remote_url(remote).map { String(cString: $0) }
    }

    /// The URL a push to the remote `name` goes to — its `pushurl`, else its
    /// URL, with `insteadOf` and `pushInsteadOf` applied as libgit2 applies
    /// them — or nil when there is no such remote.
    @objc public dynamic func remotePushURL(_ name: String = "origin") -> String? {
        var remote: OpaquePointer?
        guard !name.utf8.contains(0), git_remote_lookup(&remote, pointer, name) == 0, let remote else { return nil }
        defer { git_remote_free(remote) }
        return (git_remote_pushurl(remote) ?? git_remote_url(remote)).map { String(cString: $0) }
    }

    /// `key` from this repository's own `.git/config`, never one it
    /// inherits, or nil when it is not set there.
    @objc public dynamic func localConfigValue(_ key: String) -> String? {
        guard !key.utf8.contains(0), let local = try? localConfig() else { return nil }
        defer { git_config_free(local) }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        guard git_config_get_string_buf(&buffer, local, key) == 0, let value = buffer.ptr else { return nil }
        return String(cString: value)
    }

    /// Sets `key` in this repository's own `.git/config`.
    @objc public dynamic func setLocalConfigValue(_ value: String, for key: String) throws {
        guard !key.utf8.contains(0), !value.utf8.contains(0) else { throw GitError(.invalid, "bad configuration") }
        let local = try localConfig()
        defer { git_config_free(local) }
        try GitError.check(git_config_set_string(local, key, value), "set \(key)")
    }

    // MARK: Helpers

    /// The repository's local configuration level. The caller frees it.
    private func localConfig() throws -> OpaquePointer {
        var config: OpaquePointer?
        try GitError.check(git_repository_config(&config, pointer), "read the configuration")
        defer { git_config_free(config) }
        var local: OpaquePointer?
        try GitError.check(
            git_config_open_level(&local, config, GIT_CONFIG_LEVEL_LOCAL),
            "read the local configuration",
        )
        guard let local else { throw GitError(.notFound, "no local configuration") }
        return local
    }

    /// HEAD's commit, or nil on an unborn branch. The caller frees it.
    private func headCommit() throws -> OpaquePointer? {
        var reference: OpaquePointer?
        let code = git_repository_head(&reference, pointer)
        defer { git_reference_free(reference) }
        if code == GIT_EUNBORNBRANCH.rawValue || code == GIT_ENOTFOUND.rawValue {
            return nil
        }
        try GitError.check(code, "read HEAD")
        var object: OpaquePointer?
        try GitError.check(git_reference_peel(&object, reference, GIT_OBJECT_COMMIT), "read HEAD's commit")
        return object
    }

    /// HEAD's tree, or nil on an unborn branch. The caller frees it.
    private func headTree() throws -> OpaquePointer? {
        guard let commit = try headCommit() else { return nil }
        defer { git_commit_free(commit) }
        var tree: OpaquePointer?
        try GitError.check(git_commit_tree(&tree, commit), "read HEAD's tree")
        return tree
    }

    /// Refuses an absolute path, `..`, NUL, an empty path and anything inside
    /// `.git`; strips a leading `./`.
    @objc static dynamic func checked(_ paths: [String]) throws -> [String] {
        try paths.map { path in
            guard CanonicalPath.isPlainRelative(path) else {
                throw GitError(.invalid, "\(path.debugDescription) is not a path inside the project")
            }
            let components = CanonicalPath.components(path)
            guard !components.isEmpty, components.first != ".git" else {
                throw GitError(.invalid, "\(path.debugDescription) is not a path inside the work tree")
            }
            return components.joined(separator: "/")
        }
    }

    /// Hands libgit2 a `git_strarray` over copies of `strings`.
    static func withStrings<T>(_ strings: [String], _ body: (git_strarray) throws -> T) rethrows -> T {
        var copies = strings.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        return try copies.withUnsafeMutableBufferPointer { buffer in
            var array = git_strarray()
            array.strings = buffer.baseAddress
            array.count = buffer.count
            return try body(array)
        }
    }

    @objc static dynamic func hex(_ oid: UnsafePointer<git_oid>) -> String {
        var characters = [CChar](repeating: 0, count: Int(GIT_OID_MAX_HEXSIZE) + 1)
        git_oid_tostr(&characters, characters.count, oid)
        return String(cString: characters)
    }
}
