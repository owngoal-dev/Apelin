import enum ApelinProtocol.GitRepositoryVisibility
import Foundation

/// The approval modes (§7).
public enum ApprovalMode: String, Sendable, Hashable, Codable {
    /// Everything runs, except shell_run as root, which asks every time.
    case relaxed
    /// Project edits run; preset reads and commands run; build and install
    /// run while their descriptions match the template or an approved
    /// digest; everything else asks, every time.
    case confirm
    /// Everything runs, shell_run as root too.
    case full
}

/// A request for the user's decision. The session is suspended on it until
/// `AgentSession.approve` answers or the run is aborted.
public struct ApprovalRequest: Sendable, Hashable, Codable {
    public var id: String
    public var toolCallID: String
    public var tool: String
    /// The arguments as canonical JSON text.
    public var arguments: String
    /// Relative to the project root.
    public var workingDirectory: String
    public var projectID: String
    /// Binds the decision to tool, arguments, working directory, project
    /// and (for build/install) the description digest. Changing any of them
    /// is a different request.
    public var fingerprint: String
    /// Why the gate asked, in a sentence.
    public var reason: String
    public var detail: ApprovalDetail
    /// Whether "for this session" may be offered. Never for package removal,
    /// a push, a repository made on GitHub or an issue opened on one, an
    /// issue filed or edited as feedback, a project's deletion, packages
    /// published to the package repository, or a request bound to a
    /// description digest (the host's ledger keeps those).
    public var allowsSessionScope: Bool

    public init(
        id: String,
        toolCallID: String,
        tool: String,
        arguments: String,
        workingDirectory: String,
        projectID: String,
        fingerprint: String,
        reason: String,
        detail: ApprovalDetail,
        allowsSessionScope: Bool,
    ) {
        self.id = id
        self.toolCallID = toolCallID
        self.tool = tool
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.projectID = projectID
        self.fingerprint = fingerprint
        self.reason = reason
        self.detail = detail
        self.allowsSessionScope = allowsSessionScope
    }
}

/// What the approval card shows besides the tool and its arguments.
public enum ApprovalDetail: Sendable, Hashable, Codable {
    case none
    /// A build or packaging description that differs from its baseline: the
    /// digest the approval binds to, and the diff against the template or
    /// the last approved version.
    case descriptionChanged(kind: DescriptionKind, digest: String, diff: String)
    /// A command the presets did not cover, as classified.
    case command(RunCodeInvocation)
    /// A command that runs as root: asked in Strict and Relaxed alike,
    /// never granted for the session, and approved in the app only with
    /// the device owner checked. The host binds the approval to it.
    case rootCommand(RunCodeInvocation)
    /// A managed package removal.
    case packageRemoval(installationID: String)
    /// A push: the remote and the local branch it sends, resolved before
    /// asking (nil only when no branch is checked out).
    case gitPush(remote: String, branch: String?)
    /// A forced push: the remote's branch it overwrites, the commit there
    /// it replaces and the one it sends, and the commits that leave the
    /// branch. Asked in every mode, never granted for the session; the host
    /// lets through only the push it names, with that lease, once.
    case forcePush(ForcePushApproval)
    /// A squash of the project's own commits: the branch, each commit it
    /// combines and the new message. Never granted for the session; the
    /// host lets through only the squash it names, once.
    case squash(SquashApproval)
    /// A change to the device's git settings: the author, or the credential
    /// saved for a host (never its token).
    case gitSettings(summary: String)
    /// A toolchain set up from Apple's catalog: what is downloaded and
    /// installed. The host lets through only the setup it names.
    case toolchainSetup(ToolchainSetupApproval)
    /// An SDK imported from an enabled source: the repository and branch.
    /// The host lets through only the import it names.
    case sdkImport(SDKImportApproval)
    /// A conversation call that reaches another project than the session's.
    case otherProject(OtherProjectApproval)
    /// A build of a workspace, which runs its own script. The host lets
    /// through only the build it names, once.
    case externalBuild(ExternalBuildApproval)
    /// A skill saved to or removed from the skills folder, which every later
    /// conversation lists: the whole text a save writes.
    case skillChange(SkillChangeApproval)
    /// A rename of another project than the session's. The host lets
    /// through only the rename it names, once.
    case projectRename(ProjectRenameApproval)
    /// A public issue on Apelin's own repository: the whole title and body.
    /// The host lets through only the issue it names, once.
    case feedback(FeedbackApproval)
    /// An edit of an issue the user's GitHub account opened on Apelin's own
    /// repository: the issue and the whole new title or body. The host lets
    /// through only the edit it names, against the text it was made
    /// against, once.
    case feedbackEdit(FeedbackEditApproval)
    /// A repository made on GitHub under the user's account: its owner,
    /// name and visibility. The host lets through only the repository it
    /// names, once.
    case repositoryCreate(RepositoryCreateApproval)
    /// An issue opened under the user's account on a GitHub repository the
    /// user chose: the repository and the whole title and body. The host
    /// lets through only the issue it names, once.
    case issueCreate(IssueCreateApproval)
    /// Another project deleted for good. The host lets through only the
    /// deletion of the project it names, once.
    case projectDelete(ProjectDeleteApproval)
    /// Builds' packages put in the user's package repository: the
    /// repository and each package with its digest. The host lets through
    /// only the publication it names, once.
    case packagePublish(PackagePublishApproval)
    /// A use of the screen while Ask Before Using the Screen is on: the UI
    /// tree read, the action, or the command that runs icli. Asked in every
    /// mode, never granted for the session; the host lets through only the
    /// call it names, once.
    case screenControl(ScreenControlApproval)
    /// The project made exactly a remote's branch, discarding local work:
    /// the state it was read in and what is lost. Asked in every mode,
    /// never granted for the session; the host lets through only the
    /// reset it names, once.
    case resetToRemote(ResetToRemoteApproval)
}

