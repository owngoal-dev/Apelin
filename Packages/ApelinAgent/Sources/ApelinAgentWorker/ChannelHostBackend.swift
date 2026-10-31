import ApelinAgent
import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// `AgentHostBackend` over `ApelinService`: every system tool the agent has
/// is one request to the session host, through the same typed facade the app
/// and the console use. In `apelin-agent` the transport is the worker
/// channel (`ChannelTransport`); tests pass a fake.
///
/// Mapping (tool → host operation):
/// apelin_project_build → `buildStart`, then its task read to the end;
/// apelin_package_install → `installPackage` likewise; apelin_package_remove →
/// `removePackage`; apelin_package_list (and apelin_package_remove's package id)
/// → `installationList`, every project's;
/// apelin_device_respring → `respring`; apelin_package_confirm_loaded → a `confirmLoaded` task with the session's
/// project (and `trigger: respring` when asked), read to its end, the image
/// list never asked for;
/// apelin_log_read → a bounded `logStream` read to its end; apelin_crash_list →
/// `crashList`; apelin_crash_read → `crashOpen` (a read-only descriptor);
/// apelin_crash_symbolicate → `crashSymbolicate` (apelin-diagnostics, the project's
/// dSYMs); apelin_screen_capture / apelin_screen_read_tree / apelin_screen_interact → `captureScreen` /
/// `readUITree` / `uiAction`; apelin_sdk_analyze_framework and apelin_sdk_read_header's SDK →
/// `sdkList`, the project's pinned SDK first; shell_run → `agentRunCode`,
/// which the host runs as mobile in the project (as root, with `asRoot`, when
/// Full mode or the user's approval of that root request lets it); apelin_template_list →
/// `extensionList`, isolated extensions left out; apelin_project_create →
/// `projectCreate`; apelin_project_rename → `projectRename`;
/// apelin_project_delete → `projectDelete`; git_status / git_diff / git_stage / git_unstage /
/// git_commit, git_init → `gitStatus` / `gitDiff` / `gitStage` /
/// `gitUnstage` / `gitCommit` / `gitInit` on the session's project (no
/// author: the host's settings);
/// git_fetch / git_pull / git_push / git_clone → `gitFetch` / `gitPull` /
/// `gitPush` / `gitCloneInto`, each task read to its end;
/// apelin_conversation_create → `agentOpen` with this session's provider, model
/// and effort, in this session's project or the one named, answered
/// without waiting; apelin_conversation_send → `agentPrompt` with the text alone;
/// apelin_conversation_list → `agentList` of a project; apelin_conversation_read →
/// `agentList` for the task, then `agentAttach` (`ConversationReader`);
/// apelin_conversation_stop → `agentAbort`, then `agentClose` when asked. The host
/// keeps them to this session's project, and to another one only as the
/// user approved. apelin_toolchain_list, apelin_sdk_list, apelin_toolchain_setup,
/// apelin_toolchain_self_test, apelin_sdk_import and apelin_project_set_environment's check:
/// ChannelHostBackend+Environment. apelin_feedback_send → `feedbackSend`;
/// apelin_feedback_read → `feedbackRead`; apelin_feedback_edit →
/// `feedbackRead`, then `feedbackEdit` against what it read;
/// apelin_git_create_repository → `gitRepositoryCreate`;
/// apelin_git_create_issue → `gitIssueCreate`;
/// apelin_package_publish → `distributionPublish` with each file's digest
/// and the repository, read to its end (ChannelHostBackend+Publish). An
/// agent tool extension's tools → `toolHostOpen`, `toolHostCall` and
/// `toolHostClose`: ChannelHostBackend+ToolExtensions.
public struct ChannelHostBackend: AgentHostBackend {
    public let service: ApelinService
    public let sessionID: String
    public let project: ApelinAgent.ProjectIdentity
    /// `Projects/<name>`, read for the pinned SDK.
    public let projectURL: URL
    /// `Projects/`, where a conversation call finds the other project it names.
    public let projectsURL: URL
    /// What the session runs with now, which apelin_conversation_create passes on.
    public let modelChoice: SessionModelChoice

    public static let maximumScreenshotBytes = 4 * 1024 * 1024
    static let logExcerptBytes = 8 * 1024
    /// git_diff hands the model at most this much; a path narrows it.
    public static let maximumDiffBytes = 64 * 1024
    /// apelin_package_list hands the model at most this many installations.
    public static let maximumInstallations = 50

    /// apelin_conversation_read hands the model at most this much text.
    public static let maximumConversationBytes = 32 * 1024
    /// One attach while apelin_conversation_read waits: short, so a stop is quick.
    static let conversationPollMilliseconds = 5000

