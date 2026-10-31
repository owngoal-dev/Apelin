internal import GitKit
import Darwin
import Foundation

/// A file of a commit's tree, read without checking anything out.
public extension GitRepository {
    /// The bytes of the regular file or link at `path` in `commit`'s tree,
    /// nil when the tree has none there; larger than `limit`, it throws.
    func fileContents(_ path: String, inCommit commit: String, limit: Int = 8 << 20) throws -> Data? {
        let path = try Self.checked([path])[0]
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, commit), "read \(commit)")
        var object: OpaquePointer?
        try GitError.check(git_commit_lookup(&object, pointer, &oid), "read \(commit)")
        defer { git_commit_free(object) }
        var tree: OpaquePointer?
        try GitError.check(git_commit_tree(&tree, object), "read \(commit)'s tree")
        defer { git_tree_free(tree) }
        var entry: OpaquePointer?
        let found = git_tree_entry_bypath(&entry, tree, path)
        if found == GIT_ENOTFOUND.rawValue {
            return nil
        }
        try GitError.check(found, "find \(path) in \(commit)")
        defer { git_tree_entry_free(entry) }
        guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return nil }
        var blob: OpaquePointer?
        try GitError.check(git_blob_lookup(&blob, pointer, git_tree_entry_id(entry)), "read \(path)")
        defer { git_blob_free(blob) }
        let size = Int(git_blob_rawsize(blob))
        guard size <= limit else { throw GitError(.invalid, "\(path) in \(commit) is larger than \(limit) bytes") }
        guard size > 0, let bytes = git_blob_rawcontent(blob) else { return Data() }
        return Data(bytes: bytes, count: size)
    }
}

/// Files already in a folder that a repository's own copies replace on a
/// clone-into (`GitClone.Replacement`): each set aside under a hidden name
/// beside it before the checkout, the bytes the caller settled on written
/// once the checkout is done, and put back as they were when the clone
/// fails.
final class ReplacementRecord {
    private var setAside: [(original: URL, moved: URL?)] = []
    private var settled: [(URL, Data)] = []

    /// Moves `path` aside (when it is there) and remembers what it is to hold
    /// once the checkout has written the repository's copy: `bytes`, or the
    /// repository's own when nil.
    func setAside(_ path: String, in directory: URL, settled bytes: Data?) throws {
        let original = directory.appendingPathComponent(path)
        var metadata = stat()
        var moved: URL?
        if lstat(original.path, &metadata) == 0 {
            let name = "." + original.lastPathComponent + ".apelin-replaced-" + UUID().uuidString
            let aside = original.deletingLastPathComponent().appendingPathComponent(name)
            guard rename(original.path, aside.path) == 0 else {
                throw GitError(.failed, "set \(path) aside: \(String(cString: strerror(errno)))")
            }
            moved = aside
        }
        setAside.append((original, moved))
        if let bytes {
            settled.append((original, bytes))
        }
    }

    /// After the checkout: the settled bytes over the repository's, and the
    /// set-aside files gone.
    func finish() throws {
        for (url, bytes) in settled {
            do {
                try bytes.write(to: url, options: .atomic)
            } catch {
                throw GitError(.failed, "write \(url.lastPathComponent): \(error)")
            }
        }
        for (_, moved) in setAside {
            if let moved {
                unlink(moved.path)
            }
        }
        setAside = []
    }

    /// After a failure, once what the checkout wrote is gone: each file back
    /// where it was.
    func restore() {
        for (original, moved) in setAside.reversed() {
            if let moved {
                unlink(original.path)
                rename(moved.path, original.path)
            }
        }
        setAside = []
    }
}
