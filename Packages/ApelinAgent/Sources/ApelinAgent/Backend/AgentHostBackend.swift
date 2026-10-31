import Foundation

/// Everything the agent asks of the session host.
///
/// `apelin-agent` runs as mobile and holds no privilege of its own: every
/// system capability in §7's table is one method here, with a typed request
/// and a typed response, carried to `apelind-session` over the inherited
/// internal channel. Nothing here is `exec(path, argv)` — `runCode` carries a
/// classified invocation the host re-checks, not a command line it trusts.
///
/// The host decides independently (§2, §7): every request carries a
/// `HostCallContext` naming the session, project, tool call and the evidence
/// the agent's own approval gate acted on, so the host can refuse a forged
/// approval instead of believing it.
public protocol AgentHostBackend: Sendable {
    /// Run a command or script inside the project, as mobile.
    func runCode(_ request: RunCodeRequest) async throws -> RunCodeResponse
    /// Build the project with the registered toolchain and SDK.
    func build(_ request: BuildRequest) async throws -> BuildResponse
    /// Package and install a built artifact through Irisin's daemon.
    func install(_ request: InstallRequest) async throws -> InstallResponse
    /// Remove a managed project package by its installation record.
    func removePackage(_ request: RemovePackageRequest) async throws -> RemovePackageResponse
    /// The packages Apelin installed that are still on the device, every
    /// project's, each with the installation a removal acts on.
    func installations(_ request: InstallationListToolRequest) async throws -> InstallationListToolResponse
    /// Restart SpringBoard.
    func respring(_ request: RespringRequest) async throws -> RespringResponse
    /// Check a build is loaded in its target: marker log, loaded images,
    /// filter.
    func confirmLoaded(_ request: ConfirmLoadedRequest) async throws -> ConfirmLoadedResponse
    /// Bounded system log read, filtered to the project.
    func readLogs(_ request: ReadLogsRequest) async throws -> ReadLogsResponse
    /// Crash report ids the host can open.
    func listCrashes(_ request: ListCrashesRequest) async throws -> ListCrashesResponse
    /// One crash report's text.
    func readCrash(_ request: ReadCrashRequest) async throws -> ReadCrashResponse
    /// Symbolicate a report against the project's matching dSYM.
    func symbolicateCrash(_ request: SymbolicateCrashRequest) async throws -> SymbolicateCrashResponse
    /// Screenshot of the target, returned as a bounded attachment.
    func captureScreen(_ request: CaptureScreenRequest) async throws -> CaptureScreenResponse
    /// The target's accessibility/UI tree.
    func readUITree(_ request: ReadUITreeRequest) async throws -> ReadUITreeResponse
    /// One structured UI action on the target.
    func uiAction(_ request: UIActionRequest) async throws -> UIActionResponse
    /// Where a registered SDK lives, for `apelin_sdk_analyze_framework` and
    /// `apelin_sdk_read_header` to read as mobile.
    func registeredSDK(_ request: RegisteredSDKRequest) async throws -> RegisteredSDKResponse
    /// What a package for other people should not carry yet: warnings,
    /// never a refusal.
    func checkDistribution(_ request: DistributionCheckRequest) async throws -> DistributionCheckResponse
    /// The templates a new project can start from, for General Chat.
    func projectTemplates() async throws -> ProjectTemplateListResponse
    /// A new project in `Projects/` from one of those templates.
    func createProject(_ request: ProjectCreateToolRequest) async throws -> ProjectCreateToolResponse
    /// The session's project's branch, HEAD and changed paths.
    func gitStatus(_ request: GitStatusToolRequest) async throws -> GitStatusToolResponse
    /// A unified diff of the worktree, or of the index against HEAD.
    func gitDiff(_ request: GitDiffToolRequest) async throws -> GitDiffToolResponse
    func gitStage(_ request: GitPathsToolRequest) async throws -> GitPathsToolResponse
    func gitUnstage(_ request: GitPathsToolRequest) async throws -> GitPathsToolResponse
    /// A local commit; the author is the host's setting, never the agent's.
    func gitCommit(_ request: GitCommitToolRequest) async throws -> GitCommitToolResponse
    /// A repository on main for a project that has none.
    func gitInit(_ request: GitInitToolRequest) async throws -> GitInitToolResponse
    /// The remote's branches into remote-tracking refs, read to the end.
    func gitFetch(_ request: GitRemoteToolRequest) async throws -> GitTaskToolResponse
    /// Fetch, then fast-forward only, read to the end.
    func gitPull(_ request: GitRemoteToolRequest) async throws -> GitTaskToolResponse
    /// Push a branch, read to the end: never forced without the lease the
    /// user approved.
    func gitPush(_ request: GitRemoteToolRequest) async throws -> GitTaskToolResponse
    /// Import a repository into the session's own (empty) workspace.
    func gitClone(_ request: GitCloneToolRequest) async throws -> GitTaskToolResponse
    /// The device's commit author and the hosts with a saved credential.
    func gitSettings(context: HostCallContext) async throws -> GitSettingsToolResponse
    func gitSetAuthor(_ request: GitAuthorToolRequest) async throws -> GitSettingsToolResponse
    /// Saves a host's credential; the answer never carries the token.
    func gitSaveCredential(_ request: GitCredentialToolRequest) async throws -> GitSettingsToolResponse
    func gitRemoveCredential(_ request: GitCredentialRemoveToolRequest) async throws -> GitSettingsToolResponse
    /// An empty repository on GitHub with the user's sign-in; the host
    /// checks it was approved.
    func createRepository(_ request: RepositoryCreateToolRequest) async throws -> RepositoryCreateToolResponse
    /// An issue on a GitHub repository the user chose, with the user's
    /// sign-in; the host checks it was approved.
    func createIssue(_ request: IssueCreateToolRequest) async throws -> IssueCreateToolResponse
    /// Another conversation in the session's project, opened with a first
    /// message; answers without waiting for it.
    func conversationCreate(_ request: ConversationCreateToolRequest) async throws -> ConversationCreateToolResponse
    /// A message to another conversation of the project, as the user's.
    func conversationSend(_ request: ConversationSendToolRequest) async throws -> ConversationActionToolResponse
    /// The conversations of the session's project, or of the target.
    func conversationList(_ request: ConversationListToolRequest) async throws -> ConversationListToolResponse
    /// What a conversation of the project answered after a point, waiting
    /// for its turn to end when asked to.
    func conversationRead(_ request: ConversationReadToolRequest) async throws -> ConversationReadToolResponse
    /// Aborts, and optionally closes, a conversation this session opened.
    func conversationStop(_ request: ConversationStopToolRequest) async throws -> ConversationActionToolResponse
    /// A project under `Projects/` by its projectID or folder name, for a
    /// conversation call that names another project; the host resolves it
    /// again and decides.
    func resolveProject(_ reference: String) async throws -> ProjectIdentity
    /// The projects under `Projects/`, as `resolveProject` reads them.
    func projects() async throws -> ProjectListToolResponse
    /// A project's displayName, by `projectRename`; the host checks the
    /// session may rename it.
    func renameProject(_ request: ProjectRenameToolRequest) async throws -> ProjectRenameToolResponse
    /// Another project deleted for good, by `projectDelete`; the host
    /// checks the session may delete it and closes its conversations first.
    func deleteProject(_ request: ProjectDeleteToolRequest) async throws -> ProjectDeleteToolResponse
    /// The device's toolchains, and the releases Apple's catalog offers.
    func toolchains(context: HostCallContext) async throws -> ToolchainListToolResponse
    /// The device's SDKs, and the ones the enabled sources offer.
    func sdks(context: HostCallContext) async throws -> SDKListToolResponse
    /// A toolchain set up from Apple's catalog, read to its end.
    func toolchainSetup(_ request: ToolchainSetupToolRequest) async throws -> ToolchainTaskToolResponse
    /// A registered toolchain's self-test run again, read to its end.
    func toolchainSelfTest(_ request: ToolchainSelfTestToolRequest) async throws -> ToolchainTaskToolResponse
    /// An SDK imported from an enabled source, read to its end.
    func sdkImport(_ request: SDKImportToolRequest) async throws -> SDKImportToolResponse
    /// The session's project checked as if bound to these components:
    /// the binding with the registry's digests and its findings.
    func checkEnvironment(_ request: EnvironmentCheckToolRequest) async throws -> EnvironmentCheckToolResponse
    /// A public issue on Apelin's own repository with the user's GitHub
    /// sign-in; the host checks it was approved.
    func sendFeedback(_ request: FeedbackToolRequest) async throws -> FeedbackToolResponse
    /// An issue on Apelin's own repository, read with the user's GitHub
    /// sign-in.
    func readFeedback(_ request: FeedbackReadToolRequest) async throws -> FeedbackReadToolResponse
    /// An issue the user's GitHub account opened there, edited only while it
    /// still says what the edit was made against; the host checks it was
    /// approved.
    func editFeedback(_ request: FeedbackEditToolRequest) async throws -> FeedbackEditToolResponse
    /// An installed agent tool extension, started by the host as mobile
    /// after its own check of the manifest: the tool session its calls name.
    func openToolExtension(id: String) async throws -> String
    /// One call in that session; `notFound` once the extension has exited.
    func callToolExtension(_ request: ToolExtensionCallRequest) async throws -> ToolExtensionCallResponse
    func closeToolExtension(sessionID: String) async throws
    /// The linked package repository, the GitHub sign-in and each build's
    /// package record, read before apelin_package_publish asks.
    func packagePublication(_ request: PackagePublicationRequest) async throws -> PackagePublication
    /// Builds' packages published to the linked package repository as they
    /// were built, read to the end; the host checks they were approved.
    func publishPackages(_ request: PackagePublishToolRequest) async throws -> PackagePublishToolResponse
}

