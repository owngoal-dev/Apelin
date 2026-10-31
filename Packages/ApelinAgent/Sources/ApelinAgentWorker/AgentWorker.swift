import ApelinAgent
import ApelinCore
import ApelinProtocol
import Darwin
import Foundation
import KWWKAI

/// `apelin-agent`: one agent session per process. The session host spawns
/// it as mobile for `agentOpen` (instance = session id) and forwards the
/// session's prompt, steer, abort, approve and close to it; the same
/// executable, spawned as the `credential-import` instance, serves
/// `agentCredentialImport` and the accounts: `agentAccountList`,
/// `agentSignIn` (a `signIn` task), `agentSignInRespond`, its cancel and
/// `agentSignOut` (`AccountDesk`), and Settings ▸ Skills' `agentSkillList`.
///
/// The session's events go to the host as the events of its `agent` task.
public enum AgentWorker {
    /// Apelin's own keychain items, shared by nothing else.
    public static let keychainAccessGroup = "wiki.qaq.apelin.agent"
    public static let defaultCopilotModel = "claude-sonnet-5.5"

    /// Sign-ins and the accounts list, against the keychain the sessions read.
    static let accounts = AccountDesk(store: KeychainCredentialSource(accessGroup: keychainAccessGroup))

    public static func main() -> Never {
        let state = WorkerState()
        WorkerMain.run(role: .agent, onCancel: { taskID, _ in
            Task {
                // A sign-in's cancel ends that sign-in; any other is the session's.
                if await accounts.cancel(taskID) {
                    return
                }
                await state.abort()
            }
        }, onClose: {
            // the host has gone and the worker exits next: what still runs
            // never ends, and the journal says so while it can
            SessionJournal.interruptAll(reason: "the session host closed the worker's channel")
        }) { request, context in
            await handle(request, context: context, state: state)
        }
    }

