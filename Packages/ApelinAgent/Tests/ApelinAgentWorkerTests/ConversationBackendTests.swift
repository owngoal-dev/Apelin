import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("ChannelHostBackend's conversation tools")
struct ConversationBackendTests {
    static let child = "22222222-3333-4444-8555-666666666666"
    static let childTask = TaskHandle(taskID: TaskID("child-task"), kind: .agent)

    func summary(state: TaskState = .running) -> AgentSessionSummary {
        AgentSessionSummary(
            sessionID: Self.child,
            task: Self.childTask,
            projectID: "6f1c5b0e-0000-4000-8000-000000000001",
            title: "Docs",
            state: state,
            updatedAt: Date(timeIntervalSince1970: 100),
            parentSessionID: "11111111-2222-4333-8444-555555555555",
        )
    }

    /// Events numbered from `first`, as one attach answers them.
    func batch(_ events: [(String, ApelinCore.JSONValue?)], from first: UInt64 = 1, state: TaskState = .running) -> TaskEventBatch {
        let numbered = events.enumerated().map {
            TaskEvent(seq: EventSeq(first + UInt64($0.offset)), kind: $0.element.0, payload: $0.element.1)
        }
        return TaskEventBatch(
            taskID: Self.childTask.taskID,
            events: numbered,
            state: state,
            lastSeq: numbered.last?.seq ?? EventSeq(first - 1),
            finished: state.isTerminal,
        )
    }

    func text(_ value: String) -> ApelinCore.JSONValue {
        .object(["text": .string(value)])
    }

    @Test
    func `create opens in the session's project with the session's provider, model, effort, tier and limits, and does not wait`() async throws {
        let fixture = try Fixture()
        await fixture.backend.modelChoice.set(
            provider: .openAICodex,
            model: "gpt-6.1-sol",
            reasoningEffort: .high,
            serviceTier: .ultrafast,
            modelLimits: AgentModelLimits(contextWindow: 65000),
        )
        fixture.host.on(.agentOpen, reply: AgentOpenResponse(sessionID: Self.child, task: Self.childTask))
        let opened = try await fixture.backend.conversationCreate(ConversationCreateToolRequest(
            context: fixture.context(),
            prompt: "Write the README",
            title: "Docs",
        ))
        #expect(fixture.host.requests.map(\.operation) == [.agentOpen], "nothing is read: it answers at once")
        let sent = try #require(fixture.host.requests(AgentOpenRequest.self).first)
        #expect(sent.projectID == fixture.project.id && sent.projectName == "Hello")
        #expect(sent.provider == .openAICodex && sent.model == "gpt-6.1-sol" && sent.reasoningEffort == .high)
        #expect(sent.serviceTier == .ultrafast)
        #expect(sent.modelLimits == AgentModelLimits(contextWindow: 65000))
        #expect(sent.prompt == "Write the README" && sent.title == "Docs")
        #expect(sent.sessionID == nil && sent.temporaryID == nil && sent.closeWhenFinished == nil)
        #expect(opened == ConversationCreateToolResponse(sessionID: Self.child, taskID: "child-task"))
    }

