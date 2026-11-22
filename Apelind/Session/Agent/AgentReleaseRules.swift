import ApelinCore
import ApelinProtocol
import Foundation

/// An agent's `distributionRelease` (apelin_package_release; owner,
/// 2026-11-22, issue #77): a project's release builds published as a
/// GitHub Release of a repository the user names, tagged at the project's
/// commit, where a source that indexes releases takes them for everyone
/// who adds it, so, like a publication to the package repository, it asks
/// under Confirm every time. In every mode the request is its own
/// session's project's, names the repository, the tag, the commit and each
/// package's digest, and each file is a package a build of that project
/// reported to this host (ArtifactRegistry) with that digest: the agent
/// releases only what Apelin built, as it was built, never a `.deb` it
/// made itself or another project's.
/// Under Confirm each one spends an approval the app gave this session
/// whose own `approvalRequested` names exactly that repository, tag,
/// commit, notes and those files and digests, in order
/// (`detail.packageRelease` {projectID, repository, tag, commit, notes?,
/// packages: [{buildID, packageID, version, architecture, bootstrap, file,
/// digest}]}), once, never for the session; Relaxed and Full release as
/// they push. apelin-environment holds each file to its digest again as it
/// copies it, and the project to that commit.
enum AgentReleaseRules {
    static let detailKey = "packageRelease"

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this release.
    static func covers(_ release: DistributionReleaseRequest, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.packageRelease.rawValue,
              let detail = asked["detail"]?[detailKey],
              detail["projectID"]?.stringValue == release.projectID,
              detail["repository"]?.stringValue == release.repository,
              let tag = release.tag, detail["tag"]?.stringValue == tag,
              let commit = release.commit, detail["commit"]?.stringValue == commit,
              detail["notes"]?.stringValue == release.notes,
              case let .array(packages)? = detail["packages"], packages.count == release.files.count,
              release.digests.count == release.files.count
        else { return false }
        return zip(packages, zip(release.files, release.digests)).allSatisfy { package, sent in
            package["file"]?.stringValue == sent.0 && package["digest"]?.stringValue == sent.1
        }
    }

    /// Nil when the session may release it, else why not; under Confirm the
    /// approval that covers it is spent.
    static func authorize(
        _ release: DistributionReleaseRequest,
        session: String?,
        registry: TaskRegistry,
        artifacts: ArtifactRegistry,
    ) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard release.projectID == entry.project.id || release.projectID == entry.project.name else {
            return ApelinError(.denied, "an agent releases only its own project's builds, from that project's conversation")
        }
        guard release.tag != nil, release.commit != nil, release.digests.count == release.files.count else {
            return ApelinError(.badRequest, "an agent's release names the tag, the commit and each package's digest")
        }
        for (file, digest) in zip(release.files, release.digests) {
            guard let built = await artifacts.artifact(path: file), InstallDigest.normalized(digest) == built.digest,
                  built.projectID == entry.project.id
            else {
                return ApelinError(
                    .denied,
                    "an agent releases only packages its project's builds made, as they made them: \((file as NSString).lastPathComponent) is not one with that digest; build it again with apelin_project_build",
                )
            }
        }
        guard entry.mode.asks else { return nil }
        guard await AgentApprovals.spend(entry: entry, registry: registry, covers: { covers(release, asked: $0) }) else {
            let count = release.files.count == 1 ? "this package" : "these \(release.files.count) packages"
            return ApelinError(
                .denied,
                "approval required: the user has not approved releasing \(count) as \(release.tag ?? "a release") on \(release.repository)",
            )
        }
        return nil
    }
}