/// A backend without the device's toolchains, SDKs, installations or other
/// projects (a test double, a live test): those tools say so.
public extension AgentHostBackend {
    func installations(_: InstallationListToolRequest) async throws -> InstallationListToolResponse {
        throw ToolDeniedError(message: "installed packages are not available here")
    }

    func resolveProject(_ reference: String) async throws -> ProjectIdentity {
        throw ToolDeniedError(message: "no project \(reference) is reachable here")
    }

    func projects() async throws -> ProjectListToolResponse {
        ProjectListToolResponse(projects: [], truncated: false)
    }

    func renameProject(_: ProjectRenameToolRequest) async throws -> ProjectRenameToolResponse {
        throw ToolDeniedError(message: "renaming projects is not available here")
    }

    func deleteProject(_: ProjectDeleteToolRequest) async throws -> ProjectDeleteToolResponse {
        throw ToolDeniedError(message: "deleting projects is not available here")
    }

    func toolchains(context _: HostCallContext) async throws -> ToolchainListToolResponse {
        throw ToolDeniedError(message: "toolchains are not available here")
    }

    func sdks(context _: HostCallContext) async throws -> SDKListToolResponse {
        throw ToolDeniedError(message: "SDKs are not available here")
    }

    func toolchainSetup(_: ToolchainSetupToolRequest) async throws -> ToolchainTaskToolResponse {
        throw ToolDeniedError(message: "toolchain setup is not available here")
    }