    public init(
        service: ApelinService,
        sessionID: String,
        project: ApelinAgent.ProjectIdentity,
        projectURL: URL,
        projectsURL: URL? = nil,
        modelChoice: SessionModelChoice = SessionModelChoice(),
    ) {
        self.service = service
        self.sessionID = sessionID
        self.project = project
        self.projectURL = projectURL
        self.projectsURL = projectsURL ?? projectURL.deletingLastPathComponent()
        self.modelChoice = modelChoice
    }

    // MARK: shell_run

    public func runCode(_ request: RunCodeRequest) async throws -> RunCodeResponse {
        let response: AgentRunCodeResponse
        do {
            response = try await service.agentRunCode(AgentRunCodeRequest(
                sessionID: sessionID,
                spec: Self.spec(request.invocation),
                workingDirectory: request.workingDirectory,
                timeoutSeconds: request.timeoutSeconds,
                approval: Self.approval(request.context.approval),
                asRoot: request.asRoot ? true : nil,
            ))
        } catch let error as ApelinError where error.code == .denied && error.reason == .notAPreset {
            // The host's preset rule does not count this call; the runner
            // asks the user instead.
            throw HostRefusedPresetError(message: error.message)
        }
        return RunCodeResponse(
            exitCode: response.exitCode,
            stdout: response.stdout,
            stderr: response.timedOut
                ? response.stderr + "\n[killed after \(request.timeoutSeconds) s]"
                : response.stderr,
            truncated: response.truncated,
            durationMilliseconds: response.durationMilliseconds,
            timedOut: response.timedOut,
        )
    }

    static func spec(_ invocation: RunCodeInvocation) -> RunCodeSpec {
        switch invocation {
        case let .argv(argv): .argv(argv)
        case let .shell(text): .script(interpreter: "sh", source: text)
        case let .script(interpreter, source): .script(interpreter: interpreter, source: source)
        }
    }

    static func approval(_ evidence: ApprovalEvidence) -> RunCodeApproval {
        switch evidence {
        case let .preset(name): .preset(name)
        case let .user(requestID, _):
            requestID == ApprovalEvidence.sessionRequestID ? .session : .user(approvalID: requestID)
        // The host decides from the session's mode; anything else is not
        // evidence for running code.
        case .relaxed, .notRequired, .templateMatch, .digestApproved: .relaxed
        }
    }

    // MARK: build, install, remove, respring

    public func build(_ request: BuildRequest) async throws -> BuildResponse {
        let configuration: ApelinProtocol.BuildConfiguration = request.configuration == .release ? .release : .debug
        let bootstrap = try Self.bootstrap(request.bootstrap)
        // A distribution build reports what the package should not carry yet.
        let check = await configuration == .release && bootstrap != nil
            ? (try? distributionCheck(bootstrap: bootstrap))
            : nil
        let warnings = (check?.diagnostics ?? []).filter(Self.isDistributionWarning)
        let handle: TaskHandle
        do {
            handle = try await service.buildStart(
                projectID: project.id,
                configuration: configuration,
                bootstrap: bootstrap,
            )
        } catch let refusal as ApelinError {
            throw await unreadProjectRefusal() ?? refusal
        }
        var buildID = handle.taskID.rawValue
        var diagnostics = warnings
        var artifacts: [ApelinAgent.BuildArtifact] = []
        var log = BoundedTail(limit: Self.logExcerptBytes)
        let end = try await read(handle) { event in
            switch event.kind {
            case "diagnostic":
                if let diagnostic = try? event.payload?.decode(ProjectDiagnostic.self) {
                    diagnostics.append(diagnostic)
                }
            case "artifact":
                if let artifact = try? event.payload?.decode(ApelinProtocol.BuildArtifact.self) {
                    let file = artifact.path.map { ($0 as NSString).lastPathComponent }
                    let bootstrap = artifact.bootstrap.map { "_\($0)" } ?? ""
                    artifacts.append(ApelinAgent.BuildArtifact(
                        id: artifact.artifactID,
                        kind: .package,
                        name: file ?? "\(artifact.packageID)_\(artifact.version)\(bootstrap).deb",
                        digest: artifact.digest,
                    ))
                    // The artifact names the APELIN_BUILD_ID apelin_package_confirm_loaded matches.
                    if let named = artifact.buildID, !named.isEmpty {
                        buildID = named
                    }
                }
            case "log":
                if let line = event.payload?["line"]?.stringValue {
                    log.append(line)
                }
            default:
                break
            }
            // Another event may name the APELIN_BUILD_ID before an artifact does.
            if event.kind != "artifact", buildID == handle.taskID.rawValue,
               let named = event.payload?["buildID"]?.stringValue, !named.isEmpty
            {
                buildID = named
            }
        }
        if let message = end.message {
            log.append(message)
        }
        return BuildResponse(
            buildID: buildID,
            succeeded: end.state == .succeeded,
            diagnostics: Self.diagnostics(diagnostics),
            artifacts: artifacts,
            logExcerpt: log.text,
        )
    }

