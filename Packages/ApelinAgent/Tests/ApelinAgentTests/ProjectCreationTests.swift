@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Every chat creates projects")
struct ProjectCreationTests {
    private func runner(_ home: TemporaryHome, project: ProjectIdentity, backend: MockBackend) throws -> ToolRunner {
        try ToolRunner(sessionID: UUID().uuidString, project: project, root: ScopedRoot(home.projectURL),
                       policy: ApprovalPolicy(mode: .confirm), backend: backend, digests: MockDigestLedger(),
                       gate: ApprovalGate { _ in })
    }

    private func generalChat() throws -> ProjectIdentity {
        let id = UUID().uuidString
        return try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
    }

    private func text(_ result: AgentToolResult) -> String {
        result.content.compactMap {
            if case let .text(content) = $0 {
                content.text
            } else {
                nil
            }
        }
        .joined()
    }

    @Test
    func `General Chat and a project's chat are both offered the project tools`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let names = { (runner: ToolRunner) in Set(runner.agentTools(mcp: []).map(\.name)) }
        for chat in try [home.project, generalChat()] {
            let offered = try names(runner(home, project: chat, backend: MockBackend()))
            #expect(offered.contains("apelin_template_list") && offered.contains("apelin_project_create"), "\(chat.id)")
            #expect(offered.contains("apelin_project_list"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `apelin_project_create takes a template and runs under Confirm without asking`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let backend = MockBackend()
        let runner = try runner(home, project: generalChat(), backend: backend)
        let list = try await runner.run(.local(.templateList), toolCallID: "call-1", arguments: .object([:]), cancellation: nil, mcp: nil)
        #expect(text(list).contains("wiki.qaq.apelin.dev.tweak/tweak"))
        let arguments: JSONValue = .object([
            "template": "wiki.qaq.apelin.dev.tweak/tweak",
            "name": "Lock Screen Clock",
            "values": .object(["filter": "com.apple.springboard", "verbose": .bool(true), "count": .int(3)]),
        ])
        let created = try await runner.run(.local(.projectCreate), toolCallID: "call-2", arguments: arguments, cancellation: nil, mcp: nil)
        #expect(text(created).contains("project-1"))
        #expect(await backend.calls == [.createProject(
            template: "wiki.qaq.apelin.dev.tweak/tweak",
            name: "Lock Screen Clock",
            values: ["filter": .string("com.apple.springboard"), "verbose": .boolean(true), "count": .integer(3)],
        )])
    }

    /// The tweak template's filterBundles is a list of bundle IDs. Every
    /// call that gave one was refused, and the model settled for the
    /// default SpringBoard filter (five conversations on a device).
    @Test(.timeLimit(.minutes(1)))
    func `apelin_project_create passes a list of strings on, and names the value it refuses`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let backend = MockBackend()
        let runner = try runner(home, project: generalChat(), backend: backend)
        func create(_ values: JSONValue) async throws {
            _ = try await runner.run(.local(.projectCreate), toolCallID: UUID().uuidString, arguments: .object([
                "template": "wiki.qaq.apelin.dev.tweak/objc-hook",
                "name": "Settings Tweak",
                "values": values,
            ]), cancellation: nil, mcp: nil)
        }
        try await create(["filterBundles": ["com.apple.springboard", "com.apple.Preferences"], "displayName": "X"])
        // An empty list goes on too: apelin-build asks for 1 to 32 items.
        try await create(["filterBundles": []])
        #expect(await backend.calls == [
            .createProject(
                template: "wiki.qaq.apelin.dev.tweak/objc-hook",
                name: "Settings Tweak",
                values: ["filterBundles": .list(["com.apple.springboard", "com.apple.Preferences"]), "displayName": .string("X")],
            ),
            .createProject(template: "wiki.qaq.apelin.dev.tweak/objc-hook", name: "Settings Tweak", values: ["filterBundles": .list([])]),
        ])
        for (values, expected) in [
            (["filterBundles": [1]], "filterBundles: a list holds strings only"),
            (["filterBundles": [[:]]], "filterBundles: a list holds strings only"),
            (["displayName": "X", "filterBundles": ["bundles": "com.apple.Preferences"]], "filterBundles must be a string, boolean, integer or list of strings"),
        ] as [(JSONValue, String)] {
            let error = await #expect(throws: ToolArgumentError.self) { try await create(values) }
            #expect(error?.message.hasPrefix(expected) == true, "\(error?.message ?? "no error")")
        }
        #expect(await backend.calls.count == 2, "a refused value reaches no host")
    }

    @Test
    func `a template value round-trips as the JSON it stands for`() throws {
        let values: [String: TemplateValue] = [
            "filterBundles": .list(["com.apple.Preferences"]), "displayName": .string("X"),
            "verbose": .boolean(true), "count": .integer(3),
        ]
        let data = try JSONEncoder().encode(values)
        #expect(try JSONDecoder().decode([String: JSONValue].self, from: data)["filterBundles"] == ["com.apple.Preferences"])
        #expect(try JSONDecoder().decode([String: TemplateValue].self, from: data) == values)
    }

    @Test(.timeLimit(.minutes(1)))
    func `apelin_project_create needs a template, and a project's chat creates another without asking`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let backend = MockBackend()
        let general = try runner(home, project: generalChat(), backend: backend)
        await #expect(throws: ToolArgumentError.self) {
            try await general.run(.local(.projectCreate), toolCallID: "call-1", arguments: .object(["name": "Clock"]), cancellation: nil, mcp: nil)
        }
        #expect(await backend.calls.isEmpty)
        let project = try runner(home, project: home.project, backend: backend)
        let created = try await project.run(.local(.projectCreate), toolCallID: "call-2", arguments: .object(["template": "x/y", "name": "Clock"]), cancellation: nil, mcp: nil)
        #expect(text(created).contains("apelin://project/"))
        #expect(await backend.calls == [.createProject(template: "x/y", name: "Clock", values: [:])])
    }

    @Test
    func `General Chat's prompt says how to start a project`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let general = try SystemPrompt.make(project: generalChat(), projectRoot: home.projectURL.path, skills: [], mcpServers: [])
        #expect(general.contains("# General Chat"))
        #expect(general.contains("apelin_template_list"))
        let project = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, skills: [], mcpServers: [])
        #expect(!project.contains("# General Chat"))
    }

    /// A repository goes into an Empty workspace whose conversation clones
    /// it, as New Project does; a template it fell back to was the wrong
    /// project. Each place that names one step names the others with it,
    /// the conversation's project among them (issue #79: without it, the
    /// conversation opened in the caller's tweak project).
    @Test
    func `Every chat imports a repository through an Empty workspace's conversation`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let steps = ["wiki.qaq.apelin.workspace/empty", "apelin_conversation_create", "set to the new workspace", "git_clone"]
        func namesEveryStep(_ text: String) -> Bool {
            steps.allSatisfy { text.contains($0) }
        }
        for chat in try [home.project, generalChat()] {
            let prompt = SystemPrompt.make(project: chat, projectRoot: home.projectURL.path, skills: [], mcpServers: [])
            let line = prompt.split(separator: "\n").first { $0.contains(steps[0]) }.map(String.init)
            #expect(line.map(namesEveryStep) == true, "\(chat.id)")
        }
        #expect(namesEveryStep(AgentToolName.projectCreate.summary))
        #expect(AgentToolName.gitClone.summary.contains("apelin_project_create"))
        #expect(namesEveryStep(BuiltInSkills.gitWorkflow.body))
        let skill = BuiltInSkills.gitWorkflow.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(skill.contains("`project` is required here: without it the conversation opens in this chat's own project"))
        // and where the model reads it when it acts: the new project's
        // answer, and the opened conversation's
        let created = ProjectCreateToolResponse(projectID: "6f1c5b0e-0000-4000-8000-000000000001", name: "Repo")
        #expect(created.next.contains("apelin_conversation_create and project \"6f1c5b0e-0000-4000-8000-000000000001\""))
        #expect(AgentToolName.conversationCreate.summary.contains("Without project it opens in this conversation's own project"))
        #expect(AgentToolName.conversationCreate.summary.contains("the project it opened in"))
    }

    @Test
    func `The screen tools leave Apelin's own screen to the user`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        #expect(AgentToolName.screenInteract.summary.contains("Never in Apelin itself (wiki.qaq.apelin)"))
        // A project is deleted by its own tool, never by taps through All Projects.
        #expect(AgentToolName.screenInteract.summary.contains("a project is deleted with apelin_project_delete"))
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, skills: [], mcpServers: [])
        let line = prompt.split(separator: "\n").first { $0.contains("never on Apelin's own screen") }
        #expect(line?.contains("A project is deleted with apelin_project_delete, never through Apelin's screen.") == true)
    }
}
