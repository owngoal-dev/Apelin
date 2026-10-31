import ApelinProtocol

/// Who sent a request to the session host: the app through apelind, or a
/// worker through the socketpair it was spawned with, by the role the host
/// recorded then. Nothing in a request can change which.
enum Caller: Equatable, Sendable {
    case app
    case worker(WorkerRole, instance: String?)

    var isAgent: Bool {
        if case .worker(.agent, _) = self {
            return true
        }
        return false
    }

    var isEnvironment: Bool {
        if case .worker(.environment, _) = self {
            return true
        }
        return false
    }
}

/// What each caller may ask the session host for. The app may ask for
/// everything on the wire. A worker may ask only for task-level work, and
/// never for the app's manual protected edit, a terminal, approvals or
/// anything that would let it act as the app. Beyond this list the host
/// still decides per request: an agent's build, install and removal pass
/// the Confirm-mode ledger, an agent installs build artifacts only, and a
/// protected-edit grant scope is the app's alone.
enum CallerPolicy {
    /// The agent's tools reach these; every call is still subject to the
    /// host's own approval decision.
    static let agentOperations: Set<AppOperation> = [
        // The device's toolchains and SDKs: listed, a toolchain set up from
        // Apple's catalog or tested again, an SDK imported from a source.
        // A setup or import is one AgentEnvironmentRules allows (under
        // Confirm, the user's approval of exactly it); environmentAttach
        // reads only the tasks the session started (its git tasks too).
        // Removal stays the app's.
        .toolchainStatus, .toolchainCatalog, .toolchainSetup, .toolchainSelfTest,
        .sdkList, .sdkImport, .environmentAttach,
        .extensionList,
        // A rename is its own project's, or another's only as the user
        // approved it (AgentProjectRenameRules). A deletion is never its
        // own project's, and another's under Confirm only as the user
        // approved exactly it (AgentProjectDeleteRules).
        .projectCreate, .projectCheck, .projectRename, .projectDelete,
        .buildStart, .buildAttach, .buildCancel,
        // The installations it lists are every project's, as removal takes
        // any build's; a toolchain's or a file's is listed as not its to remove.
        .installPackage, .removePackage, .installationList, .respring, .approvalDigestState,
        .fileRead,
        .logStream, .crashList, .crashOpen, .crashSymbolicate,
        .confirmLoaded, .confirmLoadedAttach, .captureScreen, .readUITree, .uiAction,
        .toolHostOpen, .toolHostClose, .toolHostCall,
        .gitStatus, .gitDiff, .gitStage, .gitUnstage, .gitCommit, .gitInit,
        .gitCloneInto, .gitFetch, .gitPull, .gitPush,
        // Its own project's commits combined into one, under Confirm only as
        // the user approved exactly it (AgentSquashRules); a preview freely.
        .gitSquash,
        // Its own project's remotes, listed, added, pointed elsewhere or
        // removed; a push that later uses one still asks, naming its URL.
        .gitRemoteList, .gitRemoteSet, .gitRemoteRemove,
        .gitSettings, .gitAuthorSet, .gitCredentialSet, .gitCredentialRemove,
        // An empty repository on GitHub with the user's sign-in, under
        // Confirm only as the user approved exactly it
        // (AgentRepositoryCreateRules).
        .gitRepositoryCreate,
        // An issue under the user's GitHub account on a repository the user
        // chose, under Confirm only as the user approved exactly it
        // (AgentIssueCreateRules).
        .gitIssueCreate,
        // A public issue on Apelin's own repository with the user's GitHub
        // sign-in, filed or, when the account opened it, edited under
        // Confirm only as the user approved exactly it (AgentFeedbackRules),
        // and read.
        .feedbackSend, .feedbackRead, .feedbackEdit,
        // Packages builds made, published to the linked package repository
        // as they were built, under Confirm only as the user approved
        // exactly them (AgentPublishRules). Creating, linking, listing and
        // unlinking the repository stay the app's.
        .distributionPublish,
        .agentRunCode,
        // The project's other conversations (AgentConversations): AgentHandler
        // keeps an agent to its own project, and to the sessions it opened
        // for abort and close. Approving, steering and compacting stay the app's.
        .agentOpen, .agentPrompt, .agentList, .agentAttach, .agentAbort, .agentClose,
    ]

    /// The diagnostics worker asks the host for a protected crash report by
    /// id, and for the respring `confirmLoaded` triggers; nothing else.
    static let diagnosticsOperations: Set<AppOperation> = [.crashOpen, .respring]

    /// The environment worker installs and removes the local toolchain
    /// package it built — through the host's own install bridge, which
    /// stages and checks the artifact like any other — and reads that task.
    static let environmentOperations: Set<AppOperation> = [
        .installPackage, .removePackage, .buildAttach,
    ]

    static func allows(_ caller: Caller, _ operation: AppOperation) -> Bool {
        switch caller {
        case .app:
            true
        case .worker(.agent, _):
            agentOperations.contains(operation)
        case .worker(.diagnostics, _):
            diagnosticsOperations.contains(operation)
        case .worker(.environment, _):
            environmentOperations.contains(operation)
        case .worker:
            // Build and log-reader workers report through
            // events and replies; they call nothing.
            false
        }
    }
}