    func toolchainSelfTest(_: ToolchainSelfTestToolRequest) async throws -> ToolchainTaskToolResponse {
        throw ToolDeniedError(message: "toolchain self-tests are not available here")
    }

    func sdkImport(_: SDKImportToolRequest) async throws -> SDKImportToolResponse {
        throw ToolDeniedError(message: "SDK import is not available here")
    }

    func checkEnvironment(_: EnvironmentCheckToolRequest) async throws -> EnvironmentCheckToolResponse {
        throw ToolDeniedError(message: "project checks are not available here")
    }

    func sendFeedback(_: FeedbackToolRequest) async throws -> FeedbackToolResponse {
        throw ToolDeniedError(message: "sending feedback is not available here")
    }

    func readFeedback(_: FeedbackReadToolRequest) async throws -> FeedbackReadToolResponse {
        throw ToolDeniedError(message: "reading feedback is not available here")
    }

    func editFeedback(_: FeedbackEditToolRequest) async throws -> FeedbackEditToolResponse {
        throw ToolDeniedError(message: "editing feedback is not available here")
    }

    func createRepository(_: RepositoryCreateToolRequest) async throws -> RepositoryCreateToolResponse {
        throw ToolDeniedError(message: "creating repositories is not available here")
    }

    func createIssue(_: IssueCreateToolRequest) async throws -> IssueCreateToolResponse {
        throw ToolDeniedError(message: "opening issues is not available here")
    }

    func openToolExtension(id _: String) async throws -> String {
        throw ToolDeniedError(message: "agent tool extensions are not available here")
    }

    func callToolExtension(_: ToolExtensionCallRequest) async throws -> ToolExtensionCallResponse {
        throw ToolDeniedError(message: "agent tool extensions are not available here")
    }

    func closeToolExtension(sessionID _: String) async throws {}

    func packagePublication(_: PackagePublicationRequest) async throws -> PackagePublication {
        throw ToolDeniedError(message: "publishing packages is not available here")
    }

    func publishPackages(_: PackagePublishToolRequest) async throws -> PackagePublishToolResponse {
        throw ToolDeniedError(message: "publishing packages is not available here")
    }
}

// MARK: - Context

/// Identifies a call to the host. The host matches `sessionID` to the
/// process it spawned and ignores any role the agent claims.
public struct HostCallContext: Sendable, Hashable, Codable {
    public var sessionID: String
    public var project: ProjectIdentity
    public var toolCallID: String
    /// What the agent's gate acted on. Evidence, not authority.
    public var approval: ApprovalEvidence

    public init(sessionID: String, project: ProjectIdentity, toolCallID: String, approval: ApprovalEvidence) {
        self.sessionID = sessionID
        self.project = project
        self.toolCallID = toolCallID
        self.approval = approval
    }
}

/// Why the agent's gate let a call through.
public enum ApprovalEvidence: Sendable, Hashable, Codable {
    /// The session is in Relaxed or Full mode; the host decides from its
    /// own record of the mode.
    case relaxed
    /// A user-editable preset matched; the name is the preset's.
    case preset(String)
    /// The build or packaging description matches its template.
    case templateMatch(digest: String)
    /// The description's digest was approved before; the host's ledger says so.
    case digestApproved(digest: String)
    /// The user approved this request.
    case user(requestID: String, fingerprint: String)
    /// The call needs no approval (read-only within the project).
    case notRequired

    /// The `requestID` of `.user` for a call identical to one the user
    /// approved "for this session": the host accepts it only for a command
    /// and working directory it recorded a session grant for.
    public static let sessionRequestID = "session"
}