    /// A project file that does not read is refused before its build
    /// starts: by apelin-build, its errors run together, or in Strict mode
    /// by the host, which then has no description to match and says only
    /// that approval is required. The check names each error's field, and
    /// the refusal where the schema is; nil when the file reads, so the
    /// refusal stands as it came.
    private func unreadProjectRefusal() async -> ApelinError? {
        guard let check = try? await service.projectCheck(projectID: project.id) else { return nil }
        let unread = check.diagnostics.filter { Self.unreadProjectCodes.contains($0.code) }
        guard !unread.isEmpty else { return nil }
        var message = "apelin-project.json does not read, so the build did not start: "
            + unread.map(Self.fieldAndMessage).joined(separator: "; ")
        if unread.contains(where: { $0.code == Self.schemaErrorCode }) {
            message += ". " + Self.schemaPointer
        }
        return ApelinError(.badRequest, message)
    }

    // MARK: distribution

    /// What stops the build counts as well as what the package should not
    /// carry: a project whose check fails is not ready either. A workspace
    /// has no description to read before its script runs, so its release
    /// build checks the package instead, as the note says.
    public func checkDistribution(_ request: DistributionCheckRequest) async throws -> DistributionCheckResponse {
        let check = try await distributionCheck(bootstrap: Self.bootstrap(request.bootstrap))
        let issues = check.diagnostics.filter { $0.severity == .error || Self.isDistributionWarning($0) }
        return DistributionCheckResponse(
            ready: issues.isEmpty,
            issues: Self.diagnostics(issues),
            note: check.buildSystem == .external
                ? "This workspace's package is checked when its build script writes it: a release build lists what it finds among its diagnostics."
                : nil,
        )
    }

    /// The bootstrap a request names, or nil when it names none.
    static func bootstrap(_ raw: String?) throws -> ApelinProtocol.BuildBootstrap? {
        let bootstrap = raw.flatMap(ApelinProtocol.BuildBootstrap.init(rawValue:))
        guard raw == nil || bootstrap != nil else {
            throw ApelinError(.badRequest, "unknown build bootstrap")
        }
        return bootstrap
    }

    // MARK: projects

    public func projectTemplates() async throws -> ProjectTemplateListResponse {
        let extensions = try await service.extensionList().extensions.filter(\.problems.isEmpty)
        return ProjectTemplateListResponse(templates: extensions.flatMap { found in
            found.templates.map { template in
                ProjectTemplate(
                    id: template.id,
                    name: template.displayName,
                    kind: found.kind.rawValue,
                    summary: template.summary,
                    parameters: template.parameters.map { parameter in
                        ProjectTemplate.Parameter(
                            name: parameter.name,
                            kind: parameter.kind,
                            summary: parameter.summary,
                            defaultValue: parameter.defaultValue.flatMap(Self.templateValue),
                        )
                    },
                )
            }
        })
    }

    public func createProject(_ request: ProjectCreateToolRequest) async throws -> ProjectCreateToolResponse {
        let created = try await service.projectCreate(ProjectCreateRequest(
            templateID: request.templateID,
            name: request.name,
            values: request.values.mapValues { value in
                switch value {
                case let .string(text): .string(text)
                case let .boolean(flag): .bool(flag)
                case let .integer(number): .number(Double(number))
                case let .list(items): .array(items.map(ApelinCore.JSONValue.string))
                }
            },
        ))
        return ProjectCreateToolResponse(
            projectID: created.projectID,
            name: created.name,
            identifierHint: createdRoot(created.name).flatMap(PlaceholderIdentifiers.createHint),
        )
    }

    /// The folder `projectCreate` just made under `Projects/`, as mobile
    /// reads it; nil when it is not there or leads elsewhere.
    private func createdRoot(_ name: String) -> ScopedRoot? {
        guard let projects = try? ScopedRoot(projectsURL),
              let path = try? projects.resolveExisting(name),
              projects.relative(path) == name
        else { return nil }
        return try? ScopedRoot(URL(fileURLWithPath: path, isDirectory: true))
    }

    public func renameProject(_ request: ProjectRenameToolRequest) async throws -> ProjectRenameToolResponse {
        let renamed = try await service.projectRename(ProjectRenameRequest(
            projectID: request.projectID,
            displayName: request.displayName,
            onlyIfAutomatic: request.automatic,
        ))
        return ProjectRenameToolResponse(
            projectID: renamed.projectID,
            folder: request.folder,
            displayName: renamed.displayName,
            changed: renamed.changed,
        )
    }

