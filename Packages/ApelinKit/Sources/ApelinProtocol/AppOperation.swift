/// The wire between the app and apelind: a closed list of operations, every
/// one of them data, and none of them `exec(path, argv)`.
///
/// Adding an operation touches, together: a case here (and in `domain` and
/// `requestType`), its request/response types and `ApelinService` method in
/// `Operations/<Domain>.swift`, its case in apelind's
/// `Apelind/Dispatch/<Domain>Handler.swift`, and the list in `AGENTS.md` ▸
/// Decisions. `CallerPolicy` in the session host says whether a worker may
/// call it too.
public enum AppOperation: String, Codable, CaseIterable, Sendable {
    case hello

    case toolchainStatus
    case toolchainCatalog
    case toolchainSetup
    case toolchainRemove
    case toolchainSelfTest
    case toolchainSetDefault

    case sdkList
    case sdkImport
    case sdkRemove

    case environmentAttach
    case environmentCancel

    case extensionList
    case projectCreate
    case projectCheck
    case projectRename
    case projectDelete

    case buildStart
    case buildAttach
    case buildCancel

    case installPackage
    case removePackage
    case installationList
    case respring
    case approvalDigestState

    case fileRead
    case protectedEditOpen
    case protectedEditCommit

    case ptyOpen
    case ptyAttach
    case ptyResize
    case ptyClose

    case logStream
    case crashList
    case crashOpen
    case crashSymbolicate

    case confirmLoaded
    case confirmLoadedAttach
    case captureScreen
    case readUITree
    case uiAction

    case agentOpen
    case agentPrompt
    case agentSteer
    case agentAbort
    case agentCompact
    case agentApprove
    case agentAttach
    case agentList
    case agentClose
    case agentRunCode
    case agentCredentialImport
    case agentAccountList
    case agentSkillList
    case agentAPIConfiguration
    case agentModelList
    case agentModelActivate
    case agentSignIn
    case agentSignInRespond
    case agentSignInCancel
    case agentSignOut

    case toolHostOpen
    case toolHostClose
    case toolHostCall

    case gitStatus
    case gitDiff
    case gitStage
    case gitUnstage
    case gitCommit
    case gitInit
    case gitClone
    case gitCloneInto
    case gitFetch
    case gitPull
    case gitPush
    case gitSettings
    case gitAuthorSet
    case gitCredentialSet
    case gitCredentialRemove
    case gitRepositoryCreate
    case gitIssueCreate
    case gitSquash
    case gitRemoteList
    case gitRemoteSet
    case gitRemoteRemove
    case gitResetPreview
    case gitResetToRemote

    case distributionRepositoryList
    case distributionRepositoryCreate
    case distributionRepositoryLink
    case distributionRepositoryUnlink
    case distributionPublish
    case feedbackSend
    case feedbackRead
    case feedbackEdit
    case feedbackStarState
    case feedbackStar
    case transferExport
    case transferInspect
    case transferImport