    @Test
    func `send is the text alone: no mode, model, files or sender`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentPrompt, reply: Acknowledged())
        let response = try await fixture.backend.conversationSend(ConversationSendToolRequest(
            context: fixture.context(),
            sessionID: Self.child,
            text: "Also the changelog",
        ))
        let sent = try #require(fixture.host.requests(AgentPromptRequest.self).first)
        #expect(sent.sessionID == Self.child && sent.text == "Also the changelog")
        #expect(sent.approvalMode == nil && sent.provider == nil && sent.model == nil && sent.reasoningEffort == nil)
        #expect(sent.serviceTier == nil && sent.modelLimits == nil)
        #expect(sent.attachments == nil && sent.messageID == nil && sent.fromSessionID == nil, "the host writes the sender")
        #expect(response.done == "sent")
    }

    @Test
    func `list names each conversation, its opener and whether it is this one`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentList, reply: AgentListResponse(sessions: [
            AgentSessionSummary(sessionID: fixture.backend.sessionID, task: TaskHandle(taskID: TaskID("t0"), kind: .agent), state: .running, updatedAt: Date()),
            summary(state: .waitingForApproval),
            AgentSessionSummary(sessionID: "old", task: TaskHandle(taskID: TaskID("t2"), kind: .agent), state: .succeeded, updatedAt: Date()),
        ]))
        let list = try await fixture.backend.conversationList(ConversationListToolRequest(context: fixture.context())).conversations
        #expect(list.map(\.state) == ["open", "waitingForApproval", "ended"])
        #expect(list.map(\.isThisConversation) == [true, false, false])
        #expect(list[1].openedBy == fixture.backend.sessionID && list[1].title == "Docs")
        #expect(list.allSatisfy { $0.project == nil }, "this project's need no project")
    }

    @Test
    func `a list across projects names each one's project and what the host left out`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentList, reply: AgentListResponse(
            sessions: [
                AgentSessionSummary(
                    sessionID: Self.child,
                    task: Self.childTask,
                    projectID: "far-id",
                    projectName: "Far",
                    state: .interrupted,
                    updatedAt: Date(),
                ),
                AgentSessionSummary(
                    sessionID: fixture.backend.sessionID,
                    task: TaskHandle(taskID: TaskID("t0"), kind: .agent),
                    projectID: fixture.project.id,
                    projectName: "Hello",
                    state: .running,
                    updatedAt: Date(),
                ),
            ],
            unreachedProjects: 2,
        ))
        let listed = try await fixture.backend.conversationList(ConversationListToolRequest(context: fixture.context()))
        #expect(listed.conversations.map(\.project) == ["Far", nil])
        #expect(listed.conversations.first?.state == "ended", "one that has not run since the host started has ended")
        #expect(listed.note?.contains("2 more projects") == true && listed.note?.contains("project") == true)
        fixture.host.on(.agentList, reply: AgentListResponse(sessions: [], unreachedProjects: 1))
        let one = try await fixture.backend.conversationList(ConversationListToolRequest(context: fixture.context()))
        #expect(one.note?.hasPrefix("The conversations of 1 more project are not listed") == true)
        fixture.host.on(.agentList, reply: AgentListResponse(sessions: []))
        #expect(try await fixture.backend.conversationList(ConversationListToolRequest(context: fixture.context())).note == nil)
    }

    @Test
    func `an ended conversation reads to its end and waits on no approval`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentList, reply: AgentListResponse(sessions: [summary(state: .interrupted)]))
        let events = batch([
            ("prompt", text("Remove the old tweak")),
            ("message", text("Removing it")),
            ("approvalRequested", .object(["approvalID": .string("a1"), "tool": .string("apelin_package_remove"), "reason": .string("Removing a package")])),
            (TaskEvent.stateKind, .object(["state": .string("waitingForApproval")])),
            (TaskEvent.stateKind, .object(["state": .string("interrupted")])),
        ], state: .interrupted)
        fixture.host.on(.agentAttach) { request in
            let attach = try request.decode(AgentAttachRequest.self)
            return (attach.afterSeq == .start ? events : batch([], from: 6, state: .interrupted), [])
        }
        let read = try await fixture.backend.conversationRead(ConversationReadToolRequest(context: fixture.context(), sessionID: Self.child, waitSeconds: 30))
        #expect(read.state == .ended && !read.timedOut)
        #expect(read.messages.map(\.text) == ["Removing it"])
        #expect(read.pendingApprovals.isEmpty, "its task ended: nobody can give that approval now")
    }

    @Test
    func `stop aborts, and closes only when asked`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentAbort, reply: Acknowledged())
        fixture.host.on(.agentClose, reply: Acknowledged())
        let stopped = try await fixture.backend.conversationStop(ConversationStopToolRequest(context: fixture.context(), sessionID: Self.child))
        #expect(fixture.host.requests.map(\.operation) == [.agentAbort] && stopped.done == "stopped")
        let closed = try await fixture.backend.conversationStop(ConversationStopToolRequest(context: fixture.context(), sessionID: Self.child, close: true))
        #expect(fixture.host.requests.map(\.operation) == [.agentAbort, .agentAbort, .agentClose] && closed.done == "closed")
    }

    @Test
    func `the project list is every project the conversation tools reach, and only those`() async throws {
        let fixture = try Fixture(manifest: #"{"projectID":"6f1c5b0e-0000-4000-8000-000000000001","displayName":"Hello Tweak"}"#)
        let projects = fixture.projectURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: projects) }
        func project(_ name: String, _ manifest: String, in folder: URL? = nil) throws {
            let url = (folder ?? projects).appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try manifest.write(to: url.appendingPathComponent("apelin-project.json"), atomically: true, encoding: .utf8)
        }
        try project("Workspace", #"{"projectID":"w-1","kind":"workspace"}"#)
        try project("Broken", "not json")
        try project("Unnamed", #"{"displayName":"No id"}"#)
        try project(".hidden", #"{"projectID":"h-1"}"#)
        let elsewhere = projects.appendingPathComponent(".elsewhere", isDirectory: true)
        try project("Outside", #"{"projectID":"o-1"}"#, in: elsewhere)
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("Linked"), withDestinationURL: elsewhere.appendingPathComponent("Outside"))

        let listed = try await fixture.backend.projects()
        #expect(listed.projects.map(\.folder) == ["Hello", "Workspace"], "no link out, no unreadable or id-less manifest, nothing hidden")
        #expect(listed.projects.first == ListedProject(
            folder: "Hello", projectID: "6f1c5b0e-0000-4000-8000-000000000001", displayName: "Hello Tweak", buildSystem: "apelin", isThisProject: true,
        ))
        #expect(listed.projects.last == ListedProject(folder: "Workspace", projectID: "w-1", displayName: "Workspace", buildSystem: "external", isThisProject: false))
        #expect(listed.projects.last?.link == "apelin://project/w-1")
        #expect(!listed.truncated)
        #expect(try await fixture.backend.resolveProject("w-1").name.rawValue == "Workspace", "the list's ids resolve")
    }

    @Test
    func `a refusal comes back in words, with what to do`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentOpen) { _ in throw ApelinError(.conflict, "6 conversations agents opened are already running in this project; stop one first") }
        do {
            _ = try await fixture.backend.conversationCreate(ConversationCreateToolRequest(context: fixture.context(), prompt: "x"))
            Issue.record("the host refused")
        } catch let failure as ConversationToolFailure {
            #expect(failure.message.hasPrefix("apelin_conversation_create failed: 6 conversations"))
            #expect(failure.message.contains("apelin_conversation_stop"))
        }
        fixture.host.on(.agentList, reply: AgentListResponse(sessions: []))
        await #expect(throws: ConversationToolFailure.self) {
            _ = try await fixture.backend.conversationRead(ConversationReadToolRequest(context: fixture.context(), sessionID: Self.child))
        }
    }

    @Test
    func `read reports the state, the messages after a point and the approvals still waiting`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentList, reply: AgentListResponse(sessions: [summary()]))
        let events = batch([
            ("prompt", text("Write the README")),
            ("messageStarted", nil),
            ("message", text("First draft")),
            ("finished", .object(["reason": .string("completed")])),
            ("prompt", text("Shorter")),
            ("approvalRequested", .object(["approvalID": .string("a1"), "tool": .string("shell_run"), "reason": .string("Scripts require approval")])),
            (TaskEvent.stateKind, .object(["state": .string("waitingForApproval")])),
            ("message", text("Shorter draft")),
            ("error", .object(["message": .string("the provider returned an error")])),
        ], state: .waitingForApproval)
        fixture.host.on(.agentAttach) { request in
            let attach = try request.decode(AgentAttachRequest.self)
            return (attach.afterSeq == .start ? events : batch([], from: 10, state: .waitingForApproval), [])
        }
        let read = try await fixture.backend.conversationRead(ConversationReadToolRequest(context: fixture.context(), sessionID: Self.child, afterSeq: 4))
        #expect(read.state == .waitingForApproval)
        #expect(read.messages == [
            ConversationMessage(seq: 8, role: "assistant", text: "Shorter draft"),
            ConversationMessage(seq: 9, role: "error", text: "the provider returned an error"),
        ], "only what came after seq 4")
        #expect(read.pendingApprovals == [ConversationApproval(approvalID: "a1", tool: "shell_run", reason: "Scripts require approval")])
        #expect(read.lastSeq == 9 && !read.truncated && !read.timedOut && read.title == "Docs")
        #expect(fixture.host.requests(AgentAttachRequest.self).allSatisfy { $0.taskID == Self.childTask.taskID && $0.waitMilliseconds == 0 })

        var reader = ConversationReader(afterSeq: 0, byteLimit: 1024)
        reader.take(batch([("prompt", text("go")), ("messageStarted", nil)]))
        #expect(reader.state == .running && !reader.isSettled)
        reader.take(batch([("finished", .object(["reason": .string("completed")]))], from: 3))
        #expect(reader.state == .idle && reader.isSettled)
        reader.take(batch([], from: 4, state: .succeeded))
        #expect(reader.state == .ended)
    }

    @Test
    func `read waits for the turn after its point to finish, across attaches`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentList, reply: AgentListResponse(sessions: [summary()]))
        // The previous turn finished at seq 2; the new prompt is still on
        // its way when the read starts, so "idle" is not the answer yet.
        let history = batch([("prompt", text("Write the README")), ("finished", .object(["reason": .string("completed")]))])
        let later = [
            batch([("prompt", text("Also the changelog")), ("messageStarted", nil)], from: 3),
            batch([("message", text("Done: README and CHANGELOG")), ("finished", .object(["reason": .string("completed")]))], from: 5),
        ]
        let waits = Counter()
        fixture.host.on(.agentAttach) { request in
            let attach = try request.decode(AgentAttachRequest.self)
            switch attach.afterSeq.rawValue {
            case 0: return (history, [])
            case 2 where attach.waitMilliseconds == 0: return (batch([], from: 3), [])
            case 2: waits.add(); return (later[0], [])
            case 4: waits.add(); return (later[1], [])
            default: return (batch([], from: attach.afterSeq.rawValue + 1), [])
            }
        }
        let read = try await fixture.backend.conversationRead(ConversationReadToolRequest(
            context: fixture.context(),
            sessionID: Self.child,
            afterSeq: 2,
            waitSeconds: 30,
        ))
        #expect(read.state == .idle && !read.timedOut)
        #expect(read.messages.map(\.text) == ["Done: README and CHANGELOG"])
        #expect(read.lastSeq == 6)
        #expect(waits.value == 2)
        let polls = fixture.host.requests(AgentAttachRequest.self).filter { $0.waitMilliseconds > 0 }
        #expect(polls.allSatisfy { $0.waitMilliseconds <= ChannelHostBackend.conversationPollMilliseconds })
    }

    @Test
    func `a wait that runs out says so`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentList, reply: AgentListResponse(sessions: [summary()]))
        fixture.host.on(.agentAttach) { request in
            let attach = try request.decode(AgentAttachRequest.self)
            if attach.afterSeq == .start {
                return (batch([("prompt", text("go")), ("messageStarted", nil)]), [])
            }
            // The host would hold the attach until an event or its bound.
            if attach.waitMilliseconds > 0 {
                usleep(100_000)
            }
            return (batch([], from: 3), [])
        }
        let read = try await fixture.backend.conversationRead(ConversationReadToolRequest(context: fixture.context(), sessionID: Self.child, waitSeconds: 1))
        #expect(read.state == .running && read.timedOut && read.messages.isEmpty && read.lastSeq == 2)
        let unwaited = try await fixture.backend.conversationRead(ConversationReadToolRequest(context: fixture.context(), sessionID: Self.child))
        #expect(unwaited.state == .running && !unwaited.timedOut, "without wait_seconds it answers at once")
    }

    @Test
    func `the messages are cut at the bound and the next read goes on from there`() {
        var reader = ConversationReader(afterSeq: 0, byteLimit: 100)
        reader.take(batch([
            ("message", text(String(repeating: "a", count: 60))),
            ("message", text(String(repeating: "b", count: 60))),
            ("message", text("c")),
            ("finished", .object(["reason": .string("completed")])),
        ]))
        var read = reader.response(sessionID: "s", title: nil, timedOut: false)
        #expect(read.truncated && read.messages.map(\.seq) == [1] && read.lastSeq == 1)
        #expect(reader.isSettled, "a cut read does not wait")

        var next = ConversationReader(afterSeq: read.lastSeq, byteLimit: 100)
        next.take(batch([
            ("message", text(String(repeating: "a", count: 60))),
            ("message", text(String(repeating: "b", count: 60))),
            ("message", text("c")),
            ("finished", .object(["reason": .string("completed")])),
        ]))
        read = next.response(sessionID: "s", title: nil, timedOut: false)
        #expect(!read.truncated && read.messages.map(\.seq) == [2, 3] && read.lastSeq == 4)

        var huge = ConversationReader(afterSeq: 0, byteLimit: 100)
        huge.take(batch([("message", text(String(repeating: "x", count: 500))), ("message", text("after"))]))
        read = huge.response(sessionID: "s", title: nil, timedOut: false)
        #expect(read.truncated && read.messages.count == 1 && read.lastSeq == 1)
        #expect(read.messages[0].text.hasPrefix(String(repeating: "x", count: 100)) && read.messages[0].text.contains("cut at"))
        #expect(ChannelHostBackend.maximumConversationBytes == 32 * 1024)
    }

    @Test
    func `a message from another conversation reaches the task as a prompt with from`() {
        var waiting = 0
        let marked = EventRelay.events(for: .promptSubmitted(text: "Review Tweak.x", from: "opener"), waiting: &waiting)
        #expect(marked.count == 1 && marked[0].0 == "prompt")
        #expect(marked[0].1?["text"]?.stringValue == "Review Tweak.x" && marked[0].1?["from"]?.stringValue == "opener")
        let typed = EventRelay.events(for: .promptSubmitted(text: "hi"), waiting: &waiting)
        #expect(typed[0].1?["from"] == nil, "the user's own prompt has no from")
    }

    @Test
    func `the model choice follows the open request and the app's prompts`() async {
        let choice = SessionModelChoice(provider: .githubCopilot, model: "claude-sonnet-5.5")
        #expect(await choice.current == SessionModelChoice.Choice(provider: .githubCopilot, model: "claude-sonnet-5.5", reasoningEffort: nil))
        await choice.set(provider: .openAI, model: "gpt", reasoningEffort: .low, serviceTier: nil)
        let current = await choice.current
        #expect(current.provider == .openAI && current.reasoningEffort == .low)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
