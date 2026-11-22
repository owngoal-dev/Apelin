import ApelinCore
import ApelinDebian
import ApelinGit
import ApelinProtocol
import CryptoKit
import Darwin
import Foundation

/// A project's release builds published as a GitHub Release
/// (`distributionRelease`; owner, 2026-11-22, issue #77), for a source that
/// indexes each repository's newest stable Release. Nothing is built again:
/// each package is copied into the task's staging while it is hashed, held
/// to the digest its build recorded, and what was checked is what is
/// uploaded. The project's commit must be on the repository already, a tag
/// GitHub has must name it, and every file the release would hold is judged
/// before the first upload, so a refusal uploads nothing.
///
/// GitHub's own order for a release whose files must not change once it is
/// out (immutable releases): a draft, its files, then publish. A draft cut
/// off part way stays a draft, and the next release of that version fills
/// it in.
extension DistributionService {
    /// A release checked before its task is accepted.
    public struct PreparedRelease: Sendable {
        let request: DistributionReleaseRequest
        let files: [URL]
        /// The notes, nil when blank.
        let notes: String?
    }

    /// The type a `.deb` is uploaded as.
    static let debianPackageType = "application/vnd.debian.binary-package"

    /// Checked before the task is accepted: the request's shape, notes no
    /// public text may carry, packages this project's builds left under
    /// `Builds/<projectID>/`, a project that is a repository, and a
    /// github.com sign-in.
    public func prepareRelease(_ request: DistributionReleaseRequest) throws -> PreparedRelease {
        if let problem = request.problem {
            throw ApelinError(.badRequest, problem)
        }
        let notes = request.notes.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let notes, let kind = IssueReport(layout: layout).privateData(in: notes) {
            throw ApelinError(
                .badRequest,
                "The release notes hold \(kind), which a public release must not carry: leave it out and release again.",
            )
        }
        let files = try builtPackages(request.files, doing: "released")
        let (project, _) = try git.open(request.projectID)
        guard let projectID = project.projectID,
              let builds = CanonicalPath.resolve(layout.data.root.appendingPathComponent("Builds").path)
        else { throw ApelinError(.badRequest, "\(project.name) has no build to release.") }
        for file in files where !file.path.hasPrefix(builds + "/" + projectID + "/") {
            throw ApelinError(.badRequest, "\(file.lastPathComponent) is not a build of \(project.name), so it is not released with its commit.")
        }
        _ = try api()
        return PreparedRelease(request: request, files: files, notes: notes)
    }

