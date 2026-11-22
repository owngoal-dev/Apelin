import ApelinCore
import ApelinDebArchive
import ApelinDebian
import ApelinGit
import ApelinProtocol
import CryptoKit
import Darwin
import Foundation

/// Publishing (`distributionPublish`): packages builds left under `Builds/`,
/// copied into the linked repository's `debs/`, committed and pushed. Each
/// package is copied into the task's staging while it is hashed, its digest
/// held to the one the request names and its control file read from that
/// copy, and every name in `debs/` is checked, before any package goes in:
/// what was checked is what is published, and a refusal publishes nothing.
extension DistributionService {
    /// Checked before the task is accepted: packages under the data folder's
    /// `Builds/`, each a regular `.deb` GitHub takes, one digest of a build's
    /// shape for each when the request names them, a link whose project is
    /// there — the repository the request names, when it names one — and a
    /// github.com sign-in to push with.
    public func preparePublish(_ request: DistributionPublishRequest) throws -> (DistributionRepository, [URL]) {
        let maximum = DistributionPublishRequest.maximumFiles
        guard !request.files.isEmpty, request.files.count <= maximum else {
            throw ApelinError(.badRequest, "Publish between 1 and \(maximum) packages at a time.")
        }
        let files = try builtPackages(request.files, doing: "published")
        if let digests = request.digests {
            guard digests.count == files.count else {
                throw ApelinError(.badRequest, "Name one digest for each package: \(files.count) packages, \(digests.count) digests.")
            }
            guard digests.allSatisfy(DistributionPublishRequest.isDigest) else {
                throw ApelinError(.badRequest, "A package's digest is sha256: and 64 lowercase hex digits, as its build recorded it.")
            }
        }
        guard let linked = linked() else {
            throw ApelinError(.notFound, "No package repository is linked. Create or link one in Settings ▸ Git.")
        }
        if let wanted = request.repository, wanted.lowercased() != linked.fullName.lowercased() {
            throw ApelinError(.conflict, "The linked package repository is now \(linked.fullName), not \(wanted).")
        }
        _ = try api()
        return (linked, files)
    }

    /// Up to date with the remote (fast-forward only), each package into
    /// `debs/`, one commit, one push. `digests`, when given, are the
    /// request's, one for each file; `staging` is the task's own folder.
    public func publish(
        _ linked: DistributionRepository,
        files: [URL],
        digests: [String]? = nil,
        staging: URL,
        reporter: TaskReporter,
    ) async throws -> JSONValue {
        let project = try git.projects.locate(linked.projectID)
        let repository = try GitRepository(at: project.root)
        _ = try git.pull(git.preparePull(GitPullRequest(projectID: linked.projectID)), reporter: reporter)
        try reporter.checkCancelled()
        reporter.stage("preparing")
        let packages = try stagePackages(files, digests: digests, in: staging, reporter: reporter)
        let debs = project.root.appendingPathComponent("debs", isDirectory: true)
        var metadata = stat()
        if lstat(debs.path, &metadata) != 0 {
            guard mkdir(debs.path, 0o755) == 0 else { throw ApelinError(.internal, "could not make debs/") }
        } else if metadata.st_mode & S_IFMT != S_IFDIR {
            throw ApelinError(.conflict, "debs in \(project.name) is not a folder.")
        }
        // Every name is judged before the first package goes in.
        var added: [StagedPackage] = []
        var skipped: [String] = []
        for package in packages {
            let destination = debs.appendingPathComponent(package.name)
            guard lstat(destination.path, &metadata) == 0 else {
                added.append(package)
                continue
            }
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  FileManager.default.contentsEqual(atPath: destination.path, andPath: package.staged.path)
            else {
                throw ApelinError(
                    .conflict,
                    "debs/\(package.name) is already published with other contents. Raise the version and build again.",
                )
            }
            skipped.append(package.name)
        }
        var titles: [String] = []
        for package in added {
            try FileManager.default.moveItem(at: package.staged, to: debs.appendingPathComponent(package.name))
            if !titles.contains(package.title) {
                titles.append(package.title)
            }
        }
        var result: [String: JSONValue] = [
            "published": .array(added.map { .string($0.name) }),
            "skipped": .array(skipped.map(JSONValue.string)),
            "sourceURL": .string(linked.sourceURL),
            "repository": .string(linked.fullName),
        ]
        if !added.isEmpty {
            try repository.stage(added.map { "debs/" + $0.name })
            let login = (try? credentials.credential(forHost: GitHubHost.name))?.username ?? "apelin"
            result["commit"] = try .string(repository.commit(
                message: "Publish " + titles.joined(separator: ", "),
                author: author(repository, login: login),
            ))
        }
        // Pushed even when every package was there already: an earlier
        // publish whose push failed left its commit here, and the packages
        // it skips now reach GitHub with this one.
        try reporter.checkCancelled()
        reporter.stage("pushing")
        _ = try GitService.mapping { try repository.push(credentials: git.credentialLookup) }
        return .object(result)
    }

