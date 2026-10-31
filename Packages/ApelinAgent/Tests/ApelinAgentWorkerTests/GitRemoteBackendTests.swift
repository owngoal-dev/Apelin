import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("ChannelHostBackend's remotes")
struct GitRemoteBackendTests {
    @Test
    func `the remote tools are one request each on the session's project`() async throws {
        let fixture = try Fixture()
        let origin = GitRemoteSummary(name: "origin", url: "https://github.com/owngoal-dev/Pineora.git")
        fixture.host.on(.gitRemoteList, reply: GitRemoteListResponse(remotes: [origin]))
        fixture.host.on(.gitRemoteSet, reply: GitRemoteSetResponse(remote: origin, previousURL: "https://example.com/old.git"))
        fixture.host.on(.gitRemoteRemove, reply: Acknowledged())

        let listed = try await fixture.backend.gitRemoteList(GitRemoteListToolRequest(context: fixture.context()))
        let set = try await fixture.backend.gitRemoteSet(GitRemoteSetToolRequest(
            context: fixture.context(),
            name: "origin",
            url: "https://github.com/owngoal-dev/Pineora.git",
        ))
        _ = try await fixture.backend.gitRemoteRemove(GitRemoteRemoveToolRequest(context: fixture.context(), name: "upstream"))

        #expect(fixture.host.requests.map(\.operation) == [.gitRemoteList, .gitRemoteSet, .gitRemoteRemove, .gitRemoteList])
        #expect(fixture.host.requests(GitRemoteListRequest.self).allSatisfy { $0.projectID == fixture.project.id })
        let sent = try #require(fixture.host.requests(GitRemoteSetRequest.self).first)
        #expect(sent.projectID == fixture.project.id)
        #expect(sent.name == "origin" && sent.url == "https://github.com/owngoal-dev/Pineora.git")
        #expect(fixture.host.requests(GitRemoteRemoveRequest.self).first?.name == "upstream")
        #expect(listed.remotes == [GitRemoteToolEntry(name: "origin", url: "https://github.com/owngoal-dev/Pineora.git")])
        #expect(set.previousURL == "https://example.com/old.git")
    }

    @Test
    func `a fetch of a remote the project lacks says how to add one`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitFetch) { _ in throw ApelinError(.notFound, "no remote \"upstream\"", reason: .noSuchRemote) }
        do {
            _ = try await fixture.backend.gitFetch(GitRemoteToolRequest(context: fixture.context(), remote: "upstream"))
            Issue.record("the fetch went through")
        } catch let failure as GitToolFailure {
            #expect(failure.message.contains("git_remote_set"))
            #expect(failure.message.contains("git_remote_list"))
        }
    }
}
