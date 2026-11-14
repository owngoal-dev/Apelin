import ApelinCore
import ApelinProtocol
import Foundation

/// Agent sessions: one apelin-agent per session (instance = session ID).
/// The session is a task of kind `agent`; the worker emits its events. The
/// host resolves the project, keeps each session's approval mode and the
/// approvals the app gave, and re-decides `agentRunCode` itself — the agent's
/// evidence is checked, never believed.
///
/// An agent reaches other conversations too (`AgentConversations`,
/// `AgentConversationRules`): it opens one in its own project or another
/// under its own mode, sends one a message as the user's, lists and reads a
/// project's, and aborts or closes the ones it opened. Another project is
/// reached under Confirm only with the user's approval. Approving,
/// steering and compacting stay the app's.
enum AgentHandler: DomainHandler {
    /// The instance key of the agent worker that imports credentials, runs
    /// sign-ins, lists and forgets accounts; it serves no session. One
    /// executable writes and reads the keychain group the sessions use.
    static let credentialInstance = "credential-import"

    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .agentOpen:
            return await open(request, host: host)
        case .agentPrompt:
            return await prompt(request, host: host)
        case .agentSteer:
            return await forward(request, AgentSteerRequest.self, host: host) { $0.sessionID }
        case .agentAbort:
            return await abort(request, host: host)
        case .agentCompact:
            return await forward(request, AgentCompactRequest.self, host: host) { $0.sessionID }
        case .agentApprove:
            return await approve(request, host: host)
        case .agentAttach:
            return await attach(request, host: host)
        case .agentList:
            return await request.serve(AgentListRequest.self) { list in
                // An agent lists its own project's conversations, another
                // project's it may reach, or in General Chat every one's it
                // may reach, with those that have not run since the host
                // started.
                if let caller = try await callerSession(request, host: host) {
                    return try await AgentConversationList.list(
                        list,
                        caller: caller,
                        table: .shared,
                        registry: host.registry,
                        home: host.home,
                        state: host.stateDirectory,
                    )
                }
                // The app's: the sessions it may follow, every project's or one's.
                var projectID: String?
                if list.projectID != nil || list.projectName != nil {
                    projectID = try AgentProjects.resolve(
                        home: host.home,
                        projectID: list.projectID,
                        projectName: list.projectName,
                    ).id
                }
                return await AgentListResponse(sessions: AgentSessionTable.shared.summaries(
                    registry: host.registry,
                    projectID: projectID,
                ))
            }
        case .agentClose:
            let reply = await forward(request, AgentCloseRequest.self, host: host) { $0.sessionID }
            if case .success = reply.0.result, let close = try? request.decode(AgentCloseRequest.self) {
                await forgetClosed(close.sessionID, host: host)
            }
            return reply
        case .agentRunCode:
            return await runCode(request, host: host)
        // The credential worker's operations are the app's alone (CallerPolicy).
        case .agentCredentialImport, .agentAccountList, .agentSkillList, .agentAPIConfiguration, .agentModelList,
             .agentSignOut:
            return await host.forward(request, to: .agent, instance: credentialInstance)
        case .agentModelActivate:
            do {
                _ = try request.decode(AgentModelActivateRequest.self)
            } catch {
                return request.fail(error)
            }
            return await host.startTask(request, kind: .signIn, role: .agent, instance: credentialInstance)
        case .agentSignIn:
            do {
                _ = try request.decode(AgentSignInRequest.self)
            } catch {
                return request.fail(error)
            }
            return await host.startTask(request, kind: .signIn, role: .agent, instance: credentialInstance)
        case .agentSignInRespond:
            return await respondToSignIn(request, host: host)
        case .agentSignInCancel:
            do {
                _ = try await signInTask(request.decode(AgentSignInCancelRequest.self).taskID, host: host)
            } catch {
                return request.fail(error)
            }
            return await host.cancel(request, AgentSignInCancelRequest.self)
        default:
            return request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not an agent operation"))
        }
    }

    /// A closed session holds nothing it was granted, and no shell_run of
    /// it goes on.
    private static func forgetClosed(_ sessionID: String, host: SessionHost) async {
        await host.approvals.forgetSession(sessionID)
        await AgentSessionTable.shared.forgetGrants(sessionID)
        AgentRunCode.stop(session: sessionID)
    }

    /// Closes every running session of a project, each as `agentClose`
    /// closes one, before the project's folder goes (`projectDelete`), as
    /// the app's Delete closes them first. One its worker will not close
    /// keeps the project.
    static func closeSessions(ofProject projectID: String, host: SessionHost) async throws {
        for entry in await AgentSessionTable.shared.running(project: projectID, registry: host.registry) {
            guard let worker = await host.workers.existing(.agent, instance: entry.sessionID), !worker.channel.isClosed else {
                continue
            }
            do {
                let (reply, _) = try await worker.call(WireRequest(AgentCloseRequest(sessionID: entry.sessionID)), descriptors: [])
                // one that ended meanwhile is closed already
                if case let .failure(error) = reply.result, error.code != .notFound {
                    throw error
                }
            } catch {
                let reason = (error as? ApelinError)?.message ?? String(describing: error)
                throw ApelinError(
                    .conflict,
                    "the project's conversation “\(entry.title ?? entry.sessionID)” could not be closed (\(reason)), so the project was not deleted",
                )
            }
            await forgetClosed(entry.sessionID, host: host)
        }
    }

    /// A sign-in task of this host's, still running.
    private static func signInTask(_ taskID: TaskID, host: SessionHost) async throws -> TaskRegistry.Record {
        guard let record = await host.registry.record(taskID), record.kind == .signIn else {
            throw ApelinError(.notFound, "This sign-in has ended. Try again.")
        }
        return record
    }

    /// What the user typed or pasted goes to the worker running that sign-in
    /// and nowhere else: the host neither keeps nor logs it, and a worker
    /// that is gone has nothing to hand it to.
    private static func respondToSignIn(_ request: HostRequest, host: SessionHost) async -> HostReply {
        do {
            let record = try await signInTask(request.decode(AgentSignInRespondRequest.self).taskID, host: host)
            guard !record.state.isTerminal else {
                throw ApelinError(.conflict, "This sign-in has ended. Try again.")
            }
            guard let worker = await host.workers.existing(.agent, instance: credentialInstance),
                  !worker.channel.isClosed
            else {
                throw ApelinError(.notFound, "This sign-in has ended. Try again.")
            }
            return try await worker.call(request.request, descriptors: [])
        } catch {
            return request.fail(error)
        }
    }

    /// The session of the agent worker that sent `request`, still running;
    /// nil for the app. Any other caller is refused.
    private static func callerSession(
        _ request: HostRequest,
        host: SessionHost,
    ) async throws -> AgentSessionTable.Entry? {
        switch request.caller {
        case .app:
            return nil
        case let .worker(.agent, instance?):
            guard let entry = await AgentSessionTable.shared.entry(instance),
                  let record = await host.registry.record(entry.task.taskID), !record.state.isTerminal
            else {
                throw ApelinError(.denied, "this agent worker serves no open session")
            }
            return entry
        case .worker:
            throw ApelinError(.denied, "\(request.operation.rawValue) is not available to this caller")
        }
    }

    /// Opens the session in its turn (`AgentOpenTurns`): an open of a
    /// session that is already being opened waits for that one to answer,
    /// then makes every check of its own, so it answers the task the first
    /// one registered instead of registering another. The session is the
    /// one the app names to open again, else a new one; an agent's open is
    /// always of a new one (`AgentConversationRules.childOpen`).
    private static func open(_ request: HostRequest, host: SessionHost) async -> HostReply {
        let asked: AgentOpenRequest
        do {
            asked = try request.decode(AgentOpenRequest.self)
        } catch {
            return request.fail(error)
        }
        let sessionID = (request.caller == .app ? asked.sessionID : nil) ?? UUID().uuidString.lowercased()
        guard UUID(uuidString: sessionID) != nil else {
            return request.fail(ApelinError(.badRequest, "a session ID must be a UUID"))
        }
        let reply = await AgentOpenTurns.shared.run(for: sessionID) {
            await open(request, asked, sessionID: sessionID, host: host)
        }
        return reply ?? request.fail(ApelinError(.cancelled, "the chat was not opened: the request was cancelled"))
    }

    /// Resolves the project, registers the session's task, starts its worker
    /// and hands it the request with the project filled in by the host, and
    /// `hostRestarted` when the app continues a conversation no message has
    /// reached since this host started (`AgentHostRun`). An
    /// agent's open is rewritten first (`AgentConversationRules.childOpen`),
    /// in its own project or another one it names — which under Confirm
    /// spends the user's approval of exactly that open —, takes one of that
    /// project's places for agent-opened sessions, and is announced on the
    /// opener's own task as `conversationOpened`.
    private static func open(
        _ request: HostRequest,
        _ asked: AgentOpenRequest,
        sessionID: String,
        host: SessionHost,
    ) async -> HostReply {
        let opener: AgentSessionTable.Entry?
        let open: AgentOpenRequest
        let project: ResolvedProject
        do {
            opener = try await callerSession(request, host: host)
            if let opener {
                let target = asked.projectID == nil && asked.projectName == nil
                    ? opener.project
                    : try AgentProjects.resolve(home: host.home, projectID: asked.projectID, projectName: asked.projectName)
                open = try AgentConversationRules.childOpen(asked, opener: opener, target: target)
                if target != opener.project, opener.mode.asks {
                    let approved = await AgentApprovals.spend(entry: opener, registry: host.registry) {
                        AgentConversationRules.coversOpen(open, target: target, asked: $0)
                    }
                    guard approved else {
                        throw ApelinError(
                            .denied,
                            "approval required: opening a conversation in \(target.name) needs the user's approval of this call",
                        )
                    }
                }
                project = try AgentProjects.resolve(home: host.home, projectID: open.projectID, projectName: open.projectName)
                if project != target {
                    throw ApelinError(.conflict, "the project moved while the conversation was being opened")
                }
            } else {
                open = asked
                project = try AgentProjects.resolve(
                    home: host.home,
                    projectID: open.projectID,
                    projectName: open.projectName,
                    temporaryID: open.temporaryID,
                )
            }
        } catch {
            return request.fail(error)
        }

        // No other open of this session runs until this one has answered
        // (`AgentOpenTurns`), so none registers it between this lookup and
        // the add below, however long the worker takes to open it.
        let existing = await AgentSessionTable.shared.entry(sessionID)
        // A session an agent opened, opened again after the host restarted.
        let saved = existing == nil && opener == nil && open.sessionID != nil
            ? AgentSessionLineage.load(session: sessionID, state: host.stateDirectory)
            : nil
        if let existing {
            guard existing.project == project else {
                return request.fail(ApelinError(.conflict, "This chat belongs to another project. Start a new chat."))
            }
            if let record = await host.registry.record(existing.task.taskID), !record.state.isTerminal {
                return (.success(request.requestID, AgentOpenResponse(sessionID: sessionID, task: existing.task)), [])
            }
        }
        if open.sessionID != nil {
            let metadataPath = DataFolder(home: host.home).sessions
                .appendingPathComponent(sessionID)
                .appendingPathComponent("session.json")
                .path
            if let metadata = try? AgentProjects.readManifest(metadataPath),
               metadata["project"]?["id"]?.stringValue != project.id
            {
                return request.fail(ApelinError(.conflict, "This chat belongs to another project. Start a new chat."))
            }
        }
        if opener != nil {
            guard await AgentSessionTable.shared.reserveChild(project: project.id, registry: host.registry) else {
                return request.fail(ApelinError(
                    .conflict,
                    "\(AgentConversations.maximumOpenChildren) conversations agents opened are already running in this project; stop one first",
                ))
            }
        }
        // Whether the worker is told the host restarted is the host's
        // decision (`AgentHostRun`), never the caller's.
        var resolved = await AgentHostRun.shared.forwarded(open, sessionID: sessionID, byApp: opener == nil)
        resolved.projectID = project.id
        resolved.projectName = project.name
        // Spelled out, so the worker and the host read it the same way.
        let asksBeforeScreen = ScreenConsent.asks(open.asksBeforeScreen)
        resolved.asksBeforeScreen = asksBeforeScreen
        let handle = await host.registry.create(kind: .agent, owner: .agent, ownerKey: sessionID)
        await host.notices.opened(session: sessionID, task: handle.taskID, headless: open.closeWhenFinished == true)
        // The host's own Confirm decisions (builds, installs, removals) read
        // the mode from the ledger, keyed by the worker's instance.
        await host.approvals.setMode(open.approvalMode, session: sessionID)
        do {
            var wire = try WireRequest(resolved)
            wire.requestID = request.requestID
            let worker = try await host.workers.worker(.agent, instance: sessionID)
            let (reply, _) = try await worker.call(wire, descriptors: [], taskID: handle.taskID)
            if case let .failure(error) = reply.result {
                throw error
            }
        } catch {
            let failure = (error as? ApelinError)
                ?? ApelinError(.unavailable, "The chat could not be started. Try again.")
            await host.registry.finish(handle.taskID, .failed, message: failure.description)
            if opener != nil {
                await AgentSessionTable.shared.releaseChild(project: project.id)
            }
            return request.fail(failure)
        }
        // the worker took the open's prompt as the conversation's message
        if open.prompt?.isEmpty == false {
            await AgentHostRun.shared.messageReached(sessionID)
        }
        let title = open.title ?? open.prompt.map { String($0.prefix(AgentConversationRules.maximumTitleLength)) }
        if let opener {
            AgentSessionLineage.save(
                AgentSessionLineage.Record(parentSessionID: opener.sessionID, depth: opener.depth + 1),
                session: sessionID,
                state: host.stateDirectory,
            )
        }
        // A session the app opens again keeps the opener it had, after a
        // restart too.
        await AgentSessionTable.shared.add(
            AgentSessionTable.Entry(
                sessionID: sessionID,
                task: handle,
                project: project,
                mode: open.approvalMode,
                asksBeforeScreen: asksBeforeScreen,
                title: title ?? existing?.title,
                createdAt: Date(),
                parentSessionID: opener?.sessionID ?? existing?.parentSessionID ?? saved?.parentSessionID,
                depth: opener.map { $0.depth + 1 } ?? existing?.depth ?? saved?.depth ?? 0,
            ),
            releasingReservation: opener != nil,
        )
        if let opener, let prompt = open.prompt {
            await host.registry.append(
                opener.task.taskID,
                kind: AgentConversations.openedEventKind,
                payload: AgentConversationRules.openedEvent(
                    sessionID: sessionID,
                    task: handle,
                    title: open.title,
                    prompt: prompt,
                    project: project,
                ),
            )
        }
        return (.success(request.requestID, AgentOpenResponse(sessionID: sessionID, task: handle)), [])
    }

    /// The app's prompt goes as it is, minus any `fromSessionID`, and sets
    /// the session's mode and Ask Before Using the Screen first; an agent's
    /// is rewritten as a message from its session
    /// (`AgentConversationRules.childPrompt`) and changes neither.
    /// Either one its worker took has reached the session in this host's
    /// run (`AgentHostRun`).
    private static func prompt(_ request: HostRequest, host: SessionHost) async -> HostReply {
        let prompt: AgentPromptRequest
        var wire: WireRequest
        do {
            let asked = try request.decode(AgentPromptRequest.self)
            if let sender = try await callerSession(request, host: host) {
                let target = await AgentSessionTable.shared.entry(asked.sessionID)
                prompt = try AgentConversationRules.childPrompt(
                    asked,
                    sender: sender,
                    target: target,
                    descriptorCount: request.descriptors.count,
                )
                // Another project's conversation: under Confirm, the user's
                // approval of exactly this message, spent here.
                if let target, target.project != sender.project, sender.mode.asks {
                    let approved = await AgentApprovals.spend(entry: sender, registry: host.registry) {
                        AgentConversationRules.coversSend(prompt, target: target, asked: $0)
                    }
                    guard approved else {
                        throw ApelinError(
                            .denied,
                            "approval required: a message to a conversation of \(target.project.name) needs the user's approval of this call",
                        )
                    }
                }
            } else {
                prompt = AgentConversationRules.appPrompt(asked)
            }
            wire = try WireRequest(prompt)
            wire.requestID = request.requestID
        } catch {
            return request.fail(error)
        }
        let reply = await deliver(request, wire, to: prompt.sessionID, host: host) {
            // Applied before forwarding: the worker can start tools before its reply arrives.
            if let asks = prompt.asksBeforeScreen {
                await AgentSessionTable.shared.setAsksBeforeScreen(asks, session: prompt.sessionID)
            }
            guard let mode = prompt.approvalMode else { return }
            await host.approvals.setMode(mode, session: prompt.sessionID)
            await AgentSessionTable.shared.setMode(mode, session: prompt.sessionID)
        }
        if case .success = reply.0.result {
            await AgentHostRun.shared.messageReached(prompt.sessionID)
        }
        return reply
    }

    /// An agent reads its own project's conversations, and another
    /// project's it may reach (`AgentConversationList.mayAttach`).
    private static func attach(_ request: HostRequest, host: SessionHost) async -> HostReply {
        do {
            if let caller = try await callerSession(request, host: host) {
                let attach = try request.decode(AgentAttachRequest.self)
                try await AgentConversationList.mayAttach(
                    attach.taskID,
                    caller: caller,
                    table: .shared,
                    registry: host.registry,
                    home: host.home,
                )
            }
        } catch {
            return request.fail(error)
        }
        return await host.attach(request, AgentAttachRequest.self)
    }

    /// Hands a session request to that session's running worker: from the
    /// app for any session; from an agent only for a session it opened.
    private static func forward<R: OperationRequest>(
        _ request: HostRequest,
        _: R.Type,
        host: SessionHost,
        sessionID: (R) -> String,
    ) async -> HostReply {
        do {
            let id = try await reachable(request, R.self, host: host, sessionID: sessionID)
            return await deliver(request, request.request, to: id, host: host)
        } catch {
            return request.fail(error)
        }
    }

    /// The session a request names, once its caller may reach it.
    private static func reachable<R: OperationRequest>(
        _ request: HostRequest,
        _: R.Type,
        host: SessionHost,
        sessionID: (R) -> String,
    ) async throws -> String {
        let id = try sessionID(request.decode(R.self))
        if let caller = try await callerSession(request, host: host) {
            try await AgentConversationRules.mayStop(
                AgentSessionTable.shared.entry(id),
                caller: caller,
                sessionID: id,
            )
        }
        return id
    }

    /// How long a session's worker has to take a stop before the host ends
    /// it: taking one only flags the run, so a worker that has not answered
    /// by then is not serving its session any more.
    static let stopPatience = 10.0

    /// Stops a session's run, and the shell_run calls it was waiting on
    /// with it. A worker that does not take the stop is ended (#59): its
    /// task ends there, which the app reads as the turn's end, and the
    /// conversation opens again on its next message with what its
    /// transcript kept. Left running, it could be neither stopped nor
    /// continued.
    private static func abort(_ request: HostRequest, host: SessionHost) async -> HostReply {
        let id: String
        do {
            id = try await reachable(request, AgentAbortRequest.self, host: host) { $0.sessionID }
        } catch {
            return request.fail(error)
        }
        let taken = await Patience.answer(within: stopPatience) {
            await deliver(request, request.request, to: id, host: host)
        }
        guard let reply = taken else {
            NSLog("apelind-session: agent session %@ did not take a stop; ending its worker", id)
            AgentRunCode.stop(session: id)
            await host.workers.end(.agent, instance: id)
            return (.success(request.requestID, Acknowledged()), [])
        }
        if case .success = reply.0.result {
            AgentRunCode.stop(session: id)
        }
        return reply
    }

    /// Sends `wire` to session `id`'s running worker, after `prepare`.
    private static func deliver(
        _ request: HostRequest,
        _ wire: WireRequest,
        to id: String,
        host: SessionHost,
        prepare: () async -> Void = {},
    ) async -> HostReply {
        guard await AgentSessionTable.shared.entry(id) != nil, let worker = await host.workers.existing(.agent, instance: id), !worker.channel.isClosed else {
            return request.fail(ApelinError(.notFound, "This chat is no longer running."))
        }
        await prepare()
        do {
            return try await worker.call(wire, descriptors: request.descriptors)
        } catch {
            return request.fail(
                (error as? ApelinError) ?? ApelinError(.unavailable, "This chat could not be reached. Try again."),
            )
        }
    }

    /// The app's decision is recorded here before the worker hears it, so
    /// the host knows which approvals it gave when the agent cites one, and
    /// taken back when the worker does not take it (`AgentApprovals.relay`).
    ///
    /// An approval of a changed build or packaging description goes into the
    /// host's ledger (`recordApproval`), so the host's own check lets that
    /// digest through from then on; an approved package removal is allowed
    /// once (`allowRemoval`). What was asked is read from the session's own
    /// `approvalRequested` event in the registry, never from the request.
    private static func approve(_ request: HostRequest, host: SessionHost) async -> HostReply {
        let relay = { await forward(request, AgentApproveRequest.self, host: host) { $0.sessionID } }
        do {
            return try await AgentApprovals.relay(
                request.decode(AgentApproveRequest.self),
                registry: host.registry,
                ledger: host.approvals,
                forward: relay,
                accepted: { reply in (try? reply.0.result.get()) != nil },
            )
        } catch {
            return request.fail(error)
        }
    }

    /// Only the session's own worker may run code, only in its project,
    /// under Confirm only with a preset the host recognises or an approval
    /// the app gave for a `shell_run` call of this session, and as root only
    /// in Full mode or with the app's approval of that root request.
    private static func runCode(_ request: HostRequest, host: SessionHost) async -> HostReply {
        await request.serve(AgentRunCodeRequest.self) { run in
            guard case let .worker(.agent, instance) = request.caller, instance == run.sessionID else {
                throw ApelinError(.denied, "only the agent session's own worker can call shell_run")
            }
            // Taken before the checks, so a Stop or Close that comes while
            // they run still ends the process once it spawns.
            let stopsSeen = AgentRunCode.stopCount(session: run.sessionID)
            guard let entry = await AgentSessionTable.shared.entry(run.sessionID) else {
                throw ApelinError(.notFound, "no agent session \(run.sessionID)")
            }
            let identity = try await AgentApprovals.authorize(
                run,
                entry: entry,
                registry: host.registry,
                ledger: host.approvals,
                installRoot: host.installRoot,
            )
            return try await AgentRunCode.run(
                run,
                as: identity,
                project: entry.project,
                installRoot: host.installRoot,
                home: host.home,
                stopsSeen: stopsSeen,
            )
        }
    }
}
