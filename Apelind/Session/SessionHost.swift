import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// `apelind-session`: apelind started again in session mode, as a child the
/// launchd job's memory limit does not cover. It owns the task registry and
/// the workers; apelind forwards it every request but `hello`, and it
/// reports to apelind whether it has work, so apelind stays up while it does.
final class SessionHost: @unchecked Sendable {
    let installRoot: String
    /// Mobile's home, which every mobile worker gets as HOME.
    let home: String
    /// Root-only state: task records, approvals, installation records.
    let stateDirectory: URL
    let registry: TaskRegistry
    let workers: WorkerSupervisor
    /// `~/Documents/wiki.qaq.apelin`, as mobile's home spells it.
    let dataFolder: DataFolder
    /// Confirm-mode digests and agent session modes (host-private).
    let approvals: ApprovalLedger
    /// Artifacts as build workers reported them.
    let artifacts: ArtifactRegistry
    let installations: InstallationStore
    let install: InstallBridge
    let scopes: FileScopes
    let editor: ProtectedEditor
    let terminals: TerminalHost
    let toolHosts: ToolHostSessions
    /// Banners for agent sessions, posted as the app.
    let notices: AgentNotices
    /// Resumers by task kind: given a task the previous host left running,
    /// answer true once it is handled — kept, or ended with its own reason.
    /// Every other unfinished task is `interrupted`.
    private var resumers: [TaskKind: @Sendable (TaskRegistry.Record) async -> Bool] = [:]
    private let proxy: WorkerChannel
    private var lastReport: WorkReport?
    /// `session.pid` in the state directory: this process's ID while it runs.
    @objc dynamic private var pidFile: URL {
        stateDirectory.appendingPathComponent("session.pid")
    }

    init(installRoot: String, ownPath: String) {
        self.installRoot = installRoot
        // roothide keeps mobile's home inside the jbroot; rootless uses the
        // system's. The app reckons it the same way, off its own bundle.
        home = RoothideRoot.mobileHome(for: ownPath)
        stateDirectory = URL(
            fileURLWithPath: installRoot == "/" ? "/var/lib/apelin" : installRoot + "/var/lib/apelin",
            isDirectory: true,
        )
        registry = TaskRegistry(directory: stateDirectory.appendingPathComponent("tasks", isDirectory: true))
        workers = WorkerSupervisor(installRoot: installRoot, home: home)
        dataFolder = DataFolder(home: home)
        approvals = ApprovalLedger(directory: stateDirectory.appendingPathComponent("approvals", isDirectory: true))
        artifacts = ArtifactRegistry(file: stateDirectory.appendingPathComponent("artifacts.json"))
        installations = InstallationStore(
            directory: stateDirectory.appendingPathComponent("installations", isDirectory: true),
        )
        install = InstallBridge(
            paths: InstallBridge.Paths(
                installRoot: installRoot,
                dataFolder: dataFolder.root.path,
                staging: stateDirectory.appendingPathComponent("staging", isDirectory: true),
            ),
            service: IrisinInstallService(),
            registry: registry,
            artifacts: artifacts,
            installations: installations,
            packages: DpkgStatusDatabase(installRoot: installRoot),
            fileLists: DpkgFileLists(installRoot: installRoot),
            approvals: approvals,
        )
        scopes = FileScopes(installRoot: installRoot, dataFolder: dataFolder)
        editor = ProtectedEditor(installRoot: installRoot, backups: BackupStore(home: home))
        terminals = TerminalHost(installRoot: installRoot, home: home, scopes: scopes, registry: registry)
        toolHosts = ToolHostSessions(
            installRoot: installRoot,
            home: home,
            attachments: stateDirectory.appendingPathComponent("attachments", isDirectory: true),
        )
        notices = AgentNotices(stateDirectory: stateDirectory, sessions: dataFolder.sessions)
        proxy = WorkerChannel(adopting: WorkerMain.channelDescriptor)
        resumers[.install] = { [install] record in await install.resume(record) }
        let restart = TaskResume(
            registry: registry,
            dispatch: { [unowned self] record, request in
                guard let role = record.owner else {
                    throw ApelinError(.internal, "task \(record.id) has no worker")
                }
                // The previous run's package, if it reported one, is not this run's.
                if record.kind == .build {
                    await artifacts.forget(buildID: record.id)
                }
                let worker = try await workers.worker(role, instance: record.ownerKey)
                return try await worker.call(request, descriptors: [], taskID: record.id, resumed: true).0
            },
            recheck: { [unowned self] caller, request in
                // An agent's build, which carries the digest precheck adds,
                // is never resumed (TaskResume.plan).
                var checked = HostRequest(request: request, descriptors: [], caller: caller)
                guard let refusal = await precheck(&checked) else {
                    return nil
                }
                if case let .failure(error) = refusal.0.result {
                    return error
                }
                return ApelinError(.denied, "\(request.operation.rawValue) was refused")
            },
        )
        resumers[.build] = { record in await restart.resume(record) }
        resumers[.environment] = { record in await restart.resume(record) }
    }

