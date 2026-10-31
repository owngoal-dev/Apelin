import ApelinCore
import ApelinProtocol
import Foundation

/// apelin-environment's request handling, everything `Workers/Environment`
/// hands it: the toolchain and SDK operations, the git service and its
/// settings, a repository made on GitHub and an issue opened on one, the
/// package repository, the feedback filed, read and edited on Apelin's own
/// repository and the star the reader gives it, and the cancellation of the
/// tasks it runs.
///
/// An operation that starts a task arrives with the task's ID. It is checked
/// first — a bad request is the reply, not a failed task — then accepted with
/// an empty answer and run on its own Swift task, which emits the events and
/// ends with `state`. Each task gets a private staging folder under
/// `Environment/staging/<taskID>/`, removed when it ends.
///
/// The host starts a task again under the same ID after it restarted
/// (`ChannelRequest.resumed`); each operation starts over safely. The worker
/// is new by then, and its start has cleared every task's staging and the
/// folders of cut-off clones; a clone that had ended answers from its folder;
/// an import registers an SDK it already has as that record; toolchain setup
/// goes on from its job record.
public final class EnvironmentWorker: @unchecked Sendable {
    public typealias Emit = @Sendable (TaskID, String, JSONValue?) -> Void

    public let layout: EnvironmentLayout
    let sdk: SDKManager
    /// A `var` only so a test can let it reach a local remote before the
    /// first request; nothing changes it once requests arrive.
    var git: GitService
    /// A `var` for the same reason, and for a test's GitHub.
    var distribution: DistributionService
    /// `var`s for a test's GitHub too.
    var feedback: FeedbackService
    var repositories: GitHubRepositoryService
    var issues: GitHubIssueService
    let toolchains: ToolchainService
    let transfers: TransferService
    let installer: any PackageInstaller
    private let emit: Emit

    private let lock = PthreadLock()
    private var running: [TaskID: (flag: CancellationFlag, task: Task<Void, Never>?)] = [:]

    /// `credentials` is where the git service keeps its HTTPS credentials:
    /// the keychain in the worker, memory in tests and the harness.
    public init(
        layout: EnvironmentLayout,
        backend: any ToolchainBackend,
        installer: any PackageInstaller,
        credentials: any GitCredentialStore = MemoryGitCredentialStore(),
        emit: @escaping Emit,
    ) {
        self.layout = layout
        self.installer = installer
        self.emit = emit
        sdk = SDKManager(layout: layout)
        git = GitService(layout: layout, credentials: credentials)
        distribution = DistributionService(layout: layout, git: git, credentials: credentials)
        feedback = FeedbackService(layout: layout, credentials: credentials)
        repositories = GitHubRepositoryService(credentials: credentials)
        issues = GitHubIssueService(layout: layout, credentials: credentials)
        toolchains = ToolchainService(layout: layout, backend: backend)
        transfers = TransferService(layout: layout, toolchains: toolchains, sdk: sdk)
        // Nothing runs yet: a tree with no record is an interrupted import,
        // staging and local packages belong to tasks that no longer exist
        // (a setup packages its tree again when it resumes), and a marked
        // project folder is a clone that was cut off.
        sdk.store.sweepOrphans()
        try? FileManager.default.removeItem(at: layout.staging)
        try? FileManager.default.removeItem(at: layout.artifacts)
        git.sweepInterruptedClones()
        TransferService.sweepPartialExports(layout)
    }

    /// The worker as WorkerMain runs it.
    public convenience init(context: WorkerContext) {
        self.init(
            layout: EnvironmentLayout(assignment: context.assignment),
            backend: ToolchainBackends.linked,
            installer: HostPackageInstaller(host: context.host),
            credentials: KeychainGitCredentialStore(),
            emit: { taskID, kind, payload in context.emit(taskID, kind, payload) },
        )
    }

