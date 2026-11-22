import enum ApelinProject.ConfigurationName
import struct ApelinProtocol.DistributionReleaseRequest
import enum ApelinProtocol.FeedbackRules
import enum ApelinProtocol.GitHubName
import Foundation
import KWWKAI

/// apelin_package_release (owner, 2026-11-22, issue #77): the release
/// builds of one version, as their builds made them, published as a GitHub
/// Release of a repository the user names, tagged `v<version>` at the
/// project's pushed commit, for a source that indexes each repository's
/// newest stable Release. In a project's chat only: the tag is its
/// commit's. What could never be released is refused here, before anyone
/// is asked: a build that left no package, a debug build, another
/// project's, a package gone from Apelin's build folder, packages of more
/// than one ID or version, a version no tag can carry, a project with no
/// commit, no repository named and none on github.com to default to, and
/// no GitHub sign-in. Whether the commit is on the repository takes a
/// fetch, which apelin-environment makes before anything goes out. The card
/// then names the repository, the tag, the commit and each package with
/// the digest its build recorded, and apelin-environment releases nothing
/// unless every file still has it and the commit is on the repository.
public enum PackageRelease {
    static let buildIDsKey = "build_ids"
    static let repositoryKey = "repository"
    static let notesKey = "notes"

    /// The builds the call names, each once.
    static func buildIDs(_ arguments: JSONValue) throws -> [String] {
        guard let ids = arguments.argStrings(buildIDsKey)?.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !ids.isEmpty, !ids.contains(where: \.isEmpty)
        else {
            throw ToolArgumentError("Nothing was released: name the build_id of each release build to release, as apelin_project_build answered it.")
        }
        guard ids.count <= DistributionReleaseRequest.maximumFiles else {
            throw ToolArgumentError("Nothing was released: release at most \(DistributionReleaseRequest.maximumFiles) packages at a time.")
        }
        var seen: Set<String> = []
        for id in ids {
            guard seen.insert(id).inserted else {
                throw ToolArgumentError("Nothing was released: \(id) is named twice.")
            }
        }
        return ids
    }

    /// What the card names, from what `facts` read of the project and the
    /// builds `ids` names, in their order; every problem with the builds at
    /// once, else.
    static func approval(
        for ids: [String],
        arguments: JSONValue,
        facts: PackageReleaseFacts,
        project: ProjectIdentity,
    ) throws -> PackageReleaseApproval {
        guard facts.builds.count == ids.count else {
            throw ToolDeniedError(message: "Nothing was released: the builds' package records could not be read.")
        }
        var problems: [String] = []
        var packages: [PackagePublishApproval.Package] = []
        for (id, record) in zip(ids, facts.builds) {
            guard let record else {
                problems.append("No build \(id) made a package: give the build_id apelin_project_build answered, which is also its package artifact's id.")
                continue
            }
            let package = "\(record.packageID) \(record.version) for \(record.architecture)"
            guard record.projectID == project.id else {
                problems.append("\(id) is a build of another project; a release tags this project's commit, so release only this project's builds.")
                continue
            }
            // The record spells it as the project's configurations do.
            guard record.configuration == ConfigurationName.release.rawValue else {
                problems.append("\(id) is a \(record.configuration) build of \(package); release a release build, made by apelin_project_build with configuration release and the bootstrap, once for roothide and once for rootless.")
                continue
            }
            guard record.present else {
                problems.append("The package of \(id), \(package), is no longer in Apelin's build folder: build it again.")
                continue
            }
            if let twin = packages.first(where: {
                $0.packageID == record.packageID && $0.version == record.version && $0.architecture == record.architecture
            }) {
                problems.append("\(twin.buildID) and \(id) are both \(package): release one of them.")
                continue
            }
            packages.append(PackagePublishApproval.Package(
                buildID: record.buildID,
                packageID: record.packageID,
                version: record.version,
                architecture: record.architecture,
                bootstrap: record.bootstrap,
                file: record.file,
                digest: record.digest,
            ))
        }
        guard problems.isEmpty else {
            throw ToolArgumentError("Nothing was released. " + problems.joined(separator: " "))
        }
        let tag = try tag(of: packages)
        let repository = try repository(arguments, facts: facts)
        let notes = try notes(arguments)
        guard let commit = facts.commit else {
            throw ToolDeniedError(message: "Nothing was released: the project has no commit yet. Commit it with git_commit, push it to \(repository) with git_push, then release again.")
        }
        guard facts.signedIn != false else {
            throw ToolDeniedError(message: Self.signInNeeded)
        }
        return PackageReleaseApproval(
            projectID: project.id,
            repository: repository,
            tag: tag,
            commit: commit,
            notes: notes,
            packages: packages,
        )
    }