/// What a card asks while Ask Before Using the Screen is on (owner,
/// 2026-10-30), and the host matches the call to (AgentScreenRules): the
/// UI tree read or the action with its target, as the host is asked for
/// it, or the command that runs one of `ScreenConsent.programs`, which the
/// card shows as any command's.
public enum ScreenControlApproval: Sendable, Hashable, Codable {
    case readTree(targetID: String?)
    case interact(targetID: String?, action: UIAction)
    case command(RunCodeInvocation, asRoot: Bool)
}

/// What an apelin_package_publish card names, and the host matches its
/// request to (AgentPublishRules): the linked repository, then each
/// package — its build, what it is, the file the build wrote and the
/// digest it recorded —, in the order they are sent.
public struct PackagePublishApproval: Sendable, Hashable, Codable {
    public struct Package: Sendable, Hashable, Codable {
        public var buildID: String
        public var packageID: String
        public var version: String
        public var architecture: String
        /// `roothide` or `rootless`.
        public var bootstrap: String
        public var file: String
        /// `sha256:<hex>`, as the build recorded it.
        public var digest: String
        public init(
            buildID: String,
            packageID: String,
            version: String,
            architecture: String,
            bootstrap: String,
            file: String,
            digest: String,
        ) {
            self.buildID = buildID
            self.packageID = packageID
            self.version = version
            self.architecture = architecture
            self.bootstrap = bootstrap
            self.file = file
            self.digest = digest
        }
    }

    /// `owner/name`.
    public var repository: String
    /// The address a package manager adds.
    public var sourceURL: String?
    public var packages: [Package]
    public init(repository: String, sourceURL: String?, packages: [Package]) {
        self.repository = repository
        self.sourceURL = sourceURL
        self.packages = packages
    }
}

/// What an apelin_git_create_repository card names, and the host matches
/// its request to (AgentRepositoryCreateRules): the request as the tool
/// sends it. A nil owner is the signed-in account.
public struct RepositoryCreateApproval: Sendable, Hashable, Codable {
    public var owner: String?
    public var name: String
    public var visibility: GitRepositoryVisibility
    public var description: String?
    public init(owner: String?, name: String, visibility: GitRepositoryVisibility, description: String?) {
        self.owner = owner
        self.name = name
        self.visibility = visibility
        self.description = description
    }
}

