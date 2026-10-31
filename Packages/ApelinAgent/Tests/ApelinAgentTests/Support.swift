@testable import ApelinAgent
import struct ApelinProtocol.ApelinError
import struct ApelinProtocol.GitBranchComparison
import struct ApelinProtocol.GitCommitSummary
import struct ApelinProtocol.GitPushLease
import struct ApelinProtocol.GitSquashResponse
import Foundation

/// A throwaway home with `Documents/wiki.qaq.apelin/Projects/<name>/`.
struct TemporaryHome {
    let home: URL
    let dataRoot: ApelinDataRoot
    let project: ProjectIdentity
    let projectURL: URL

    init(projectName: String = "Hello") throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apelin-agent-tests-\(UUID().uuidString)", isDirectory: true)
        dataRoot = ApelinDataRoot(home: home)
        project = try ProjectIdentity(id: "project-\(UUID().uuidString.prefix(8))", name: ProjectName(projectName))
        projectURL = dataRoot.project(named: project.name)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    func write(_ relative: String, _ content: String) throws {
        let url = projectURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ relative: String) throws -> String {
        try String(contentsOf: projectURL.appendingPathComponent(relative), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}

/// The host's side of the digest rule: what the template says, what was
/// approved, and the recording the host does when it relays an approval.
actor MockDigestLedger: ApprovalDigestStore {
    var current: [DescriptionKind: String] = [.build: "build-template", .packaging: "packaging-template"]
    var template: [DescriptionKind: String] = [.build: "build-template", .packaging: "packaging-template"]
    var approved: Set<String> = []

    func state(of kind: DescriptionKind, for project: ProjectIdentity) -> DescriptionState {
        let digest = current[kind]!
        if digest == template[kind] {
            return DescriptionState(digest: digest, baseline: .matchesTemplate)
        }
        if approved.contains("\(project.id)/\(kind.rawValue)/\(digest)") {
            return DescriptionState(digest: digest, baseline: .approved)
        }
        return DescriptionState(digest: digest, baseline: .changed(diff: "- \(template[kind]!)\n+ \(digest)"))
    }

    func change(_ kind: DescriptionKind, to digest: String) {
        current[kind] = digest
    }

    /// A workspace's packages by artifact ID, with the packaging digest
    /// apelin-build recorded for each.
    var artifacts: [String: String] = [:]

    func addArtifact(_ artifactID: String, packaging digest: String) {
        artifacts[artifactID] = digest
    }

    func packagingState(ofArtifact artifactID: String, for project: ProjectIdentity) -> DescriptionState? {
        guard let digest = artifacts[artifactID] else { return nil }
        if approved.contains("\(project.id)/packaging/\(digest)") {
            return DescriptionState(digest: digest, baseline: .approved)
        }
        return DescriptionState(digest: digest, baseline: .changed(diff: "a package not approved before"))
    }

    /// What the host does when it relays a user's approval of a
    /// `.descriptionChanged` request.
    func record(_ request: ApprovalRequest, decision: ApprovalDecision) {
        guard case .approve = decision, case let .descriptionChanged(kind, digest, _) = request.detail else { return }
        approved.insert("\(request.projectID)/\(kind.rawValue)/\(digest)")
    }
}

/// Records every call and answers with fixed values.
actor MockBackend: AgentHostBackend {
    enum Call: Equatable {
        case runCode(RunCodeInvocation)
        case build(digest: String, evidence: ApprovalEvidence)
        case install(artifact: String, digest: String, packaging: String, evidence: ApprovalEvidence)
        case removePackage(String)
        case respring
        case confirmLoaded(build: String, target: String)
        case createProject(template: String, name: String, values: [String: TemplateValue])
        case renameProject(projectID: String, displayName: String, automatic: Bool)
        case deleteProject(projectID: String, folder: String, evidence: ApprovalEvidence)
        case gitStatus
        case gitDiff(path: String?, staged: Bool)
        case gitStage([String])
        case gitUnstage([String])
        case gitCommit(String, all: Bool = false)
        case gitInit
        case gitFetch(remote: String?)
        case gitPull(remote: String?)
        case gitPush(remote: String?, branch: String?, url: String?, evidence: ApprovalEvidence)
        case gitClone(url: String, branch: String?)
        case gitSetAuthor(name: String?, email: String?)
        case gitSaveCredential(host: String, username: String, token: String)
        case gitRemoveCredential(host: String)
        case conversationCreate(prompt: String, title: String?)
        case conversationSend(sessionID: String, text: String)
        case conversationList
        case conversationRead(sessionID: String, afterSeq: UInt64?, waitSeconds: Int)
        case conversationStop(sessionID: String, close: Bool)
        /// A conversation call that went to another project.
        case conversationElsewhere(tool: String, project: String, evidence: ApprovalEvidence)
        case toolchains
        case sdks
        case toolchainSetup(productID: String, components: [String], evidence: ApprovalEvidence)
        case toolchainSelfTest(String)
        case sdkImport(url: String, branch: String, evidence: ApprovalEvidence)
        case checkEnvironment(toolchainID: String?, sdkID: String?)
        case feedback(title: String, body: String, evidence: ApprovalEvidence)
        case feedbackRead(Int)
        case feedbackEdit(FeedbackEditToolRequest)
        case createRepository(RepositoryCreateApproval, evidence: ApprovalEvidence)
        case createIssue(IssueCreateApproval, evidence: ApprovalEvidence)
        case publishPackages(PackagePublishApproval, evidence: ApprovalEvidence)
        /// A fetch that compares a branch with the remote's, as a forced
        /// push makes before it asks.
        case gitFetchComparing(remote: String?, branch: String)
        /// A push with a lease: forced.
        case gitForcePush(remote: String?, branch: String?, url: String?, lease: GitPushLease, evidence: ApprovalEvidence)
        /// A squash's preview: what it would combine, by base or count.
        case gitSquashPreview(base: String?, count: Int?)
        case gitSquash(base: String?, expectedHead: String?, message: String?, evidence: ApprovalEvidence)
        case other(String)
    }

    /// What a fetch that compares a branch answers; nil: the remote has the
    /// branch at the local commit.
    var comparison: GitBranchComparison?

    func setComparison(_ comparison: GitBranchComparison?) {
        self.comparison = comparison
    }

    /// What a squash's preview answers: three commits after a base, none of
    /// them on the upstream unless a test says so.
    static let defaultSquashPreview = GitSquashResponse(
        branch: "main",
        previousHead: String(repeating: "d", count: 40),
        base: String(repeating: "a", count: 40),
        commits: [
            GitCommitSummary(commit: String(repeating: "d", count: 40), subject: "Fix the hand"),
            GitCommitSummary(commit: String(repeating: "c", count: 40), subject: "Draw the face"),
            GitCommitSummary(commit: String(repeating: "b", count: 40), subject: "Hook the clock"),
        ],
        count: 3,
    )

    var squashPreview = MockBackend.defaultSquashPreview

    func setSquashPreview(_ preview: GitSquashResponse) {
        squashPreview = preview
    }

    func gitSquash(_ request: GitSquashToolRequest) -> GitSquashResponse {
        guard !request.preview else {
            calls.append(.gitSquashPreview(base: request.base, count: request.count))
            return squashPreview
        }
        calls.append(.gitSquash(
            base: request.base,
            expectedHead: request.expectedHead,
            message: request.message,
            evidence: request.context.approval,
        ))
        var done = squashPreview
        done.commit = String(repeating: "e", count: 40)
        return done
    }

    /// What apelin_package_publish reads before it asks: a linked
    /// repository, a sign-in, and the builds a test records.
    var publishRepository: PackagePublication.Repository? = .init(
        fullName: "someone/packages",
        sourceURL: "https://someone.github.io/packages/",
    )
    var publishSignedIn: Bool? = true
    var buildRecords: [String: PackageBuildRecord] = [:]

    func setPublishing(repository: PackagePublication.Repository?, signedIn: Bool?) {
        publishRepository = repository
        publishSignedIn = signedIn
    }

    func record(_ build: PackageBuildRecord) {
        buildRecords[build.buildID] = build
    }

    func packagePublication(_ request: PackagePublicationRequest) -> PackagePublication {
        PackagePublication(
            repository: publishRepository,
            signedIn: publishSignedIn,
            builds: request.buildIDs.map { buildRecords[$0] },
        )
    }

    func publishPackages(_ request: PackagePublishToolRequest) -> PackagePublishToolResponse {
        calls.append(.publishPackages(request.publication, evidence: request.context.approval))
        let files = request.publication.packages.map { "\($0.packageID)_\($0.version)_\($0.architecture).deb" }
        return PackagePublishToolResponse(
            repository: request.publication.repository,
            sourceURL: request.publication.sourceURL,
            published: files,
            alreadyPublished: [],
            commit: "abc123",
            next: "Package managers see them once the repository's workflow on GitHub has indexed debs/.",
        )
    }

    /// What apelin_toolchain_list and apelin_sdk_list answer.
    var toolchainList = ToolchainListToolResponse(
        installed: [InstalledToolchain(id: "clt-16.4-c", version: "16.4", components: ["c"], newestSDK: "18.5", boundByThisProject: true)],
        available: [
            AvailableToolchain(productID: "082-27", version: "27.0", sizeBytes: 900_000_000, newestSDK: "27", unavailable: "This toolchain requires iOS 26.0 or later."),
            AvailableToolchain(productID: "082-16", version: "16.4", sizeBytes: 800_000_000, newestSDK: "18.5", installedAs: ["clt-16.4-c"]),
            AvailableToolchain(productID: "082-15", version: "15.3", sizeBytes: 700_000_000, newestSDK: "17.4", swift: "Swift 5.10"),
        ],
    )
    var sdkList = SDKListToolResponse(
        installed: [InstalledSDK(id: "iPhoneOS18.2-aaaaaaaa", version: "18.2", readBy: ["clt-16.4-c"], boundByThisProject: true)],
        available: [
            AvailableSDK(version: "17.5", branch: "sdk/iPhoneOS17.5", source: "OwnGoal iOS SDKs", sourceURL: "https://github.com/owngoal-dev/iOS-SDKs.git", readBy: ["clt-16.4-c"]),
        ],
    )
    /// What apelin_project_set_environment's check answers, by SDK id.
    var environmentFindings: [String: [EnvironmentDiagnostic]] = [:]
    /// Other projects resolve_project finds, by name or id.
    var otherProjects: [String: ProjectIdentity] = [:]

    /// What apelin_project_list answers: none, as a backend without other
    /// projects answers, unless a test lists some.
    var listedProjects = ProjectListToolResponse(projects: [], truncated: false)

    func addProject(_ identity: ProjectIdentity) {
        otherProjects[identity.id] = identity
        otherProjects[identity.name.rawValue] = identity
    }

    func setListedProjects(_ listing: ProjectListToolResponse) {
        listedProjects = listing
    }

    func setFindings(_ findings: [EnvironmentDiagnostic], forSDK sdkID: String) {
        environmentFindings[sdkID] = findings
    }

    /// What git_status answers as the checked-out branch.
    var gitBranch: String? = "main"

    func setGitBranch(_ branch: String?) {
        gitBranch = branch
    }

    var calls: [Call] = []
    var sdkRoot: String = "/nonexistent"

    func setSDKRoot(_ path: String) {
        sdkRoot = path
    }

    /// The evidence of every shell_run call, refused ones included.
    var runCodeEvidence: [ApprovalEvidence] = []
    /// Every shell_run request that ran, whole: its invocation, working
    /// directory and whether it asked for root.
    var runCodeRequests: [RunCodeRequest] = []
    /// Whether this host's preset rule refuses every preset, as the real
    /// host does for a call its own rule does not count.
    var refusesPresets = false

    func setRefusesPresets(_ refuses: Bool) {
        refusesPresets = refuses
    }

    func runCode(_ request: RunCodeRequest) throws -> RunCodeResponse {
        runCodeEvidence.append(request.context.approval)
        if refusesPresets, case .preset = request.context.approval {
            throw HostRefusedPresetError(message: "the host does not recognise this command as a preset; ask the user")
        }
        calls.append(.runCode(request.invocation))
        runCodeRequests.append(request)
        return RunCodeResponse(exitCode: 0, stdout: "ok", stderr: "")
    }

    func build(_ request: BuildRequest) -> BuildResponse {
        calls.append(.build(digest: request.buildDescriptionDigest, evidence: request.context.approval))
        return BuildResponse(
            buildID: "build-1",
            succeeded: true,
            artifacts: [BuildArtifact(id: "artifact-1", kind: .package, name: "hello.deb", digest: "deb-digest-1")],
        )
    }

    /// Whether the installer reports success.
    var installSucceeds = true

    func setInstallSucceeds(_ succeeds: Bool) {
        installSucceeds = succeeds
    }

    func install(_ request: InstallRequest) -> InstallResponse {
        calls.append(.install(artifact: request.artifactID, digest: request.artifactDigest, packaging: request.packagingDescriptionDigest, evidence: request.context.approval))
        return InstallResponse(
            transactionID: "tx-1",
            installationID: installSucceeds ? "inst-1" : nil,
            packageID: "wiki.qaq.hello",
            version: "1.0",
            succeeded: installSucceeds,
        )
    }

    /// What apelin_package_list answers, newest first, as the host would;
    /// nil for a host that cannot list them, so a removal goes by its id.
    var installedPackages: [ListedInstallation]?
    /// Whether that list was cut short.
    var installationsTruncated = false
    /// Every installation list asked for, package and project; a read, so
    /// not among `calls`.
    var installationQueries: [InstallationListToolRequest] = []
    /// What the host answers a removal with instead of removing.
    var removalRefusal: ApelinError?

    func setInstallations(_ installations: [ListedInstallation], truncated: Bool = false) {
        installedPackages = installations
        installationsTruncated = truncated
    }

    func setRemovalRefusal(_ refusal: ApelinError?) {
        removalRefusal = refusal
    }

    func removePackage(_ request: RemovePackageRequest) throws -> RemovePackageResponse {
        if let removalRefusal {
            throw removalRefusal
        }
        calls.append(.removePackage(request.installationID))
        return RemovePackageResponse(transactionID: "tx-2", succeeded: true)
    }

    func installations(_ request: InstallationListToolRequest) throws -> InstallationListToolResponse {
        installationQueries.append(request)
        guard let installedPackages else { throw ToolDeniedError(message: "installed packages are not available here") }
        let listed = installedPackages.filter {
            (request.packageID == nil || $0.packageID == request.packageID)
                && (request.projectID == nil || $0.projectID == request.projectID)
        }
        return InstallationListToolResponse(installations: listed, truncated: installationsTruncated)
    }

    func respring(_: RespringRequest) -> RespringResponse {
        calls.append(.respring)
        return RespringResponse(succeeded: true)
    }

    func confirmLoaded(_ request: ConfirmLoadedRequest) -> ConfirmLoadedResponse {
        calls.append(.confirmLoaded(build: request.buildID, target: request.target))
        return ConfirmLoadedResponse(loaded: true, markerLogged: true, filterMatches: true, logEvidence: ["Hello loaded build-1"])
    }

    func readLogs(_: ReadLogsRequest) -> ReadLogsResponse {
        calls.append(.other("readLogs"))
        return ReadLogsResponse(entries: [])
    }

    func listCrashes(_: ListCrashesRequest) -> ListCrashesResponse {
        calls.append(.other("listCrashes"))
        return ListCrashesResponse(reports: [])
    }

    func readCrash(_ request: ReadCrashRequest) -> ReadCrashResponse {
        calls.append(.other("readCrash"))
        return ReadCrashResponse(reportID: request.reportID, text: "")
    }

    func symbolicateCrash(_ request: SymbolicateCrashRequest) -> SymbolicateCrashResponse {
        calls.append(.other("symbolicateCrash"))
        return SymbolicateCrashResponse(reportID: request.reportID, matchedImageUUID: nil, crashedThread: [])
    }

    func captureScreen(_: CaptureScreenRequest) -> CaptureScreenResponse {
        calls.append(.other("captureScreen"))
        return CaptureScreenResponse(attachmentID: "att-1", mimeType: "image/png", width: 1, height: 1, imageData: Data([0x89, 0x50]))
    }

    func readUITree(_: ReadUITreeRequest) -> ReadUITreeResponse {
        calls.append(.other("readUITree"))
        return ReadUITreeResponse(root: UIElementNode(id: "root", role: "application"))
    }

    func uiAction(_: UIActionRequest) -> UIActionResponse {
        calls.append(.other("uiAction"))
        return UIActionResponse(performed: true)
    }

    func registeredSDK(_: RegisteredSDKRequest) -> RegisteredSDKResponse {
        RegisteredSDKResponse(sdkID: "iPhoneOS16.5", rootPath: sdkRoot, platform: "iphoneos", version: "16.5")
    }

    func checkDistribution(_: DistributionCheckRequest) -> DistributionCheckResponse {
        DistributionCheckResponse(ready: true)
    }

    func projectTemplates() -> ProjectTemplateListResponse {
        ProjectTemplateListResponse(templates: [
            ProjectTemplate(id: "wiki.qaq.apelin.dev.tweak/tweak", name: "Tweak", kind: "tweak", parameters: [
                ProjectTemplate.Parameter(name: "filter", kind: "string", defaultValue: .string("com.apple.springboard")),
            ]),
        ])
    }

    func createProject(_ request: ProjectCreateToolRequest) -> ProjectCreateToolResponse {
        calls.append(.createProject(template: request.templateID, name: request.name, values: request.values))
        return ProjectCreateToolResponse(projectID: "project-1", name: request.name)
    }

    func gitStatus(_: GitStatusToolRequest) -> GitStatusToolResponse {
        calls.append(.gitStatus)
        return GitStatusToolResponse(branch: gitBranch, head: "abc123", entries: [])
    }

    func gitDiff(_ request: GitDiffToolRequest) -> GitDiffToolResponse {
        calls.append(.gitDiff(path: request.path, staged: request.staged))
        return GitDiffToolResponse(diff: "")
    }

    func gitStage(_ request: GitPathsToolRequest) -> GitPathsToolResponse {
        calls.append(.gitStage(request.paths))
        return GitPathsToolResponse(paths: request.paths)
    }

    func gitUnstage(_ request: GitPathsToolRequest) -> GitPathsToolResponse {
        calls.append(.gitUnstage(request.paths))
        return GitPathsToolResponse(paths: request.paths)
    }

    func gitCommit(_ request: GitCommitToolRequest) -> GitCommitToolResponse {
        calls.append(.gitCommit(request.message, all: request.all))
        return GitCommitToolResponse(commitID: "def456")
    }

    func gitInit(_: GitInitToolRequest) -> GitInitToolResponse {
        calls.append(.gitInit)
        return GitInitToolResponse(branch: "main")
    }

    func gitFetch(_ request: GitRemoteToolRequest) -> GitTaskToolResponse {
        guard let branch = request.branch else {
            calls.append(.gitFetch(remote: request.remote))
            return GitTaskToolResponse(remote: request.remote ?? "origin", updated: [])
        }
        calls.append(.gitFetchComparing(remote: request.remote, branch: branch))
        let same = GitBranchComparison(branch: branch, local: "abc123", localSubject: "Mine", remote: "abc123")
        return GitTaskToolResponse(remote: request.remote ?? "origin", updated: [], comparison: comparison ?? same)
    }

    func gitPull(_ request: GitRemoteToolRequest) -> GitTaskToolResponse {
        calls.append(.gitPull(remote: request.remote))
        return GitTaskToolResponse(branch: gitBranch, upToDate: true)
    }

    func gitPush(_ request: GitRemoteToolRequest) -> GitTaskToolResponse {
        if let lease = request.lease {
            calls.append(.gitForcePush(
                remote: request.remote,
                branch: request.branch,
                url: request.url,
                lease: lease,
                evidence: request.context.approval,
            ))
            return GitTaskToolResponse(
                remote: request.remote ?? "origin",
                branch: request.branch,
                commit: lease.localCommit,
                from: lease.expectedCommit,
                forced: true,
            )
        }
        calls.append(.gitPush(
            remote: request.remote,
            branch: request.branch,
            url: request.url,
            evidence: request.context.approval,
        ))
        return GitTaskToolResponse(remote: request.remote ?? "origin", branch: request.branch, commit: "abc123")
    }

    func gitClone(_ request: GitCloneToolRequest) -> GitTaskToolResponse {
        calls.append(.gitClone(url: request.url, branch: request.branch))
        return GitTaskToolResponse(branch: request.branch ?? "main", commit: "abc123")
    }

    func gitSettings(context _: HostCallContext) -> GitSettingsToolResponse {
        calls.append(.other("gitSettings"))
        return GitSettingsToolResponse(credentials: [.init(host: "github.com", username: "octocat")])
    }

    func gitSetAuthor(_ request: GitAuthorToolRequest) -> GitSettingsToolResponse {
        calls.append(.gitSetAuthor(name: request.name, email: request.email))
        return GitSettingsToolResponse(authorName: request.name, authorEmail: request.email)
    }

    func gitSaveCredential(_ request: GitCredentialToolRequest) -> GitSettingsToolResponse {
        calls.append(.gitSaveCredential(host: request.host, username: request.username, token: request.token))
        return GitSettingsToolResponse(credentials: [.init(host: request.host, username: request.username)])
    }

    func gitRemoveCredential(_ request: GitCredentialRemoveToolRequest) -> GitSettingsToolResponse {
        calls.append(.gitRemoveCredential(host: request.host))
        return GitSettingsToolResponse()
    }

    func createIssue(_ request: IssueCreateToolRequest) -> IssueCreateToolResponse {
        let issue = IssueCreateApproval(repository: request.repository, title: request.title, body: request.body)
        calls.append(.createIssue(issue, evidence: request.context.approval))
        return IssueCreateToolResponse(repository: request.repository, issue: 7, url: "https://github.com/\(request.repository)/issues/7")
    }

    func createRepository(_ request: RepositoryCreateToolRequest) -> RepositoryCreateToolResponse {
        let repository = RepositoryCreateApproval(
            owner: request.owner,
            name: request.name,
            visibility: request.visibility,
            description: request.description,
        )
        calls.append(.createRepository(repository, evidence: request.context.approval))
        let fullName = (request.owner ?? "someone") + "/" + request.name
        return RepositoryCreateToolResponse(
            fullName: fullName,
            cloneURL: "https://github.com/\(fullName).git",
            url: "https://github.com/\(fullName)",
            next: "git_push with url https://github.com/\(fullName).git",
        )
    }

    func conversationCreate(_ request: ConversationCreateToolRequest) -> ConversationCreateToolResponse {
        if let target = request.target {
            calls.append(.conversationElsewhere(tool: "apelin_conversation_create", project: target.id, evidence: request.context.approval))
        } else {
            calls.append(.conversationCreate(prompt: request.prompt, title: request.title))
        }
        return ConversationCreateToolResponse(sessionID: "child-session", taskID: "child-task", project: request.target)
    }

    func conversationSend(_ request: ConversationSendToolRequest) -> ConversationActionToolResponse {
        if let target = request.target {
            calls.append(.conversationElsewhere(tool: "apelin_conversation_send", project: target.id, evidence: request.context.approval))
        } else {
            calls.append(.conversationSend(sessionID: request.sessionID, text: request.text))
        }
        return ConversationActionToolResponse(sessionID: request.sessionID, done: "sent")
    }

    func conversationList(_ request: ConversationListToolRequest) -> ConversationListToolResponse {
        if let target = request.target {
            calls.append(.conversationElsewhere(tool: "apelin_conversation_list", project: target.id, evidence: request.context.approval))
        } else {
            calls.append(.conversationList)
        }
        return ConversationListToolResponse(conversations: [])
    }

    func conversationRead(_ request: ConversationReadToolRequest) -> ConversationReadToolResponse {
        if let target = request.target {
            calls.append(.conversationElsewhere(tool: "apelin_conversation_read", project: target.id, evidence: request.context.approval))
        } else {
            calls.append(.conversationRead(sessionID: request.sessionID, afterSeq: request.afterSeq, waitSeconds: request.waitSeconds))
        }
        return ConversationReadToolResponse(sessionID: request.sessionID, state: .idle, lastSeq: 0)
    }

    func resolveProject(_ reference: String) throws -> ProjectIdentity {
        guard let found = otherProjects[reference] else { throw ToolDeniedError(message: "no project \(reference)") }
        return found
    }

    func projects() -> ProjectListToolResponse {
        listedProjects
    }

    func renameProject(_ request: ProjectRenameToolRequest) -> ProjectRenameToolResponse {
        calls.append(.renameProject(projectID: request.projectID, displayName: request.displayName, automatic: request.automatic))
        return ProjectRenameToolResponse(projectID: request.projectID, folder: request.folder, displayName: request.displayName, changed: true)
    }

    func deleteProject(_ request: ProjectDeleteToolRequest) -> ProjectDeleteToolResponse {
        calls.append(.deleteProject(projectID: request.projectID, folder: request.folder, evidence: request.context.approval))
        return ProjectDeleteToolResponse(projectID: request.projectID, folder: request.folder)
    }

    func toolchains(context _: HostCallContext) -> ToolchainListToolResponse {
        calls.append(.toolchains)
        return toolchainList
    }

    func sdks(context _: HostCallContext) -> SDKListToolResponse {
        calls.append(.sdks)
        return sdkList
    }

    func toolchainSetup(_ request: ToolchainSetupToolRequest) -> ToolchainTaskToolResponse {
        calls.append(.toolchainSetup(productID: request.productID, components: request.components, evidence: request.context.approval))
        return ToolchainTaskToolResponse(succeeded: true, stages: ["downloading", "ready"])
    }

    func toolchainSelfTest(_ request: ToolchainSelfTestToolRequest) -> ToolchainTaskToolResponse {
        calls.append(.toolchainSelfTest(request.toolchainID))
        return ToolchainTaskToolResponse(succeeded: true, stages: ["validating"])
    }

    func sdkImport(_ request: SDKImportToolRequest) -> SDKImportToolResponse {
        calls.append(.sdkImport(url: request.url, branch: request.branch, evidence: request.context.approval))
        return SDKImportToolResponse(succeeded: true)
    }

    /// The registry's digest of each id is `sha256:<id>`.
    func sendFeedback(_ request: FeedbackToolRequest) -> FeedbackToolResponse {
        calls.append(.feedback(title: request.title, body: request.body, evidence: request.context.approval))
        return FeedbackToolResponse(repository: "owngoal-dev/Apelin", issue: 7, url: "https://github.com/owngoal-dev/Apelin/issues/7")
    }

    /// What apelin_feedback_read answers, by number: #12, the user's own,
    /// unless a test sets others.
    var feedbackIssues: [Int: FeedbackReadToolResponse] = [12: FeedbackReadToolResponse(
        repository: "owngoal-dev/Apelin",
        issue: 12,
        url: "https://github.com/owngoal-dev/Apelin/issues/12",
        title: "The build log stops early",
        state: "open",
        author: "someone",
        openedByUser: true,
        body: "It ends before the link step.",
        footer: "Sent with Apelin 0.2.7 (18) · iOS 17.3.1 · rootless",
    )]

    func setFeedbackIssue(_ issue: FeedbackReadToolResponse) {
        feedbackIssues[issue.issue] = issue
    }

    func readFeedback(_ request: FeedbackReadToolRequest) throws -> FeedbackReadToolResponse {
        calls.append(.feedbackRead(request.number))
        guard let issue = feedbackIssues[request.number] else {
            throw ToolDeniedError(message: "owngoal-dev/Apelin has no issue #\(request.number)")
        }
        return issue
    }

    /// Applied to the issue, as GitHub would, so a read after it sees it.
    func editFeedback(_ request: FeedbackEditToolRequest) -> FeedbackEditToolResponse {
        calls.append(.feedbackEdit(request))
        if let issue = feedbackIssues[request.number] {
            feedbackIssues[request.number] = FeedbackReadToolResponse(
                repository: issue.repository,
                issue: issue.issue,
                url: issue.url,
                title: request.title ?? issue.title,
                state: issue.state,
                author: issue.author,
                openedByUser: issue.openedByUser,
                body: request.body ?? issue.body,
                footer: issue.footer,
            )
        }
        let changed: [String] = [request.title.map { _ in "title" }, request.body.map { _ in "body" }].compactMap(\.self)
        return FeedbackEditToolResponse(
            repository: "owngoal-dev/Apelin",
            issue: request.number,
            url: "https://github.com/owngoal-dev/Apelin/issues/\(request.number)",
            changed: changed,
            title: request.title ?? request.expectedTitle,
            body: request.body ?? request.expectedBody,
        )
    }

    func checkEnvironment(_ request: EnvironmentCheckToolRequest) -> EnvironmentCheckToolResponse {
        calls.append(.checkEnvironment(toolchainID: request.toolchainID, sdkID: request.sdkID))
        let toolchain = request.toolchainID ?? "clt-16.4-c"
        let sdk = request.sdkID ?? "iPhoneOS18.2-aaaaaaaa"
        return EnvironmentCheckToolResponse(
            toolchain: ComponentBinding(id: toolchain, digest: "sha256:" + toolchain),
            sdk: ComponentBinding(id: sdk, digest: "sha256:" + sdk),
            diagnostics: environmentFindings[sdk] ?? [],
        )
    }

    func conversationStop(_ request: ConversationStopToolRequest) -> ConversationActionToolResponse {
        calls.append(.conversationStop(sessionID: request.sessionID, close: request.close))
        return ConversationActionToolResponse(sessionID: request.sessionID, done: request.close ? "closed" : "stopped")
    }

    // MARK: Agent tool extensions

    /// The extension of each tool session the host opened, in order; the
    /// session's ID is `tool-session-<n>`.
    var toolSessionsOpened: [String] = []
    var toolSessionsClosed: [String] = []
    /// Every call made, in a session the host had or not.
    var toolCalls: [ToolExtensionCallRequest] = []
    /// Sessions the host let go when their extension exited.
    var toolSessionsEnded: Set<String> = []
    /// What a call in a session the host has answers.
    var toolAnswer: @Sendable (ToolExtensionCallRequest) -> ToolExtensionCallResponse = { request in
        ToolExtensionCallResponse(text: "\(request.tool) ran")
    }

    func setToolAnswer(_ answer: @escaping @Sendable (ToolExtensionCallRequest) -> ToolExtensionCallResponse) {
        toolAnswer = answer
    }

    /// The extension of `sessionID` exits, and the host lets the session go.
    func endToolSession(_ sessionID: String) {
        toolSessionsEnded.insert(sessionID)
    }

    func openToolExtension(id: String) -> String {
        toolSessionsOpened.append(id)
        return "tool-session-\(toolSessionsOpened.count)"
    }

    func callToolExtension(_ request: ToolExtensionCallRequest) throws -> ToolExtensionCallResponse {
        toolCalls.append(request)
        guard !toolSessionsEnded.contains(request.sessionID) else {
            throw ApelinError(.notFound, "no tool session \(request.sessionID)")
        }
        return toolAnswer(request)
    }

    func closeToolExtension(sessionID: String) {
        toolSessionsClosed.append(sessionID)
    }
}

/// Collects session events in order.
actor EventCollector {
    var events: [AgentSessionEvent] = []
    func add(_ event: AgentSessionEvent) {
        events.append(event)
    }
}