    /// `v<version>` of packages that are one package ID at one version, each
    /// with a file name GitHub keeps.
    private static func tag(of packages: [PackagePublishApproval.Package]) throws -> String {
        let ids = Set(packages.map(\.packageID))
        let versions = Set(packages.map(\.version)).sorted()
        guard ids.count == 1, versions.count == 1, let version = versions.first else {
            let named = packages.map { "\($0.buildID) (\($0.packageID) \($0.version))" }.joined(separator: ", ")
            throw ToolArgumentError("Nothing was released: a release holds one package at one version, such as its roothide and its rootless build; these are \(named).")
        }
        guard let tag = DistributionReleaseRequest.tag(forVersion: version) else {
            throw ToolArgumentError("Nothing was released: version \(version) cannot name a release, whose tag takes only letters, digits, periods, hyphens and underscores. Ask the user for a version such as 1.0.2, set it in apelin-project.json and build again.")
        }
        for package in packages {
            let name = "\(package.packageID)_\(version)_\(package.architecture).deb"
            guard DistributionReleaseRequest.isAssetName(name) else {
                throw ToolArgumentError("Nothing was released: GitHub renames a release file named \(name), so its package ID cannot be released as it is.")
            }
        }
        return tag
    }

    /// The repository the call names, as one of the project's remotes
    /// spells it when it is one; else the project's own on github.com, its
    /// origin first. The commit the tag names has to be there.
    private static func repository(_ arguments: JSONValue, facts: PackageReleaseFacts) throws -> String {
        guard let named = arguments.argNonEmptyString(repositoryKey)?.trimmingCharacters(in: .whitespaces) else {
            guard let origin = facts.githubRemotes.first else {
                throw ToolArgumentError("Nothing was released: the project has no remote on github.com. Ask the user which GitHub repository (owner/name) the release goes to; its commit must be pushed there first.")
            }
            return origin
        }
        guard GitHubName.isFullName(named) else {
            throw ToolArgumentError("Nothing was released: name the GitHub repository as owner/name, exactly as the user named it, such as octocat/hello-world.")
        }
        return facts.githubRemotes.first { $0.lowercased() == named.lowercased() } ?? named
    }

    /// The notes, nil when the call gives none; checked as public text.
    private static func notes(_ arguments: JSONValue) throws -> String? {
        guard let notes = arguments.argNonEmptyString(notesKey),
              !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        guard notes.utf8.count <= DistributionReleaseRequest.maximumNotesBytes else {
            throw ToolArgumentError("Nothing was released: the notes are at most \(DistributionReleaseRequest.maximumNotesBytes / 1024) KB.")
        }
        if let kind = FeedbackRules.privateData(in: notes) {
            throw ToolArgumentError("Nothing was released: the notes hold \(kind), which a public release must not carry; leave it out.")
        }
        return notes
    }

    /// What the model hears without a GitHub sign-in, or with one GitHub
    /// refused.
    public static let signInNeeded = "Nothing was released: GitHub authorization is needed. Ask the user to Sign In with GitHub in Settings ▸ Git, then release again."
}