    @objc dynamic func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        var metadata = stat()
        guard fstat(WorkerMain.channelDescriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK else {
            NSLog("apelind-session: start this through apelind")
            exit(EX_USAGE)
        }
        try? FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        // The host's process name is apelind's, as the kernel takes it from
        // the executable, so `killall` cannot tell the two apart; this file
        // names the one to kill when testing a restart (Documents/Console.md).
        try? Data("\(getpid())\n".utf8).write(to: pidFile, options: .atomic)

        let ready = DispatchSemaphore(value: 0)
        Task {
            // A worker's events and its exit, applied in the order they came:
            // a task per event lets a final `state` overtake the `artifact`
            // before it, and an exit overtake the `state` it followed.
            let feed = TaskEventFeed<WorkerNews> { [self] news in
                switch news {
                case let .event(worker, taskID, kind, payload):
                    // A worker writes only to tasks it was given.
                    guard let record = await registry.record(taskID), record.owner == worker.role,
                          record.ownerKey == worker.key else { return }
                    // A build's package, as the build worker itself reported it.
                    if worker.role == .build, kind == "artifact" {
                        await artifacts.record(event: payload, buildID: taskID)
                    }
                    // The title an agent gave its session, which agentList
                    // names it by for the other conversations of its project.
                    if worker.role == .agent, kind == "title", let key = worker.key,
                       let title = AgentConversationRules.title(payload?["text"]?.stringValue)
                    {
                        await AgentSessionTable.shared.setTitle(title, session: key)
                    }
                    await registry.append(taskID, kind: kind, payload: payload)
                    await notices.relayed(record, kind: kind, payload: payload)
                case let .exit(worker):
                    await registry.ownerExited(role: worker.role, key: worker.key)
                    if worker.role == .agent {
                        await toolHosts.closeAll(ownedBy: .worker(.agent, instance: worker.key))
                    }
                }
            }
            await workers.configure(
                onRequest: { [self] worker, request in
                    await Dispatcher.handle(
                        HostRequest(
                            request: request.request,
                            descriptors: request.descriptors,
                            caller: .worker(worker.role, instance: worker.key),
                        ),
                        host: self,
                    )
                },
                onEvent: { worker, frame in
                    guard let taskID = frame.header.taskID, let kind = frame.header.name else { return }
                    let payload = frame.body.isEmpty ? nil : try? JSONCoding.decode(JSONValue.self, from: frame.body)
                    feed.send(.event(worker, taskID, kind, payload))
                },
                onExit: { worker in
                    feed.send(.exit(worker))
                },
                isBusy: { [self] role, key in
                    await registry.hasActiveTask(owner: role, key: key)
                },
            )
            // Resume what the previous host left running, before anything
            // new can start (the workers are configured first: a resumed
            // build's events need somewhere to go); a task nobody can resume
            // ends `interrupted`. The folders removed toolchains left go
            // first, while nothing can install into them yet.
            await install.pruneLeftoverToolchains()
            for record in await registry.load() {
                if let resumer = resumers[record.kind], await resumer(record) {
                    continue
                }
                await registry.interrupt(record.id)
            }
            await install.reconcile()
            ready.signal()
        }
        ready.wait()

        proxy.onRequest { [self] request in
            await Dispatcher.handle(
                HostRequest(request: request.request, descriptors: request.descriptors, caller: .app),
                host: self,
            )
        }
        proxy.onControl { [self] frame in
            if frame.header.name == WorkerControl.shutdown {
                shutdown()
            }
        }
        proxy.onClose { [self] in shutdown() }
        proxy.start()

        // Report work to apelind as it changes, and stop idle workers.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "wiki.qaq.apelind.session.report"))
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [self] in
            Task { await reportWork() }
        }
        timer.activate()
        dispatchMain()
    }

    private func reportWork() async {
        await workers.sweep()
        // Every kind of work: builds, environment tasks, terminals, agent
        // sessions and installs are tasks; workers and tool extensions are
        // processes. The proxy counts the connected app itself.
        let report = await WorkReport(
            activeTasks: registry.activeCount,
            workers: workers.count,
            toolHosts: toolHosts.count,
            tasksByKind: registry.activeByKind,
        )
        guard report != lastReport else { return }
        lastReport = report
        try? proxy.sendControl(WorkerControl.work, body: report)
    }

    @objc dynamic private func shutdown() {
        // Every event is on disk as it comes, and every record change the
        // events do not tell (TaskRegistry); nothing is left to flush.
        Task {
            await terminals.stopAll()
            await toolHosts.stopAll()
            await workers.stopAll()
            AgentRunCode.stopAll()
            unlink(pidFile.path)
            exit(0)
        }
    }

    // MARK: Helpers for the domain handlers

    /// Forwards the request to the role's worker and returns its answer.
    func forward(_ request: HostRequest, to role: WorkerRole, instance: String? = nil) async -> HostReply {
        do {
            let worker = try await workers.worker(role, instance: instance)
            return try await worker.call(request.request, descriptors: request.descriptors)
        } catch {
            return request.fail((error as? ApelinError) ?? ApelinError(.unavailable, String(describing: error)))
        }
    }

    /// Registers a task, hands the request to the role's worker with the
    /// task's ID, and answers the `TaskHandle`. The worker answers once it
    /// has accepted the task (its payload is ignored), then emits events and
    /// a final `state`. If it refuses, the task fails and the refusal is the
    /// reply. A `resumable` task's request is kept in its record first
    /// (`TaskResume.plan`), so a host that stops while it runs starts it
    /// again on its next launch.
    func startTask(
        _ request: HostRequest,
        kind: TaskKind,
        role: WorkerRole,
        instance: String? = nil,
        resumable: Bool = false,
    ) async -> HostReply {
        let handle = await registry.create(kind: kind, owner: role, ownerKey: instance)
        // An agent reads back only the tasks its session started.
        if case let .worker(.agent, session?) = request.caller {
            await AgentSessionTable.shared.recordStarted(handle.taskID, session: session)
        }
        if resumable {
            await registry.setResume(
                handle.taskID,
                TaskResume.plan(request.request, descriptorCount: request.descriptors.count, caller: request.caller),
            )
        }
        do {
            let worker = try await workers.worker(role, instance: instance)
            let (reply, descriptors) = try await worker.call(
                request.request,
                descriptors: request.descriptors,
                taskID: handle.taskID,
            )
            if case let .failure(error) = reply.result {
                await registry.finish(handle.taskID, .failed, message: error.description)
                return (reply, descriptors)
            }
            return (.success(request.requestID, handle), [])
        } catch {
            let failure = (error as? ApelinError) ?? ApelinError(.unavailable, String(describing: error))
            await registry.finish(handle.taskID, .failed, message: failure.description)
            return request.fail(failure)
        }
    }

    /// Serves any attach request from the registry.
    func attach<R: TaskAttachRequest>(_ request: HostRequest, _: R.Type) async -> HostReply {
        await request.serve(R.self) { attach in
            try await registry.attach(
                attach.taskID,
                as: R.operation,
                afterSeq: attach.afterSeq,
                waitMilliseconds: attach.waitMilliseconds,
            )
        }
    }

    /// Serves any cancel request: marks it, tells the owning worker, and
    /// ends a task no worker is serving.
    func cancel<R: TaskCancelRequest>(_ request: HostRequest, _: R.Type) async -> HostReply {
        await request.serve(R.self) { cancel in
            let record = try await registry.requestCancel(cancel.taskID)
            guard !record.state.isTerminal else { return Acknowledged() }
            if let role = record.owner, let worker = await workers.existing(role, instance: record.ownerKey) {
                try worker.channel.sendControl(WorkerControl.cancel, taskID: cancel.taskID)
            } else {
                await registry.finish(cancel.taskID, .cancelled)
            }
            return Acknowledged()
        }
    }
}

/// What a worker tells the host outside a reply, in arrival order.
enum WorkerNews: Sendable {
    case event(WorkerProcess, TaskID, String, JSONValue?)
    case exit(WorkerProcess)
}
