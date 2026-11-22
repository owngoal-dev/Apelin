import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("apelin_package_release is one distributionRelease task")
struct ReleaseBackendTests {
    private static let commit = String(repeating: "d", count: 40)

    private static let release = PackageReleaseApproval(
        projectID: "p-clock",
        repository: "someone/clock",
        tag: "v1.0",
        commit: commit,
        notes: "First release.",
        packages: [
            .init(buildID: "b-hide", packageID: "com.example.clock", version: "1.0", architecture: "iphoneos-arm64e",
                  bootstrap: "roothide", file: "/data/Builds/p-clock/b-hide/a.deb", digest: "sha256:" + String(repeating: "a", count: 64)),
            .init(buildID: "b-less", packageID: "com.example.clock", version: "1.0", architecture: "iphoneos-arm64",
                  bootstrap: "rootless", file: "/data/Builds/p-clock/b-less/b.deb", digest: "sha256:" + String(repeating: "b", count: 64)),
        ],
    )

    @Test
    func `before asking it reads the project's commit and GitHub remotes, the sign-in and each build's record`() async throws {
        let data = try PublishBackendTests.DataFolder()
        defer { data.remove() }
        let deb = try data.build("b-hide")
        data.host.on(.gitStatus, reply: GitStatusResponse(branch: "main", head: Self.commit))
        data.host.on(.gitRemoteList, reply: GitRemoteListResponse(remotes: [
            GitRemoteSummary(name: "backup", url: "https://github.com/someone/backup.git"),
            GitRemoteSummary(name: "mirror", url: "https://gitlab.com/someone/clock.git"),
            GitRemoteSummary(name: "origin", url: "https://github.com/someone/clock"),
        ]))
        data.host.on(.gitSettings, reply: GitSettingsResponse(credentials: [GitCredentialSummary(host: "github.com", username: "someone")]))

        let facts = try await data.backend.packageReleaseFacts(PackageReleaseFactsRequest(
            context: data.context(),
            buildIDs: ["b-hide", "b-nothing"],
        ))
        #expect(facts.commit == Self.commit)
        #expect(facts.branch == "main")
        #expect(facts.githubRemotes == ["someone/clock", "someone/backup"], "origin first, github.com only")
        #expect(facts.signedIn == true)
        #expect(facts.builds.first??.file == deb)
        #expect(facts.builds.last == .some(nil))
        let projects = data.host.requests(GitStatusRequest.self).map(\.projectID)
            + data.host.requests(GitRemoteListRequest.self).map(\.projectID)
        #expect(projects == ["p-clock", "p-clock"], "the session's own project, as every agent git call is")
    }

    @Test
    func `the release goes in one distributionRelease with the card's tag, commit, notes and digests, read to the end`() async throws {
        let data = try PublishBackendTests.DataFolder()
        defer { data.remove() }
        data.host.on(.distributionRelease, reply: TaskHandle(taskID: TaskID("release-task"), kind: .environment))
        let done = DistributionReleaseResult(
            repository: "someone/clock",
            tag: "v1.0",
            commit: Self.commit,
            url: "https://github.com/someone/clock/releases/tag/v1.0",
            uploaded: ["com.example.clock_1.0_iphoneos-arm64e.deb"],
            skipped: ["com.example.clock_1.0_iphoneos-arm64.deb"],
            checksums: "replaced",
            created: false,
        )
        try data.host.on(.environmentAttach, reply: batch("release-task", [
            ("stage", .object(["stage": .string("fetching")])),
            ("result", ApelinCore.JSONValue(encoding: done)),
            stateEvent(.succeeded),
        ]))
        let response = try await data.backend.releasePackages(PackageReleaseToolRequest(context: data.context(), release: Self.release))

        let sent = try #require(data.host.requests(DistributionReleaseRequest.self).first)
        #expect(data.host.requests.map(\.operation) == [.distributionRelease, .environmentAttach])
        #expect(sent.projectID == "p-clock")
        #expect(sent.repository == "someone/clock")
        #expect(sent.files == Self.release.packages.map(\.file))
        #expect(sent.digests == Self.release.packages.map(\.digest))
        #expect(sent.tag == "v1.0" && sent.commit == Self.commit && sent.notes == "First release.")
        #expect(response.url == "https://github.com/someone/clock/releases/tag/v1.0")
        #expect(response.uploaded == ["com.example.clock_1.0_iphoneos-arm64e.deb"])
        #expect(response.alreadyThere == ["com.example.clock_1.0_iphoneos-arm64.deb"])
        #expect(response.checksums == "replaced")
        #expect(response.next.contains("give the user its link"))
    }

    @Test
    func `a refusal says what to do: Sign In with GitHub by the reason, else the host's words`() async throws {
        let data = try PublishBackendTests.DataFolder()
        defer { data.remove() }
        data.host.on(.distributionRelease) { _ in
            throw ApelinError(.denied, "Sign in with GitHub in Settings ▸ Git first.", reason: .authenticationRequired)
        }
        await #expect {
            _ = try await data.backend.releasePackages(PackageReleaseToolRequest(context: data.context(), release: Self.release))
        } throws: { error in
            (error as? PackageReleaseToolFailure)?.message == PackageRelease.signInNeeded
        }

        data.host.on(.distributionRelease, reply: TaskHandle(taskID: TaskID("release-task"), kind: .environment))
        data.host.on(.environmentAttach, reply: batch("release-task", [
            stateEvent(.failed, "conflict: ddddddd, the commit Clock is at, is on no branch of someone/clock. Push it there first, then release again."),
        ]))
        await #expect {
            _ = try await data.backend.releasePackages(PackageReleaseToolRequest(context: data.context(), release: Self.release))
        } throws: { error in
            (error as? PackageReleaseToolFailure)?.message
                == "The release did not finish: ddddddd, the commit Clock is at, is on no branch of someone/clock. Push it there first, then release again."
        }
    }

    @Test
    func `the approval carries the project, repository, tag, commit, notes, files and digests the host matches`() throws {
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "apelin_package_release", arguments: "{}", workingDirectory: ".",
            projectID: "p-clock", fingerprint: "f", reason: "Publishes these 2 packages on GitHub.",
            detail: .packageRelease(Self.release), allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let detail = try #require(payload["detail"]?["packageRelease"])
        #expect(detail["projectID"] == .string("p-clock"))
        #expect(detail["repository"] == .string("someone/clock"))
        #expect(detail["tag"] == .string("v1.0"))
        #expect(detail["commit"] == .string(Self.commit))
        #expect(detail["notes"] == .string("First release."))
        guard case let .array(packages)? = detail["packages"] else {
            Issue.record("no packages"); return
        }
        #expect(packages.map { $0["file"]?.stringValue } == Self.release.packages.map(\.file))
        #expect(packages.map { $0["digest"]?.stringValue } == Self.release.packages.map(\.digest))
        #expect(payload["allowsSessionScope"] == .bool(false))
    }
}