    /// The project the card named, in the folder it named.
    public func deleteProject(_ request: ProjectDeleteToolRequest) async throws -> ProjectDeleteToolResponse {
        let deleted = try await service.projectDelete(ProjectDeleteRequest(projectID: request.projectID, projectName: request.folder))
        return ProjectDeleteToolResponse(projectID: deleted.projectID, folder: deleted.projectName)
    }

    static func templateValue(_ value: ApelinCore.JSONValue) -> TemplateValue? {
        switch value {
        case let .string(text): .string(text)
        case let .bool(flag): .boolean(flag)
        case let .number(number) where number.rounded() == number && abs(number) < 1e15: .integer(Int(number))
        // A list kind's default, such as the tweak's filterBundles.
        case let .array(items) where items.allSatisfy { $0.stringValue != nil }: .list(items.compactMap(\.stringValue))
        default: nil
        }
    }

    private func distributionCheck(
        bootstrap: ApelinProtocol.BuildBootstrap?,
    ) async throws -> (diagnostics: [ProjectDiagnostic], buildSystem: BuildSystemKind?) {
        let response = try await service.projectCheck(projectID: project.id, purpose: .distribution, bootstrap: bootstrap)
        return (response.diagnostics, response.buildSystem)
    }

    private static func isDistributionWarning(_ diagnostic: ProjectDiagnostic) -> Bool {
        diagnostic.code.hasPrefix("distribution.") && diagnostic.severity != .error
    }

    static func diagnostic(_ diagnostic: ProjectDiagnostic) -> BuildDiagnostic {
        let severity: BuildDiagnostic.Severity = switch diagnostic.severity {
        case .error: .error
        case .warning: .warning
        case .note: .note
        }
        return BuildDiagnostic(
            severity: severity,
            file: diagnostic.file,
            line: diagnostic.line,
            column: diagnostic.column,
            field: diagnostic.field,
            message: diagnostic.message,
        )
    }

    /// Each finding with its field, and after a schema error a note saying
    /// where the schema is.
    static func diagnostics(_ found: [ProjectDiagnostic]) -> [BuildDiagnostic] {
        var diagnostics = found.map(diagnostic)
        if found.contains(where: { $0.code == schemaErrorCode }) {
            diagnostics.append(BuildDiagnostic(severity: .note, file: "apelin-project.json", message: schemaPointer))
        }
        return diagnostics
    }

    /// What apelin-build's check reports when `apelin-project.json` did not
    /// read: the file itself, its JSON, or its schema.
    static let unreadProjectCodes: Set = ["project.unreadable", "project.json", schemaErrorCode]
    /// A member the schema does not allow, lacks or types wrongly; its field
    /// says which.
    static let schemaErrorCode = "project.invalid"

    static let schemaPointer = "apelin-project.json does not match its schema; each error's field is the member to fix. Read the apelin-project-description skill and its file apelin-project.schema.json (apelin_skill_read) before editing it."

    /// A finding as the check first wrote it, its field in front:
    /// `/configurations/Debug/linkerFlags: unknown member`.
    static func fieldAndMessage(_ diagnostic: ProjectDiagnostic) -> String {
        diagnostic.field.map { "\($0): \(diagnostic.message)" } ?? diagnostic.message
    }

    public func install(_ request: InstallRequest) async throws -> InstallResponse {
        let handle = try await service.installPackage(artifactID: request.artifactID, digest: request.artifactDigest)
        var result: InstallResult?
        var conflicts: [InstallConflict] = []
        let end = try await read(handle) { event in
            if event.kind == "result", let decoded = try? event.payload?.decode(InstallResult.self) {
                result = decoded
            }
            if event.kind == "conflict", let conflict = try? event.payload?.decode(InstallConflict.self) {
                conflicts.append(conflict)
            }
        }
        return InstallResponse(
            transactionID: result?.transactionID ?? handle.taskID.rawValue,
            installationID: result?.installationID,
            packageID: result?.packageID ?? "",
            version: result?.version ?? "",
            succeeded: end.state == .succeeded,
            message: end.message ?? "",
            conflicts: conflicts.isEmpty ? nil : conflicts,
        )
    }

    public func removePackage(_ request: ApelinAgent.RemovePackageRequest) async throws -> RemovePackageResponse {
        let handle = try await service.removePackage(installationID: request.installationID)
        let end = try await read(handle) { _ in }
        return RemovePackageResponse(
            transactionID: handle.taskID.rawValue,
            succeeded: end.state == .succeeded,
            message: end.message ?? "",
        )
    }

