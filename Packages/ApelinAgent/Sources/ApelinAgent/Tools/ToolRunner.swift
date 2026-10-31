import struct ApelinCore.MemorySnapshot
import struct ApelinCore.MemoryStore
import enum ApelinCore.MemoryStoreError
import enum ApelinProtocol.AgentToolName
import struct ApelinProtocol.ApelinError
import enum ApelinProtocol.BuildBootstrap
import struct ApelinProtocol.GitPushLease
import Foundation
import KWWKAgent
import KWWKAI

public struct ToolDeniedError: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? {
        message
    }
}

/// Gathers the facts of a call, puts it through the approval gate, then runs
/// it: file tools here, everything else through the host backend.
actor ToolRunner {
    let sessionID: String
    let project: ProjectIdentity
    let root: ScopedRoot
    private var policy: ApprovalPolicy
    let backend: any AgentHostBackend
    let digests: any ApprovalDigestStore
    let gate: ApprovalGate
    let memory: MemoryStore?
    let skills: URL?
    /// Where the read tools reach besides the project.
    let readOnlyRoots: ReadOnlyRoots
    /// Writes an event to the session's log: apelin_notification_send's `notice`.
    let record: (@Sendable (AgentSessionEvent) async throws -> Void)?
    let webFetch: WebFetch
    /// The agent tool extensions' sessions, opened as their tools are called.
    let toolExtensions: ToolExtensionSessions
    /// Hears how a call was refused, stopped or ran out of time, where that
    /// is decided, for the session's diagnostic journal.
    let journal: SessionJournal?
    private var notices = UserNotices()

    init(
        sessionID: String,
        project: ProjectIdentity,
        root: ScopedRoot,
        policy: ApprovalPolicy,
        backend: any AgentHostBackend,
        digests: any ApprovalDigestStore,
        gate: ApprovalGate,
        memory: MemoryStore? = nil,
        skills: URL? = nil,
        readOnlyRoots: ReadOnlyRoots = .none,
        record: (@Sendable (AgentSessionEvent) async throws -> Void)? = nil,
        webFetch: WebFetch = .shared,
        journal: SessionJournal? = nil,
    ) {
        self.sessionID = sessionID
        self.project = project
        self.root = root
        self.policy = policy
        self.backend = backend
        self.digests = digests
        self.gate = gate
        self.memory = memory
        self.skills = skills
        self.readOnlyRoots = readOnlyRoots
        self.record = record
        self.webFetch = webFetch
        self.journal = journal
        toolExtensions = ToolExtensionSessions(backend: backend)
    }

    @discardableResult
    func setMode(_ mode: ApprovalMode) -> Bool {
        guard policy.mode != mode else { return false }
        policy.mode = mode
        return true
    }

    var approvalMode: ApprovalMode {
        policy.mode
    }

    func setAsksBeforeScreen(_ asks: Bool) {
        policy.asksBeforeScreen = asks
    }

    var asksBeforeScreen: Bool {
        policy.asksBeforeScreen
    }

    /// A run ended: the next one may send its own notices.
    func turnEnded() {
        notices.turnEnded()
    }

    /// The session closes: the extensions it started go with it.
    func closeToolExtensions() async {
        await toolExtensions.closeAll()
    }

    static let maxImageBytes = 4 * 1024 * 1024

    /// kwwk tool definitions for the §7 tools, then wrapped MCP tools, then
    /// the tools of the agent tool extensions offered.
    nonisolated func agentTools(mcp: [AgentTool], extensions: [OfferedToolExtension] = []) -> [AgentTool] {
        let offered = AgentToolName.allCases.filter { !project.isTemporary || !$0.isProjectOnly }
        var tools = offered.map { name in
            AgentTool(
                name: name.rawValue,
                label: name.rawValue,
                description: name.summary,
                parameters: ToolReason.adding(to: name.parameters),
            ) { id, args, cancellation, _ in
                try await self.run(
                    .local(name),
                    toolCallID: id,
                    arguments: ToolReason.removing(from: args),
                    cancellation: cancellation,
                    mcp: nil,
                )
            }
        }
        for tool in mcp {
            var wrapped = tool
            let inner = tool.execute
            let name = tool.name
            wrapped.parameters = ToolReason.adding(to: tool.parameters)
            wrapped.execute = { id, args, cancellation, update in
                try await self.run(
                    .mcp(name),
                    toolCallID: id,
                    arguments: ToolReason.removing(from: args),
                    cancellation: cancellation,
                ) { args in
                    try await inner(id, args, cancellation, update)
                }
            }
            tools.append(wrapped)
        }
        for definition in extensions.flatMap(\.definitions) {
            let extensionTool = definition.tool
            var agentTool = AgentTool(
                name: extensionTool.name,
                label: extensionTool.name,
                description: definition.description,
                parameters: definition.parameters,
            ) { id, args, cancellation, _ in
                try await self.run(
                    .toolExtension(extensionTool),
                    toolCallID: id,
                    arguments: ToolReason.removing(from: args),
                    cancellation: cancellation,
                    mcp: nil,
                )
            }
            // A blank optional argument is dropped before kwwk holds the
            // call to the schema, which an empty enum or `minLength` fails.
            agentTool.omitsBlankOptionalArguments = true
            tools.append(agentTool)
        }
        return tools
    }

    // MARK: - Gate

    /// Runs one call; one that throws is noted in the journal for what it
    /// came to (`ToolCallOutcome`), unless where it was decided noted it.
    func run(
        _ tool: InvocationFacts.Tool,
        toolCallID: String,
        arguments: JSONValue,
        cancellation: CancellationHandle?,
        mcp: (@Sendable (JSONValue) async throws -> AgentToolResult)?,
    ) async throws -> AgentToolResult {
        do {
            return try await gated(tool, toolCallID: toolCallID, arguments: arguments, cancellation: cancellation, mcp: mcp)
        } catch {
            let stopped = cancellation?.isCancelled == true || Task.isCancelled
            journal?.note(ToolCallOutcome.of(error, stopped: stopped), for: toolCallID)
            throw error
        }
    }

    private func gated(
        _ tool: InvocationFacts.Tool,
        toolCallID: String,
        arguments: JSONValue,
        cancellation: CancellationHandle?,
        mcp: (@Sendable (JSONValue) async throws -> AgentToolResult)?,
    ) async throws -> AgentToolResult {
        let arguments = switch tool {
        case let .local(name): ToolArguments.normalized(arguments, for: name)
        // The host holds the arguments to the extension's own schema.
        case let .toolExtension(tool): ToolArguments.normalized(arguments, keeping: tool.required)
        case .mcp: arguments
        }
        // Before the gate: a workspace that declares no build has nothing to
        // run or approve.
        if case .local(.projectBuild) = tool, ProjectBuildSystem.read(in: root) == .external,
           ProjectBuildSystem.externalScript(in: root) == nil
        {
            throw ToolDeniedError(message: ProjectBuildSystem.externalBuildRefusal)
        }
        let facts = try await gatherFacts(tool, arguments: arguments)
        let workingDirectory = arguments.argString("cwd") ?? "."
        let toolName: String = switch tool {
        case let .local(name): name.rawValue
        case let .mcp(name): name
        case let .toolExtension(tool): tool.name
        }
        // A grant for an extension's tool holds for the version it was
        // given for: an upgrade mid-session asks again.
        let bound: String? = if case let .toolExtension(tool) = tool {
            "\(tool.extensionID) \(tool.extensionVersion)"
        } else {
            facts.description?.digest
        }
        let fingerprint = ApprovalFingerprint.make(
            tool: toolName,
            arguments: arguments,
            workingDirectory: workingDirectory,
            projectID: project.id,
            digest: bound,
        )

        let ask = { (reason: String, detail: ApprovalDetail) async throws -> ApprovalEvidence in
            try await self.askUser(
                tool,
                toolName: toolName,
                toolCallID: toolCallID,
                arguments: arguments,
                workingDirectory: workingDirectory,
                fingerprint: fingerprint,
                reason: reason,
                detail: detail,
                cancellation: cancellation,
            )
        }
        let hostRefusal = "Apelin could not confirm that this command is one of your approved presets. Review it before running."
        let evidence: ApprovalEvidence
        switch policy.evaluate(facts, root: root) {
        case let .allow(allowed):
            evidence = allowed
        case let .deny(reason):
            journal?.note(ToolCallOutcome(.denied, "the approval policy refused it: \(reason)"), for: toolCallID)
            throw ToolDeniedError(message: "refused: \(reason)\(readOnlyNote(tool))")
        case let .ask(reason, detail):
            evidence = try await ask(reason, detail)
        }
        try cancellation?.throwIfCancelled()

        if let mcp {
            return try await mcp(arguments)
        }
        if case let .toolExtension(tool) = tool {
            return try await runExtension(tool, arguments: arguments, cancellation: cancellation)
        }
        guard case let .local(name) = tool else { throw ToolDeniedError(message: "unknown tool") }
        var context = HostCallContext(
            sessionID: sessionID,
            project: project,
            toolCallID: toolCallID,
            approval: evidence,
        )
        do {
            return try await execute(
                name,
                arguments: arguments,
                facts: facts,
                context: context,
                cancellation: cancellation,
            )
        } catch let refusal as HostRefusedPresetError {
            // The host's preset rule is the one that counts: where it does
            // not count this call, the user decides, as for any command no
            // preset covers, and the call goes again with that approval.
            // Nothing is remembered: the host's answer depends on the
            // repository (a `.git` made, a `.gitmodules` removed), so the
            // next call is sent as a preset again and the host decides.
            guard case .preset = evidence, let command = facts.command else { throw refusal }
            context.approval = try await ask(hostRefusal, .command(command))
            try cancellation?.throwIfCancelled()
            return try await execute(
                name,
                arguments: arguments,
                facts: facts,
                context: context,
                cancellation: cancellation,
            )
        }
    }

    /// Asks the user about one call — unless it is one they approved for
    /// this session — and answers the evidence to send, or throws when they
    /// decline.
    private func askUser(
        _ tool: InvocationFacts.Tool,
        toolName: String,
        toolCallID: String,
        arguments: JSONValue,
        workingDirectory: String,
        fingerprint: String,
        reason: String,
        detail: ApprovalDetail,
        cancellation: CancellationHandle?,
    ) async throws -> ApprovalEvidence {
        let sessionScope = Self.allowsSessionScope(tool, detail: detail)
        if sessionScope, await gate.isRemembered(fingerprint) {
            return .user(requestID: ApprovalEvidence.sessionRequestID, fingerprint: fingerprint)
        }
        let request = ApprovalRequest(
            id: UUID().uuidString,
            toolCallID: toolCallID,
            tool: toolName,
            arguments: arguments.canonicalJSON,
            workingDirectory: workingDirectory,
            projectID: project.id,
            fingerprint: fingerprint,
            reason: reason,
            detail: detail,
            allowsSessionScope: sessionScope,
        )
        switch await gate.request(request, cancellation: cancellation) {
        case .approve:
            return .user(requestID: request.id, fingerprint: fingerprint)
        case let .deny(reason):
            // a stop while it waited is the stop's, as the wrapper notes it
            if cancellation?.isCancelled != true {
                journal?.note(ToolCallOutcome(.denied, "the user declined it"), for: toolCallID)
            }
            throw ToolDeniedError(message: "the user declined this call\(reason.map { ": \($0)" } ?? "")")
        }
    }

    /// "For this session" is never offered for package removal or for a
    /// request bound to a description digest: the host's ledger keeps those.
    /// Nor for a push: each one publishes, so each one is asked. Nor for a
    /// toolchain or SDK install, which changes the device for every
    /// project, nor for a call that reaches another project, nor for a
    /// command as root, nor for an issue filed or edited in public as
    /// feedback, nor for a repository made on GitHub or an issue opened on
    /// one, nor for a project's deletion, which cannot be undone, nor for
    /// packages published to the user's package repository, nor for a use
    /// of the screen while Ask Before Using the Screen is on, nor for a
    /// forced push, which takes commits off the remote's branch, nor for a
    /// squash, which replaces the project's own.
    static func allowsSessionScope(_ tool: InvocationFacts.Tool, detail: ApprovalDetail) -> Bool {
        switch tool {
        case .local(.packageRemove), .local(.gitPush), .local(.toolchainSetup), .local(.sdkImport),
             .local(.skillSave), .local(.skillRemove), .local(.feedbackSend), .local(.gitCreateRepository),
             .local(.projectDelete), .local(.packagePublish), .local(.feedbackEdit), .local(.gitCreateIssue),
             .local(.gitSquash):
            return false
        default:
            break
        }
        switch detail {
        case .gitSettings, .descriptionChanged, .toolchainSetup, .sdkImport, .otherProject, .externalBuild, .skillChange,
             .projectRename, .rootCommand, .feedback, .feedbackEdit, .repositoryCreate, .issueCreate, .projectDelete,
             .packagePublish, .screenControl, .forcePush, .squash:
            return false
        case .none, .command, .packageRemoval, .gitPush:
            return true
        }
    }

    // MARK: - Execution

    private func execute(
        _ name: AgentToolName,
        arguments: JSONValue,
        facts: InvocationFacts,
        context: HostCallContext,
        cancellation: CancellationHandle?,
    ) async throws -> AgentToolResult {
        let files = ProjectFileTools(root: root)
        switch name {
        case .memoryList, .memorySave, .memoryDelete:
            guard let memory else { throw ToolDeniedError(message: "Memory storage is unavailable.") }
            do {
                if name == .memoryList, arguments.argBool("all_projects") == true {
                    guard arguments.argNonEmptyString("project") == nil else {
                        throw ToolArgumentError("Name one project with project, or every project with all_projects, not both.")
                    }
                    let snapshot = try memory.read()
                    return try await json(MemoryTools.listEveryProject(snapshot, projects: memoryProjects(snapshot)))
                }
                let tools = try await memoryTools(memory, naming: arguments.argNonEmptyString("project"))
                switch name {
                case .memoryList: return try json(tools.list())
                case .memorySave: return try json(tools.save(arguments))
                default: return try json(tools.delete(arguments))
                }
            } catch MemoryStoreError.changed {
                throw ToolDeniedError(message: "Memory changed. Read apelin_memory_list again and respect the user's latest corrections or deletions; do not blindly retry.")
            } catch MemoryStoreError.invalidContent {
                throw ToolArgumentError("Memory needs a nonempty, single-line title and nonempty body, without NUL bytes.")
            } catch MemoryStoreError.full {
                throw ToolArgumentError("Memory is full (\(MemoryStore.maximumRecords) records or \(MemoryStore.maximumContentBytes) content bytes). Consolidate outdated records before adding more.")
            }

        case .skillRead:
            guard let skills else { throw ToolDeniedError(message: "Skills are unavailable.") }
            return try text(SkillReader(userDirectory: skills).read(arguments))

        case .skillList:
            return try json(skillTools().list())

        case .skillSave, .skillRemove:
            // The skill the card named, checked again as kwwk reads it.
            guard let change = facts.skillChange else {
                throw ToolDeniedError(message: "the skill to change could not be identified")
            }
            let tools = try skillTools()
            return name == .skillSave ? try json(tools.save(change)) : try json(tools.remove(change))

        case .notificationSend:
            // No host request: the `notice` event is relayed with the rest,
            // and the host posts it by its own rules (AgentNoticeTrack).
            guard let record else { throw ToolDeniedError(message: "Notifications are unavailable.") }
            let notice = try notices.take(arguments, now: Date())
            try await record(.notice(title: notice.title, body: notice.body))
            return text(notices.sentMessage)

        case .webFetch:
            // No host request either: the worker fetches the page itself,
            // as mobile, and answers its text.
            let webFetch = webFetch
            return try await text(Self.untilCancelled(cancellation) { try await webFetch.fetch(arguments) }.answer)

        case .fileWrite: return try text(files.writeFile(arguments))

        case .fileEdit: return try text(files.patchFile(arguments))

        case .fileCreate: return try text(files.createFile(arguments))

        case .fileRead:
            // An image comes back as a picture, as a screenshot does.
            let reader = readFiles(arguments)
            if let image = try reader.readImage(arguments) {
                return AgentToolResult(content: [
                    .text(TextContent(text: image.summary)),
                    .image(ImageContent(data: image.data.base64EncodedString(), mimeType: image.mimeType)),
                ])
            }
            return try text(reader.readFile(arguments))

        case .fileList: return try text(readFiles(arguments).list(arguments))

        case .fileGrep: return try text(readFiles(arguments).grep(arguments))

        case .fileFind: return try text(readFiles(arguments).find(arguments))

        case .fileShow: return try files.show(arguments)

        case .projectCheckDistribution:
            let bootstrap = try Self.bootstrap(arguments)
            return try await json(backend.checkDistribution(DistributionCheckRequest(
                project: project,
                bootstrap: bootstrap,
            )))

        case .templateList:
            return try await json(backend.projectTemplates())

        case .projectList:
            return try await json(backend.projects())

        case .projectRename:
            // The project the facts resolved, and for another one the
            // rename its card named.
            guard let target = facts.renamedProject else {
                throw ToolDeniedError(message: "the project to rename could not be identified")
            }
            let automatic = arguments.argBool("automatic") ?? false
            var renamed = try await backend.renameProject(ProjectRenameToolRequest(
                context: context,
                projectID: target.id,
                folder: target.name.rawValue,
                displayName: arguments.requireString("display_name").trimmingCharacters(in: .whitespaces),
                automatic: automatic,
            ))
            // A new project named for its goal: the moment to settle the
            // identifiers Apelin made up for it.
            if automatic, target.id == project.id {
                renamed.identifierHint = PlaceholderIdentifiers.renameHint(in: root)
            }
            return json(renamed)

        case .projectDelete:
            // The project the card named.
            guard let deletion = facts.projectDeletion else {
                throw ToolDeniedError(message: "the project to delete could not be identified")
            }
            return try await json(backend.deleteProject(ProjectDeleteToolRequest(
                context: context,
                projectID: deletion.projectID,
                folder: deletion.folder,
            )))

        case .projectCreate:
            return try await json(backend.createProject(ProjectCreateToolRequest(
                context: context,
                templateID: arguments.requireString("template"),
                name: arguments.requireString("name"),
                values: Self.templateValues(arguments),
            )))

        case .sdkAnalyzeFramework, .sdkReadHeader:
            let sdk = try await backend.registeredSDK(RegisteredSDKRequest(
                sdkID: arguments.argString("sdk_id"),
                project: project,
            ))
            let tools = try FrameworkTools(sdk: ScopedRoot(URL(fileURLWithPath: sdk.rootPath, isDirectory: true)))
            let output = name == .sdkAnalyzeFramework ? try tools.analyze(arguments) : try tools.header(arguments)
            return text("SDK \(sdk.sdkID) (\(sdk.platform) \(sdk.version))\n\(output)")

        case .shellRun:
            guard let invocation = facts.command else {
                throw ToolArgumentError("shell_run needs argv, command or script")
            }
            let timeout = min(1800, max(1, arguments.argInt("timeout_seconds") ?? 120))
            let ran = try await backend.runCode(RunCodeRequest(
                context: context,
                invocation: invocation,
                workingDirectory: facts.workingDirectory,
                timeoutSeconds: timeout,
                asRoot: facts.runsAsRoot,
            ))
            if ran.timedOut == true {
                journal?.note(ToolCallOutcome(.timedOut, "killed after \(timeout) s"), for: context.toolCallID)
            }
            return json(ran)

        case .projectBuild:
            // A workspace has no build description: its build runs its own
            // script, which the host matches to the approval it spends.
            let digest: String
            if facts.externalBuild != nil {
                digest = ""
            } else if let state = facts.description {
                digest = state.digest
            } else {
                throw ToolDeniedError(message: "the build description could not be checked")
            }
            let configuration = BuildConfiguration(rawValue: arguments.argString("configuration") ?? "debug") ?? .debug
            var built = try await backend.build(BuildRequest(
                context: context,
                configuration: configuration,
                buildDescriptionDigest: digest,
                bootstrap: Self.bootstrap(arguments),
            ))
            if built.succeeded, configuration == .debug, facts.externalBuild == nil {
                built.identifierHint = await firstInstallIdentifierHint()
            }
            return json(built)

        case .packageInstall:
            guard let state = facts.description else {
                throw ToolDeniedError(message: "the packaging description could not be checked")
            }
            var installed = try await backend.install(InstallRequest(
                context: context,
                artifactID: arguments.requireString("artifact_id"),
                artifactDigest: arguments.requireString("artifact_digest"),
                packagingDescriptionDigest: state.digest,
            ))
            if installed.succeeded {
                installed.relaunchHint = AppRelaunch.hint(in: root)
            }
            return json(installed)

        case .packageRemove:
            // The installation the card named, by its id or found for the package.
            guard let installationID = facts.installationID else {
                throw ToolDeniedError(message: "the package to remove could not be identified")
            }
            do {
                return try await json(backend.removePackage(RemovePackageRequest(
                    context: context,
                    installationID: installationID,
                )))
            } catch let refusal as ApelinError where [.badRequest, .notFound, .conflict].contains(refusal.code) {
                let instead = await removableInstead()
                throw ToolDeniedError(message: refusal.message + instead)
            }

        case .packagePublish:
            // The repository and packages the card named.
            guard let publication = facts.packagePublish else {
                throw ToolDeniedError(message: "the packages to publish could not be read")
            }
            return try await json(backend.publishPackages(PackagePublishToolRequest(context: context, publication: publication)))

        case .packageList:
            var projectID: String?
            if let reference = arguments.argNonEmptyString("project") {
                projectID = try await backend.resolveProject(reference).id
            }
            return try await json(backend.installations(InstallationListToolRequest(
                packageID: arguments.argNonEmptyString("package_id"),
                projectID: projectID,
            )))

        case .deviceRespring:
            return try await json(backend.respring(RespringRequest(context: context)))

        case .packageConfirmLoaded:
            return try await json(backend.confirmLoaded(ConfirmLoadedRequest(
                context: context,
                buildID: arguments.requireString("build_id"),
                target: arguments.requireString("target"),
                respring: arguments.argBool("respring") ?? false,
            )))

        case .logRead:
            return try await json(backend.readLogs(ReadLogsRequest(
                context: context,
                process: arguments.argString("process"),
                subsystem: arguments.argString("subsystem"),
                listenSeconds: min(
                    ReadLogsRequest.maximumListenSeconds,
                    max(1, arguments.argInt("listen_seconds") ?? ReadLogsRequest.maximumListenSeconds),
                ),
                limit: min(1000, max(1, arguments.argInt("limit") ?? 200)),
            )))

        case .crashList:
            return try await json(backend.listCrashes(ListCrashesRequest(
                context: context,
                process: arguments.argString("process"),
                limit: min(200, max(1, arguments.argInt("limit") ?? 20)),
            )))

        case .crashRead:
            return try await json(backend.readCrash(ReadCrashRequest(
                context: context,
                reportID: arguments.requireString("report_id"),
                maxBytes: 256 * 1024,
            )))

        case .crashSymbolicate:
            return try await json(backend.symbolicateCrash(SymbolicateCrashRequest(
                context: context,
                reportID: arguments.requireString("report_id"),
                buildID: arguments.argString("build_id"),
            )))

        case .screenCapture:
            var response = try await backend.captureScreen(CaptureScreenRequest(
                context: context,
                targetID: arguments.argString("target_id"),
            ))
            let image = response.imageData.flatMap { $0.count <= Self.maxImageBytes ? $0 : nil }
            response.imageData = nil
            var result = json(response)
            if let image {
                result.content.append(.image(ImageContent(
                    data: image.base64EncodedString(),
                    mimeType: response.mimeType,
                )))
            }
            return result

        case .screenReadTree:
            return try await json(backend.readUITree(ReadUITreeRequest(
                context: context,
                targetID: arguments.argString("target_id"),
                maxDepth: min(40, max(1, arguments.argInt("max_depth") ?? 12)),
            )))

        case .screenInteract:
            return try await json(backend.uiAction(UIActionRequest(
                context: context,
                targetID: arguments.argString("target_id"),
                action: Self.uiAction(arguments),
            )))

        case .gitStatus:
            return try await json(backend.gitStatus(GitStatusToolRequest(context: context)))

        case .gitDiff:
            return try await json(backend.gitDiff(GitDiffToolRequest(
                context: context,
                path: arguments.argNonEmptyString("path"),
                staged: arguments.argBool("staged") ?? false,
            )))

        case .gitStage, .gitUnstage:
            guard let paths = arguments.argStrings("paths"), !paths.isEmpty else {
                throw ToolArgumentError("paths must be a non-empty list of project-relative paths")
            }
            let request = GitPathsToolRequest(context: context, paths: paths)
            return try await json(name == .gitStage ? backend.gitStage(request) : backend.gitUnstage(request))

        case .gitCommit:
            let message = try arguments.requireString("message")
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolArgumentError("the commit message is empty")
            }
            return try await json(backend.gitCommit(GitCommitToolRequest(
                context: context,
                message: message,
                all: arguments.argBool("all") ?? false,
            )))

        case .gitInit:
            return try await json(backend.gitInit(GitInitToolRequest(context: context)))

        case .gitFetch, .gitPull:
            // No remote named is the host's default, `origin`.
            let request = GitRemoteToolRequest(context: context, remote: arguments.argNonEmptyString("remote"))
            return try await json(name == .gitFetch ? backend.gitFetch(request) : backend.gitPull(request))

        case .gitPush:
            // Forced only with the lease the card named, which the host
            // holds the request to.
            let force = facts.forcePush
            var pushed = try await backend.gitPush(GitRemoteToolRequest(
                context: context,
                remote: arguments.argNonEmptyString("remote"),
                branch: facts.push?.branch,
                url: force?.url ?? facts.push?.url,
                lease: force.map { GitPushLease(expectedCommit: $0.expectedCommit, localCommit: $0.localCommit) },
            ))
            pushed.note = facts.push?.unforced ?? force.map(Self.forcedPushNote)
            return json(pushed)

        case .gitSquash:
            return try await json(squash(facts.squash, context: context))

        case .gitClone:
            return try await json(backend.gitClone(GitCloneToolRequest(
                context: context,
                url: arguments.requireString("url"),
                branch: arguments.argNonEmptyString("branch"),
            )))

        case .gitRemoteList:
            return try await json(backend.gitRemoteList(GitRemoteListToolRequest(context: context)))

        case .gitRemoteSet:
            return try await json(backend.gitRemoteSet(GitRemoteSetToolRequest(
                context: context,
                name: arguments.requireString("name"),
                url: arguments.requireString("url"),
            )))

        case .gitRemoteRemove:
            return try await json(backend.gitRemoteRemove(GitRemoteRemoveToolRequest(
                context: context,
                name: arguments.requireString("name"),
            )))

        case .gitReadSettings:
            return try await json(backend.gitSettings(context: context))

        case .gitSetAuthor:
            return try await json(backend.gitSetAuthor(GitAuthorToolRequest(
                context: context,
                name: arguments.argString("name"),
                email: arguments.argString("email"),
            )))

        case .gitSaveCredential:
            return try await json(backend.gitSaveCredential(GitCredentialToolRequest(
                context: context,
                host: arguments.requireString("host"),
                username: arguments.requireString("username"),
                token: arguments.requireString("token"),
            )))

        case .gitRemoveCredential:
            return try await json(backend.gitRemoveCredential(GitCredentialRemoveToolRequest(
                context: context,
                host: arguments.requireString("host"),
            )))

        case .gitCreateRepository:
            // The repository the card named.
            guard let repository = facts.repositoryCreate else {
                throw ToolDeniedError(message: "the repository to create could not be read")
            }
            return try await json(backend.createRepository(RepositoryCreateToolRequest(
                context: context,
                owner: repository.owner,
                name: repository.name,
                visibility: repository.visibility,
                description: repository.description,
            )))

        case .gitCreateIssue:
            // The repository and the issue the card named.
            guard let issue = facts.issueCreate else {
                throw ToolDeniedError(message: "the issue to open could not be read")
            }
            return try await json(backend.createIssue(IssueCreateToolRequest(
                context: context,
                repository: issue.repository,
                title: issue.title,
                body: issue.body,
            )))

        case .conversationCreate:
            let prompt = try arguments.requireString("prompt")
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolArgumentError("the prompt is empty: say what the other conversation should do and deliver")
            }
            return try await json(backend.conversationCreate(ConversationCreateToolRequest(
                context: context,
                prompt: prompt,
                title: arguments.argNonEmptyString("title"),
                target: facts.targetProject,
            )))

        case .conversationSend:
            let target = try Self.conversation(arguments)
            guard target != sessionID else {
                throw ToolArgumentError("session_id is this conversation; send to another one")
            }
            let text = try arguments.requireString("text")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolArgumentError("the message is empty")
            }
            return try await json(backend.conversationSend(ConversationSendToolRequest(
                context: context,
                sessionID: target,
                text: text,
                target: facts.targetProject,
            )))

        case .conversationList:
            return try await json(backend.conversationList(ConversationListToolRequest(
                context: context,
                target: facts.targetProject,
            )))

        case .conversationRead:
            let request = try ConversationReadToolRequest(
                context: context,
                sessionID: Self.conversation(arguments),
                afterSeq: arguments.argInt("after_seq").map { UInt64(max(0, $0)) },
                waitSeconds: Self.conversationWait(arguments),
                target: facts.targetProject,
            )
            let backend = backend
            return try await json(Self.untilCancelled(cancellation) { try await backend.conversationRead(request) })

        case .conversationStop:
            return try await json(backend.conversationStop(ConversationStopToolRequest(
                context: context,
                sessionID: Self.conversation(arguments),
                close: arguments.argBool("close") ?? false,
            )))

        case .toolchainList:
            return try await json(backend.toolchains(context: context))

        case .sdkList:
            return try await json(backend.sdks(context: context))

        case .toolchainSetup:
            // The release the card named, by product ID.
            guard let setup = facts.toolchainSetup else {
                throw ToolDeniedError(message: "the toolchain to set up could not be identified")
            }
            return try await json(backend.toolchainSetup(ToolchainSetupToolRequest(
                context: context,
                productID: setup.productID,
                components: setup.components,
            )))

        case .sdkImport:
            guard let sdkImport = facts.sdkImport else {
                throw ToolDeniedError(message: "the SDK to import could not be identified")
            }
            return try await json(backend.sdkImport(SDKImportToolRequest(
                context: context,
                url: sdkImport.url,
                branch: sdkImport.branch,
            )))

        case .toolchainSelfTest:
            return try await json(backend.toolchainSelfTest(ToolchainSelfTestToolRequest(
                context: context,
                toolchainID: arguments.requireString("toolchain_id"),
            )))

        case .projectSetEnvironment:
            return try await json(setEnvironment(arguments, context: context))

        case .feedbackSend:
            // The issue the card named.
            guard let feedback = facts.feedback else {
                throw ToolDeniedError(message: "the feedback to send could not be read")
            }
            return try await json(backend.sendFeedback(FeedbackToolRequest(
                context: context,
                title: feedback.title,
                body: feedback.body,
            )))

        case .feedbackRead:
            return try await json(backend.readFeedback(FeedbackReadToolRequest(
                context: context,
                number: FeedbackEdit.number(arguments),
            )))

        case .feedbackEdit:
            // The edit the card named, against the text read before asking.
            guard let edit = facts.feedbackEdit else {
                throw ToolDeniedError(message: "the edit to make could not be read")
            }
            return try await json(backend.editFeedback(FeedbackEditToolRequest(
                context: context,
                number: edit.number,
                title: edit.title,
                body: edit.body,
                expectedTitle: edit.currentTitle,
                expectedBody: edit.currentBody,
            )))
        }
    }

    /// Switches the project's toolchain and/or SDK: checked by the host as
    /// a project bound to them would be, refused on any `environment.*`
    /// error with its reason, then written into apelin-project.json through
    /// the file tools' writer with the registry's digests.
    private func setEnvironment(
        _ arguments: JSONValue,
        context: HostCallContext,
    ) async throws -> ProjectEnvironmentSetToolResponse {
        let toolchainID = arguments.argNonEmptyString("toolchain_id")
        let sdkID = arguments.argNonEmptyString("sdk_id")
        guard toolchainID != nil || sdkID != nil else {
            throw ToolArgumentError("name toolchain_id, sdk_id or both")
        }
        guard ProjectBuildSystem.read(in: root) != .external else {
            throw ToolDeniedError(message: "this workspace builds with its own tools through shell_run; it binds no Apelin toolchain or SDK")
        }
        let checked = try await backend.checkEnvironment(EnvironmentCheckToolRequest(
            context: context,
            toolchainID: toolchainID,
            sdkID: sdkID,
        ))
        let errors = checked.diagnostics.filter { $0.severity == "error" }
        guard errors.isEmpty else {
            throw ToolDeniedError(message: "refused: " + errors.map(\.message).joined(separator: "; "))
        }
        let target = try root.resolveForWrite(ProjectEnvironmentEdit.fileName)
        guard target.exists else { throw PathPolicyError.notFound(ProjectEnvironmentEdit.fileName) }
        let original = try Data(contentsOf: URL(fileURLWithPath: target.finalPath))
        let edit = try ProjectEnvironmentEdit.rebind(original, toolchain: checked.toolchain, sdk: checked.sdk)
        if edit.data != original {
            try target.commit(edit.data, exclusive: false)
        }
        return ProjectEnvironmentSetToolResponse(
            toolchain: checked.toolchain,
            sdk: checked.sdk,
            changed: edit.changed,
            warnings: checked.diagnostics.filter { $0.severity == "warning" }.map(\.message),
        )
    }

    /// A Debug build's note on the identifiers Apelin made up, while
    /// nothing this project built is installed; nil too when that list does
    /// not read, since then nothing says the first install is still ahead.
    private func firstInstallIdentifierHint() async -> String? {
        guard let hint = PlaceholderIdentifiers.buildHint(in: root),
              let installed = try? await backend.installations(InstallationListToolRequest(projectID: project.id)),
              installed.installations.isEmpty
        else { return nil }
        return hint
    }

    /// The skills folder's tools; unavailable where the session has none.
    func skillTools() throws -> SkillTools {
        guard let skills else { throw ToolDeniedError(message: "Skills are unavailable.") }
        return SkillTools(directory: skills)
    }

    /// The memory a call reaches: this session's project's, or the
    /// project it names, by projectID or folder as apelin_project_list
    /// answers them. A projectID no project has now still reaches the
    /// records kept for it, to change or delete, but takes no new one.
    private func memoryTools(_ store: MemoryStore, naming reference: String?) async throws -> MemoryTools {
        guard let reference else {
            let refusal = project.isTemporary
                ? "General Chat has no project of its own: name it with project (its projectID or folder name, as apelin_project_list answers them), or use scope global."
                : nil
            return MemoryTools(store: store, projectID: project.id, newRecordRefusal: refusal)
        }
        let target: ProjectIdentity
        do {
            target = try await backend.resolveProject(reference)
        } catch {
            guard (try? store.read())?.records.contains(where: { $0.projectID == reference }) == true else { throw error }
            return MemoryTools(
                store: store,
                projectID: reference,
                newRecordRefusal: "No project has the id \(reference) now: its memories can be changed or deleted, not added to.",
            )
        }
        guard !target.isTemporary else { throw ToolDeniedError(message: "a temporary chat keeps no memories of its own") }
        return MemoryTools(store: store, projectID: target.id)
    }

    /// The projects the records of `snapshot` are kept for, by projectID,
    /// as apelin_project_list names them; one that is not there is gone.
    private func memoryProjects(_ snapshot: MemorySnapshot) async throws -> [String: MemoryListing.Project] {
        let listing = try await backend.projects()
        var projects: [String: MemoryListing.Project] = [:]
        for listed in listing.projects {
            projects[listed.projectID] = MemoryListing.Project(folder: listed.folder, displayName: listed.displayName)
        }
        // a list cut short is no proof that a project is gone
        guard listing.truncated else { return projects }
        for id in Set(snapshot.records.compactMap(\.projectID)) where projects[id] == nil {
            guard let found = try? await backend.resolveProject(id), found.id == id else { continue }
            projects[id] = MemoryListing.Project(folder: found.name.rawValue, displayName: nil)
        }
        return projects
    }

    /// The root a read tool reads `path` from: the project's, unless the
    /// path is absolute and lies in one of the read-only roots.
    func readRoot(for path: String) -> ScopedRoot {
        readOnlyRoots.root(containing: path)?.root ?? root
    }

    /// The read tools against the root this call's `path` lies in.
    private func readFiles(_ arguments: JSONValue) -> ProjectFileTools {
        let path = arguments.argString("path") ?? "."
        guard let readOnly = readOnlyRoots.root(containing: path) else { return ProjectFileTools(root: root) }
        return ProjectFileTools(root: readOnly.root, shownRoot: readOnly.shownAs)
    }

    /// What a read tool's refusal of a path outside the project adds: the
    /// folders it reads besides.
    private func readOnlyNote(_ tool: InvocationFacts.Tool) -> String {
        guard case let .local(name) = tool, ReadOnlyRoots.tools.contains(name),
              let note = readOnlyRoots.refusalNote
        else { return "" }
        return "; " + note
    }

    /// Runs `body` until it answers or the call is cancelled: a stop does
    /// not wait for a long wait on another conversation to run out.
    static func untilCancelled<T: Sendable>(
        _ cancellation: CancellationHandle?,
        _ body: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        let task = Task { try await body() }
        let registration = cancellation?.onCancel { _ in task.cancel() }
        defer { registration?.cancel() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func text(_ string: String) -> AgentToolResult {
        AgentToolResult(content: [.text(TextContent(text: string))])
    }

    private func json(_ value: some Encodable) -> AgentToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return text(String(decoding: data, as: UTF8.self))
    }
}