    static func handle(
        _ request: ChannelRequest,
        context: WorkerContext,
        state: WorkerState,
    ) async -> (WireReply, [OwnedDescriptor]) {
        switch request.request.operation {
        case .agentOpen:
            await WorkerMain.serve(AgentOpenRequest.self, request) { open in
                guard let taskID = request.taskID else {
                    throw ApelinError(.badRequest, "agentOpen comes with its task")
                }
                try await state.open(open, taskID: taskID, context: context)
                return AgentOpenResponse(
                    sessionID: context.assignment.sessionID ?? "",
                    task: TaskHandle(taskID: taskID, kind: .agent),
                )
            }
        case .agentPrompt:
            await WorkerMain.serve(AgentPromptRequest.self, request) { prompt in
                let session = try await state.session(prompt.sessionID)
                if let mode = prompt.approvalMode {
                    await session.setApprovalMode(AgentWorker.approvalMode(mode))
                }
                if let asks = prompt.asksBeforeScreen {
                    await session.setAsksBeforeScreen(asks)
                }
                if let provider = prompt.provider {
                    try await session.configure(
                        provider: AgentWorker.provider(AgentOpenRequest(provider: provider, model: prompt.model)),
                        thinking: .init(rawValue: prompt.reasoningEffort?.rawValue ?? "off") ?? .off,
                        serviceTier: AgentWorker.serviceTier(prompt.serviceTier),
                        credentials: KeychainCredentialSource(accessGroup: keychainAccessGroup),
                    )
                    await state.modelChoice.set(
                        provider: provider,
                        model: prompt.model,
                        reasoningEffort: prompt.reasoningEffort,
                        serviceTier: prompt.serviceTier,
                    )
                }
                guard (prompt.attachments?.count ?? 0) <= 8 else {
                    throw ApelinError(.badRequest, "invalid attachment descriptor")
                }
                let limit = AgentSession.maximumAttachmentBytes
                let files = try (prompt.attachments ?? []).map { attachment -> (name: String, mimeType: String, data: Data) in
                    guard request.descriptors.indices.contains(attachment.descriptor.index) else {
                        throw ApelinError(.badRequest, "invalid attachment descriptor")
                    }
                    let descriptor = request.descriptors[attachment.descriptor.index]
                    var info = stat()
                    guard fstat(descriptor.rawValue, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                          info.st_size >= 0, info.st_size <= off_t(limit)
                    else {
                        throw ApelinError(
                            .badRequest,
                            "attachments must be regular files no larger than \(limit >> 20) MB",
                        )
                    }
                    let handle = FileHandle(fileDescriptor: descriptor.rawValue, closeOnDealloc: false)
                    try handle.seek(toOffset: 0)
                    let data = try handle.read(upToCount: limit + 1) ?? Data()
                    guard data.count <= limit else { throw ApelinError(.badRequest, "attachment too large") }
                    return (attachment.name, attachment.mimeType, data)
                }
                var sender: ConversationSender?
                if let from = prompt.fromSessionID {
                    sender = await AgentWorker.sender(from, context: context)
                }
                try await session.prompt(prompt.text, messageID: prompt.messageID, files: files, from: sender)
                await session.generateTitle(for: prompt.text)
                return Acknowledged()
            }
        case .agentSteer:
            await WorkerMain.serve(AgentSteerRequest.self, request) { steer in
                try await state.session(steer.sessionID).steer(steer.text)
                return Acknowledged()
            }
        case .agentAbort:
            await WorkerMain.serve(AgentAbortRequest.self, request) { abort in
                try await (state.session(abort.sessionID)).abort()
                return Acknowledged()
            }
        case .agentCompact:
            await WorkerMain.serve(AgentCompactRequest.self, request) { compact in
                try await state.session(compact.sessionID).compact()
                return Acknowledged()
            }
        case .agentApprove:
            await WorkerMain.serve(AgentApproveRequest.self, request) { approve in
                try await state.approve(approve)
                return Acknowledged()
            }
        case .agentClose:
            await WorkerMain.serve(AgentCloseRequest.self, request) { close in
                _ = try await state.session(close.sessionID)
                await state.close(.succeeded, message: "closed")
                return Acknowledged()
            }
        case .agentCredentialImport:
            await WorkerMain.serve(AgentCredentialImportRequest.self, request) { _ in
                await CredentialInbox(home: context.assignment.home)
                    .importAll(into: KeychainCredentialSource(accessGroup: keychainAccessGroup))
            }
        case .agentAccountList:
            await WorkerMain.serve(AgentAccountListRequest.self, request) { _ in
                await accounts.list()
            }
        case .agentSkillList:
            await WorkerMain.serve(AgentSkillListRequest.self, request) { _ in
                let home = URL(fileURLWithPath: context.assignment.home, isDirectory: true)
                return SkillCatalog.listing(userDirectory: ApelinDataRoot(home: home).skills)
            }
        case .agentAPIConfiguration:
            await WorkerMain.serve(AgentAPIConfigurationRequest.self, request) { query in
                try await accounts.apiConfiguration(for: query.provider)
            }
        case .agentModelList:
            await WorkerMain.serve(AgentModelListRequest.self, request) { query in
                try await accounts.models(for: query.provider)
            }
        case .agentModelActivate:
            await WorkerMain.serve(AgentModelActivateRequest.self, request) { query in
                guard let taskID = request.taskID else {
                    throw ApelinError(.badRequest, "model verification requires a task")
                }
                try await accounts.activateModels(query, taskID: taskID, reporter: SignInReporter(context: context))
                return TaskHandle(taskID: taskID, kind: .signIn)
            }
        case .agentSignIn:
            await WorkerMain.serve(AgentSignInRequest.self, request) { signIn in
                guard let taskID = request.taskID else {
                    throw ApelinError(.badRequest, "agentSignIn comes with its task")
                }
                try await accounts.start(signIn, taskID: taskID, reporter: SignInReporter(context: context))
                return TaskHandle(taskID: taskID, kind: .signIn)
            }
        case .agentSignInRespond:
            await WorkerMain.serve(AgentSignInRespondRequest.self, request) { respond in
                try await accounts.respond(respond)
                return Acknowledged()
            }
        case .agentSignOut:
            await WorkerMain.serve(AgentSignOutRequest.self, request) { signOut in
                try await accounts.signOut(signOut.provider)
                return Acknowledged()
            }
        default:
            WorkerMain.unimplemented(request)
        }
    }

    /// The conversation a message came from (the host wrote its session ID),
    /// with its title when the host lists one.
    static func sender(_ sessionID: String, context: WorkerContext) async -> ConversationSender {
        let listed = try? await context.host.agentList().sessions.first { $0.sessionID == sessionID }
        return ConversationSender(sessionID: sessionID, title: listed?.title)
    }

    /// The wire's approval mode as the session's gate takes it.
    static func approvalMode(_ wire: ApelinProtocol.ApprovalMode) -> ApelinAgent.ApprovalMode {
        switch wire {
        case .relaxed: .relaxed
        case .confirm: .confirm
        case .full: .full
        }
    }

    static func serviceTier(_ wire: AgentServiceTier?) -> ServiceTier? {
        wire.flatMap { ServiceTier(rawValue: $0.rawValue) }
    }

    /// The kwwk provider configuration for an open request. The first four
    /// keep their own cases (and need a model named, as they always have);
    /// every other provider uses its credential store id and the default
    /// model chosen by ProviderRegistration when none is named.
    static func provider(_ open: AgentOpenRequest) throws -> ProviderConfiguration {
        let model = open.model.flatMap { $0.isEmpty ? nil : $0 }
        let provider = open.provider ?? .githubCopilot
        switch provider {
        case .githubCopilot:
            return .githubCopilot(model: model ?? defaultCopilotModel)
        case .anthropic:
            guard let model else { throw ApelinError(.badRequest, "name the model for \(provider.rawValue)") }
            return .anthropic(model: model, oauth: false)
        case .anthropicOAuth:
            guard let model else { throw ApelinError(.badRequest, "name the model for \(provider.rawValue)") }
            return .anthropic(model: model, oauth: true)
        case .openAICompatible:
            guard let model else { throw ApelinError(.badRequest, "name the model for \(provider.rawValue)") }
            return .openAICompatible(model: model)
        case .openAICodex, .cursor, .devin, .kiro, .qoder, .qoderCN, .workBuddy, .workBuddyAI, .kimiCoding,
             .kimiCodingGlobal, .xai, .zai, .zaiCodingCN, .openRouter, .openAI, .google, .deepSeek, .openCodeGo,
             .openCodeZen:
            return .stored(storeID: provider.storeID, model: model)
        }
    }
}

/// The one session this process serves, and the relay of its events.
actor WorkerState {
    /// What the session runs with now, which a conversation it opens starts with.
    let modelChoice = SessionModelChoice()
    private var session: AgentSession?
    /// An open is under way. It takes the place before its first
    /// suspension, so an open the host sends meanwhile is refused rather
    /// than served by a second session writing the same log.
    private var opening = false
    private var taskID: TaskID?
    private var context: WorkerContext?
    private var relay: Task<Void, Never>?
    private var closeWhenFinished = false
    private var finished = false

    func open(_ open: AgentOpenRequest, taskID: TaskID, context: WorkerContext) async throws {
        guard session == nil, !opening else {
            throw ApelinError(.conflict, "this process already serves or is opening a session")
        }
        guard let sessionID = context.assignment.sessionID, SessionEventLog.isValidSessionID(sessionID) else {
            throw ApelinError(.badRequest, "an agent session needs a session id from the host")
        }
        guard let projectID = open.projectID, let projectName = open.projectName else {
            throw ApelinError(.badRequest, "the host did not name the session's project")
        }
        let identity: ApelinAgent.ProjectIdentity
        do {
            identity = try ApelinAgent.ProjectIdentity(id: projectID, name: ApelinAgent.ProjectName(projectName))
        } catch {
            throw ApelinError(.badRequest, "\(projectName) is not a project name")
        }
        let home = URL(fileURLWithPath: context.assignment.home, isDirectory: true)
        let dataRoot = ApelinDataRoot(home: home)
        let projectURL = dataRoot.workspace(for: identity.name, temporaryID: open.temporaryID)

        opening = true
        // one that fails leaves the place free for the host to try again
        defer { opening = false }
        // Credentials the owner dropped in the inbox are taken first.
        let keychain = KeychainCredentialSource(accessGroup: AgentWorker.keychainAccessGroup)
        let imported = await CredentialInbox(home: context.assignment.home).importAll(into: keychain)

        let ledger = HostDigestLedger(service: context.host, projectURL: projectURL, dataFolder: dataRoot.url)
        let session: AgentSession
        do {
            session = try await AgentSession(
                configuration: AgentSessionConfiguration(
                    id: sessionID,
                    project: identity,
                    temporaryID: open.temporaryID,
                    provider: AgentWorker.provider(open),
                    approval: ApprovalPolicy(
                        mode: AgentWorker.approvalMode(open.approvalMode),
                        asksBeforeScreen: ScreenConsent.asks(open.asksBeforeScreen),
                    ),
                    dataRoot: dataRoot,
                    thinking: .init(rawValue: open.reasoningEffort?.rawValue ?? "off") ?? .off,
                    serviceTier: AgentWorker.serviceTier(open.serviceTier),
                    installRoot: context.assignment.installRoot,
                    hostRestarted: open.hostRestarted == true,
                ),
                backend: ChannelHostBackend(
                    service: context.host,
                    sessionID: sessionID,
                    project: identity,
                    projectURL: projectURL,
                    projectsURL: dataRoot.projects,
                    modelChoice: modelChoice,
                ),
                digests: ledger,
                credentials: keychain,
            )
        } catch let error as ProviderResolutionError {
            var message = error.localizedDescription
            if !imported.rejected.isEmpty {
                message += " (inbox: \(imported.rejected.joined(separator: "; ")))"
            }
            throw ApelinError(.denied, message)
        } catch let error as ApelinError {
            throw error
        } catch {
            throw ApelinError(.internal, error.localizedDescription)
        }

        self.session = session
        self.taskID = taskID
        self.context = context
        closeWhenFinished = open.closeWhenFinished == true
        await modelChoice.set(
            provider: open.provider,
            model: open.model,
            reasoningEffort: open.reasoningEffort,
            serviceTier: open.serviceTier,
        )

        let events = try await session.events(afterSeq: 0)
        let relay = EventRelay(context: context, taskID: taskID)
        self.relay = Task { [weak self] in
            for await record in events {
                await relay.relay(record.event)
                if case let .finished(reason) = record.event {
                    await relay.flush()
                    await self?.runFinished(reason)
                }
            }
            await relay.flush()
        }
        if let prompt = open.prompt, !prompt.isEmpty {
            try await session.prompt(prompt)
            // A conversation another agent opened is named by its opener,
            // or like one the user started; a headless run is not named.
            if let title = open.title {
                await session.setTitle(title)
            } else if !closeWhenFinished {
                await session.generateTitle(for: prompt)
            }
        }
    }

    func session(_ id: String) throws -> AgentSession {
        guard let session, id == session.id else {
            throw ApelinError(.notFound, "this process does not serve session \(id)")
        }
        return session
    }

    func approve(_ approve: AgentApproveRequest) async throws {
        let session = try session(approve.sessionID)
        guard await session.pendingApprovals.contains(where: { $0.id == approve.approvalID }) else {
            throw ApelinError(.notFound, "This approval request is no longer waiting for a decision.")
        }
        // The host records a description or removal approval in its own
        // ledger as it relays this decision; the agent keeps nothing.
        try await session.approve(requestID: approve.approvalID, decision: Self.decision(approve))
    }

    /// The app's decision as the session's gate takes it: "for this
    /// session" where the app said so (the gate keeps it only for a request
    /// that offered it, and the host records the matching grant).
    static func decision(_ approve: AgentApproveRequest) -> ApelinAgent.ApprovalDecision {
        guard approve.decision == .approve else { return .deny(reason: "denied in Apelin") }
        return .approve(approve.scope == .session ? .session : .once)
    }

    func abort() async {
        await session?.abort()
    }

    /// A run ended; a headless session ends with it.
    private func runFinished(_ reason: FinishReason) async {
        guard closeWhenFinished else { return }
        let state: TaskState = switch reason {
        case .completed: .succeeded
        case .aborted: .cancelled
        case .failed: .failed
        }
        await close(state, message: "the run \(reason.rawValue)")
    }

    /// Ends the task and, a moment after the reply has gone, the process.
    func close(_ state: TaskState, message: String) async {
        guard !finished else { return }
        finished = true
        let session = session
        let context = context
        let taskID = taskID
        Task.detached {
            await session?.close()
            if let context, let taskID {
                context.finish(taskID, state, message: message)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }
}

/// Turns session events into task events. Streamed text is coalesced into
/// `text` events of at least a few hundred bytes or a quarter second apart,
/// so a long answer is not thousands of events in the host's registry. The
/// run's `received` count goes out with the same flushes, its latest only.
actor EventRelay {
    private let emit: @Sendable (String, ApelinCore.JSONValue?) -> Void
    private var text = ""
    private var thinking = ""
    private var received: Int?
    private var lastFlush = Date()
    private var flushScheduled = false
    private var waiting = 0

    init(context: WorkerContext, taskID: TaskID) {
        self.init { kind, payload in context.emit(taskID, kind, payload) }
    }

    /// `emit` takes each task event, in order.
    init(emit: @escaping @Sendable (String, ApelinCore.JSONValue?) -> Void) {
        self.emit = emit
    }

    func relay(_ event: AgentSessionEvent) {
        switch event {
        case let .textDelta(delta):
            text += delta
            scheduleFlush()
            return
        case let .thinkingDelta(delta):
            thinking += delta
            scheduleFlush()
            return
        case let .received(tokens):
            received = tokens
            scheduleFlush()
            return
        default:
            flush()
        }
        for (kind, payload) in Self.events(for: event, waiting: &waiting) {
            emit(kind, payload)
        }
    }

    func flush() {
        if !thinking.isEmpty {
            emit("thinking", .object(["text": .string(thinking)]))
        }
        if !text.isEmpty {
            emit("text", .object(["text": .string(text)]))
        }
        if let received {
            for (kind, payload) in Self.events(for: .received(tokens: received), waiting: &waiting) {
                emit(kind, payload)
            }
        }
        text = ""
        thinking = ""
        received = nil
        lastFlush = Date()
    }

    private func scheduleFlush() {
        if text.utf8.count + thinking.utf8.count >= 512 || Date().timeIntervalSince(lastFlush) > 0.25 {
            flush()
            return
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.timedFlush()
        }
    }

    private func timedFlush() {
        flushScheduled = false
        flush()
    }

    /// The task events one session event becomes. Kinds and payloads are
    /// listed in AGENTS.md ▸ Decisions ▸ Agent sessions.
    static func events(for event: AgentSessionEvent, waiting: inout Int) -> [(String, ApelinCore.JSONValue?)] {
        switch event {
        case let .userMessage(id, text, attachments):
            return [("prompt", .object([
                "id": .string(id.uuidString),
                "text": .string(text),
                "attachments": (try? ApelinCore.JSONValue(encoding: attachments)) ?? .array([]),
            ]))]
        case let .userMessageQueued(id, text, attachments):
            return [("queued", .object([
                "id": .string(id.uuidString),
                "text": .string(text),
                "attachments": (try? ApelinCore.JSONValue(encoding: attachments)) ?? .array([]),
            ]))]
        case let .queuedMessagesDropped(ids):
            return [("queueDropped", .object(["ids": .array(ids.map { .string($0.uuidString) })]))]
        case let .promptSubmitted(text, from):
            var payload: [String: ApelinCore.JSONValue] = ["text": .string(text)]
            if let from {
                payload["from"] = .string(from)
            }
            return [("prompt", .object(payload))]
        case let .titleUpdated(title):
            return [("title", .object(["text": .string(title)]))]
        case let .projectNameSuggested(name):
            return [("projectNameSuggested", .object(["name": .string(name)]))]
        case let .steered(text):
            return [("steer", .object(["text": .string(text)]))]
        case .messageStarted:
            return [("messageStarted", nil)]
        case .messageDiscarded:
            return [("messageDiscarded", nil)]
        case .reconnecting:
            return [("reconnecting", nil)]
        case .toolCallPreparing:
            return [("toolCallPreparing", nil)]
        case let .textDelta(text):
            return [("text", .object(["text": .string(text)]))]
        case let .thinkingDelta(text):
            return [("thinking", .object(["text": .string(text)]))]
        case let .messageFinished(text):
            return [("message", .object(["text": .string(text)]))]
        case let .received(tokens):
            return [("received", .object(["tokens": .number(Double(tokens))]))]
        case let .toolCallStarted(call):
            return [("toolCall", .object([
                "id": .string(call.id),
                "tool": .string(call.name),
                "arguments": .string(ToolArgumentRedaction.redacted(call.arguments, tool: call.name)),
            ]))]
        case let .toolCallFinished(result):
            return [("toolResult", .object([
                "id": .string(result.id),
                "tool": .string(result.name),
                "output": .string(result.output),
                "isError": .bool(result.isError),
                "attachments": (try? ApelinCore.JSONValue(encoding: result.attachments ?? [])) ?? .array([]),
            ]))]
        case let .approvalRequested(request):
            waiting += 1
            return [
                ("approvalRequested", approvalPayload(request)),
                (TaskEvent.stateKind, .object(["state": .string(TaskState.waitingForApproval.rawValue)])),
            ]
        case let .approvalResolved(requestID, decision):
            waiting = max(0, waiting - 1)
            var resolved: [(String, ApelinCore.JSONValue?)] = [("approvalResolved", .object([
                "approvalID": .string(requestID),
                "decision": .string(decisionName(decision)),
            ]))]
            if waiting == 0 {
                resolved.append((TaskEvent.stateKind, .object(["state": .string(TaskState.running.rawValue)])))
            }
            return resolved
        case let .notice(title, body):
            var payload: [String: ApelinCore.JSONValue] = ["body": .string(body)]
            if let title {
                payload["title"] = .string(title)
            }
            return [(AgentNoticeRules.eventKind, .object(payload))]
        case let .error(message):
            return [("error", .object(["message": .string(message)]))]
        case let .finished(reason):
            return [("finished", .object(["reason": .string(reason.rawValue)]))]
        case .compactionStarted:
            return [("compactionStarted", nil)]
        case let .compactionFinished(result):
            return [("compactionFinished", (try? ApelinCore.JSONValue(encoding: result)) ?? .null)]
        }
    }

    static func approvalPayload(_ request: ApprovalRequest) -> ApelinCore.JSONValue {
        var payload: [String: ApelinCore.JSONValue] = [
            "approvalID": .string(request.id),
            "toolCallID": .string(request.toolCallID),
            "tool": .string(request.tool),
            "arguments": .string(ToolArgumentRedaction.redacted(request.arguments, tool: request.tool)),
            "workingDirectory": .string(request.workingDirectory),
            "projectID": .string(request.projectID),
            "fingerprint": .string(request.fingerprint),
            "reason": .string(request.reason),
            "allowsSessionScope": .bool(request.allowsSessionScope),
        ]
        switch request.detail {
        case .none:
            break
        case let .descriptionChanged(kind, digest, diff):
            payload["detail"] = .object(["descriptionChanged": .object([
                "kind": .string(kind.rawValue),
                "digest": .string(digest),
                "diff": .string(diff),
            ])])
        case let .command(invocation):
            payload["detail"] = .object(["command": (try? ApelinCore.JSONValue(encoding: invocation)) ?? .null])
        // Its own key, so the host never takes it for an ordinary command's
        // approval, nor the other way round.
        case let .rootCommand(invocation):
            payload["detail"] = .object([
                RunCodeApproval.rootCommandDetail: (try? ApelinCore.JSONValue(encoding: invocation)) ?? .null,
            ])
        case let .packageRemoval(installationID):
            payload["detail"] = .object(["packageRemoval": .object(["installationID": .string(installationID)])])
        case let .gitPush(remote, branch):
            var push: [String: ApelinCore.JSONValue] = ["remote": .string(remote)]
            if let branch {
                push["branch"] = .string(branch)
            }
            payload["detail"] = .object(["gitPush": .object(push)])
        // The push and lease the host matches an agent's forced gitPush to
        // (AgentForcePushRules).
        case let .forcePush(force):
            payload["detail"] = .object(["forcePush": (try? ApelinCore.JSONValue(encoding: force)) ?? .null])
        // The squash the host matches an agent's gitSquash to
        // (AgentSquashRules).
        case let .squash(squash):
            payload["detail"] = .object(["squash": (try? ApelinCore.JSONValue(encoding: squash)) ?? .null])
        case let .gitSettings(summary):
            payload["detail"] = .object(["gitSettings": .object(["summary": .string(summary)])])
        // What the host matches an agent's setup, import or call into another
        // project to (AgentEnvironmentRules, AgentConversationRules).
        case let .toolchainSetup(setup):
            payload["detail"] = .object(["toolchainSetup": (try? ApelinCore.JSONValue(encoding: setup)) ?? .null])
        case let .sdkImport(sdkImport):
            payload["detail"] = .object(["sdkImport": (try? ApelinCore.JSONValue(encoding: sdkImport)) ?? .null])
        case let .otherProject(reach):
            payload["detail"] = .object(["otherProject": (try? ApelinCore.JSONValue(encoding: reach)) ?? .null])
        case let .externalBuild(build):
            payload["detail"] = .object(["externalBuild": (try? ApelinCore.JSONValue(encoding: build)) ?? .null])
        case let .skillChange(change):
            payload["detail"] = .object(["skillChange": (try? ApelinCore.JSONValue(encoding: change)) ?? .null])
        case let .projectRename(rename):
            payload["detail"] = .object(["projectRename": (try? ApelinCore.JSONValue(encoding: rename)) ?? .null])
        // The issue the host matches an agent's feedbackSend to
        // (AgentFeedbackRules).
        case let .feedback(feedback):
            payload["detail"] = .object(["feedback": (try? ApelinCore.JSONValue(encoding: feedback)) ?? .null])
        // The issue, the new text and what it was made against, which the
        // host matches an agent's feedbackEdit to (AgentFeedbackRules); a
        // field that stays is left out.
        case let .feedbackEdit(edit):
            payload["detail"] = .object(["feedbackEdit": (try? ApelinCore.JSONValue(encoding: edit)) ?? .null])
        // The repository the host matches an agent's gitRepositoryCreate to
        // (AgentRepositoryCreateRules).
        case let .repositoryCreate(repository):
            payload["detail"] = .object(["repositoryCreate": (try? ApelinCore.JSONValue(encoding: repository)) ?? .null])
        // The repository and issue the host matches an agent's
        // gitIssueCreate to (AgentIssueCreateRules).
        case let .issueCreate(issue):
            payload["detail"] = .object(["issueCreate": (try? ApelinCore.JSONValue(encoding: issue)) ?? .null])
        // The project the host matches an agent's projectDelete to
        // (AgentProjectDeleteRules).
        case let .projectDelete(deletion):
            payload["detail"] = .object(["projectDelete": (try? ApelinCore.JSONValue(encoding: deletion)) ?? .null])
        // The repository, files and digests the host matches an agent's
        // distributionPublish to (AgentPublishRules).
        case let .packagePublish(publication):
            payload["detail"] = .object(["packagePublish": (try? ApelinCore.JSONValue(encoding: publication)) ?? .null])
        // What the host matches an agent's readUITree, uiAction or
        // agentRunCode to while Ask Before Using the Screen is on
        // (AgentScreenRules).
        case let .screenControl(use):
            payload["detail"] = .object(screenDetail(use))
        // The state the host matches an agent's gitResetToRemote to
        // (AgentResetToRemoteRules).
        case let .resetToRemote(reset):
            payload["detail"] = .object(["resetToRemote": (try? ApelinCore.JSONValue(encoding: reset)) ?? .null])
        }
        return .object(payload)
    }

    /// `detail` of a screen card: `screenControl` {operation, request?},
    /// the tree read or the action as `ChannelHostBackend` sends it to the
    /// host, and a command's own `command` — `rootCommand` as root — as any
    /// shell_run card has it, which the app's card shows. A request that
    /// would not reach the host (an element with nothing to tap it by) is
    /// left out, so no approval covers it.
    static func screenDetail(_ use: ScreenControlApproval) -> [String: ApelinCore.JSONValue] {
        func marker(_ operation: AppOperation, request: ApelinCore.JSONValue? = nil) -> ApelinCore.JSONValue {
            var marker: [String: ApelinCore.JSONValue] = ["operation": .string(operation.rawValue)]
            marker["request"] = request
            return .object(marker)
        }
        switch use {
        case let .readTree(targetID):
            let request = try? ApelinCore.JSONValue(encoding: ApelinProtocol.ReadUITreeRequest(targetID: targetID))
            return [ScreenConsent.detailKey: marker(.readUITree, request: request)]
        case let .interact(targetID, action):
            let request = (try? ChannelHostBackend.action(action)).flatMap { wire in
                try? ApelinCore.JSONValue(encoding: ApelinProtocol.UIActionRequest(targetID: targetID, action: wire))
            }
            return [ScreenConsent.detailKey: marker(.uiAction, request: request)]
        case let .command(invocation, asRoot):
            let key = asRoot ? RunCodeApproval.rootCommandDetail : "command"
            return [
                ScreenConsent.detailKey: marker(.agentRunCode),
                key: (try? ApelinCore.JSONValue(encoding: invocation)) ?? .null,
            ]
        }
    }

    static func decisionName(_ decision: ApelinAgent.ApprovalDecision) -> String {
        switch decision {
        case .approve: "approve"
        case .deny: "deny"
        }
    }
}
