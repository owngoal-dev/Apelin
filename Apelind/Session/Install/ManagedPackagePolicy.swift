import ApelinProtocol
import Foundation

/// What the package database says is installed, read from the file, never
/// from a package manager's binary.
struct InstalledPackage: Equatable, Sendable {
    var packageID: String
    var version: String
    /// `install ok installed`, or another dpkg status triple.
    var status: String
    var essential: Bool
    var priority: String?

    var isInstalled: Bool {
        status.hasSuffix(" installed")
    }
}

protocol InstalledPackageSource: Sendable {
    func installedPackages() throws -> [String: InstalledPackage]
}

/// `<install root>/var/lib/dpkg/status`, parsed as the RFC 822 stanzas it is.
struct DpkgStatusDatabase: InstalledPackageSource {
    let path: String

    init(installRoot: String) {
        path = (installRoot == "/" ? "" : installRoot) + "/var/lib/dpkg/status"
    }

    func installedPackages() throws -> [String: InstalledPackage] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ApelinError(.unavailable, "The list of installed packages could not be read. Try again.")
        }
        return Self.parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> [String: InstalledPackage] {
        var result: [String: InstalledPackage] = [:]
        for stanza in text.components(separatedBy: "\n\n") {
            var fields: [String: String] = [:]
            for line in stanza.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.first == " " || line.first == "\t" {
                    continue // a continuation line; none of the fields read here have one
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let package = fields["package"], !package.isEmpty else { continue }
            let entry = InstalledPackage(
                packageID: package,
                version: fields["version"] ?? "",
                status: fields["status"] ?? "",
                essential: fields["essential"]?.lowercased() == "yes",
                priority: fields["priority"]?.lowercased(),
            )
            // A package with more than one stanza (architectures): an installed one wins.
            if let existing = result[package], existing.isInstalled, !entry.isInstalled {
                continue
            }
            result[package] = entry
        }
        return result
    }
}

/// Milestone 1 §8, managed packages: which packages a project install may
/// put on the device, and which installation records a removal may act on.
///
/// - The bootstrap's core, the install service, Apelin itself and protected
///   system packages are never a project's: an install naming one is
///   refused, and so is its removal, whatever the records say.
/// - An install whose package ID is already installed by someone else — no
///   installation record of ours claims it at the installed version — is
///   refused, so a project cannot overwrite a package and then remove it as
///   its own.
/// - A removal acts only on a record this bridge wrote when irisind reported
///   the install succeeded, and only while the installed state still matches
///   it: the same package at the same version. Anything else is not managed,
///   and is the user's package manager's to remove.
enum ManagedPackagePolicy {
    /// Package ID prefixes that are never a project's: Apelin and its
    /// extensions, Irisin (irisind refuses its own too), the system's
    /// virtual packages.
    static let reservedPrefixes = ["wiki.qaq.apelin", "wiki.qaq.irisin", "gsc.", "cy+"]

    /// Bootstrap core and the package managers, by exact ID.
    static let reservedIDs: Set<String> = [
        "apt", "apt-key", "apt7", "apt7-key", "apt7-lib", "apt1.4", "libapt", "libapt-pkg", "libapt-pkg6.0",
        "dpkg", "dpkg-dev", "base", "bash", "coreutils", "coreutils-bin", "dash", "debianutils", "diffutils",
        "findutils", "grep", "gzip", "sed", "tar", "xz-utils", "zsh", "sudo", "openssh", "openssh-server",
        "openssh-client", "launchctl", "uikittools", "ldid", "libroothide", "roothide", "rootless-compat",
        "procursus-keyring", "libiosexec1", "libxcrypt1", "libintl8", "libncursesw6", "ncurses-term",
        "firmware", "essential", "system-cmds", "shell-cmds", "file-cmds", "text-cmds", "darwintools", "profile.d",
        "libssl3", "ca-certificates", "sileo", "org.coolstar.sileo", "zebra", "xyz.willy.zebra",
        "ellekit", "com.opa334.dopamine", "com.opa334.dopamine-roothide", "com.roothide.bootstrap",
        "mobilesubstrate", "com.saurik.substrate.safemode", "libhooker", "org.coolstar.libhooker",
        "trustcache", "jbctl", "libjailbreak", "nathanlr", "palera1n", "bootstrap", "libkrw0", "libkernrw0",
        "xinamine", "serotonin",
    ]

    /// The one family under Apelin's own prefix a source other than the
    /// IDE's package may install: apelin-environment's local toolchains, and
    /// only from that source.
    static let toolchainPrefix = "wiki.qaq.apelin.toolchain."

