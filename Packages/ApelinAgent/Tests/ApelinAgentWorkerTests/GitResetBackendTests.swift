import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("ChannelHostBackend's reset to a remote")
struct GitResetBackendTests {
    static let remoteCommit = String(repeating: "a", count: 40)
    static let head = String(repeating: "b", count: 40)

    static let preview = GitResetPreview(
        remote: "origin",
        url: "https://github.com/owngoal-dev/Pineora.git",
        branch: "main",
        remoteCommit: remoteCommit,
        remoteSubject: "Add the settings pane",
        head: head,
        currentBranch: "main",
        unrelatedHistories: true,
        lostCommitCount: 12,
        lostCommits: (1 ... 12).map { GitCommitLine(commit: String(repeating: "c", count: 40), subject: "Mine \($0)") },
        changedFileCount: 1,
        changedFiles: [GitStatusEntry(path: "Sources/Tweak.m", index: " ", worktree: "M")],
        projectFile: .repositoryWithProjectID,
    )

    @Test
    func `the preview is read to its end, and the reset carries what it showed`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitRemoteList, reply: GitRemoteListResponse(remotes: [
            GitRemoteSummary(name: "origin", url: "https://github.com/owngoal-dev/Pineora.git"),
        ]))
        fixture.host.on(.gitResetPreview, reply: TaskHandle(taskID: TaskID("preview"), kind: .environment))
        fixture.host.on(.gitResetToRemote, reply: TaskHandle(taskID: TaskID("reset"), kind: .environment))
        fixture.host.on(.environmentAttach) { request in
            let attach = try request.decode(EnvironmentAttachRequest.self)
            if attach.taskID == TaskID("preview") {
                return try (batch("preview", [("result", ApelinCore.JSONValue(encoding: Self.preview)), stateEvent(.succeeded)]), [])
            }
            return (batch("reset", [
                ("result", .object([
                    "remote": .string("origin"), "branch": .string("main"), "commit": .string(Self.remoteCommit),
                    "previousHead": .string(Self.head), "backupBranch": .string("apelin-backup/20261031-120000"),
                    "projectFile": .string("repositoryWithProjectID"),
                ])),
                stateEvent(.succeeded),
            ]), [])
        }

        let preview = try await fixture.backend.gitResetPreview(GitResetPreviewToolRequest(context: fixture.context(), remote: "origin", branch: nil))
        let card = preview.approval
        #expect(!preview.upToDate)
        #expect(card.projectID == fixture.project.id)
        #expect(card.remoteCommit == Self.remoteCommit && card.head == Self.head)
        #expect(card.url == "https://github.com/owngoal-dev/Pineora.git")
        #expect(card.lostCommitCount == 12 && card.lostCommits.count == 10, "the card lists a few, counts them all")
        #expect(card.changedFiles == ["Sources/Tweak.m"])

        let reset = try await fixture.backend.gitResetToRemote(GitResetToolRequest(context: fixture.context(), approval: card))
        let sent = try #require(fixture.host.requests(GitResetToRemoteRequest.self).first)
        #expect(sent.projectID == fixture.project.id)
        #expect(sent.remote == "origin" && sent.branch == "main")
        #expect(sent.expectedRemoteCommit == Self.remoteCommit)
        #expect(sent.expectedHead == Self.head)
        #expect(sent.expectedURL == "https://github.com/owngoal-dev/Pineora.git")
        #expect(reset.backupBranch == "apelin-backup/20261031-120000")
        #expect(reset.projectFile?.contains("this project's own projectID") == true)
    }

    @Test
    func `the approval carries what the host matches the reset to`() throws {
        let card = ChannelHostBackend.approval(Self.preview, projectID: "p")
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "git_reset_to_remote", arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "Makes this project exactly origin/main.", detail: .resetToRemote(card),
            allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let detail = try #require(payload["detail"]?["resetToRemote"])
        #expect(detail["projectID"]?.stringValue == "p")
        #expect(detail["remote"]?.stringValue == "origin")
        #expect(detail["url"]?.stringValue == "https://github.com/owngoal-dev/Pineora.git")
        #expect(detail["branch"]?.stringValue == "main")
        #expect(detail["remoteCommit"]?.stringValue == Self.remoteCommit)
        #expect(detail["head"]?.stringValue == Self.head)
        #expect(payload["allowsSessionScope"] == ApelinCore.JSONValue.bool(false))
    }

    @Test
    func `a reset the state moved under is told to ask again`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitResetToRemote, reply: TaskHandle(taskID: TaskID("reset"), kind: .environment))
        fixture.host.on(.environmentAttach, reply: batch("reset", [stateEvent(.failed, "conflict: origin/main is at 1234567 now")]))
        let card = ChannelHostBackend.approval(Self.preview, projectID: fixture.project.id)
        do {
            _ = try await fixture.backend.gitResetToRemote(GitResetToolRequest(context: fixture.context(), approval: card))
            Issue.record("the reset went through")
        } catch let failure as GitToolFailure {
            #expect(failure.message.contains("Nothing was changed"))
            #expect(failure.message.contains("git_reset_to_remote again"))
        }
    }
}
