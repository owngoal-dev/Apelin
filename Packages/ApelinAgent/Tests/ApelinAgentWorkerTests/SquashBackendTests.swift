import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

/// A squash through the host: one request, a preview or the squash itself,
/// on the session's project; the approval's shape the host matches; and
/// what a moved head tells the model.
@Suite("ChannelHostBackend's squash")
struct SquashBackendTests {
    private static let base = String(repeating: "a", count: 40)
    private static let head = String(repeating: "d", count: 40)

    @Test
    func `a preview and a squash are one gitSquash request each on the session's project`() async throws {
        let fixture = try Fixture()
        let answer = GitSquashResponse(
            branch: "main", previousHead: Self.head, base: Self.base,
            commits: [GitCommitSummary(commit: Self.head, subject: "Fix the hand")], count: 2,
        )
        fixture.host.on(.gitSquash, reply: answer)
        let preview = try await fixture.backend.gitSquash(GitSquashToolRequest(context: fixture.context(), count: 2, preview: true))
        _ = try await fixture.backend.gitSquash(GitSquashToolRequest(
            context: fixture.context(), base: Self.base, message: "Add the clock", expectedHead: Self.head, preview: false,
        ))
        let sent = fixture.host.requests(GitSquashRequest.self)
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.projectID == fixture.project.id })
        #expect(sent.first?.preview == true && sent.first?.count == 2 && sent.first?.base == nil)
        #expect(sent.last?.preview == nil, "a squash is no preview")
        #expect(sent.last?.base == Self.base && sent.last?.expectedHead == Self.head && sent.last?.message == "Add the clock")
        #expect(preview == answer)
    }

    @Test
    func `a head that moved says nothing was squashed and to ask again`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitSquash) { _ in
            throw ApelinError(.conflict, "main is at \(Self.base) now, not \(Self.head): nothing was squashed", reason: .headChanged)
        }
        await #expect {
            _ = try await fixture.backend.gitSquash(GitSquashToolRequest(
                context: fixture.context(), base: Self.base, message: "x", expectedHead: Self.head, preview: false,
            ))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.hasPrefix("git squash failed: main is at") && message.contains("call git_squash again")
        }
    }

    /// What the host matches an agent's squash to: AgentSquashRules reads
    /// `detail.squash` with these keys (the session host's checks hold that
    /// shape).
    @Test
    func `a squash approval carries the base, head and message in the event`() throws {
        let squash = SquashApproval(
            projectID: "p", branch: "main", base: Self.base, expectedHead: Self.head, message: "Add the clock",
            commits: [GitCommitSummary(commit: Self.head, subject: "Fix the hand")], count: 2,
            upstream: "origin/main", published: 1,
        )
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "git_squash", arguments: #"{"count":2}"#, workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "Squashes 2 commits on main into one.",
            detail: .squash(squash), allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let detail = try #require(payload["detail"]?["squash"])
        #expect(detail["projectID"] == .string("p"))
        #expect(detail["branch"] == .string("main"))
        #expect(detail["base"] == .string(Self.base))
        #expect(detail["expectedHead"] == .string(Self.head))
        #expect(detail["message"] == .string("Add the clock"))
        #expect(detail["count"] == .number(2))
        #expect(detail["upstream"] == .string("origin/main"))
        #expect(detail["published"] == .number(1))
        #expect(payload["allowsSessionScope"] == .bool(false))
    }
}