    public func handle(_ request: ChannelRequest) async -> (WireReply, [OwnedDescriptor]) {
        switch request.request.operation {
        case .sdkList:
            await WorkerMain.serve(SDKListRequest.self, request) { [self] typed in
                var response = sdk.list(typed)
                response.activeTasks = activeTasks
                return response
            }
        case .sdkRemove:
            await WorkerMain.serve(SDKRemoveRequest.self, request) { [self] in try sdk.remove($0) }
        case .sdkImport:
            await startTask(SDKImportRequest.self, request) { [self] typed, _ in
                let prepared = try sdk.prepare(typed, descriptors: request.descriptors)
                return { reporter, staging in
                    let record = try await self.sdk.run(
                        prepared,
                        staging: staging,
                        hasSwiftToolchain: self.toolchains.hasSwift,
                        reporter: reporter,
                    )
                    try reporter.emit("result", .object(["sdk": JSONValue(encoding: record)]))
                }
            }
        case .toolchainStatus:
            await WorkerMain.serve(ToolchainStatusRequest.self, request) { [self] _ in
                toolchains.status(activeTasks: activeTasks)
            }
        case .toolchainSetDefault:
            await WorkerMain.serve(ToolchainSetDefaultRequest.self, request) { [self] typed in
                try toolchains.setDefault(id: typed.id)
                return Acknowledged()
            }
        case .toolchainCatalog:
            await WorkerMain.serve(ToolchainCatalogRequest.self, request) { [self] _ in
                try await toolchains.catalog()
            }
        case .toolchainSetup:
            await startTask(ToolchainSetupRequest.self, request) { [self] typed, taskID in
                let prepared = try toolchains.prepare(typed)
                return { reporter, _ in
                    let record = try await self.toolchains.setup(
                        prepared,
                        taskID: taskID,
                        installer: self.installer,
                        reporter: reporter,
                    )
                    try reporter.emit("result", .object(["toolchain": JSONValue(encoding: record)]))
                }
            }
        case .toolchainRemove:
            await startTask(ToolchainRemoveRequest.self, request) { [self] typed, _ in
                let record = try toolchains.prepareRemoval(typed)
                return { reporter, _ in
                    try await self.toolchains.remove(record, installer: self.installer, reporter: reporter)
                    reporter.emit("result", .object(["removed": .string(record.id)]))
                }
            }
        case .toolchainSelfTest:
            await startTask(ToolchainSelfTestRequest.self, request) { [self] typed, taskID in
                let record = try toolchains.prepareSelfTest(typed)
                return { reporter, _ in
                    let tested = try await self.toolchains.selfTest(record, taskID: taskID, reporter: reporter)
                    try reporter.emit("result", .object(["toolchain": JSONValue(encoding: tested)]))
                }
            }
        case .gitStatus:
            await WorkerMain.serve(GitStatusRequest.self, request) { [self] in try git.status($0) }
        case .gitDiff:
            await WorkerMain.serve(GitDiffRequest.self, request) { [self] in try git.diff($0) }
        case .gitStage:
            await WorkerMain.serve(GitStageRequest.self, request) { [self] in try git.stage($0) }
        case .gitUnstage:
            await WorkerMain.serve(GitUnstageRequest.self, request) { [self] in try git.unstage($0) }
        case .gitCommit:
            await WorkerMain.serve(GitCommitRequest.self, request) { [self] in try git.commit($0) }
        case .gitInit:
            await WorkerMain.serve(GitInitRequest.self, request) { [self] in try git.initialize($0) }
        case .gitRemoteList:
            await WorkerMain.serve(GitRemoteListRequest.self, request) { [self] in try git.remotes($0) }
        case .gitRemoteSet:
            await WorkerMain.serve(GitRemoteSetRequest.self, request) { [self] in try git.setRemote($0) }
        case .gitRemoteRemove:
            await WorkerMain.serve(GitRemoteRemoveRequest.self, request) { [self] in try git.removeRemote($0) }
        case .distributionRepositoryList:
            await WorkerMain.serve(DistributionRepositoryListRequest.self, request) { [self] in
                try await distribution.list($0)
            }
        case .distributionRepositoryUnlink:
            await WorkerMain.serve(DistributionRepositoryUnlinkRequest.self, request) { [self] _ in
                try distribution.unlink()
            }
        case .distributionRepositoryCreate:
            await startTask(DistributionRepositoryCreateRequest.self, request, resultInState: true) { [self] typed, _ in
                let name = try distribution.prepareCreate(typed)
                return { reporter, _ in
                    let result = try await self.distribution.create(typed, name: name, reporter: reporter)
                    reporter.emit("result", result)
                }
            }
        case .distributionRepositoryLink:
            await startTask(DistributionRepositoryLinkRequest.self, request, resultInState: true) { [self] typed, _ in
                try distribution.prepareLink(typed)
                return { reporter, _ in
                    let result = try await self.distribution.link(typed, reporter: reporter)
                    reporter.emit("result", result)
                }
            }
        case .distributionPublish:
            await startTask(DistributionPublishRequest.self, request, resultInState: true) { [self] typed, _ in
                let (linked, files) = try distribution.preparePublish(typed)
                return { reporter, staging in
                    let result = try await self.distribution.publish(
                        linked,
                        files: files,
                        digests: typed.digests,
                        staging: staging,
                        reporter: reporter,
                    )
                    reporter.emit("result", result)
                }
            }
        case .feedbackSend:
            await WorkerMain.serve(FeedbackSendRequest.self, request) { [self] in try await feedback.send($0) }
        case .feedbackRead:
            await WorkerMain.serve(FeedbackReadRequest.self, request) { [self] in try await feedback.read($0) }
        case .feedbackEdit:
            await WorkerMain.serve(FeedbackEditRequest.self, request) { [self] in try await feedback.edit($0) }
        case .feedbackStarState:
            await WorkerMain.serve(FeedbackStarStateRequest.self, request) { [self] in try await feedback.starState($0) }
        case .feedbackStar:
            await WorkerMain.serve(FeedbackStarRequest.self, request) { [self] in try await feedback.star($0) }
        case .gitClone:
            await startTask(GitCloneRequest.self, request) { [self] typed, taskID in
                if request.resumed, let result = git.finishedClone(typed, taskID: taskID) {
                    return { reporter, _ in reporter.emit("result", result) }
                }
                let root = try git.checkClone(typed)
                return { reporter, _ in
                    try reporter.emit("result", self.git.clone(typed, into: root, taskID: taskID, reporter: reporter))
                }
            }
        case .gitCloneInto:
            await startTask(GitCloneIntoRequest.self, request) { [self] typed, _ in
                let root = try git.checkCloneInto(typed)
                return { reporter, _ in
                    try reporter.emit("result", self.git.cloneInto(typed, into: root, reporter: reporter))
                }
            }
        case .gitFetch:
            await startTask(GitFetchRequest.self, request) { [self] typed, _ in
                let target = try git.prepareFetch(typed)
                return { reporter, _ in try reporter.emit("result", self.git.fetch(target, reporter: reporter)) }
            }
        case .gitPull:
            await startTask(GitPullRequest.self, request) { [self] typed, _ in
                let target = try git.preparePull(typed)
                return { reporter, _ in try reporter.emit("result", self.git.pull(target, reporter: reporter)) }
            }
        case .gitPush:
            await startTask(GitPushRequest.self, request) { [self] typed, _ in
                let target = try git.preparePush(typed)
                return { reporter, _ in try reporter.emit("result", self.git.push(target, reporter: reporter)) }
            }
        case .gitResetPreview:
            await startTask(GitResetPreviewRequest.self, request, resultInState: true) { [self] typed, _ in
                let target = try git.prepareResetPreview(typed)
                return { reporter, _ in try reporter.emit("result", self.git.resetPreview(target, reporter: reporter)) }
            }
        case .gitResetToRemote:
            await startTask(GitResetToRemoteRequest.self, request, resultInState: true) { [self] typed, _ in
                let target = try git.prepareReset(typed)
                return { reporter, _ in try reporter.emit("result", self.git.reset(target, typed, reporter: reporter)) }
            }
        case .gitSettings:
            await WorkerMain.serve(GitSettingsRequest.self, request) { [self] _ in try git.settings() }
        case .gitAuthorSet:
            await WorkerMain.serve(GitAuthorSetRequest.self, request) { [self] in try git.setAuthor($0) }
        case .gitCredentialSet:
            await WorkerMain.serve(GitCredentialSetRequest.self, request) { [self] in try git.setCredential($0) }
        case .gitCredentialRemove:
            await WorkerMain.serve(GitCredentialRemoveRequest.self, request) { [self] in try git.removeCredential($0) }
        case .gitRepositoryCreate:
            await WorkerMain.serve(GitRepositoryCreateRequest.self, request) { [self] in try await repositories.create($0) }
        case .gitIssueCreate:
            await WorkerMain.serve(GitIssueCreateRequest.self, request) { [self] in try await issues.create($0) }
        case .gitSquash:
            await WorkerMain.serve(GitSquashRequest.self, request) { [self] in try git.squash($0) }
        case .transferInspect:
            await WorkerMain.serve(TransferInspectRequest.self, request) { [self] in
                try transfers.inspect($0, descriptors: request.descriptors)
            }
        case .transferExport:
            await startTask(TransferExportRequest.self, request, resultInState: true) { [self] typed, _ in
                let prepared = try transfers.prepareExport(typed)
                return { reporter, staging in
                    let export = try await self.transfers.export(prepared, staging: staging, reporter: reporter)
                    try reporter.emit("result", .object(["export": JSONValue(encoding: export)]))
                }
            }
        case .transferImport:
            await startTask(TransferImportRequest.self, request, resultInState: true) { [self] typed, taskID in
                let prepared = try transfers.prepareImport(typed, descriptors: request.descriptors)
                return { reporter, staging in
                    let result = try await self.transfers.runImport(
                        prepared,
                        staging: staging,
                        taskID: taskID,
                        installer: self.installer,
                        reporter: reporter,
                    )
                    reporter.emit("result", result)
                }
            }
        default:
            WorkerMain.unimplemented(request)
        }
    }