    /// The commit checked against the repository, the packages copied and
    /// read, every file judged against the release, then the draft made,
    /// the files uploaded and the release published. `staging` is the
    /// task's own folder.
    public func release(_ prepared: PreparedRelease, staging: URL, reporter: TaskReporter) async throws -> JSONValue {
        let request = prepared.request
        let fullName = request.repository
        let api = try api()

        reporter.stage("fetching")
        let (project, repository) = try git.open(request.projectID)
        let head = repository.head()
        guard let commit = head.commit else {
            throw ApelinError(
                .conflict,
                "\(project.name) has no commit yet. Commit it and push it to \(fullName), then release again.",
                reason: .notPushed,
            )
        }
        if let expected = request.commit, expected != commit {
            throw ApelinError(
                .conflict,
                "\(project.name) is at \(Self.short(commit)) now, not at \(Self.short(expected)), the commit the release was to tag. Nothing was released.",
                reason: .headChanged,
            )
        }
        // asked first, so a name the account cannot see or push to says so
        // in GitHub's terms rather than as a fetch that failed
        _ = try await api.pushableRepository(fullName)
        // the repository itself, whatever the project's remotes call it
        let holding = try GitService.mapping {
            try repository.branches(
                at: remoteURL(fullName),
                holding: commit,
                first: head.branch,
                credentials: git.credentialLookup,
                progress: GitService.fetchProgress(reporter),
            )
        }
        guard !holding.isEmpty else {
            throw ApelinError(
                .conflict,
                "\(Self.short(commit)), the commit \(project.name) is at, is on no branch of \(fullName). Push it there first, then release again.",
                reason: .notPushed,
            )
        }
        try reporter.checkCancelled()

        reporter.stage("checking")
        let packages = try stagePackages(prepared.files, digests: request.digests, in: staging, reporter: reporter)
        let tag = try Self.tag(of: packages, wanted: request.tag)
        let plan = try await plan(packages, tag: tag, commit: commit, project: project.name, fullName: fullName, api: api)
        try reporter.checkCancelled()

        reporter.stage("uploading")
        var release: GitHubAPI.Release = if let existing = plan.release {
            existing
        } else {
            try await api.createDraftRelease(fullName, tag: tag, commit: commit, notes: prepared.notes)
        }
        for asset in plan.unfinished {
            try await api.deleteAsset(fullName, asset)
        }
        var uploaded: [String] = []
        for package in plan.uploads {
            try reporter.checkCancelled()
            let asset = try await api.uploadAsset(
                fullName,
                release: release,
                name: package.name,
                contentType: Self.debianPackageType,
                file: package.staged,
            )
            try Self.checkUploaded(asset, name: package.name, digest: package.digest, size: Self.size(of: package.staged))
            uploaded.append(asset.name)
        }
        if plan.checksums != "unchanged" {
            try reporter.checkCancelled()
            if let old = plan.oldChecksums {
                try await api.deleteAsset(fullName, old)
            }
            let file = staging.appendingPathComponent(DistributionReleaseRequest.checksumsName)
            try plan.checksumsText.write(to: file, options: .withoutOverwriting)
            let asset = try await api.uploadAsset(
                fullName,
                release: release,
                name: DistributionReleaseRequest.checksumsName,
                contentType: "text/plain",
                file: file,
            )
            try Self.checkUploaded(
                asset,
                name: DistributionReleaseRequest.checksumsName,
                digest: Self.digest(plan.checksumsText),
                size: plan.checksumsText.count,
            )
        }
        try reporter.checkCancelled()

        reporter.stage("releasing")
        var warnings: [String] = []
        var fields: [String: Any] = [:]
        let hasNotes = !(release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if plan.release != nil, let notes = prepared.notes {
            if hasNotes {
                warnings.append("The release \(tag) had notes of its own already, which were kept.")
            } else {
                fields["body"] = notes
            }
        }
        if release.draft {
            // GitHub publishes onto a tag that exists whatever it names, so
            // one made meanwhile is checked again; the draft stays a draft
            if let tagged = try await api.tagCommit(fullName, tag: tag), tagged != commit {
                throw Self.movedTag(
                    tag,
                    tagged: tagged,
                    commit: commit,
                    project: project.name,
                    fullName: fullName,
                    then: "The release stays a draft, with its files.",
                )
            }
            fields["draft"] = false
            fields["prerelease"] = false
            fields["tag_name"] = tag
            fields["target_commitish"] = commit
            fields["make_latest"] = try await latestMark(fullName, version: packages[0].version, api: api)
        } else if release.prerelease {
            warnings.append(
                "The release \(tag) was published before as a pre-release and stays one, so a source that takes each repository's newest stable release skips it. Mark it as a full release on GitHub if it should be taken.",
            )
        }
        if !fields.isEmpty {
            release = try await api.updateRelease(
                fullName,
                id: release.id,
                fields,
                doing: release.draft ? "publish the release \(tag)" : "write the notes of the release \(tag)",
            )
        }
        for warning in warnings {
            reporter.warning(warning)
        }
        return try JSONValue(encoding: DistributionReleaseResult(
            repository: fullName,
            tag: tag,
            commit: commit,
            url: release.htmlURL,
            uploaded: uploaded,
            skipped: plan.skipped,
            checksums: plan.checksums,
            created: plan.release == nil,
            warnings: warnings,
        ))
    }

    // MARK: Judging

    /// What a release does, judged before anything is uploaded.
    struct ReleasePlan {
        /// The release the tag has already; nil makes one.
        var release: GitHubAPI.Release?
        /// Packages to upload.
        var uploads: [StagedPackage] = []
        /// Packages the release holds already, with the same bytes.
        var skipped: [String] = []
        /// Uploads GitHub lost part way under a name to upload again.
        var unfinished: [GitHubAPI.Asset] = []
        /// `sha256sum`'s lines for every package the release will hold.
        var checksumsText = Data()
        /// `added`, `replaced` or `unchanged`.
        var checksums = "added"
        var oldChecksums: GitHubAPI.Asset?
    }

    /// `v<version>` of packages that are one package ID at one version,
    /// each named as GitHub keeps it; `wanted`, when the caller named one,
    /// must be it.
    static func tag(of packages: [StagedPackage], wanted: String?) throws -> String {
        let ids = Set(packages.map(\.package)).sorted()
        let versions = Set(packages.map(\.version)).sorted()
        guard ids.count == 1, versions.count == 1, let version = versions.first else {
            throw ApelinError(
                .badRequest,
                "A release holds one package at one version, such as its roothide and rootless builds; these are \(packages.map(\.title).joined(separator: ", ")).",
            )
        }
        guard let tag = DistributionReleaseRequest.tag(forVersion: version) else {
            throw ApelinError(
                .badRequest,
                "Version \(version) cannot name a release: a tag takes only letters, digits, periods, hyphens and underscores here. Set a version such as 1.0.2 and build again.",
            )
        }
        if let wanted, wanted != tag {
            throw ApelinError(.conflict, "These packages are version \(version), so their tag is \(tag), not \(wanted). Nothing was released.")
        }
        for package in packages where !DistributionReleaseRequest.isAssetName(package.name) {
            throw ApelinError(
                .badRequest,
                "GitHub renames a release file named \(package.name): its package ID takes only letters, digits, periods and hyphens here.",
            )
        }
        return tag
    }

    /// The repository, the tag, the release and every file it would hold,
    /// read from GitHub and judged; nothing is changed yet.
    private func plan(
        _ packages: [StagedPackage],
        tag: String,
        commit: String,
        project: String,
        fullName: String,
        api: GitHubAPI,
    ) async throws -> ReleasePlan {
        if let tagged = try await api.tagCommit(fullName, tag: tag), tagged != commit {
            throw Self.movedTag(tag, tagged: tagged, commit: commit, project: project, fullName: fullName, then: "Nothing was uploaded.")
        }
        var plan = try await ReleasePlan(release: api.release(fullName, tag: tag))
        var assets: [GitHubAPI.Asset] = []
        if let release = plan.release {
            assets = try await api.assets(fullName, release: release.id)
        }
        var held: [String: String] = [:]
        for asset in assets where asset.state == "uploaded" && asset.name.hasSuffix(".deb") {
            guard !packages.contains(where: { $0.name == asset.name }) else { continue }
            held[asset.name] = try await api.digest(of: asset, in: fullName)
        }
        for package in packages {
            held[package.name] = package.digest
            guard let asset = assets.first(where: { $0.name == package.name }) else {
                plan.uploads.append(package)
                continue
            }
            guard asset.state == "uploaded" else {
                plan.unfinished.append(asset)
                plan.uploads.append(package)
                continue
            }
            // a size that differs needs no download to tell
            var same = try asset.size == Self.size(of: package.staged)
            if same {
                same = try await api.digest(of: asset, in: fullName) == package.digest
            }
            guard same else {
                throw ApelinError(
                    .conflict,
                    "The release \(tag) of \(fullName) holds \(package.name) already, with other contents. A release's files are never replaced: raise the version and build again. Nothing was uploaded.",
                )
            }
            plan.skipped.append(package.name)
        }
        plan.checksumsText = Data(held.sorted { $0.key < $1.key }.map { name, digest in
            "\(digest.dropFirst("sha256:".count))  \(name)\n"
        }.joined().utf8)
        if let old = assets.first(where: { $0.name == DistributionReleaseRequest.checksumsName }) {
            plan.oldChecksums = old
            var unchanged = old.state == "uploaded" && old.size == plan.checksumsText.count
            if unchanged {
                unchanged = try await api.digest(of: old, in: fullName) == Self.digest(plan.checksumsText)
            }
            plan.checksums = unchanged ? "unchanged" : "replaced"
        }
        if let release = plan.release, !release.draft, release.immutable == true,
           !plan.uploads.isEmpty || plan.checksums != "unchanged"
        {
            let names = plan.uploads.map(\.name) + (plan.checksums == "unchanged" ? [] : [DistributionReleaseRequest.checksumsName])
            throw ApelinError(
                .conflict,
                "The release \(tag) of \(fullName) is published and immutable, so GitHub takes no file added to it or changed (\(names.joined(separator: ", "))). Release a new version instead. Nothing was uploaded.",
            )
        }
        return plan
    }

    /// The repository's latest release stays the latest when it is of a
    /// newer version than `version` (an earlier version released later):
    /// `make_latest` is `false` then, else `true`.
    private func latestMark(_ fullName: String, version: String, api: GitHubAPI) async throws -> String {
        guard let latest = try await api.latestRelease(fullName), latest.tagName.hasPrefix("v") else { return "true" }
        let theirs = String(latest.tagName.dropFirst())
        guard DebianVersion.isValid(theirs), DebianVersion.isValid(version) else { return "true" }
        return DebianVersion.compare(version, theirs) < 0 ? "false" : "true"
    }

    // MARK: Helpers

    /// What GitHub answered for an upload is what was sent: its name, its
    /// size and, when GitHub gives one, its digest.
    static func checkUploaded(_ asset: GitHubAPI.Asset, name: String, digest: String, size: Int) throws {
        guard asset.name == name else {
            throw ApelinError(.unavailable, "GitHub named the uploaded \(name) \(asset.name).")
        }
        let answered = asset.digest?.lowercased()
        guard asset.size == size, answered == nil || answered == digest else {
            throw ApelinError(.unavailable, "GitHub holds \(name) with other contents than were uploaded. Release again to upload it once more.")
        }
    }

    /// A tag GitHub has at another commit than the one to release, both
    /// named; `then` says what was left.
    static func movedTag(
        _ tag: String,
        tagged: String,
        commit: String,
        project: String,
        fullName: String,
        then: String,
    ) -> ApelinError {
        ApelinError(
            .conflict,
            "The tag \(tag) on \(fullName) names \(short(tagged)), not \(short(commit)), the commit \(project) is at. A tag is never moved: release a new version from this commit, or this version from \(short(tagged)). \(then)",
        )
    }

    static func short(_ commit: String) -> String {
        String(commit.prefix(7))
    }

    static func digest(_ data: Data) -> String {
        "sha256:" + TransferDigest.hex(SHA256.hash(data: data))
    }

    static func size(of file: URL) throws -> Int {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0 else {
            throw ApelinError(.internal, "could not read \(file.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        return Int(metadata.st_size)
    }
}