    /// The host's rows, with the folder each project is under now, which is
    /// what the model names a project by.
    public func installations(_ request: InstallationListToolRequest) async throws -> InstallationListToolResponse {
        let listed = try await service.installationList(packageID: request.packageID, projectID: request.projectID)
            .installations
        let known = await (try? projects().projects) ?? []
        let folders = Dictionary(known.map { ($0.projectID, $0.folder) }, uniquingKeysWith: { first, _ in first })
        return InstallationListToolResponse(
            installations: listed.prefix(Self.maximumInstallations).map { row in
                ListedInstallation(
                    installationID: row.installationID,
                    packageID: row.packageID,
                    version: row.version,
                    projectID: row.projectID,
                    project: row.projectID.flatMap { folders[$0] },
                    buildID: row.buildID,
                    installedAt: row.installedAt,
                    removable: row.removable,
                    reason: row.reason,
                )
            },
            truncated: listed.count > Self.maximumInstallations,
        )
    }

    public func respring(_: ApelinAgent.RespringRequest) async throws -> RespringResponse {
        try await service.respring()
        return RespringResponse(
            succeeded: true,
            reconnectHint: "SpringBoard restarts; this session keeps running in the session host",
        )
    }

    // MARK: apelin_package_confirm_loaded

    public func confirmLoaded(
        _ request: ApelinAgent.ConfirmLoadedRequest,
    ) async throws -> ApelinAgent.ConfirmLoadedResponse {
        // The answer is the task's, in the session host: the respring this may
        // trigger takes the app down, not this worker.
        let response = try await service.confirmLoaded(
            buildID: request.buildID,
            targetID: request.target,
            projectID: project.id,
            trigger: request.respring ? .respring : nil,
        )
        let marker = response.evidence.first { $0.kind == "log" }
        let filter = response.evidence.first { $0.kind == "filter" }
        let filterMatches: Bool? = filter.flatMap { evidence in
            if evidence.passed {
                return true
            }
            return evidence.detail.hasPrefix("absent") ? false : nil
        }
        // The image evidence is always `notRead`; the answer's `basis` says
        // so once.
        let notes = response.evidence.filter { $0.kind != "image" }.map { "\($0.kind): \($0.detail)" }
        return ApelinAgent.ConfirmLoadedResponse(
            loaded: response.loaded,
            markerLogged: marker?.passed ?? false,
            filterMatches: filterMatches,
            logEvidence: marker.map { [$0.detail] } ?? [],
            notes: notes.joined(separator: "\n"),
        )
    }

    // MARK: SDK

    public func registeredSDK(_ request: RegisteredSDKRequest) async throws -> RegisteredSDKResponse {
        let list = try await service.sdkList()
        let wanted = request.sdkID ?? Self.pinnedSDK(projectURL: projectURL)
        let record = wanted.flatMap { id in list.sdks.first { $0.id == id || $0.canonicalName == id } }
            ?? list.sdks.first
        guard let record else { throw ApelinError(.notFound, "no SDK is registered; add one in Apelin's SDK manager") }
        if let asked = request.sdkID, record.id != asked, record.canonicalName != asked {
            throw ApelinError(.notFound, "no registered SDK matches \(asked)")
        }
        return RegisteredSDKResponse(
            sdkID: record.id,
            rootPath: record.path,
            platform: "iphoneos",
            version: record.version,
        )
    }

    /// `environment.sdk.id` in the project's `apelin-project.json`.
    static func pinnedSDK(projectURL: URL) -> String? {
        let url = projectURL.appendingPathComponent("apelin-project.json")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              let json = try? JSONCoding.decode(ApelinCore.JSONValue.self, from: data)
        else { return nil }
        return json.value(at: "environment.sdk.id")?.stringValue
    }

    // MARK: git

    public func gitStatus(_: GitStatusToolRequest) async throws -> GitStatusToolResponse {
        let status = try await git("git status") { try await service.gitStatus(projectID: project.id) }
        return GitStatusToolResponse(
            branch: status.branch,
            head: status.head,
            entries: status.entries.map { GitStatusToolEntry(path: $0.path, index: $0.index, worktree: $0.worktree) },
        )
    }

    public func gitDiff(_ request: GitDiffToolRequest) async throws -> GitDiffToolResponse {
        let response = try await git("git diff") {
            try await service.gitDiff(projectID: project.id, path: request.path, staged: request.staged)
        }
        let (diff, truncated) = Self.bounded(response.diff, bytes: Self.maximumDiffBytes)
        return GitDiffToolResponse(diff: diff, truncated: truncated)
    }

    public func gitStage(_ request: GitPathsToolRequest) async throws -> GitPathsToolResponse {
        try await git("git stage") { try await service.gitStage(projectID: project.id, paths: request.paths) }
        return GitPathsToolResponse(paths: request.paths)
    }

    public func gitUnstage(_ request: GitPathsToolRequest) async throws -> GitPathsToolResponse {
        try await git("git unstage") { try await service.gitUnstage(projectID: project.id, paths: request.paths) }
        return GitPathsToolResponse(paths: request.paths)
    }

