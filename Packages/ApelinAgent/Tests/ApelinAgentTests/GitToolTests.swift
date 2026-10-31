@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("git tools")
struct GitToolTests {
    static let gitTools: [AgentToolName] = [
        .gitStatus, .gitDiff, .gitStage, .gitUnstage, .gitCommit, .gitInit, .gitFetch, .gitPull, .gitPush, .gitClone,
    ]

    private func runner(_ home: TemporaryHome, backend: MockBackend, projectID: String? = nil) throws -> ToolRunner {
        let project = try projectID.map { try ProjectIdentity(id: $0, name: home.project.name) } ?? home.project
        return try ToolRunner(
            sessionID: UUID().uuidString,
            project: project,
            root: ScopedRoot(home.projectURL),
            policy: ApprovalPolicy(mode: .confirm),
            backend: backend,
            digests: MockDigestLedger(),
            gate: ApprovalGate { _ in },
        )
    }

    // MARK: Catalog

    @Test
    func `the catalog names the git tools with their risks`() {
        #expect(Self.gitTools.map(\.rawValue) == [
            "git_status", "git_diff", "git_stage", "git_unstage", "git_commit", "git_init", "git_fetch", "git_pull",
            "git_push", "git_clone",
        ])
        #expect(AgentToolName.gitStatus.risk == .readOnly)
        #expect(AgentToolName.gitDiff.risk == .readOnly)
        for tool in [AgentToolName.gitStage, .gitUnstage, .gitCommit, .gitInit, .gitFetch, .gitPull, .gitClone] {
            #expect(tool.risk == .writeProject, "\(tool.rawValue)")
        }
        #expect(AgentToolName.gitPush.risk == .system)
        for tool in Self.gitTools {
            #expect(tool.isProjectOnly, "\(tool.rawValue)")
            #expect(!tool.summary.isEmpty)
        }
    }

    @Test
    func `git_commit takes no author, and every git tool asks for a reason`() {
        func properties(_ tool: AgentToolName) -> [String: JSONValue] {
            guard case let .object(schema) = ToolReason.adding(to: tool.parameters),
                  case let .object(properties)? = schema["properties"] else { return [:] }
            return properties
        }
        func required(_ tool: AgentToolName) -> [String] {
            guard case let .object(schema) = ToolReason.adding(to: tool.parameters),
                  case let .array(names)? = schema["required"] else { return [] }
            return names.compactMap {
                if case let .string(name) = $0 {
                    name
                } else {
                    nil
                }
            }
        }
        #expect(Set(properties(.gitCommit).keys) == ["message", "all", "reason"])
        #expect(Set(properties(.gitInit).keys) == ["reason"])
        #expect(Set(properties(.gitPush).keys) == ["remote", "branch", "url", "force_with_lease", "reason"])
        #expect(Set(properties(.gitClone).keys) == ["url", "branch", "reason"])
        #expect(Set(properties(.gitDiff).keys) == ["path", "staged", "reason"])
        #expect(required(.gitStage) == ["paths", "reason"])
        for tool in Self.gitTools {
            #expect(required(tool).contains("reason"), "\(tool.rawValue)")
        }
    }

    @Test
    func `a project's chat offers the git tools; General Chat does not`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let project = try runner(home, backend: MockBackend()).agentTools(mcp: []).map(\.name)
        for tool in Self.gitTools {
            #expect(project.contains(tool.rawValue), "\(tool.rawValue)")
        }
        let general = try runner(home, backend: MockBackend(), projectID: "temporary:\(UUID().uuidString)")
            .agentTools(mcp: []).map(\.name)
        for tool in Self.gitTools {
            #expect(!general.contains(tool.rawValue), "\(tool.rawValue)")
        }
        #expect(general.contains("apelin_project_create"))
    }

    // MARK: Approval

    @Test
    func `Confirm reads status and diff as presets and lets project git changes through`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let root = try ScopedRoot(home.projectURL)
        let policy = ApprovalPolicy(mode: .confirm)
        #expect(policy.evaluate(InvocationFacts(tool: .local(.gitStatus)), root: root) == .allow(.preset("git_status")))
        #expect(policy.evaluate(InvocationFacts(tool: .local(.gitDiff)), root: root) == .allow(.preset("git_diff")))
        for tool in [AgentToolName.gitStage, .gitUnstage, .gitCommit, .gitInit, .gitFetch, .gitPull, .gitClone] {
            #expect(policy.evaluate(InvocationFacts(tool: .local(tool)), root: root) == .allow(.notRequired), "\(tool.rawValue)")
        }
        let relaxed = ApprovalPolicy(mode: .relaxed)
        let push = InvocationFacts(tool: .local(.gitPush), push: GitPushTarget(remote: "origin", branch: "main"))
        #expect(relaxed.evaluate(push, root: root) == .allow(.relaxed))
    }

    @Test
    func `Confirm asks for every push, names the remote and branch, and never offers the session`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let root = try ScopedRoot(home.projectURL)
        let facts = InvocationFacts(tool: .local(.gitPush), push: GitPushTarget(remote: "upstream", branch: "feature"))
        guard case let .ask(reason, detail) = ApprovalPolicy(mode: .confirm).evaluate(facts, root: root) else {
            Issue.record("a push should ask"); return
        }
        #expect(detail == .gitPush(remote: "upstream", branch: "feature"))
        #expect(reason.contains("upstream") && reason.contains("feature"))
        #expect(!ToolRunner.allowsSessionScope(.local(.gitPush), detail: detail))
        #expect(!ToolRunner.allowsSessionScope(.local(.gitPush), detail: .none))
    }

    @Test
    func `a push asks each time, with the checked-out branch, and sends that branch`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await harness.backend.setGitBranch("develop")

        let (_, first) = try await harness.run(.gitPush, [:], answering: .approve(.session))
        let request = try #require(first.first)
        #expect(first.count == 1)
        #expect(request.tool == "git_push")
        #expect(request.detail == .gitPush(remote: "origin", branch: "develop"))
        #expect(!request.allowsSessionScope)

        // Even after a "for this session" answer, the same push asks again.
        let (_, second) = try await harness.run(.gitPush, [:])
        #expect(second.count == 1)

        let pushes = await harness.backend.calls.compactMap { call -> String? in
            guard case let .gitPush(remote, branch, _, evidence) = call else { return nil }
            guard case .user = evidence else { return "not user" }
            return "\(remote ?? "nil") \(branch ?? "nil")"
        }
        #expect(pushes == ["nil develop", "nil develop"])
    }

    @Test
    func `a push to a new remote names its address on the card and sends it`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let url = "https://github.com/owner/clock.git"
        let (_, asked) = try await harness.run(.gitPush, ["url": .string(url)])
        let request = try #require(asked.first)
        #expect(asked.count == 1)
        #expect(request.reason.contains("origin at \(url)"))
        #expect(!request.allowsSessionScope)
        let pushes = await harness.backend.calls.compactMap { call -> String? in
            guard case let .gitPush(remote, branch, url, _) = call else { return nil }
            return "\(remote ?? "nil") \(branch ?? "nil") \(url ?? "nil")"
        }
        #expect(pushes == ["nil main \(url)"])
    }

    @Test
    func `a declined push does not reach the host`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await #expect(throws: ToolDeniedError.self) {
            _ = try await harness.run(.gitPush, ["remote": "origin", "branch": "main"], answering: .deny(reason: nil))
        }
        let pushes = await harness.backend.calls.filter {
            if case .gitPush = $0 {
                true
            } else {
                false
            }
        }
        #expect(pushes.isEmpty)
    }

    @Test
    func `Confirm runs project git changes without asking, on the session's project`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        var asked: [ApprovalRequest] = []
        let calls: [(AgentToolName, JSONValue)] = [
            (.gitStatus, [:]),
            (.gitDiff, ["path": "Sources/Tweak.m", "staged": true]),
            (.gitStage, ["paths": ["Sources/Tweak.m"]]),
            (.gitUnstage, ["paths": ["Sources/Tweak.m"]]),
            (.gitCommit, ["message": "Hook the clock"]),
            (.gitInit, [:]),
            (.gitCommit, ["message": "Save everything", "all": true]),
            (.gitFetch, ["remote": "upstream"]),
            (.gitPull, [:]),
            (.gitClone, ["url": "https://example.com/hello.git", "branch": "main"]),
        ]
        for (tool, arguments) in calls {
            asked += try await harness.run(tool, arguments).1
        }
        #expect(asked.isEmpty)
        #expect(await harness.backend.calls == [
            .gitStatus,
            .gitDiff(path: "Sources/Tweak.m", staged: true),
            .gitStage(["Sources/Tweak.m"]),
            .gitUnstage(["Sources/Tweak.m"]),
            .gitCommit("Hook the clock"),
            .gitInit,
            .gitCommit("Save everything", all: true),
            .gitFetch(remote: "upstream"),
            .gitPull(remote: nil),
            .gitClone(url: "https://example.com/hello.git", branch: "main"),
        ])
    }

    @Test
    func `bad git arguments are refused before the host`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.gitStage, ["paths": []]) }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.gitCommit, ["message": "  "]) }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.gitClone, [:]) }
        #expect(await harness.backend.calls.isEmpty)
    }

    // MARK: Workspaces

    @Test
    func `a workspace that declares no build is told how to declare one, before asking`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", #"{"schemaVersion":1,"projectID":"x","kind":"workspace","displayName":"Hello"}"#)
        await #expect(throws: ToolDeniedError.self) { _ = try await harness.run(.projectBuild, [:]) }
        do {
            _ = try await harness.run(.projectBuild, [:])
        } catch let error as ToolDeniedError {
            #expect(error.message.contains("\"external\""))
            #expect(error.message.contains("APELIN_PACKAGE_DIR"))
            #expect(error.message.contains("apelin-external-build skill"))
        }
        #expect(await harness.backend.calls.isEmpty)
        #expect(await harness.events.events.isEmpty, "nothing is asked")
    }

    @Test
    func `a project is a workspace by kind or by buildSystem`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let root = try ScopedRoot(home.projectURL)
        #expect(ProjectBuildSystem.read(in: root) == .apelin, "no manifest")
        try home.write("apelin-project.json", #"{"kind":"workspace"}"#)
        #expect(ProjectBuildSystem.read(in: root) == .external)
        try home.write("apelin-project.json", #"{"kind":"workspace","buildSystem":"external"}"#)
        #expect(ProjectBuildSystem.read(in: root) == .external)
        try home.write("apelin-project.json", #"{"kind":"tweak","buildSystem":"external"}"#)
        #expect(ProjectBuildSystem.read(in: root) == .external)
        try home.write("apelin-project.json", #"{"kind":"tweak","configurations":{}}"#)
        #expect(ProjectBuildSystem.read(in: root) == .apelin)
        try home.write("apelin-project.json", "not json")
        #expect(ProjectBuildSystem.read(in: root) == .apelin)
    }

    @Test
    func `the prompt carries the git rule, and the workspace section only for a workspace`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        func prompt(_ buildSystem: ProjectBuildSystem) -> String {
            SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, skills: [], mcpServers: [], buildSystem: buildSystem)
        }
        let tweak = prompt(.apelin)
        #expect(tweak.contains("only through the git_* tools"))
        #expect(tweak.contains("A refused push is never a reason to force it"))
        #expect(!tweak.contains("# Workspace"))

        let workspace = prompt(.external)
        #expect(workspace.contains("# Workspace"))
        #expect(workspace.contains("build system is external"))
        #expect(workspace.contains("shell_run"))
        #expect(workspace.contains("AGENTS.md"))
        #expect(workspace.contains("git_clone"))
        #expect(workspace.contains("Settings ▸ Git"))

        #expect(prompt(.apelin).contains("git_push"))
    }

    // MARK: Settings

    @Test
    func `the settings tools read freely and ask for every change`() {
        #expect(AgentToolName.gitReadSettings.risk == .readOnly)
        for tool in [AgentToolName.gitSetAuthor, .gitSaveCredential, .gitRemoveCredential] {
            #expect(tool.risk == .system, "\(tool.rawValue)")
            #expect(!tool.isProjectOnly, "\(tool.rawValue)")
        }
    }

    @Test
    func `saving a credential asks each time, names the host, and keeps the token off the card`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let arguments: JSONValue = ["host": "git.example.com", "username": "octocat", "token": "ghp_secret"]
        let (_, first) = try await harness.run(.gitSaveCredential, arguments, answering: .approve(.session))
        let request = try #require(first.first)
        #expect(!request.allowsSessionScope)
        guard case let .gitSettings(summary) = request.detail else {
            Issue.record("the card should say what changes"); return
        }
        #expect(summary.contains("git.example.com") && summary.contains("octocat"))
        #expect(!summary.contains("ghp_secret") && !request.reason.contains("ghp_secret"))
        let (_, second) = try await harness.run(.gitSaveCredential, arguments)
        #expect(second.count == 1)
        let saved = await harness.backend.calls.filter { $0 == .gitSaveCredential(host: "git.example.com", username: "octocat", token: "ghp_secret") }
        #expect(saved.count == 2)
    }

    @Test
    func `github.com takes no token from the conversation, before anyone is asked`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        for host in ["github.com", " GitHub.com "] {
            await #expect(throws: ToolArgumentError.self) {
                _ = try await harness.run(.gitSaveCredential, ["host": .string(host), "username": "octocat", "token": "ghp_secret"])
            }
        }
        #expect(await harness.backend.calls.isEmpty)
    }

    @Test
    func `a recorded call shows a mask for the token and nothing else changes`() {
        let arguments = #"{"host":"github.com","token":"ghp_secret","username":"octocat"}"#
        let redacted = ToolArgumentRedaction.redacted(arguments, tool: "apelin_git_save_credential")
        #expect(!redacted.contains("ghp_secret"))
        #expect(redacted.contains("github.com") && redacted.contains("octocat"))
        #expect(ToolArgumentRedaction.redacted("not json ghp_secret", tool: "apelin_git_save_credential") == "{}")
        #expect(ToolArgumentRedaction.redacted(arguments, tool: "git_status") == arguments)
        // A session recorded before the rename relays its calls again on reopen.
        #expect(!ToolArgumentRedaction.redacted(arguments, tool: "git_save_credential").contains("ghp_secret"))
    }
}
