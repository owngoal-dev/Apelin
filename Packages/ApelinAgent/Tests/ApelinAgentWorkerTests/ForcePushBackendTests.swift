import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

/// A forced push through the host (issue #29): the fetch that compares the
/// branch, the lease on the push, the approval's shape the host matches,
/// and what a refused lease tells the model.
@Suite("ChannelHostBackend's forced push")
struct ForcePushBackendTests {
    private static let theirs = String(repeating: "a", count: 40)
    private static let mine = String(repeating: "b", count: 40)

    @Test
    func `a fetch with a branch asks for the comparison and reads it back`() async throws {
        let fixture = try Fixture()
        let comparison = GitBranchComparison(
            branch: "main", local: Self.mine, localSubject: "Mine", remote: Self.theirs,
            pushURL: "https://github.com/owner/clock.git",
            remoteOnly: [GitCommitSummary(commit: Self.theirs, subject: "Theirs")], remoteOnlyCount: 1,
        )
        fixture.host.on(.gitFetch, reply: TaskHandle(taskID: TaskID("fetch-task"), kind: .environment))
        try fixture.host.on(.environmentAttach, reply: batch("fetch-task", [
            ("result", .object([
                "remote": .string("origin"), "updated": .array([]),
                "comparison": ApelinCore.JSONValue(encoding: comparison),
            ])),
            stateEvent(.succeeded),
        ]))
        let fetched = try await fixture.backend.gitFetch(GitRemoteToolRequest(context: fixture.context(), branch: "main"))
        let sent = try #require(fixture.host.requests(GitFetchRequest.self).first)
        #expect(sent.branch == "main")
        #expect(sent.projectID == fixture.project.id)
        #expect(fetched.comparison == comparison)
    }

    @Test
    func `a leased push sends the lease and reports what it replaced`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitPush, reply: TaskHandle(taskID: TaskID("push-task"), kind: .environment))
        fixture.host.on(.environmentAttach, reply: batch("push-task", [
            ("lease", .object([
                "branch": .string("main"), "expectedCommit": .string(Self.theirs), "found": .string(Self.theirs),
                "held": .bool(true),
            ])),
            ("result", .object([
                "remote": .string("origin"), "branch": .string("main"), "commit": .string(Self.mine),
                "from": .string(Self.theirs), "forced": .bool(true),
            ])),
            stateEvent(.succeeded),
        ]))
        let lease = GitPushLease(expectedCommit: Self.theirs, localCommit: Self.mine)
        let pushed = try await fixture.backend.gitPush(GitRemoteToolRequest(
            context: fixture.context(), branch: "main", url: "https://github.com/owner/clock.git", lease: lease,
        ))
        let sent = try #require(fixture.host.requests(GitPushRequest.self).first)
        #expect(sent.forceWithLease == lease)
        #expect(sent.branch == "main" && sent.url == "https://github.com/owner/clock.git")
        #expect(pushed == GitTaskToolResponse(
            remote: "origin", branch: "main", commit: Self.mine, from: Self.theirs, forced: true,
        ))
    }

    @Test
    func `a lease that did not hold says nothing was pushed and to ask again`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitPush, reply: TaskHandle(taskID: TaskID("push-task"), kind: .environment))
        fixture.host.on(.environmentAttach, reply: batch("push-task", [
            (TaskEvent.stateKind, .object([
                "state": .string("failed"),
                "message": .string("conflict: origin's main is at \(Self.mine) now, not \(Self.theirs)"),
                "reason": .string("remoteChanged"),
            ])),
        ]))
        let lease = GitPushLease(expectedCommit: Self.theirs, localCommit: Self.mine)
        await #expect {
            _ = try await fixture.backend.gitPush(GitRemoteToolRequest(context: fixture.context(), branch: "main", lease: lease))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.hasPrefix("forced git push failed: origin's main is at")
                && message.contains("nothing was pushed") && message.contains("asks them again")
                && !message.contains("pull first")
        }
    }

    @Test
    func `a forced push the remote refuses keeps its words and is not worked around`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitPush, reply: TaskHandle(taskID: TaskID("push-task"), kind: .environment))
        fixture.host.on(.environmentAttach, reply: batch("push-task", [
            (TaskEvent.stateKind, .object([
                "state": .string("failed"),
                "message": .string("conflict: origin refused refs/heads/main: protected branch hook declined"),
                "reason": .string("rejected"),
            ])),
        ]))
        let lease = GitPushLease(expectedCommit: Self.theirs, localCommit: Self.mine)
        await #expect {
            _ = try await fixture.backend.gitPush(GitRemoteToolRequest(context: fixture.context(), branch: "main", lease: lease))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.contains("protected branch hook declined") && message.contains("never try to get around it")
        }
    }

    /// What the host matches an agent's forced push to: AgentForcePushRules
    /// reads `detail.forcePush` with these keys (the session host's checks
    /// hold that shape).
    @Test
    func `a forced push approval carries the push and its lease in the event`() throws {
        let force = ForcePushApproval(
            projectID: "p", remote: "origin", url: "https://github.com/owner/clock.git", branch: "main",
            expectedCommit: Self.theirs, localCommit: Self.mine, localSubject: "Mine",
            overwritten: [GitCommitSummary(commit: Self.theirs, subject: "Theirs")], overwrittenCount: 1,
        )
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "git_push", arguments: #"{"force_with_lease":true}"#, workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "Force-pushes main to origin, overwriting its history there.",
            detail: .forcePush(force), allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let detail = try #require(payload["detail"]?["forcePush"])
        #expect(detail["projectID"] == .string("p"))
        #expect(detail["remote"] == .string("origin"))
        #expect(detail["url"] == .string("https://github.com/owner/clock.git"))
        #expect(detail["branch"] == .string("main"))
        #expect(detail["expectedCommit"] == .string(Self.theirs))
        #expect(detail["localCommit"] == .string(Self.mine))
        #expect(detail["overwrittenCount"] == .number(1))
        guard case let .array(overwritten)? = detail["overwritten"] else {
            Issue.record("no overwritten commits"); return
        }
        #expect(overwritten.first?["subject"] == .string("Theirs"))
        #expect(payload["allowsSessionScope"] == .bool(false))
    }
}
