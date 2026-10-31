@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// The mock host's preview and reset, recorded as `other`: a remote named
/// "current" is the project already.
extension MockBackend {
    static let remoteCommit = String(repeating: "a", count: 40)
    static let head = String(repeating: "b", count: 40)

    static func resetCard(remote: String, branch: String) -> ResetToRemoteApproval {
        ResetToRemoteApproval(
            projectID: "p",
            remote: remote,
            url: "https://github.com/owngoal-dev/Pineora.git",
            branch: branch,
            remoteCommit: remoteCommit,
            remoteSubject: "Add the settings pane",
            head: head,
            currentBranch: "main",
            unrelatedHistories: true,
            lostCommitCount: 7,
            lostCommits: (1 ... 7).map { .init(commit: String(repeating: "\($0)", count: 40), subject: "Local change \($0)") },
            changedFileCount: 2,
            changedFiles: ["Sources/Tweak.m", "apelin-project.json"],
            overwrittenFileCount: 1,
            overwrittenFiles: ["notes.txt"],
            projectFile: "repositoryWithProjectID",
        )
    }

    func gitResetPreview(_ request: GitResetPreviewToolRequest) -> GitResetPreviewToolResponse {
        calls.append(.other("gitResetPreview \(request.remote) \(request.branch ?? "default")"))
        let card = Self.resetCard(remote: request.remote, branch: request.branch ?? "main")
        return GitResetPreviewToolResponse(approval: card, upToDate: request.remote == "current")
    }

    func gitResetToRemote(_ request: GitResetToolRequest) -> GitResetToolResponse {
        let card = request.approval
        calls.append(.other("gitResetToRemote \(card.remote) \(card.branch) \(card.remoteCommit) \(card.head ?? "none") \(card.url) \(request.context.approval)"))
        return GitResetToolResponse(
            remote: card.remote,
            branch: card.branch,
            commit: card.remoteCommit,
            previousHead: card.head,
            backupBranch: "apelin-backup/20261031-120000",
            projectFile: nil,
        )
    }
}

@Suite("git_reset_to_remote")
struct GitResetToolTests {
    private func resets(_ backend: MockBackend) async -> [String] {
        await backend.calls.compactMap { call -> String? in
            guard case let .other(text) = call, text.hasPrefix("gitResetToRemote") else { return nil }
            return text
        }
    }

    @Test
    func `the tool is the project's, a system one, kept to the user's explicit request`() {
        let tool = AgentToolName.gitResetToRemote
        #expect(tool.rawValue == "git_reset_to_remote")
        #expect(tool.risk == .system)
        #expect(tool.isProjectOnly)
        #expect(!ApprovalPresets.default.readTools.contains(tool) && !ApprovalPresets.default.systemTools.contains(tool))
        let summary = tool.summary
        #expect(summary.contains("only when the user explicitly asks for the project to match the remote"))
        #expect(summary.contains("in every mode, Full included"))
        #expect(summary.contains("never to resolve a conflict or get past a refused pull or push"))
        #expect(summary.contains("apelin-backup/"))
        guard case let .object(schema) = ToolReason.adding(to: tool.parameters), case let .object(properties)? = schema["properties"] else {
            Issue.record("no schema"); return
        }
        #expect(Set(properties.keys) == ["remote", "branch", "reason"])
    }

    @Test
    func `it asks on a card in Strict, Relaxed and Full alike, never for the session`() async throws {
        for mode in [ApprovalMode.confirm, .relaxed, .full] {
            let harness = try DigestApprovalTests.Harness(mode: mode)
            defer { harness.home.remove() }
            let (result, first) = try await harness.run(.gitResetToRemote, [:], answering: .approve(.session))
            let request = try #require(first.first, "\(mode)")
            #expect(first.count == 1, "\(mode)")
            #expect(request.tool == "git_reset_to_remote")
            #expect(!request.allowsSessionScope, "\(mode)")
            #expect(request.detail == .resetToRemote(MockBackend.resetCard(remote: "origin", branch: "main")), "\(mode)")
            #expect(request.reason.contains("7 local commits leave the branch"), "\(request.reason)")
            #expect(request.reason.contains("“Local change 1”"))
            #expect(request.reason.contains("nothing in common"))
            #expect(request.reason.contains("Sources/Tweak.m"))
            #expect(request.reason.contains("notes.txt"))
            #expect(request.reason.contains("apelin-backup/"))
            #expect(request.reason.contains("in every mode"))
            #expect(result.content.contains {
                if case let .text(text) = $0 {
                    text.text.contains("apelin-backup/20261031-120000")
                } else {
                    false
                }
            })

            // Even after a "for this session" answer, the next reset asks again.
            let (_, second) = try await harness.run(.gitResetToRemote, [:])
            #expect(second.count == 1, "\(mode)")
            let sent = await resets(harness.backend)
            #expect(sent.count == 2, "\(mode)")
            #expect(sent.allSatisfy {
                $0.contains("origin main \(MockBackend.remoteCommit) \(MockBackend.head) https://github.com/owngoal-dev/Pineora.git user(")
            }, "the reset carries what the card showed: \(sent)")
            #expect(!ToolRunner.allowsSessionScope(.local(.gitResetToRemote), detail: .none))
            #expect(!ToolRunner.allowsSessionScope(.local(.shellRun), detail: request.detail))
        }
    }

    @Test
    func `the preview reads the remote and branch the call names before asking`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .full)
        defer { harness.home.remove() }
        let (_, asked) = try await harness.run(.gitResetToRemote, ["remote": "upstream", "branch": "develop"])
        #expect(asked.first?.detail == .resetToRemote(MockBackend.resetCard(remote: "upstream", branch: "develop")))
        let calls = await harness.backend.calls
        #expect(calls.first == .other("gitResetPreview upstream develop"))
    }

    @Test
    func `a declined reset never reaches the host`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .full)
        defer { harness.home.remove() }
        await #expect(throws: ToolDeniedError.self) {
            _ = try await harness.run(.gitResetToRemote, [:], answering: .deny(reason: nil))
        }
        #expect(await resets(harness.backend).isEmpty)
    }

    @Test
    func `nothing to discard is answered without asking, and an address is no remote`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .confirm)
        defer { harness.home.remove() }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.gitResetToRemote, ["remote": "current"]) }
        await #expect(throws: ToolArgumentError.self) {
            _ = try await harness.run(.gitResetToRemote, ["remote": "https://github.com/owngoal-dev/Pineora.git"])
        }
        #expect(await harness.events.events.isEmpty, "nothing is asked")
        #expect(await resets(harness.backend).isEmpty)
    }

    @Test
    func `the prompt and the skill keep it to the user's explicit request`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, skills: [], mcpServers: [])
        #expect(prompt.contains("git_reset_to_remote makes the project exactly a remote's branch and discards local work"))
        #expect(prompt.contains("only when the user explicitly asks"))
        #expect(prompt.contains("never on your own initiative, to resolve a conflict or a refused pull or push"))
        #expect(prompt.contains("In every mode, git_reset_to_remote asks the user each time"))
        let skill = BuiltInSkills.gitWorkflow.body
        #expect(skill.contains("git_reset_to_remote"))
        #expect(skill.contains("Never use it to resolve a conflict"))
    }
}
