import ApelinProtocol
import Darwin
import Foundation

/// The paths an installed package lists, read from the package database's
/// own files, never through a package manager's binary.
protocol PackageFileLists: Sendable {
    /// What `packageID` installs, as dpkg lists it; empty when it lists nothing.
    func files(of packageID: String) throws -> [String]
    /// When `packageID`'s list was last written, which an install does;
    /// nil when it has none.
    func written(of packageID: String) -> Date?
}

/// `<install root>/var/lib/dpkg/info/<package>.list`, the name irisind
/// writes and reads too. A bootstrap that keeps no lists has no file owners
/// to name, and a refused install says only what irisind said.
struct DpkgFileLists: PackageFileLists {
    static let maximumBytes = 4 << 20

    let directory: String

    init(installRoot: String) {
        directory = (installRoot == "/" ? "" : installRoot) + "/var/lib/dpkg/info"
    }

    func files(of packageID: String) throws -> [String] {
        let name = packageID.lowercased()
        guard ManagedPackagePolicy.isValidPackageID(name) else { return [] }
        let descriptor = open(directory + "/" + name + ".list", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return []
            }
            throw ApelinError(.unavailable, "\(name).list: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= Self.maximumBytes
        else {
            throw ApelinError(.unavailable, "\(name).list is not a file list")
        }
        // An empty file reads as nil.
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else {
            throw ApelinError(.unavailable, "\(name).list is not a file list")
        }
        return Self.parse(String(decoding: data, as: UTF8.self))
    }

    func written(of packageID: String) -> Date? {
        let name = packageID.lowercased()
        guard ManagedPackagePolicy.isValidPackageID(name) else { return nil }
        var metadata = stat()
        guard lstat(directory + "/" + name + ".list", &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        let modified = metadata.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec) / 1_000_000_000)
    }

    /// One absolute path a line; `/.`, the archive's own root, is no file.
    static func parse(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") && $0 != "/." }
    }
}

/// Who is in the way of an install irisind refused, and what to do about
/// it. irisind is the authority and has decided already: nothing here runs
/// before it, and nothing is removed. The package database is read only to
/// name the package, and its installation when Apelin made it.
enum InstallConflicts {
    /// One entry a package and relation, by package ID: an installed package
    /// (not this one, nor one it Replaces) that lists a path this one
    /// installs, then one this package's Conflicts or Breaks names. A
    /// versioned relation is left to irisind's own words, since the host
    /// compares no versions.
    static func find(
        packageID: String,
        packageFiles: [String],
        control: DebControlPeek.Control?,
        installed: [String: InstalledPackage],
        lists: PackageFileLists,
        records: [InstallationRecord],
    ) -> [InstallConflict] {
        func conflict(_ relation: InstallConflict.Relation, _ other: InstalledPackage, file: String? = nil) -> InstallConflict {
            let record = ManagedPackagePolicy.removableRecord(of: other.packageID, installed: installed, records: records)
            return InstallConflict(
                relation: relation,
                file: file,
                packageID: other.packageID,
                version: other.version,
                installationID: record?.installationID,
                projectID: record?.projectID,
            )
        }
        let others = installed.values.filter { $0.isInstalled && $0.packageID != packageID }
            .sorted { $0.packageID < $1.packageID }
        var found: [InstallConflict] = []
        if !packageFiles.isEmpty {
            let replaced = Set((control?.replaces ?? []).map(\.package))
            for other in others where !replaced.contains(other.packageID) {
                guard let listed = try? Set(lists.files(of: other.packageID)),
                      let file = packageFiles.first(where: listed.contains)
                else { continue }
                found.append(conflict(.file, other, file: file))
            }
        }
        let relations: [(InstallConflict.Relation, [DebControlPeek.Relation])] = [
            (.conflicts, control?.conflicts ?? []),
            (.breaks, control?.breaks ?? []),
        ]
        for (relation, named) in relations {
            let names = Set(named.filter { $0.constraint == nil }.map(\.package))
            for other in others where names.contains(other.packageID) {
                found.append(conflict(relation, other))
            }
        }
        return found
    }

    /// What the failed task says first: each package in the way with its
    /// fix, three at most; nil when none was found.
    static func explanation(_ conflicts: [InstallConflict], installed: [String: InstalledPackage]) -> String? {
        var named = Set<String>()
        let packages = conflicts.filter { named.insert($0.packageID).inserted }
        guard !packages.isEmpty else { return nil }
        var sentences = packages.prefix(3).map { conflict in
            sentence(
                conflict,
                protected: ManagedPackagePolicy.isReserved(
                    conflict.packageID,
                    installed: installed[conflict.packageID],
                    origin: .build,
                ),
            )
        }
        if packages.count > 3 {
            sentences.append("\(packages.count - 3) more installed packages are in the way too.")
        }
        return sentences.joined(separator: " ")
    }

    static func sentence(_ conflict: InstallConflict, protected: Bool) -> String {
        let package = "\(conflict.packageID) \(conflict.version)"
        let field = conflict.relation == .breaks ? "Breaks" : "Conflicts"
        switch (conflict.relation, conflict.installationID) {
        case (.file, _) where protected:
            return "\(conflict.file ?? "A file") already belongs to \(package), a protected system package. Leave that file out of this package, then install again."
        case let (.file, installation?):
            return "\(conflict.file ?? "A file") already belongs to \(package), which Apelin installed (installation \(installation)). Remove that installation first, then install again."
        case (.file, nil):
            return "\(conflict.file ?? "A file") already belongs to \(package), which Apelin did not install. Remove it with your preferred package manager first, then install again. Add \(conflict.packageID) to this package's Replaces only if this package is meant to take over its files."
        case _ where protected:
            return "This package's \(field) names \(package), a protected system package. Take it out of \(field), then install again."
        case let (_, installation?):
            return "This package's \(field) names \(package), which Apelin installed (installation \(installation)). The installer does not remove it: remove that installation first, then install again."
        case (_, nil):
            return "This package's \(field) names \(package), which is installed. The installer does not remove it: remove it with your preferred package manager first, then install again."
        }
    }
}
