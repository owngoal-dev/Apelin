import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("ChannelHostBackend's imports")
struct GitImportBackendTests {
    @Test
    func `an import says what became of apelin-project.json`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitCloneInto, reply: TaskHandle(taskID: TaskID("clone-task"), kind: .environment))
        fixture.host.on(.environmentAttach, reply: batch("clone-task", [
            ("result", .object([
                "branch": .string("main"), "commit": .string("abc"),
                "projectID": .string(fixture.project.id), "projectFile": .string("repositoryWithProjectID"),
            ])),
            stateEvent(.succeeded),
        ]))
        let response = try await fixture.backend.gitClone(GitCloneToolRequest(context: fixture.context(), url: "https://github.com/owngoal-dev/Pineora.git"))
        let note = try #require(response.projectFile)
        #expect(note.contains("this project's own projectID"))
        #expect(note.contains("git_status shows it changed"))
        #expect(ChannelHostBackend.projectFileNote(.project) == nil)
    }
}