    public func gitCommit(_ request: GitCommitToolRequest) async throws -> GitCommitToolResponse {
        let response = try await git("git commit") {
            try await service.gitCommit(GitCommitRequest(
                projectID: project.id,
                message: request.message,
                all: request.all ? true : nil,
            ))
        }
        return GitCommitToolResponse(commitID: response.commitID)
    }

    public func gitInit(_: GitInitToolRequest) async throws -> GitInitToolResponse {
        let response = try await git("git init") { try await service.gitInit(projectID: project.id) }
        return GitInitToolResponse(branch: response.branch)
    }

    public func gitFetch(_ request: GitRemoteToolRequest) async throws -> GitTaskToolResponse {
        try await gitTask("git fetch") {
            try await service.gitFetch(projectID: project.id, remote: request.remote, branch: request.branch)
        }
    }

    public func gitPull(_ request: GitRemoteToolRequest) async throws -> GitTaskToolResponse {
        try await gitTask("git pull") { try await service.gitPull(projectID: project.id, remote: request.remote) }
    }

    public func gitPush(_ request: GitRemoteToolRequest) async throws -> GitTaskToolResponse {
        let host = request.url.flatMap { URLComponents(string: $0)?.host }
        return try await gitTask("git push", host: host, forced: request.lease != nil) {
            try await service.gitPush(GitPushRequest(
                projectID: project.id,
                remote: request.remote,
                branch: request.branch,
                url: request.url,
                forceWithLease: request.lease,
            ))
        }
    }

    public func gitSquash(_ request: GitSquashToolRequest) async throws -> GitSquashResponse {
        try await git("git squash") {
            try await service.gitSquash(GitSquashRequest(
                projectID: project.id,
                base: request.base,
                count: request.count,
                message: request.message,
                expectedHead: request.expectedHead,
                preview: request.preview ? true : nil,
            ))
        }
    }

    public func gitClone(_ request: GitCloneToolRequest) async throws -> GitTaskToolResponse {
        let host = URLComponents(string: request.url)?.host
        return try await gitTask("git clone", host: host) {
            try await service.gitCloneInto(GitCloneIntoRequest(
                projectID: project.id,
                url: request.url,
                branch: request.branch,
            ))
        }
    }

    public func gitSettings(context _: HostCallContext) async throws -> GitSettingsToolResponse {
        try await Self.settings(git("git settings") { try await service.gitSettings() })
    }

    public func gitSetAuthor(_ request: GitAuthorToolRequest) async throws -> GitSettingsToolResponse {
        try await git("git set author") { try await service.gitAuthorSet(name: request.name, email: request.email) }
        return try await gitSettings(context: request.context)
    }

    public func gitSaveCredential(_ request: GitCredentialToolRequest) async throws -> GitSettingsToolResponse {
        try await git("git save credential") {
            try await service.gitCredentialSet(GitCredentialSetRequest(
                host: request.host,
                username: request.username,
                token: request.token,
            ))
        }
        return try await gitSettings(context: request.context)
    }

    public func gitRemoveCredential(_ request: GitCredentialRemoveToolRequest) async throws -> GitSettingsToolResponse {
        try await git("git remove credential") { try await service.gitCredentialRemove(host: request.host) }
        return try await gitSettings(context: request.context)
    }

    // MARK: apelin_git_create_repository

    /// Without a github.com sign-in, or with one GitHub refused, the model
    /// hears where the user signs in, read from the reply's reason; any
    /// other refusal is GitHub's or the host's, in their words.
    public func createRepository(_ request: RepositoryCreateToolRequest) async throws -> RepositoryCreateToolResponse {
        let response: GitRepositoryCreateResponse
        do {
            response = try await service.gitRepositoryCreate(GitRepositoryCreateRequest(
                name: request.name,
                visibility: request.visibility,
                owner: request.owner,
                description: request.description,
            ))
        } catch let error as ApelinError where error.reason == .authenticationRequired {
            throw GitToolFailure(message: Self.repositorySignInNeeded)
        }
        return RepositoryCreateToolResponse(
            fullName: response.fullName,
            cloneURL: response.cloneURL,
            url: response.url,
            next: "It is empty. To publish the project there, git_push with url \(response.cloneURL): it adds the remote as origin (or as the remote you name, when the user wants another), and asks the user in Strict mode as every push does.",
        )
    }

    static let repositorySignInNeeded = "Nothing was created: GitHub authorization is needed. Ask the user to Sign In with GitHub in Settings ▸ Git, then try again."

    // MARK: apelin_git_create_issue