    static func isReserved(
        _ packageID: String,
        installed: InstalledPackage?,
        origin: InstallationRecord.Origin,
    ) -> Bool {
        let id = packageID.lowercased()
        if origin == .environment {
            // A toolchain package, and nothing but one.
            return !(id.hasPrefix(toolchainPrefix) && id.count > toolchainPrefix.count)
        }
        if reservedIDs.contains(id) {
            return true
        }
        if reservedPrefixes.contains(where: { id.hasPrefix($0) }) {
            return true
        }
        if let installed, installed.essential || installed.priority == "required" || installed.priority == "important" {
            return true
        }
        return false
    }

    /// irisind's own rule for a package ID: lowercase `a-z 0-9 + - .`,
    /// 2 to 256 characters, starting with a letter or digit.
    static func isValidPackageID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (2 ... 256).contains(bytes.count), let first = bytes.first, isLowerAlnum(first) else { return false }
        return bytes.allSatisfy { isLowerAlnum($0) || $0 == 43 || $0 == 45 || $0 == 46 }
    }

    private static func isLowerAlnum(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (97 ... 122).contains(byte)
    }

    /// Before an install is handed over.
    static func checkInstall(
        packageID: String,
        origin: InstallationRecord.Origin = .build,
        installed: [String: InstalledPackage],
        records: [InstallationRecord],
    ) throws {
        guard isValidPackageID(packageID) else {
            throw ApelinError(.badRequest, "\(packageID) is not a valid package ID")
        }
        let current = installed[packageID]
        guard !isReserved(packageID, installed: current, origin: origin) else {
            throw ApelinError(
                .denied,
                origin == .environment
                    ? "a toolchain package is \(toolchainPrefix)<id>, not \(packageID)"
                    : "\(packageID) is a protected system package, so a project cannot install it.",
            )
        }
        guard let current, current.isInstalled else { return }
        let ours = records.contains {
            $0.packageID == packageID && $0.status == .installed && $0.version == current.version
        }
        guard ours else {
            throw ApelinError(
                .conflict,
                "\(packageID) \(current.version) is already installed from another source. Remove it with your preferred package manager, then try again.",
            )
        }
    }

    /// Before a removal is handed over: the record must be ours and current.
    static func checkRemoval(
        _ record: InstallationRecord?,
        installed: [String: InstalledPackage],
        records: [InstallationRecord],
    ) throws {
        guard let record else {
            throw ApelinError(
                .notFound,
                "Apelin did not install this package. Remove it with your preferred package manager.",
            )
        }
        guard record.status == .installed, record.receipt?.isInstalled == true else {
            throw ApelinError(
                .denied,
                "This package is not installed, or it is still being installed or removed.",
            )
        }
        let current = installed[record.packageID]
        guard !isReserved(record.packageID, installed: current, origin: record.origin) else {
            throw ApelinError(
                .denied,
                record.origin == .environment
                    ? "\(record.packageID) is not a toolchain package, so the environment cannot remove it."
                    : "\(record.packageID) is a protected system package, so Apelin cannot remove it.",
            )
        }
        guard let current, current.isInstalled else {
            throw ApelinError(.conflict, "\(record.packageID) is no longer installed.")
        }
        guard current.version == record.version else {
            throw ApelinError(
                .conflict,
                "\(record.packageID) is now version \(current.version), not version \(record.version) that Apelin installed. Remove it with your preferred package manager.",
            )
        }
        // A later install of the same package supersedes this record.
        if let newer = records.filter({
            $0.packageID == record.packageID && $0.status == .installed && $0.createdAt > record.createdAt
        }).max(by: { $0.createdAt < $1.createdAt }) {
            throw ApelinError(
                .conflict,
                "A newer installation of \(record.packageID) exists: \(newer.installationID). Remove that installation instead.",
            )
        }
    }

    /// The installation a removal of this package would act on: its newest
    /// record, when `checkRemoval` accepts it. nil when Apelin did not
    /// install the version there now.
    static func removableRecord(
        of packageID: String,
        installed: [String: InstalledPackage],
        records: [InstallationRecord],
    ) -> InstallationRecord? {
        let newest = records.filter { $0.packageID == packageID && $0.status == .installed }
            .max { $0.createdAt < $1.createdAt }
        guard let newest, (try? checkRemoval(newest, installed: installed, records: records)) != nil else {
            return nil
        }
        return newest
    }
}
