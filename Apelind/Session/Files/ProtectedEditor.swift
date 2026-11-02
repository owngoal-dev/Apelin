import ApelinCore
import ApelinProtocol
import CryptoKit
import Darwin
import Foundation

/// The app's manual protected edit: `protectedEditOpen` grants one save of
/// one file at one version, `protectedEditCommit` spends it. CallerPolicy
/// keeps every worker away from both; the agent has no way to make or spend
/// a grant.
actor ProtectedEditor {
    struct Grant {
        var target: ProtectedEditPolicy.Target
        var expires: Date
    }

    static let grantLifetime: TimeInterval = 15 * 60

    private let installRoot: String
    private let backups: BackupStore
    private var grants: [String: Grant] = [:]

    init(installRoot: String, backups: BackupStore) {
        self.installRoot = installRoot
        self.backups = backups
    }

    /// The grant, and a read-only descriptor of the contents it was made for.
    func open(_ request: ProtectedEditOpenRequest) throws -> (ProtectedEditOpenResponse, OwnedDescriptor) {
        let target = try ProtectedEditPolicy.evaluate(request.path, installRoot: installRoot)
        let descriptor = Darwin.open(target.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ApelinError(.internal, "\(target.path): \(String(cString: strerror(errno)))")
        }
        let owned = OwnedDescriptor(adopting: descriptor)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, UInt64(metadata.st_ino) == target.version.inode else {
            throw ApelinError(.conflict, "\(target.path) changed while it was opened; try again")
        }
        sweep()
        let id = UUID().uuidString.lowercased()
        grants[id] = Grant(target: target, expires: Date().addingTimeInterval(Self.grantLifetime))
        let response = ProtectedEditOpenResponse(
            grantID: id,
            expiresIn: Int(Self.grantLifetime),
            descriptor: DescriptorSlot(index: 0),
            path: target.path,
            version: target.version,
            needsConfirmation: target.needsConfirmation,
            backups: backups.list(for: target.path),
        )
        return (response, owned)
    }

    /// The grant's file, for `fileRead{grant:<id>}`; the grant stays.
    func grantedPath(_ id: String) throws -> String {
        sweep()
        guard let grant = grants[id] else { throw ApelinError(.notFound, "no grant \(id), or it expired") }
        return grant.target.path
    }

    func commit(
        _ request: ProtectedEditCommitRequest,
        descriptors: [OwnedDescriptor],
    ) throws -> ProtectedEditCommitResponse {
        sweep()
        // One save per grant, whatever happens next.
        guard let grant = grants.removeValue(forKey: request.grantID) else {
            throw ApelinError(.notFound, "no grant \(request.grantID), or it expired or was used; open the file again")
        }
        let target = grant.target
        guard request.expectedVersion.inode == target.version.inode,
              request.expectedVersion.device == target.version.device,
              request.expectedVersion.size == target.version.size,
              request.expectedVersion.sha256 == nil || request.expectedVersion.sha256 == target.version.sha256
        else {
            throw ApelinError(.conflict, "the version you edited is not the one this grant was made for")
        }
        if target.needsConfirmation, !request.confirmed {
            throw ApelinError(
                .denied,
                "\(target.path) is a LaunchDaemons plist: confirm the change (confirmed: true); it is saved only, never loaded",
            )
        }
        let contents = try Self.contents(of: request, descriptors: descriptors)

        // Still the file that was granted, byte for byte?
        let current = try ProtectedEditPolicy.evaluate(target.path, installRoot: installRoot)
        guard current.version.inode == target.version.inode, current.version.sha256 == target.version.sha256 else {
            throw ApelinError(.conflict, "\(target.path) changed after it was opened; open it again")
        }

        let backupID = try backups.save(path: target.path)
        let version = try AtomicReplace.replace(target.path, with: contents, expecting: current.version)
        return ProtectedEditCommitResponse(version: version, backupID: backupID)
    }

    private func sweep() {
        let now = Date()
        grants = grants.filter { $0.value.expires > now }
    }

    private static func contents(
        of request: ProtectedEditCommitRequest,
        descriptors: [OwnedDescriptor],
    ) throws -> Data {
        if let base64 = request.contentsBase64 {
            guard request.contents == nil else {
                throw ApelinError(.badRequest, "send the contents once: a descriptor or base64")
            }
            guard let data = Data(base64Encoded: base64) else {
                throw ApelinError(.badRequest, "contentsBase64 is not base64")
            }
            guard data.count <= ProtectedEditPolicy.maximumBytes else {
                throw ApelinError(.badRequest, "the new contents are too large")
            }
            return data
        }
        guard let slot = request.contents, descriptors.indices.contains(slot.index) else {
            throw ApelinError(.badRequest, "the new contents are missing")
        }
        let descriptor = descriptors[slot.index].rawValue
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var offset: off_t = 0
        var metadata = stat()
        let positional = fstat(descriptor, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                positional
                    ? pread(descriptor, bytes.baseAddress, bytes.count, offset)
                    : read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw ApelinError(.badRequest, "reading the new contents: \(String(cString: strerror(errno)))")
            }
            if count == 0 {
                break
            }
            data.append(contentsOf: buffer[0 ..< count])
            offset += off_t(count)
            guard data.count <= ProtectedEditPolicy.maximumBytes else {
                throw ApelinError(.badRequest, "the new contents are too large")
            }
        }
        return data
    }
}