    /// Without a github.com sign-in, or with one GitHub refused, the model
    /// hears where the user signs in, read from the reply's reason; any
    /// other refusal is GitHub's or the host's, in their words, with what
    /// the model must not do instead.
    public func createIssue(_ request: IssueCreateToolRequest) async throws -> IssueCreateToolResponse {
        let response: GitIssueCreateResponse
        do {
            response = try await service.gitIssueCreate(repository: request.repository, title: request.title, body: request.body)
        } catch let error as ApelinError where error.reason == .authenticationRequired {
            throw GitToolFailure(message: Self.issueSignInNeededToPost)
        } catch let error as ApelinError {
            throw GitToolFailure(message: Self.issueRefused(error.message, repository: request.repository))
        }
        return IssueCreateToolResponse(repository: response.repository, issue: response.number, url: response.url)
    }

    static let issueSignInNeededToPost = "Nothing was posted: GitHub authorization is needed. Ask the user to Sign In with GitHub in Settings ▸ Git, then try again."

    static func issueRefused(_ message: String, repository: String) -> String {
        let words = message.hasSuffix(".") ? message : message + "."
        return "Nothing was posted on \(repository): \(words) Tell the user what blocks it; never post it to another repository, or through a browser or the screen, instead."
    }

    // MARK: apelin_feedback_send

    /// Without a github.com sign-in, or with one GitHub refused, the model
    /// hears where the user signs in, read from the reply's reason.
    public func sendFeedback(_ request: FeedbackToolRequest) async throws -> FeedbackToolResponse {
        let response: FeedbackSendResponse
        do {
            response = try await service.feedbackSend(title: request.title, body: request.body)
        } catch let error as ApelinError where error.reason == .authenticationRequired {
            throw FeedbackToolFailure(message: Self.gitHubSignInNeeded)
        }
        return FeedbackToolResponse(repository: FeedbackRules.repository, issue: response.number, url: response.url)
    }

    static let gitHubSignInNeeded = "Nothing was posted: GitHub authorization is needed. Ask the user to Sign In with GitHub in Settings ▸ Git, then send again."

    // MARK: apelin_feedback_read, apelin_feedback_edit

    public func readFeedback(_ request: FeedbackReadToolRequest) async throws -> FeedbackReadToolResponse {
        let issue: FeedbackReadResponse
        do {
            issue = try await service.feedbackRead(number: request.number)
        } catch let error as ApelinError where error.reason == .authenticationRequired {
            throw FeedbackToolFailure(message: Self.issueSignInNeeded)
        }
        return FeedbackReadToolResponse(
            repository: FeedbackRules.repository,
            issue: issue.number,
            url: issue.url,
            title: issue.title,
            state: issue.state,
            author: issue.author,
            openedByUser: issue.isAuthor,
            body: issue.body,
            footer: issue.footer,
        )
    }

    /// apelin-environment's refusals are in words the model acts on: an
    /// issue that changed since it was read, another account's.
    public func editFeedback(_ request: FeedbackEditToolRequest) async throws -> FeedbackEditToolResponse {
        let response: FeedbackEditResponse
        do {
            response = try await service.feedbackEdit(FeedbackEditRequest(
                number: request.number,
                title: request.title,
                body: request.body,
                expectedTitle: request.expectedTitle,
                expectedBody: request.expectedBody,
            ))
        } catch let error as ApelinError where error.reason == .authenticationRequired {
            throw FeedbackToolFailure(message: "Nothing was changed: " + Self.issueSignInNeeded)
        }
        let changed: [String] = [request.title.map { _ in "title" }, request.body.map { _ in "body" }].compactMap(\.self)
        return FeedbackEditToolResponse(
            repository: FeedbackRules.repository,
            issue: response.number,
            url: response.url,
            changed: changed,
            title: response.title,
            body: response.body,
        )
    }

    static let issueSignInNeeded = "GitHub authorization is needed. Ask the user to Sign In with GitHub in Settings ▸ Git, then try again."

    static func settings(_ response: GitSettingsResponse) -> GitSettingsToolResponse {
        GitSettingsToolResponse(
            authorName: response.authorName,
            authorEmail: response.authorEmail,
            credentials: response.credentials.map { .init(host: $0.host, username: $0.username) },
        )
    }

    /// One git request; a refusal comes back as a `GitToolFailure` that says
    /// what to do about it.
    func git<T>(
        _ operation: String,
        host: String? = nil,
        forced: Bool = false,
        _ body: () async throws -> T,
    ) async throws -> T {
        do {
            return try await body()
        } catch let error as ApelinError {
            throw GitFailure.describe(
                operation,
                code: error.code,
                message: error.message,
                reason: error.reason?.rawValue,
                host: host,
                forced: forced,
            )
        }
    }

