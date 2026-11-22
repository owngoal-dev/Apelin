import ApelinAgent
import ApelinCore
import ApelinProtocol
import Foundation

/// apelin_package_release → `distributionRelease` with every file's digest
/// and the repository, tag, commit and notes the card named, read to its
/// end. What the tool checks before anyone is asked is the session
/// project's commit and remotes (`gitStatus`, `gitRemoteList`, its own
/// project's as every agent git call is), whether a github.com sign-in is
/// saved (`gitSettings`) and each build's record, read as mobile from the
/// data folder (`Builds/artifacts/<id>.json`).
extension ChannelHostBackend {
    public func packageReleaseFacts(_ request: PackageReleaseFactsRequest) async throws -> PackageReleaseFacts {
        let projectID = request.context.project.id
        let status = try? await service.gitStatus(projectID: projectID)
        let remotes = await (try? service.gitRemoteList(projectID: projectID))?.remotes ?? []
        var github: [String] = []
        for remote in remotes.sorted(by: { $0.name == "origin" && $1.name != "origin" }) {
            guard let url = remote.url, let fullName = GitHubName.fullName(remoteURL: url),
                  !github.contains(where: { $0.lowercased() == fullName.lowercased() })
            else { continue }
            github.append(fullName)
        }
        let settings = try? await service.gitSettings()
        return PackageReleaseFacts(
            commit: status?.head,
            branch: status?.branch,
            githubRemotes: github,
            signedIn: settings.map { $0.credentials.contains { $0.host == "github.com" } },
            builds: request.buildIDs.map { packageRecord($0) },
        )
    }

    /// Without a github.com sign-in, or with one GitHub refused, the model
    /// hears where the user signs in, read from the reply's reason; any
    /// other refusal is the host's or apelin-environment's, in their words.
    public func releasePackages(_ request: PackageReleaseToolRequest) async throws -> PackageReleaseToolResponse {
        let release = request.release
        let handle: TaskHandle
        do {
            handle = try await service.distributionRelease(DistributionReleaseRequest(
                projectID: release.projectID,
                repository: release.repository,
                files: release.packages.map(\.file),
                digests: release.packages.map(\.digest),
                tag: release.tag,
                commit: release.commit,
                notes: release.notes,
            ))
        } catch let error as ApelinError {
            throw Self.releaseFailure(message: error.message, reason: error.reason?.rawValue, started: false)
        }
        var result: ApelinCore.JSONValue?
        var reason: String?
        let end = try await read(handle) { event in
            if event.kind == "result" {
                result = event.payload
            } else if event.kind == TaskEvent.stateKind {
                result = event.payload?["result"] ?? result
                reason = event.payload?["reason"]?.stringValue
            }
        }
        switch end.state {
        case .succeeded:
            guard let done = try? result?.decode(DistributionReleaseResult.self) else {
                throw PackageReleaseToolFailure(message: "The release finished, but what it did could not be read. Check \(release.repository)'s releases on GitHub.")
            }
            return Self.released(done)
        case .cancelled, .interrupted:
            throw PackageReleaseToolFailure(message: "Releasing stopped before it finished. Release the same builds again: a file the release holds already with the same bytes is left as it is, and a draft left behind is filled in and published.")
        default:
            throw Self.releaseFailure(message: GitFailure.split(end.message).1, reason: reason, started: true)
        }
    }

    /// A refusal before the task started released nothing; a failure once
    /// it ran may have left a draft, which the next release fills in.
    static func releaseFailure(message: String, reason: String?, started: Bool) -> PackageReleaseToolFailure {
        if reason == ApelinError.Reason.authenticationRequired.rawValue {
            return PackageReleaseToolFailure(message: PackageRelease.signInNeeded)
        }
        let text = message.isEmpty ? "no reason was given." : message
        return PackageReleaseToolFailure(message: (started ? "The release did not finish: " : "Nothing was released: ") + text)
    }

    /// What the task's result names, and what happens next.
    static func released(_ result: DistributionReleaseResult) -> PackageReleaseToolResponse {
        let next = if result.uploaded.isEmpty, result.checksums == "unchanged", !result.created {
            "The release \(result.tag) held every package already, with the same bytes; nothing new was uploaded. Give the user its link."
        } else {
            "The release \(result.tag) is published on GitHub; give the user its link. A source that indexes the repository's newest stable release takes it the next time it runs."
        }
        return PackageReleaseToolResponse(
            repository: result.repository,
            tag: result.tag,
            commit: result.commit,
            url: result.url,
            uploaded: result.uploaded,
            alreadyThere: result.skipped,
            checksums: result.checksums,
            created: result.created,
            warnings: result.warnings,
            next: next,
        )
    }
}