    /// Which `Operations/<Domain>.swift` and `Dispatch/<Domain>Handler.swift`
    /// own the operation.
    public var domain: OperationDomain {
        switch self {
        case .hello: .hello
        case .toolchainStatus, .toolchainCatalog, .toolchainSetup, .toolchainRemove, .toolchainSelfTest, .toolchainSetDefault: .toolchain
        case .sdkList, .sdkImport, .sdkRemove: .sdk
        case .environmentAttach, .environmentCancel: .environment
        case .extensionList, .projectCreate, .projectCheck, .projectRename, .projectDelete: .project
        case .buildStart, .buildAttach, .buildCancel: .build
        case .installPackage, .removePackage, .installationList, .respring, .approvalDigestState: .install
        case .fileRead, .protectedEditOpen, .protectedEditCommit: .files
        case .ptyOpen, .ptyAttach, .ptyResize, .ptyClose: .terminal
        case .logStream, .crashList, .crashOpen, .crashSymbolicate: .logs
        case .confirmLoaded, .confirmLoadedAttach, .captureScreen, .readUITree, .uiAction: .diagnostics
        case .agentOpen, .agentPrompt, .agentSteer, .agentAbort, .agentCompact, .agentApprove, .agentAttach, .agentList,
             .agentClose, .agentRunCode, .agentCredentialImport, .agentAccountList, .agentSkillList,
             .agentAPIConfiguration, .agentModelList,
             .agentModelActivate, .agentSignIn, .agentSignInRespond, .agentSignInCancel, .agentSignOut:
            .agent
        case .toolHostOpen, .toolHostClose, .toolHostCall: .toolHost
        case .gitStatus, .gitDiff, .gitStage, .gitUnstage, .gitCommit, .gitInit, .gitClone, .gitCloneInto, .gitFetch,
             .gitPull,
             .gitPush, .gitSettings, .gitAuthorSet, .gitCredentialSet, .gitCredentialRemove, .gitRepositoryCreate,
             .gitIssueCreate, .gitSquash, .gitRemoteList, .gitRemoteSet, .gitRemoteRemove, .gitResetPreview,
             .gitResetToRemote:
            .git
        case .transferExport, .transferInspect, .transferImport: .transfer
        case .distributionRepositoryList, .distributionRepositoryCreate, .distributionRepositoryLink,
             .distributionRepositoryUnlink, .distributionPublish, .feedbackSend, .feedbackRead, .feedbackEdit,
             .feedbackStarState, .feedbackStar:
            .distribution
        }
    }