    /// Starts a git task and reads it to its final `state`: the `result` it
    /// reported, or a failure in words.
    private func gitTask(
        _ operation: String,
        host: String? = nil,
        forced: Bool = false,
        _ start: () async throws -> TaskHandle,
    ) async throws -> GitTaskToolResponse {
        let handle = try await git(operation, host: host, forced: forced, start)
        var result: ApelinCore.JSONValue?
        var reason: String?
        let end = try await read(handle) { event in
            if event.kind == "result" {
                result = event.payload
            } else if event.kind == TaskEvent.stateKind {
                result = event.payload?["result"] ?? result
                reason = event.payload?["reason"]?.stringValue
            }
        }
        switch end.state {
        case .succeeded:
            return Self.gitResult(result)
        case .cancelled:
            throw GitToolFailure(message: "\(operation) was cancelled.")
        case .interrupted:
            throw GitToolFailure(message: "\(operation) was cut off when the session host stopped; check git_status, then run it again if it is still needed.")
        default:
            let (code, message) = GitFailure.split(end.message)
            throw GitFailure.describe(operation, code: code, message: message, reason: reason, host: host, forced: forced)
        }
    }

    static func gitResult(_ json: ApelinCore.JSONValue?) -> GitTaskToolResponse {
        guard let json else { return GitTaskToolResponse() }
        var updates: [GitRefUpdate]?
        if case let .array(entries)? = json["updated"] {
            updates = entries.compactMap { entry in
                guard let ref = entry["ref"]?.stringValue, let to = entry["to"]?.stringValue else { return nil }
                return GitRefUpdate(ref: ref, from: entry["from"]?.stringValue, to: to)
            }
        }
        var upToDate: Bool?
        if case let .bool(flag)? = json["upToDate"] {
            upToDate = flag
        }
        var forced: Bool?
        if case let .bool(flag)? = json["forced"] {
            forced = flag
        }
        return GitTaskToolResponse(
            remote: json["remote"]?.stringValue,
            branch: json["branch"]?.stringValue,
            commit: json["commit"]?.stringValue,
            from: json["from"]?.stringValue,
            to: json["to"]?.stringValue,
            upToDate: upToDate,
            updated: updates,
            comparison: try? json["comparison"]?.decode(GitBranchComparison.self),
            forced: forced,
            projectFile: json["projectFile"]?.stringValue.flatMap(GitProjectFile.init(rawValue:)).flatMap(projectFileNote),
        )
    }

    /// What an import or a reset did to apelin-project.json, for the model;
    /// nil when the project's own stayed.
    static func projectFileNote(_ file: GitProjectFile) -> String? {
        switch file {
        case .repository:
            "apelin-project.json is now the repository's, as it is: the project is what it describes, with its projectID. A build of that description asks the user first in Strict mode."
        case .repositoryWithProjectID:
            "apelin-project.json is now the repository's, with this project's own projectID in place of the one it carried, so git_status shows it changed: commit it with your next change. The project is what it describes; a build of that description asks the user first in Strict mode."
        case .project:
            nil
        }
    }

    /// At most `bytes` of `text`, cut at a line end where one is near.
    static func bounded(_ text: String, bytes: Int) -> (String, Bool) {
        let utf8 = text.utf8
        guard utf8.count > bytes else { return (text, false) }
        var cut = utf8.index(utf8.startIndex, offsetBy: bytes)
        while cut > utf8.startIndex, String.Index(cut, within: text) == nil {
            cut = utf8.index(before: cut)
        }
        let head = text[..<cut]
        let lines = head.lastIndex(of: "\n").map { head[...$0] } ?? head
        return (String(lines) + "\n… (diff cut at \(bytes / 1024) KiB; pass a path to see one file)\n", true)
    }

    // MARK: Helpers

    struct TaskEnd {
        var state: TaskState
        var message: String?
    }

    /// Reads a task to its end, handing each event to `body`.
    func read(_ handle: TaskHandle, _ body: (TaskEvent) throws -> Void) async throws -> TaskEnd {
        var end = TaskEnd(state: .running, message: nil)
        for try await event in service.events(of: handle) {
            if event.kind == TaskEvent.stateKind, let name = event.payload?["state"]?.stringValue, let state = TaskState(rawValue: name) {
                end = TaskEnd(state: state, message: event.payload?["message"]?.stringValue)
            }
            try body(event)
        }
        return end
    }

    /// Up to `limit` bytes from the descriptor's current offset.
    static func read(_ descriptor: Int32, upTo limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limit {
            let wanted = min(buffer.count, limit - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if count < 0, errno == EINTR {
                continue
            }
            if count < 0 {
                throw ApelinError(.internal, "read: \(String(cString: strerror(errno)))")
            }
            if count == 0 {
                break
            }
            data.append(contentsOf: buffer[0 ..< count])
        }
        return data
    }
}