    /// The host asked to stop a task: flag it and cancel its Swift task, so
    /// both the polled flag and `Task.checkCancellation` see it.
    public func cancel(_ taskID: TaskID) {
        let entry = lock.withLock { running[taskID] }
        entry?.flag.cancel()
        entry?.task?.cancel()
    }

    /// The tasks this worker is running now.
    public var activeTasks: [TaskHandle] {
        lock.withLock {
            running.keys.sorted { $0.rawValue < $1.rawValue }.map { TaskHandle(taskID: $0, kind: .environment) }
        }
    }

    // MARK: Tasks

    typealias Body = @Sendable (TaskReporter, URL) async throws -> Void

    /// Decodes and checks the request with `accept`, which answers the work
    /// to run; answers the host at once and runs that work on its own task.
    /// With `resultInState`, the task's last `result` is also carried by its
    /// final `state` as `result`, as a load check's is, so a reader that
    /// keeps only the last event (the console) has it.
    private func startTask<R: OperationRequest>(
        _: R.Type,
        _ request: ChannelRequest,
        resultInState: Bool = false,
        _ accept: (R, TaskID) throws -> Body,
    ) async -> (WireReply, [OwnedDescriptor]) {
        let requestID = request.request.requestID
        guard let taskID = request.taskID else {
            return (.failure(requestID, ApelinError(.badRequest, "\(R.operation.rawValue) runs as a task")), [])
        }
        let body: Body
        let staging: URL
        do {
            body = try accept(request.request.decode(R.self), taskID)
            staging = try layout.makeStaging(taskID.rawValue)
        } catch let error as ApelinError {
            return (.failure(requestID, error), [])
        } catch {
            return (.failure(requestID, ApelinError(.badRequest, String(describing: error))), [])
        }

        let flag = CancellationFlag()
        let emit = emit
        let lastResult = ResultBox()
        let reporter = TaskReporter(cancellation: flag) { kind, payload in
            if resultInState, kind == "result" {
                lastResult.value = payload
            }
            emit(taskID, kind, payload)
        }
        lock.withLock { running[taskID] = (flag, nil) }
        let task = Task { [self] in
            emit(taskID, TaskEvent.stateKind, .object(["state": .string(TaskState.running.rawValue)]))
            let state: TaskState
            var message: String?
            var reason: ApelinError.Reason?
            do {
                try await body(reporter, staging)
                state = reporter.isCancelled ? .cancelled : .succeeded
            } catch {
                let failure = GitService.apelinError(error)
                if reporter.isCancelled || failure.code == .cancelled || error is CancellationError {
                    state = .cancelled
                } else {
                    state = .failed
                    message = failure.description
                    reason = failure.reason
                }
            }
            try? FileManager.default.removeItem(at: staging)
            lock.withLock { running[taskID] = nil }
            var payload: [String: JSONValue] = ["state": .string(state.rawValue)]
            if let message {
                payload["message"] = .string(message)
            }
            // The error's reason, beside its message, for a reader that acts
            // on it rather than on the text.
            if let reason {
                payload["reason"] = .string(reason.rawValue)
            }
            if state == .succeeded, let result = lastResult.value {
                payload["result"] = result
            }
            emit(taskID, TaskEvent.stateKind, .object(payload))
        }
        lock.withLock { running[taskID]?.task = task }
        return (.success(requestID, Acknowledged()), [])
    }
}

/// A task's last `result`, for its final `state`.
private final class ResultBox: @unchecked Sendable {
    private let lock = PthreadLock()
    private var stored: JSONValue?

    var value: JSONValue? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
