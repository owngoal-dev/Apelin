@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("conversation tools")
struct ConversationToolTests {
    static let tools: [AgentToolName] = [
        .conversationCreate, .conversationSend, .conversationList, .conversationRead, .conversationStop,
    ]

    // MARK: Catalog

    @Test
    func `the catalog names the conversation tools with their risks, in every chat`() {
        #expect(Self.tools.map(\.rawValue) == [
            "apelin_conversation_create", "apelin_conversation_send", "apelin_conversation_list", "apelin_conversation_read", "apelin_conversation_stop",
        ])
        for tool in [AgentToolName.conversationCreate, .conversationSend, .conversationStop] {
            #expect(tool.risk == .writeProject, "\(tool.rawValue)")
        }
        for tool in [AgentToolName.conversationList, .conversationRead] {
            #expect(tool.risk == .readOnly, "\(tool.rawValue)")
            #expect(!tool.isSensitiveRead, "\(tool.rawValue)")
        }
        for tool in Self.tools {
            #expect(!tool.isProjectOnly, "\(tool.rawValue)")
            #expect(tool.isConversation, "\(tool.rawValue)")
            #expect(!tool.summary.isEmpty)
        }
    }

    @Test
    func `each tool takes what it needs, and a reason`() {
        func schema(_ tool: AgentToolName) -> (properties: Set<String>, required: [String]) {
            guard case let .object(fields) = ToolReason.adding(to: tool.parameters),
                  case let .object(properties)? = fields["properties"],
                  case let .array(required)? = fields["required"] else { return ([], []) }
            return (Set(properties.keys), required.compactMap {
                if case let .string(name) = $0 {
                    name
                } else {
                    nil
                }
            })
        }
        #expect(schema(.conversationCreate).properties == ["prompt", "title", "project", "reason"])
        #expect(schema(.conversationCreate).required == ["prompt", "reason"])
        #expect(schema(.conversationSend).required == ["session_id", "text", "reason"])
        #expect(schema(.conversationSend).properties.contains("project"))
        #expect(schema(.conversationList).properties == ["project", "reason"])
        #expect(schema(.conversationRead).properties == ["session_id", "after_seq", "wait_seconds", "project", "reason"])
        #expect(schema(.conversationStop).properties == ["session_id", "close", "reason"])
    }

    @Test
    func `a project's chat and General Chat both offer them`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        func offered(_ project: ProjectIdentity) throws -> [String] {
            try ToolRunner(
                sessionID: UUID().uuidString,
                project: project,
                root: ScopedRoot(home.projectURL),
                policy: ApprovalPolicy(mode: .confirm),
                backend: MockBackend(),
                digests: MockDigestLedger(),
                gate: ApprovalGate { _ in },
            ).agentTools(mcp: []).map(\.name)
        }
        let project = try offered(home.project)
        let id = UUID().uuidString
        let general = try offered(ProjectIdentity(id: "temporary:" + id, name: ProjectName(id)))
        for tool in Self.tools {
            #expect(project.contains(tool.rawValue), "\(tool.rawValue)")
            #expect(general.contains(tool.rawValue), "\(tool.rawValue)")
        }
    }

    // MARK: Another project

    /// A runner over `backend` that knows one other project, Far.
    static func runner(
        _ home: TemporaryHome,
        project: ProjectIdentity,
        mode: ApprovalMode = .confirm,
        backend: MockBackend,
        gate: ApprovalGate,
    ) throws -> ToolRunner {
        try ToolRunner(
            sessionID: UUID().uuidString,
            project: project,
            root: ScopedRoot(home.projectURL),
            policy: ApprovalPolicy(mode: mode),
            backend: backend,
            digests: MockDigestLedger(),
            gate: gate,
        )
    }

    static let far = try! ProjectIdentity(id: "6f1c5b0e-0000-4000-8000-00000000f00d", name: ProjectName("Far"))

    @Test(.timeLimit(.minutes(1)))
    func `Strict asks for every call that reaches another project, naming it and the text, never for the session`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await harness.backend.addProject(Self.far)
        let (created, asked) = try await harness.run(.conversationCreate, ["prompt": "Import the repo and build it", "project": "Far"])
        #expect(asked.count == 1 && asked.first?.allowsSessionScope == false)
        #expect(asked.first?.detail == .otherProject(OtherProjectApproval(
            action: "create",
            projectID: Self.far.id,
            projectName: "Far",
            text: "Import the repo and build it",
        )))
        #expect(asked.first?.reason.contains("Far") == true && asked.first?.reason.contains("Import the repo and build it") == true)
        let createdText = created.content.compactMap {
            if case let .text(text) = $0 {
                text.text
            } else {
                nil
            }
        }.joined()
        #expect(createdText.contains("apelin://conversation/child-session") && createdText.contains("apelin://project/\(Self.far.id)"))
        let (_, sendAsked) = try await harness.run(.conversationSend, ["session_id": "far-chat", "text": "Also push", "project": .string(Self.far.id)])
        #expect(sendAsked.first?.detail == .otherProject(OtherProjectApproval(
            action: "send",
            projectID: Self.far.id,
            projectName: "Far",
            sessionID: "far-chat",
            text: "Also push",
        )))
        let (_, listAsked) = try await harness.run(.conversationList, ["project": "Far"])
        let (_, readAsked) = try await harness.run(.conversationRead, ["session_id": "far-chat", "project": "Far"])
        #expect(listAsked.count == 1 && readAsked.count == 1)
        let calls = await harness.backend.calls
        #expect(calls.map {
            if case let .conversationElsewhere(tool, project, _) = $0 {
                "\(tool) \(project)"
            } else {
                ""
            }
        } == [
            "apelin_conversation_create \(Self.far.id)", "apelin_conversation_send \(Self.far.id)",
            "apelin_conversation_list \(Self.far.id)", "apelin_conversation_read \(Self.far.id)",
        ])
        // The same call again asks again.
        let (_, again) = try await harness.run(.conversationCreate, ["prompt": "Import the repo and build it", "project": "Far"], answering: .approve(.session))
        #expect(again.count == 1)
        let (_, stillAsks) = try await harness.run(.conversationCreate, ["prompt": "Import the repo and build it", "project": "Far"])
        #expect(stillAsks.count == 1, "a session approval is never remembered for another project")
    }

    @Test(.timeLimit(.minutes(1)))
    func `naming the session's own project changes nothing, and Relaxed reaches another without asking`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await harness.backend.addProject(harness.home.project)
        let (_, own) = try await harness.run(.conversationCreate, ["prompt": "Docs", "project": .string(harness.home.project.name.rawValue)])
        #expect(own.isEmpty)
        #expect(await harness.backend.calls == [.conversationCreate(prompt: "Docs", title: nil)])

        let relaxed = try DigestApprovalTests.Harness(mode: .relaxed)
        defer { relaxed.home.remove() }
        await relaxed.backend.addProject(Self.far)
        let (_, asked) = try await relaxed.run(.conversationCreate, ["prompt": "Build it", "project": "Far"])
        #expect(asked.isEmpty)
        #expect(await relaxed.backend.calls == [.conversationElsewhere(tool: "apelin_conversation_create", project: Self.far.id, evidence: .relaxed)])
    }

    @Test(.timeLimit(.minutes(1)))
    func `General Chat names the project, and hands the new project its first conversation`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let backend = MockBackend()
        await backend.addProject(Self.far)
        let id = UUID().uuidString
        let general = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        let runner = try Self.runner(home, project: general, mode: .relaxed, backend: backend, gate: ApprovalGate { _ in })
        await #expect(throws: ToolArgumentError.self) {
            try await runner.run(.local(.conversationCreate), toolCallID: "c1", arguments: ["prompt": "Build it"], cancellation: nil, mcp: nil)
        }
        await #expect(throws: ToolArgumentError.self) {
            try await runner.run(.local(.conversationRead), toolCallID: "c2", arguments: ["session_id": "far-chat"], cancellation: nil, mcp: nil)
        }
        _ = try await runner.run(.local(.conversationCreate), toolCallID: "c3", arguments: ["prompt": "Build it", "project": "Far"], cancellation: nil, mcp: nil)
        #expect(await backend.calls == [.conversationElsewhere(tool: "apelin_conversation_create", project: Self.far.id, evidence: .relaxed)])
        await #expect(throws: ToolDeniedError.self) {
            try await runner.run(.local(.conversationCreate), toolCallID: "c4", arguments: ["prompt": "x", "project": "Nowhere"], cancellation: nil, mcp: nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `General Chat lists without a project, asking nothing even in Strict mode: the host lists what it may reach`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let backend = MockBackend()
        let id = UUID().uuidString
        let general = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        // A call that asked is stopped at once, and never reaches the backend.
        let cancellation = CancellationHandle()
        let gate = ApprovalGate { event in
            if case .approvalRequested = event {
                cancellation.cancel(reason: "asked")
            }
        }
        let runner = try Self.runner(home, project: general, mode: .confirm, backend: backend, gate: gate)
        _ = try? await runner.run(.local(.conversationList), toolCallID: "c1", arguments: [:], cancellation: cancellation, mcp: nil)
        #expect(await backend.calls == [.conversationList])
    }

    // MARK: Approval

    @Test
    func `Confirm lets every conversation tool through without asking`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let root = try ScopedRoot(home.projectURL)
        let policy = ApprovalPolicy(mode: .confirm)
        for tool in [AgentToolName.conversationCreate, .conversationSend, .conversationStop] {
            #expect(policy.evaluate(InvocationFacts(tool: .local(tool)), root: root) == .allow(.notRequired), "\(tool.rawValue)")
        }
        for tool in [AgentToolName.conversationList, .conversationRead] {
            #expect(policy.evaluate(InvocationFacts(tool: .local(tool)), root: root) == .allow(.preset(tool.rawValue)), "\(tool.rawValue)")
        }
    }

    // MARK: Running

    @Test
    func `each tool is one backend call with its arguments, and none asks`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        var asked = 0
        asked += try await harness.run(.conversationCreate, ["prompt": "Write the README", "title": "Docs"]).1.count
        asked += try await harness.run(.conversationCreate, ["prompt": "Check the filter", "title": ""]).1.count
        asked += try await harness.run(.conversationSend, ["session_id": "child-session", "text": "Also the changelog"]).1.count
        asked += try await harness.run(.conversationList, [:]).1.count
        asked += try await harness.run(.conversationRead, ["session_id": "child-session", "after_seq": 12, "wait_seconds": 5000]).1.count
        asked += try await harness.run(.conversationRead, ["session_id": "child-session", "wait_seconds": -3]).1.count
        asked += try await harness.run(.conversationStop, ["session_id": "child-session"]).1.count
        asked += try await harness.run(.conversationStop, ["session_id": "child-session", "close": true]).1.count
        #expect(asked == 0)
        #expect(await harness.backend.calls == [
            .conversationCreate(prompt: "Write the README", title: "Docs"),
            .conversationCreate(prompt: "Check the filter", title: nil),
            .conversationSend(sessionID: "child-session", text: "Also the changelog"),
            .conversationList,
            .conversationRead(sessionID: "child-session", afterSeq: 12, waitSeconds: ConversationReadToolRequest.maximumWaitSeconds),
            .conversationRead(sessionID: "child-session", afterSeq: nil, waitSeconds: 0),
            .conversationStop(sessionID: "child-session", close: false),
            .conversationStop(sessionID: "child-session", close: true),
        ])
    }

    @Test
    func `an empty prompt or message, or a message to itself, is refused before the host`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.conversationCreate, ["prompt": " \n"]) }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.conversationSend, ["session_id": "child-session", "text": ""]) }
        await #expect(throws: ToolArgumentError.self) {
            _ = try await harness.run(.conversationSend, ["session_id": .string(harness.runner.sessionID), "text": "hi"])
        }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.conversationRead, ["session_id": " "]) }
        #expect(await harness.backend.calls.isEmpty)
    }

    @Test
    func `a stop cancels a read that is still waiting`() async throws {
        let cancellation = CancellationHandle()
        let started = Date()
        let read = Task {
            try await ToolRunner.untilCancelled(cancellation) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        cancellation.cancel(reason: "aborted")
        await #expect(throws: CancellationError.self) { _ = try await read.value }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// #59: a call waiting on something that answers neither it nor its
    /// cancellation (a request to the session host, a transfer that
    /// stalled) held the run, so Stop did nothing and every later message
    /// queued behind it.
    @Test
    func `a stop ends a call that would never answer`() async throws {
        let cancellation = CancellationHandle()
        let never = NeverAnswers()
        let started = Date()
        let call = Task {
            try await ToolRunner.untilCancelled(cancellation, grace: .milliseconds(200)) {
                await never.wait()
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        cancellation.cancel(reason: "aborted")
        await #expect(throws: CancellationError.self) { _ = try await call.value }
        #expect(Date().timeIntervalSince(started) < 10)
        never.answer()
    }

    /// What the worker's stop watch reads (`WorkerState.abort`): whether
    /// the run a stop was stopping has ended, whatever started since.
    @Test
    func `a stop knows whether what it stopped has ended`() async throws {
        #expect(AgentSession.StoppedWork([]).hasEnded, "nothing was running")
        let never = NeverAnswers()
        let stuck = Task { await never.wait() }
        let quick = Task {}
        await quick.value
        let stopped = AgentSession.StoppedWork([quick, stuck])
        try await Task.sleep(for: .milliseconds(100))
        #expect(!stopped.hasEnded, "one of them is still going")
        never.answer()
        await stuck.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(stopped.hasEnded)
    }

    /// A call that ends when it is cancelled says so itself: an approval
    /// denied, a command's output up to where the stop killed it.
    @Test
    func `a stopped call that ends by itself keeps its own answer`() async throws {
        struct Denied: Error {}
        let cancellation = CancellationHandle()
        let call = Task {
            try await ToolRunner.untilCancelled(cancellation, grace: .seconds(20)) {
                try? await Task.sleep(for: .seconds(30))
                throw Denied()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let stopped = Date()
        cancellation.cancel(reason: "aborted")
        await #expect(throws: Denied.self) { _ = try await call.value }
        #expect(Date().timeIntervalSince(stopped) < 10)
    }

    @Test
    func `a call that answers first is not disturbed by a later stop`() async throws {
        let cancellation = CancellationHandle()
        let answer = try await ToolRunner.untilCancelled(cancellation) { 7 }
        cancellation.cancel(reason: "aborted")
        #expect(answer == 7)
        // one stopped before it began never runs to an answer
        await #expect(throws: CancellationError.self) {
            _ = try await ToolRunner.untilCancelled(cancellation) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
    }

    // MARK: Prompt

    @Test
    func `both prompts explain conversations; General Chat's hands a new project its first one, with links`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let project = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, skills: [], mcpServers: [])
        #expect(project.contains("# Conversations"))
        #expect(project.contains("apelin_conversation_create") && project.contains("not the user"))
        let id = UUID().uuidString
        let general = try SystemPrompt.make(
            project: ProjectIdentity(id: "temporary:" + id, name: ProjectName(id)),
            projectRoot: home.projectURL.path,
            skills: [],
            mcpServers: [],
        )
        #expect(general.contains("# Conversations") && general.contains("apelin_conversation_create with project set to the new project"))
        for prompt in [project, general] {
            #expect(prompt.contains("apelin://conversation/<session id>") && prompt.contains("apelin://project/<projectID>"))
            #expect(!prompt.contains("there is no Apelin URL scheme"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a message from another conversation is marked for the app and prefixed for the model`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let seen = SeenText()
        provider.setResponses([.factory { context, _, _, _ in
            let text = context.messages.compactMap { message -> String? in
                guard case let .user(user) = message else { return nil }
                return user.content.compactMap { block -> String? in
                    if case let .text(content) = block {
                        return content.text
                    }
                    return nil
                }.joined()
            }.joined(separator: "\n")
            await seen.set(text)
            return fauxAssistantMessage("Reviewed.")
        }])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(provider.getModel()),
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let sender = ConversationSender(sessionID: "opener-session", title: "Plan the tweak")
        try await session.prompt("Review Tweak.x", from: sender)
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(events.contains(.promptSubmitted(text: "Review Tweak.x", from: "opener-session")), "the app sees the text as sent, marked with the sender")
        let modelText = await seen.text
        #expect(modelText.contains(sender.prefix + "\nReview Tweak.x"), "the model reads one line naming the sender right before the message")
        #expect(sender.prefix.contains("“Plan the tweak” (opener-session)") && sender.prefix.contains("not from the user"))
        #expect(ConversationSender(sessionID: "s").prefix.contains("conversation s,"))
        await session.close()
    }
}

/// What the faux model was sent.
actor SeenText {
    var text = ""
    func set(_ value: String) {
        text = value
    }
}

/// A wait that ends only when told to, whatever its task's cancellation.
private final class NeverAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock { waiting.append(continuation) }
        }
    }

    func answer() {
        let waiting = lock.withLock {
            defer { self.waiting = [] }
            return self.waiting
        }
        waiting.forEach { $0.resume() }
    }
}