/// What an apelin_git_create_issue card names, and the host matches its
/// issue to (AgentIssueCreateRules): the repository, the title and the
/// body, as the tool sends them.
public struct IssueCreateApproval: Sendable, Hashable, Codable {
    /// `owner/name`.
    public var repository: String
    public var title: String
    public var body: String
    public init(repository: String, title: String, body: String) {
        self.repository = repository
        self.title = title
        self.body = body
    }
}

/// What an apelin_project_delete card names, and the host matches its
/// deletion to (AgentProjectDeleteRules): the project, its folder and the
/// name the sidebar shows.
public struct ProjectDeleteApproval: Sendable, Hashable, Codable {
    public var projectID: String
    public var folder: String
    public var displayName: String
    public init(projectID: String, folder: String, displayName: String) {
        self.projectID = projectID
        self.folder = folder
        self.displayName = displayName
    }
}

/// What an apelin_feedback_send card names, and the host matches its issue
/// to (AgentFeedbackRules): the repository, the title and the body, as the
/// tool sends them.
public struct FeedbackApproval: Sendable, Hashable, Codable {
    public var repository: String
    public var title: String
    public var body: String
    public init(repository: String, title: String, body: String) {
        self.repository = repository
        self.title = title
        self.body = body
    }
}

/// What an apelin_feedback_edit card names, and the host matches its edit to
/// (AgentFeedbackRules): the issue, the title and body it puts in — nil for
/// one that stays — and the title and body it was made against, as the
/// tool read them just before asking.
public struct FeedbackEditApproval: Sendable, Hashable, Codable {
    public var repository: String
    public var number: Int
    public var url: String
    public var title: String?
    public var body: String?
    public var currentTitle: String
    public var currentBody: String
    public init(
        repository: String,
        number: Int,
        url: String,
        title: String?,
        body: String?,
        currentTitle: String,
        currentBody: String,
    ) {
        self.repository = repository
        self.number = number
        self.url = url
        self.title = title
        self.body = body
        self.currentTitle = currentTitle
        self.currentBody = currentBody
    }
}

/// What an apelin_project_rename card names for another project, and the
/// host matches its rename to (AgentProjectRenameRules): the project and
/// the name it is given.
public struct ProjectRenameApproval: Sendable, Hashable, Codable {
    public var projectID: String
    public var folder: String
    /// The name the sidebar shows now.
    public var currentName: String
    public var displayName: String
    public init(projectID: String, folder: String, currentName: String, displayName: String) {
        self.projectID = projectID
        self.folder = folder
        self.currentName = currentName
        self.displayName = displayName
    }
}

/// What an apelin_skill_save or apelin_skill_remove card names: the skill,
/// its place in the skills folder, and for a save the `SKILL.md` it writes.
public struct SkillChangeApproval: Sendable, Hashable, Codable {
    /// `save` or `remove`.
    public var action: String
    public var name: String
    /// Its place in the skills folder, relative to it.
    public var location: String
    /// Whether a save replaces a skill of that name.
    public var replacing: Bool
    /// The `SKILL.md` a save writes, frontmatter included.
    public var text: String?
    public init(action: String, name: String, location: String, replacing: Bool, text: String?) {
        self.action = action
        self.name = name
        self.location = location
        self.replacing = replacing
        self.text = text
    }
}

/// What a workspace build's card names, and the host matches its build to
/// (AgentExternalBuildRules): the project, the configuration and the
/// bootstrap. `script` is shown, from the workspace's declaration.
public struct ExternalBuildApproval: Sendable, Hashable, Codable {
    public var projectID: String
    public var script: String
    /// `debug` or `release`.
    public var configuration: String
    /// `roothide` or `rootless` when the build names one; nil for this
    /// device's.
    public var bootstrap: String?
    public init(projectID: String, script: String, configuration: String, bootstrap: String?) {
        self.projectID = projectID
        self.script = script
        self.configuration = configuration
        self.bootstrap = bootstrap
    }
}