    /// Each of `paths` as a package Apelin built: a regular `.deb` under the
    /// data folder's `Builds/`, of at most 100 MB, canonical.
    func builtPackages(_ paths: [String], doing what: String) throws -> [URL] {
        let builds = CanonicalPath.resolve(layout.data.root.appendingPathComponent("Builds").path)
        return try paths.map { path -> URL in
            guard let builds, !path.utf8.contains(0), let resolved = CanonicalPath.resolve(path),
                  resolved.hasPrefix(builds + "/"), resolved.hasSuffix(".deb")
            else { throw ApelinError(.badRequest, "Only a package Apelin built can be \(what).") }
            var metadata = stat()
            guard lstat(resolved, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                throw ApelinError(.notFound, "\((resolved as NSString).lastPathComponent) is not there.")
            }
            guard metadata.st_size <= Self.maximumPackageBytes else {
                throw ApelinError(.badRequest, "\((resolved as NSString).lastPathComponent) is over 100 MB, which GitHub refuses.")
            }
            return URL(fileURLWithPath: resolved)
        }
    }

    /// One package as it goes into `debs/` or onto a release: its copy in
    /// the task's staging, what its control file says and the name it
    /// gives it there.
    struct StagedPackage {
        let staged: URL
        let name: String
        /// `<Package> <Version>`, for the commit's message.
        let title: String
        let package: String
        let version: String
        /// `sha256:<hex>` of the copy.
        let digest: String
    }

    /// Each package copied into `staging` while it is hashed and refused
    /// when its bytes are not the digest named for it, then named from its
    /// copy's control file; two packages of one name are refused.
    func stagePackages(
        _ files: [URL],
        digests: [String]?,
        in staging: URL,
        reporter: TaskReporter,
    ) throws -> [StagedPackage] {
        let builds = CanonicalPath.resolve(layout.data.root.appendingPathComponent("Builds").path)
        var packages: [StagedPackage] = []
        for (index, file) in files.enumerated() {
            let staged = staging.appendingPathComponent("package-\(index).deb")
            let digest = try Self.copyHashing(file, inside: builds, to: staged, reporter: reporter)
            if let expected = digests?[index], digest != expected {
                throw ApelinError(
                    .conflict,
                    "\(file.lastPathComponent) is \(digest), not \(expected), the digest its build recorded: it changed since, so none of the packages went in. Build it again.",
                )
            }
            let control = try DebianControlFile(parsing: DebArchiveReader.control(of: .path(staged.path)))
            guard let package = control["Package"], let version = control["Version"],
                  let architecture = control["Architecture"]
            else { throw ApelinError(.badRequest, "\(file.lastPathComponent) has no Package, Version or Architecture.") }
            let name = try Self.packageFileName(package: package, version: version, architecture: architecture)
            guard !packages.contains(where: { $0.name == name }) else {
                throw ApelinError(.badRequest, "Two of these packages are \(name); publish one of them.")
            }
            packages.append(StagedPackage(
                staged: staged,
                name: name,
                title: "\(package) \(version)",
                package: package,
                version: version,
                digest: digest,
            ))
        }
        return packages
    }

    /// `source` copied to a new file at `destination` while it is hashed,
    /// opened without following a link and read only while it is a regular
    /// file inside `root` of at most `maximumPackageBytes`; answers
    /// `sha256:<hex>` of the bytes copied.
    static func copyHashing(
        _ source: URL,
        inside root: String?,
        to destination: URL,
        reporter: TaskReporter,
    ) throws -> String {
        let name = source.lastPathComponent
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw ApelinError(.notFound, "\(name) is not there.") }
        defer { close(input) }
        var metadata = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(input, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              let root, fcntl(input, F_GETPATH, &path) == 0,
              let opened = CanonicalPath.resolve(String(cString: path)),
              CanonicalPath.isCanonical(opened, inside: root)
        else { throw ApelinError(.conflict, "\(name) is no longer a package in Apelin's build folder.") }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard output >= 0 else {
            throw ApelinError(.internal, "could not copy \(name): \(String(cString: strerror(errno)))")
        }
        defer { close(output) }
        var hash = SHA256()
        var size = 0
        let chunk = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(input, buffer, chunk)
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw ApelinError(.internal, "could not read \(name): \(String(cString: strerror(errno)))")
            }
            if count == 0 {
                break
            }
            size += count
            guard size <= maximumPackageBytes else {
                throw ApelinError(.badRequest, "\(name) is over 100 MB, which GitHub refuses.")
            }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            var written = 0
            while written < count {
                let wrote = Darwin.write(output, buffer + written, count - written)
                if wrote < 0, errno == EINTR {
                    continue
                }
                guard wrote > 0 else {
                    throw ApelinError(.internal, "could not copy \(name): \(String(cString: strerror(errno)))")
                }
                written += wrote
            }
            try reporter.checkCancelled()
        }
        return "sha256:" + TransferDigest.hex(hash.finalize())
    }
}
