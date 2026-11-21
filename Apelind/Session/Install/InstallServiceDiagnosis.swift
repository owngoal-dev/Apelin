import Darwin
import Foundation
import XPC

/// Why irisind did not answer the bridge's handshake, as far as root on this
/// device can tell, most basic first: a fix for an earlier one may clear the
/// ones after it.
enum InstallServiceProblem: Equatable, Sendable {
    /// The package database lists no Irisin, or one removed.
    case notInstalled
    /// dpkg's state for Irisin is one an install stops in: `half-installed`,
    /// `unpacked` or `half-configured`.
    case unfinished(state: String)
    case tooOld(version: String)
    /// irisind or its launchd job is not on the device.
    case missing(path: String)
    /// launchd has no such service: irisind's job is not loaded.
    case notLoaded
    /// launchd took the handshake and nothing answered it.
    case noAnswer
    /// irisind's admission rule refuses this folder, or this executable.
    case untrustedFolder(path: String, owner: uid_t, mode: mode_t)
    case untrustedExecutable(path: String, owner: uid_t, mode: mode_t)
    /// This executable lacks an entitlement irisind requires.
    case missingEntitlement(String)
    /// Every connection was closed, and nothing here says why.
    case refused
    /// Not even the package database could be read.
    case unknown

    /// The sentence the install or setup fails with.
    var message: String {
        let minimum = InstallServiceRequirement.minimumIrisin
        switch self {
        case .notInstalled:
            return "Irisin is not installed. Install Irisin \(minimum) or later, then try again."
        case .unfinished:
            return "Irisin was not completely installed. Reinstall Irisin, then try again."
        case let .tooOld(version):
            return "Irisin \(version) is installed, but Apelin requires Irisin \(minimum) or later. Update Irisin, then try again."
        case let .missing(path):
            return "Irisin's background service is missing \(path). Reinstall Irisin, then try again."
        case .notLoaded:
            return "Irisin's background service is not loaded. Reinstall Irisin, or restart your device and jailbreak it again, then try again."
        case .noAnswer:
            return "Irisin's background service is not responding. Restart your device and jailbreak it again, then try again."
        case let .untrustedFolder(path, owner, mode):
            let permissions = String(mode, radix: 8)
            return "Irisin rejected Apelin's background service because the folder \(path) has unsafe permissions (owner \(owner), permissions \(permissions)). Set its owner to root and its permissions to 755, then try again."
        case let .untrustedExecutable(path, owner, mode):
            let permissions = String(mode, radix: 8)
            return "Irisin rejected Apelin's background service because \(path) has invalid permissions (owner \(owner), permissions \(permissions)). Reinstall Apelin, then try again."
        case let .missingEntitlement(name):
            return "Irisin rejected Apelin's background service because it is missing the \(name) entitlement. Reinstall Apelin, then try again."
        case .refused:
            return "Irisin closed the connection from Apelin's background service. Restart your device and jailbreak it again, then try again."
        case .unknown:
            return "Irisin is not responding. Make sure Irisin \(minimum) or later is installed, then try again."
        }
    }
}

/// What the session host, as root, can find out on its own when irisind
/// does not answer, so the failure names its cause. Nothing here asks
/// irisind, runs a package manager or changes anything: the package
/// database read from its file, a few `lstat`s, this process's own
/// entitlements and, after a failed transaction, the database's locks.
///
/// irisind says nothing to a program it refuses (Irisin's
/// `Documentation/ExternalClients.md` ▸ Transport): it cancels the
/// connection, and every request then fails as interrupted, just as for a
/// daemon that went away. "No such service" is launchd's answer while
/// irisind's job is not loaded. A refusal is told apart by running irisind's
/// admission rule here, on this executable (Irisin's `PeerAuthenticator` and
/// `ExecutableAdmission`), so it names the folder or file it would refuse.
struct InstallServiceDiagnosis: Sendable {
    /// Canonical, as this process found it from its own path.
    let installRoot: String
    /// This process's executable, canonical.
    var ownExecutable: @Sendable () -> String?
    /// Whether this process carries `name`, strictly `true`.
    var hasEntitlement: @Sendable (String) -> Bool
    /// Who irisind trusts to own the executable: root on a device. A
    /// folder may also be owned by a system account below 500.
    var trustedOwners: Set<uid_t> = [0]

    /// This process, as irisind sees it.
    static func live(installRoot: String) -> InstallServiceDiagnosis {
        InstallServiceDiagnosis(
            installRoot: installRoot,
            ownExecutable: { executablePath(pid: getpid()) },
            hasEntitlement: { ownEntitlement($0) },
        )
    }