/// What a apelin_toolchain_setup card names, and the host matches its setup to.
public struct ToolchainSetupApproval: Sendable, Hashable, Codable {
    public var productID: String
    public var version: String
    /// `c`, and `swift` when asked for.
    public var components: [String]
    public var sizeBytes: Int64?
    public init(productID: String, version: String, components: [String], sizeBytes: Int64?) {
        self.productID = productID
        self.version = version
        self.components = components
        self.sizeBytes = sizeBytes
    }
}

/// What an apelin_sdk_import card names, and the host matches its import to.
public struct SDKImportApproval: Sendable, Hashable, Codable {
    public var source: String
    public var url: String
    public var branch: String
    public var version: String
    public init(source: String, url: String, branch: String, version: String) {
        self.source = source
        self.url = url
        self.branch = branch
        self.version = version
    }
}

/// A conversation call that reaches another project: what it does there.
/// The host matches an open or a message to `projectID`, `sessionID` and
/// `text`, and lets the session list and read that project's conversations
/// once the user approved any of them.
public struct OtherProjectApproval: Sendable, Hashable, Codable {
    /// `create`, `send`, `list` or `read`.
    public var action: String
    public var projectID: String
    public var projectName: String
    /// The conversation a send or a read names.
    public var sessionID: String?
    /// The prompt or message, as the other agent will read it.
    public var text: String?
    public init(action: String, projectID: String, projectName: String, sessionID: String? = nil, text: String? = nil) {
        self.action = action
        self.projectID = projectID
        self.projectName = projectName
        self.sessionID = sessionID
        self.text = text
    }
}

public enum ApprovalDecision: Sendable, Hashable, Codable {
    public enum Scope: String, Sendable, Hashable, Codable {
        /// This call only.
        case once
        /// Identical calls (same fingerprint) for the rest of this session.
        case session
    }

    case approve(Scope)
    case deny(reason: String?)
}

// MARK: - Descriptions and their digests

public enum DescriptionKind: String, Sendable, Hashable, Codable {
    /// `apelin-project.json`'s build steps, compile/link flags and the
    /// build scripts the project carries.
    case build
    /// Control fields, maintainer scripts, install layout and dependencies.
    case packaging
}

/// The current state of a project's build or packaging description, as the
/// host computed it from the project and its registered template.
public struct DescriptionState: Sendable, Hashable, Codable {
    public enum Baseline: Sendable, Hashable, Codable {
        /// Byte-for-byte the template's (at the project's registered
        /// template version).
        case matchesTemplate
        /// Differs from the template, but this digest was approved before.
        case approved
        /// Differs and was never approved: the first run after the change
        /// asks. `diff` is against the template or the last approved
        /// version.
        case changed(diff: String)
    }

    /// SHA-256 of the description, hex.
    public var digest: String
    public var baseline: Baseline

    public init(digest: String, baseline: Baseline) {
        self.digest = digest
        self.baseline = baseline
    }
}

/// The host's record of description digests. Read-only from the agent's
/// side: there is no method that writes, and the ledger lives in the host's
/// private state, bound to the project id, where neither the agent nor a
/// project file can reach it. The host records an approval itself when it
/// relays the user's decision on a `.descriptionChanged` request.
public protocol ApprovalDigestStore: Sendable {
    func state(of kind: DescriptionKind, for project: ProjectIdentity) async throws -> DescriptionState
    /// The packaging state of one built package, by its artifact ID: what a
    /// workspace's install is judged by, since a workspace has no packaging
    /// description of its own. Nil when the artifact is not known.
    func packagingState(ofArtifact artifactID: String, for project: ProjectIdentity) async throws -> DescriptionState?
}

public extension ApprovalDigestStore {
    func packagingState(ofArtifact _: String, for _: ProjectIdentity) async throws -> DescriptionState? {
        nil
    }
}