    /// The request type the payload decodes as. Its `Response` is the reply.
    public var requestType: any OperationRequest.Type {
        switch self {
        case .hello: HelloRequest.self
        case .toolchainStatus: ToolchainStatusRequest.self
        case .toolchainCatalog: ToolchainCatalogRequest.self
        case .toolchainSetup: ToolchainSetupRequest.self
        case .toolchainRemove: ToolchainRemoveRequest.self
        case .toolchainSelfTest: ToolchainSelfTestRequest.self
        case .toolchainSetDefault: ToolchainSetDefaultRequest.self
        case .sdkList: SDKListRequest.self
        case .sdkImport: SDKImportRequest.self
        case .sdkRemove: SDKRemoveRequest.self
        case .environmentAttach: EnvironmentAttachRequest.self
        case .environmentCancel: EnvironmentCancelRequest.self
        case .extensionList: ExtensionListRequest.self
        case .projectCreate: ProjectCreateRequest.self
        case .projectCheck: ProjectCheckRequest.self
        case .projectRename: ProjectRenameRequest.self
        case .projectDelete: ProjectDeleteRequest.self
        case .buildStart: BuildStartRequest.self
        case .buildAttach: BuildAttachRequest.self
        case .buildCancel: BuildCancelRequest.self
        case .installPackage: InstallPackageRequest.self
        case .removePackage: RemovePackageRequest.self
        case .installationList: InstallationListRequest.self
        case .respring: RespringRequest.self
        case .approvalDigestState: ApprovalDigestStateRequest.self
        case .fileRead: FileReadRequest.self
        case .protectedEditOpen: ProtectedEditOpenRequest.self
        case .protectedEditCommit: ProtectedEditCommitRequest.self
        case .ptyOpen: PtyOpenRequest.self
        case .ptyAttach: PtyAttachRequest.self
        case .ptyResize: PtyResizeRequest.self
        case .ptyClose: PtyCloseRequest.self
        case .logStream: LogStreamRequest.self
        case .crashList: CrashListRequest.self
        case .crashOpen: CrashOpenRequest.self
        case .crashSymbolicate: CrashSymbolicateRequest.self
        case .confirmLoaded: ConfirmLoadedRequest.self
        case .confirmLoadedAttach: ConfirmLoadedAttachRequest.self
        case .captureScreen: CaptureScreenRequest.self
        case .readUITree: ReadUITreeRequest.self
        case .uiAction: UIActionRequest.self
        case .agentOpen: AgentOpenRequest.self
        case .agentPrompt: AgentPromptRequest.self
        case .agentSteer: AgentSteerRequest.self
        case .agentAbort: AgentAbortRequest.self
        case .agentCompact: AgentCompactRequest.self
        case .agentApprove: AgentApproveRequest.self
        case .agentAttach: AgentAttachRequest.self
        case .agentList: AgentListRequest.self
        case .agentClose: AgentCloseRequest.self
        case .agentRunCode: AgentRunCodeRequest.self
        case .agentCredentialImport: AgentCredentialImportRequest.self
        case .agentAccountList: AgentAccountListRequest.self
        case .agentSkillList: AgentSkillListRequest.self
        case .agentAPIConfiguration: AgentAPIConfigurationRequest.self
        case .agentModelList: AgentModelListRequest.self
        case .agentModelActivate: AgentModelActivateRequest.self
        case .agentSignIn: AgentSignInRequest.self
        case .agentSignInRespond: AgentSignInRespondRequest.self
        case .agentSignInCancel: AgentSignInCancelRequest.self
        case .agentSignOut: AgentSignOutRequest.self
        case .toolHostOpen: ToolHostOpenRequest.self
        case .toolHostClose: ToolHostCloseRequest.self
        case .toolHostCall: ToolHostCallRequest.self
        case .gitStatus: GitStatusRequest.self
        case .gitDiff: GitDiffRequest.self
        case .gitStage: GitStageRequest.self
        case .gitUnstage: GitUnstageRequest.self
        case .gitCommit: GitCommitRequest.self
        case .gitInit: GitInitRequest.self
        case .gitClone: GitCloneRequest.self
        case .gitCloneInto: GitCloneIntoRequest.self
        case .gitFetch: GitFetchRequest.self
        case .gitPull: GitPullRequest.self
        case .gitPush: GitPushRequest.self
        case .gitSettings: GitSettingsRequest.self
        case .gitAuthorSet: GitAuthorSetRequest.self
        case .gitCredentialSet: GitCredentialSetRequest.self
        case .gitCredentialRemove: GitCredentialRemoveRequest.self
        case .gitRepositoryCreate: GitRepositoryCreateRequest.self
        case .gitIssueCreate: GitIssueCreateRequest.self
        case .gitSquash: GitSquashRequest.self
        case .gitRemoteList: GitRemoteListRequest.self
        case .gitRemoteSet: GitRemoteSetRequest.self
        case .gitRemoteRemove: GitRemoteRemoveRequest.self
        case .gitResetPreview: GitResetPreviewRequest.self
        case .gitResetToRemote: GitResetToRemoteRequest.self
        case .distributionRepositoryList: DistributionRepositoryListRequest.self
        case .distributionRepositoryCreate: DistributionRepositoryCreateRequest.self
        case .distributionRepositoryLink: DistributionRepositoryLinkRequest.self
        case .distributionRepositoryUnlink: DistributionRepositoryUnlinkRequest.self
        case .distributionPublish: DistributionPublishRequest.self
        case .feedbackSend: FeedbackSendRequest.self
        case .feedbackRead: FeedbackReadRequest.self
        case .feedbackEdit: FeedbackEditRequest.self
        case .feedbackStarState: FeedbackStarStateRequest.self
        case .feedbackStar: FeedbackStarRequest.self
        case .transferExport: TransferExportRequest.self
        case .transferInspect: TransferInspectRequest.self
        case .transferImport: TransferImportRequest.self
        }
    }
}

/// One per `Operations/<Domain>.swift` and `Apelind/Dispatch/<Domain>Handler.swift`.
public enum OperationDomain: String, Codable, CaseIterable, Sendable {
    case hello
    case toolchain
    case sdk
    case environment
    case project
    case build
    case install
    case files
    case terminal
    case logs
    case diagnostics
    case agent
    case toolHost
    case git
    case transfer
    case distribution
}

/// A request on the wire. Each operation has exactly one request type, and
/// the type names the operation, so a request cannot be sent as another.
public protocol OperationRequest: Codable, Sendable {
    associatedtype Response: Codable & Sendable
    static var operation: AppOperation { get }
}

/// The reply of an operation that answers nothing but success.
public struct Acknowledged: Codable, Sendable, Equatable {
    public init() {}
}

/// A file descriptor passed beside the JSON payload. The JSON carries the
/// index into the message's descriptor list; the integer itself means nothing
/// in another process.
public struct DescriptorSlot: Codable, Sendable, Equatable {
    public var index: Int
    public init(index: Int) {
        self.index = index
    }
}
