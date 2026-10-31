import ApelinProtocol
import Darwin
import Foundation

/// A project's `apelin-project.json`, opened through its folder without
/// following a link and replaced relative to that folder: a temporary file
/// beside it with its mode and owner, synced, then renamed over it only
/// while the manifest is still the file that was read, byte for byte. A
/// rename (`ProjectMetadata`) and a build's formatting
/// (`ProjectManifestFormat.formatFile`) write it this way; the formatting,
/// which nobody asked for, only where the owner is kept too.
final class ProjectManifestFile {
    /// Held from reading a manifest to replacing it, so the writers in one
    /// process never refuse each other; another process's edit is caught
    /// by `replace(with:)` reading the file again.
    static let lock = NSLock()

    /// The manifest as it was read.
    let original: Data
    private let directory: Int32
    private let handle: FileHandle
    private let identity: stat

    /// The manifest of the project folder at the canonical path `root`.
    init(root: String) throws {
        let directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ApelinError(.notFound, "The project folder is no longer available.") }
        var kept = false
        defer {
            if !kept {
                close(directory)
            }
        }
        let descriptor = openat(directory, ProjectStore.projectFileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ELOOP
                ? ApelinError(.badRequest, "The project manifest is not a regular supported file.")
                : ApelinError(.notFound, "The project has no manifest.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var identity = stat()
        guard fstat(descriptor, &identity) == 0, identity.st_mode & S_IFMT == S_IFREG,
              identity.st_size <= 8 * 1024 * 1024
        else {
            throw ApelinError(.badRequest, "The project manifest is not a regular supported file.")
        }
        original = try handle.readToEnd() ?? Data()
        self.directory = directory
        self.handle = handle
        self.identity = identity
        kept = true
    }

    deinit {
        close(directory)
    }

    /// Puts `data` in the manifest's place, its mode kept, and its owner and
    /// group where this process may set them; with `ownerRequired`, a
    /// manifest whose owner or group could not be kept is not replaced
    /// (`denied`). False, with nothing changed, when the manifest was
    /// replaced or edited since it was read.
    func replace(with data: Data, ownerRequired: Bool) throws -> Bool {
        let mode = identity.st_mode & 0o777
        let temporary = ".apelin-metadata-" + UUID().uuidString
        let output = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard output >= 0 else { throw POSIXError(.EIO) }
        defer { close(output); unlinkat(directory, temporary, 0) }
        var created = stat()
        guard fstat(output, &created) == 0 else { throw POSIXError(.EIO) }
        if created.st_uid != identity.st_uid || created.st_gid != identity.st_gid,
           fchown(output, identity.st_uid, identity.st_gid) != 0, ownerRequired
        {
            throw ApelinError(.denied, "The project manifest's owner could not be kept.")
        }
        guard fchmod(output, mode) == 0 else { throw POSIXError(.EIO) }
        try FileHandle(fileDescriptor: output, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(output) == 0 else { throw POSIXError(.EIO) }
        var latest = stat()
        try handle.seek(toOffset: 0)
        guard fstatat(directory, ProjectStore.projectFileName, &latest, AT_SYMLINK_NOFOLLOW) == 0,
              latest.st_dev == identity.st_dev, latest.st_ino == identity.st_ino,
              try handle.readToEnd() == original
        else {
            return false
        }
        guard renameat(directory, temporary, directory, ProjectStore.projectFileName) == 0 else {
            throw POSIXError(.EIO)
        }
        _ = fsync(directory)
        return true
    }
}