/// `~/Documents/wiki.qaq.apelin/backups/`: the old contents of every file a
/// protected edit replaced, named by time and the canonical path, the newest
/// `keep` per file. The folder is mobile's, so the host writes as root into
/// a place mobile controls: every level is opened with `O_NOFOLLOW`, the
/// backup is a new file (`O_EXCL`), and it is handed to mobile, 0600.
struct BackupStore: Sendable {
    /// Mobile's home, canonical; its parent is root's.
    let home: String
    let owner: uid_t = 501
    let group: gid_t = 501
    let keep = 10
    /// Below `home`, each opened with `O_NOFOLLOW`.
    static let levels = ["Documents", DataFolder.bundleIdentifier, "backups"]

    init(home: String) {
        self.home = CanonicalPath.resolve(home) ?? home
    }

    var folder: String {
        ([home] + Self.levels).joined(separator: "/")
    }

    /// A backup's name: this time stamp, `-`, then the file's key.
    static let stampFormat = "yyyyMMdd-HHmmss-SSS"

    /// `/var/jb/etc/hosts` → `var_jb_etc_hosts-<sha8>`: the flattened stem
    /// alone is shared by `/etc/a_b` and `/etc/a/b`, so the path's SHA-256
    /// keeps one file's backups from being another's. Under a roothide root
    /// the key is made from `jbroot/` and the path below it, since the root's
    /// own name changes on a reboot and would leave every earlier backup
    /// unlisted and never pruned (issue #34).
    static func key(for path: String) -> String {
        if let below = BootstrapRootPath.belowRoot(path) {
            return key(components: ["jbroot"] + CanonicalPath.components(below).map(String.init))
        }
        return legacyKey(for: path)
    }

    /// The key before roothide's root was left out of it: the whole path.
    static func legacyKey(for path: String) -> String {
        key(components: CanonicalPath.components(path).map(String.init))
    }

    private static func key(components: [String]) -> String {
        let flattened = components.joined(separator: "_")
        let safe = flattened.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            let plain = (48 ... 57).contains(value) || (65 ... 90).contains(value) || (97 ... 122).contains(value)
                || value == 45 || value == 46 || value == 95
            return plain ? Character(scalar) : "_"
        }
        let digest = SHA256.hash(data: Data(("/" + components.joined(separator: "/")).utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        return String(String(safe).suffix(151)) + "-" + digest
    }

    /// Newest first: the file's backups under its key, and those an earlier
    /// version made under the whole path as it is spelt now.
    func list(for path: String) -> [String] {
        let keys: Set<Substring> = [Substring(Self.key(for: path)), Substring(Self.legacyKey(for: path))]
        let stamp = Self.stampFormat.count + 1
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.count > stamp && keys.contains($0.dropFirst(stamp)) }.sorted(by: >)
    }

    /// Copies the file's current contents into a new backup; answers its name.
    func save(path: String) throws -> String {
        let directory = try openFolder()
        defer { close(directory) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = Self.stampFormat
        let name = formatter.string(from: Date()) + "-" + Self.key(for: path)

        let source = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else {
            throw ApelinError(.internal, "backing up \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(source) }
        let destination = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else {
            throw ApelinError(.internal, "backing up \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(destination) }
        guard fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_DATA)) == 0, fsync(destination) == 0 else {
            unlinkat(directory, name, 0)
            throw ApelinError(.internal, "backing up \(path): \(String(cString: strerror(errno)))")
        }
        if geteuid() == 0 {
            _ = fchown(destination, owner, group)
        }
        _ = fchmod(destination, 0o600)
        prune(path: path, directory: directory)
        return name
    }

    private func prune(path: String, directory: Int32) {
        for stale in list(for: path).dropFirst(keep) {
            unlinkat(directory, stale, 0)
        }
    }

    /// Opens (making the last level if missing) the backups folder, one
    /// level at a time from mobile's home, never through a link: a
    /// `Documents` mobile swapped for a link cannot send a root-made file
    /// anywhere else.
    private func openFolder() throws -> Int32 {
        var parentDescriptor = open(home, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentDescriptor >= 0 else { throw ApelinError(.unavailable, "mobile's home \(home) is missing") }
        for level in Self.levels.dropLast() {
            let next = openat(parentDescriptor, level, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(parentDescriptor)
            guard next >= 0 else {
                throw ApelinError(.unavailable, "the data folder is missing or not a folder (\(level))")
            }
            parentDescriptor = next
        }
        defer { close(parentDescriptor) }
        let name = Self.levels.last!
        if mkdirat(parentDescriptor, name, 0o755) == 0 {
            if geteuid() == 0 {
                let made = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if made >= 0 {
                    _ = fchown(made, owner, group)
                    close(made)
                }
            }
        } else if errno != EEXIST {
            throw ApelinError(.internal, "making \(folder): \(String(cString: strerror(errno)))")
        }
        let descriptor = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ApelinError(.denied, "\(folder) is not a folder") }
        return descriptor
    }
}