    /// The cause of a handshake that failed with `failure` through the
    /// whole grace.
    func problem(after failure: InstallServiceError.Code, packages: InstalledPackageSource) -> InstallServiceProblem {
        let database = try? packages.installedPackages()
        if let database {
            let irisin = database[InstallServiceRequirement.irisinPackage]
            let state = irisin.flatMap { $0.status.split(separator: " ").last.map(String.init) } ?? "not-installed"
            switch state {
            case "not-installed", "config-files":
                return .notInstalled
            case "half-installed", "unpacked", "half-configured":
                return .unfinished(state: state)
            default:
                // installed, or installed with its triggers still to run
                if let version = irisin?.version, InstallServiceRequirement.meetsMinimum(version) == false {
                    return .tooOld(version: version)
                }
            }
        }
        let prefix = installRoot == "/" ? "" : installRoot
        for file in InstallServiceRequirement.daemonFiles {
            let path = "\(prefix)\(file)"
            var info = stat()
            guard let canonical = canonicalPath(path), stat(canonical, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG
            else {
                return .missing(path: path)
            }
        }
        switch failure {
        case .unavailable:
            return .notLoaded
        case .noAnswer:
            return .noAnswer
        case .interrupted:
            if let refusal = admissionRefusal() {
                return refusal
            }
            if let missing = InstallServiceRequirement.clientEntitlements.first(where: { !hasEntitlement($0) }) {
                return .missingEntitlement(missing)
            }
            return database == nil ? .unknown : .refused
        default:
            return .unknown
        }
    }

    /// What irisind's admission rule would refuse in this executable's
    /// place, checked in its order: the file, then every folder from the
    /// install root down to the file's own. Nil when it would admit it, or
    /// when this executable cannot be found to say.
    func admissionRefusal() -> InstallServiceProblem? {
        guard let executable = ownExecutable(), let root = canonicalPath(installRoot) else { return nil }
        var info = stat()
        guard lstat(executable, &info) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG,
              trustedOwners.contains(info.st_uid),
              info.st_mode & S_IXUSR != 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            return .untrustedExecutable(path: executable, owner: info.st_uid, mode: info.st_mode & 0o7777)
        }
        let rootComponents = Self.components(root)
        let fileComponents = Self.components(executable)
        // Outside the install root irisind admits the sealed system volume
        // only, which is not where a package puts anything.
        guard fileComponents.count > rootComponents.count,
              zip(rootComponents, fileComponents).allSatisfy({ $0.utf8.elementsEqual($1.utf8) })
        else { return nil }
        var folder = root
        if let refusal = untrustedFolder(folder) {
            return refusal
        }
        for component in fileComponents.dropFirst(rootComponents.count).dropLast() {
            folder = folder == "/" ? "/\(component)" : "\(folder)/\(component)"
            if let refusal = untrustedFolder(folder) {
                return refusal
            }
        }
        return nil
    }

    /// Owned by root or a system account below 500 (mobile is 501), not a
    /// link, and writable by nobody but its owner; else the refusal.
    private func untrustedFolder(_ path: String) -> InstallServiceProblem? {
        var info = stat()
        // A folder above this running executable that cannot be read has
        // nothing to say about it.
        guard lstat(path, &info) == 0 else { return nil }
        let owner = info.st_uid
        guard info.st_mode & S_IFMT == S_IFDIR,
              owner < 500 || trustedOwners.contains(owner),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            return .untrustedFolder(path: path, owner: owner, mode: info.st_mode & 0o7777)
        }
        return nil
    }

    /// The names between slashes, empty ones dropped, as irisind compares
    /// them: by bytes.
    private static func components(_ path: String) -> [String] {
        path.utf8.split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Whether this process carries `name`, strictly `true`, read from the
    /// kernel by its own audit token as irisind reads it.
    static func ownEntitlement(_ name: String) -> Bool {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard status == KERN_SUCCESS, let value = name.withCString({ daemonCopyEntitlement($0, &token) }) else {
            return false
        }
        return xpc_get_type(value) == AppXPC.typeBool && xpc_bool_get_value(value)
    }

    // MARK: The package database's locks

    /// Who holds the package database's locks now: each process, once.
    func lockHolders() -> [PackageDatabaseLock.Holder] {
        PackageDatabaseLock.holders(installRoot: installRoot)
    }
}

/// The package database's two locks, dpkg's `lock` and apt's
/// `lock-frontend`, which Irisin's helper also takes, without waiting,
/// before it changes anything: another program holding either fails the
/// transaction at once. Read with `F_GETLK`, which takes nothing and waits
/// for nothing. This process never holds them, so opening and closing the
/// files here releases nothing.
enum PackageDatabaseLock {
    struct Holder: Equatable, Sendable {
        var pid: pid_t
        /// Its executable's name, when the process can still be found.
        var name: String?
    }

    /// Procursus keeps the database in `Library/dpkg`, with `var/lib/dpkg`
    /// a link to it; either is read, each folder once.
    static func holders(installRoot: String) -> [Holder] {
        let prefix = installRoot == "/" ? "" : installRoot
        var folders: [String] = []
        for candidate in ["/Library/dpkg", "/var/lib/dpkg"] {
            if let folder = canonicalPath("\(prefix)\(candidate)"), !folders.contains(folder) {
                folders.append(folder)
            }
        }
        var found: [Holder] = []
        for folder in folders {
            for file in ["lock-frontend", "lock"] {
                guard let pid = holder(of: "\(folder)/\(file)"), !found.contains(where: { $0.pid == pid }) else {
                    continue
                }
                found.append(Holder(pid: pid, name: executablePath(pid: pid).map { ($0 as NSString).lastPathComponent }))
            }
        }
        return found
    }

    /// The process holding a lock on the regular file at `path`, if any.
    static func holder(of path: String) -> pid_t? {
        guard let canonical = canonicalPath(path) else { return nil }
        let descriptor = open(canonical, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK), lock.l_pid > 0 else {
            return nil
        }
        return lock.l_pid
    }

    /// The sentence that goes before Irisin's own words when a transaction
    /// failed while another program held the database; nil when none does.
    static func sentence(_ holders: [Holder]) -> String? {
        guard !holders.isEmpty else { return nil }
        let named = holders.map { holder in
            holder.name.map { "\($0) (process \(holder.pid))" } ?? "process \(holder.pid)"
        }
        guard let last = named.last, named.count > 1 else {
            return "The package database is in use by \(named[0]). Wait for it to finish, then try again."
        }
        let others: String = named.dropLast().joined(separator: ", ")
        return "The package database is in use by \(others) and \(last). Wait for them to finish, then try again."
    }
}
