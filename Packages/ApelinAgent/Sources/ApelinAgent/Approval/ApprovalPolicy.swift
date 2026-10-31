import enum ApelinProtocol.AgentToolName
import CryptoKit
import Foundation
import KWWKAI

/// The user-editable presets of Confirm mode, kept in the app's settings and
/// handed to the session when it opens. No tool can change them: the agent
/// has no write path to settings, and the session holds its own copy.
public struct ApprovalPresets: Sendable, Hashable, Codable {
    /// Read tools that run without asking. Only read-only tools count; a
    /// system tool named here is ignored.
    public var readTools: Set<AgentToolName>
    /// System tools that run without asking. Only `apelin_device_respring` and
    /// `apelin_screen_interact` can be preset; build and install follow the digest rule,
    /// shell_run follows `commands`, and package removal always asks.
    public var systemTools: Set<AgentToolName>
    public var commands: [CommandPreset]

    public init(readTools: Set<AgentToolName>, systemTools: Set<AgentToolName>, commands: [CommandPreset]) {
        self.readTools = readTools
        self.systemTools = systemTools
        self.commands = commands
    }

    /// Every read tool except the screen, the UI tree and the web fetch
    /// (`isSensitiveRead`); respring; a few read-only commands that stay
    /// inside the project.
    public static let `default` = ApprovalPresets(
        readTools: Set(AgentToolName.allCases.filter { $0.risk == .readOnly && !$0.isSensitiveRead }),
        systemTools: [.deviceRespring],
        commands: [
            CommandPreset(name: "ls", executable: "ls"),
            CommandPreset(name: "cat", executable: "cat"),
            CommandPreset(name: "head", executable: "head"),
            CommandPreset(name: "tail", executable: "tail"),
            CommandPreset(name: "wc", executable: "wc"),
            CommandPreset(name: "file", executable: "file"),
            CommandPreset(name: "stat", executable: "stat"),
            CommandPreset(name: "plutil -p", executable: "plutil", argumentPrefix: ["-p"]),
            CommandPreset(name: "git status", executable: "git", argumentPrefix: ["status"]),
            CommandPreset(name: "git diff", executable: "git", argumentPrefix: ["diff"]),
            CommandPreset(name: "git log", executable: "git", argumentPrefix: ["log"]),
        ],
    )
}

/// What the gate knows about one call, gathered before deciding.
public struct InvocationFacts: Sendable, Hashable {
    public enum PathCheck: Sendable, Hashable {
        case inside
        case outside(String)
    }

    public enum Tool: Sendable, Hashable {
        case local(AgentToolName)
        /// A tool from an MCP server; always treated as a system tool.
        case mcp(String)
        /// A tool of an installed agent tool extension; treated as an MCP
        /// tool is, whatever risk its manifest declares.
        case toolExtension(ExtensionTool)
    }

    public var tool: Tool
    public var pathCheck: PathCheck?
    public var command: RunCodeInvocation?
    /// For build (`.build`) and install (`.packaging`).
    public var description: DescriptionState?
    /// For apelin_package_remove: the installation record it removes.
    public var installationID: String?
    /// That installation as apelin_package_list lists it, when the backend
    /// found it: what the card names.
    public var removedPackage: ListedInstallation?
    /// For git_push: where it pushes, and what.
    public var push: GitPushTarget?
    /// For git_push with force_with_lease, when the push would take commits
    /// off the remote's branch: what it overwrites, as the fetch before it
    /// found the remote. Nil for an ordinary push, which loses nothing.
    public var forcePush: ForcePushApproval?
    /// For git_squash: what it combines, as the preview before it found it.
    public var squash: SquashApproval?
    /// For the git settings tools: what they change, in words, without a
    /// token ("the commit author", "the credential for github.com").
    public var gitSettings: String?
    /// For shell_run: its working directory, relative to the project root,
    /// which a preset's path arguments are read from.
    public var workingDirectory: String
    /// For shell_run: run as root (`root: true`).
    public var runsAsRoot: Bool
    /// For apelin_toolchain_setup: the release, resolved in Apple's catalog before
    /// asking, and sent by product ID.
    public var toolchainSetup: ToolchainSetupApproval?
    /// For apelin_sdk_import: the source and branch, resolved before asking.
    public var sdkImport: SDKImportApproval?
    /// For a conversation tool that names another project than the
    /// session's: what it does there.
    public var otherProject: OtherProjectApproval?
    /// That project, as the backend resolved it, which the call is sent to.
    public var targetProject: ProjectIdentity?
    /// For build in a workspace: what it builds, which runs the workspace's
    /// own script.
    public var externalBuild: ExternalBuildApproval?
    /// For apelin_skill_save and apelin_skill_remove: the skill, checked
    /// before asking, and what a save writes.
    public var skillChange: SkillChangeApproval?
    /// For apelin_project_rename of another project than the session's: the
    /// project and the name; nil for the session's own project.
    public var projectRename: ProjectRenameApproval?
    /// The project apelin_project_rename renames, as the backend resolved it.
    public var renamedProject: ProjectIdentity?
    /// For apelin_feedback_send: the issue, checked before asking, as it is
    /// sent.
    public var feedback: FeedbackApproval?
    /// For apelin_feedback_edit: the issue, read and checked before asking,
    /// and the edit as it is sent.
    public var feedbackEdit: FeedbackEditApproval?
    /// For apelin_git_create_repository: the repository, checked before
    /// asking, as it is requested.
    public var repositoryCreate: RepositoryCreateApproval?
    /// For apelin_git_create_issue: the repository and the issue, checked
    /// before asking, as they are sent.
    public var issueCreate: IssueCreateApproval?
    /// For apelin_project_delete: the project, resolved before asking,
    /// which is the one deleted.
    public var projectDeletion: ProjectDeleteApproval?
    /// For apelin_package_publish: the repository and the packages,
    /// checked before asking, as they are sent.
    public var packagePublish: PackagePublishApproval?
    /// For apelin_screen_read_tree, apelin_screen_interact and a shell_run
    /// that runs icli (or another of `ScreenConsent.programs`): what it does
    /// on the screen, as the host is asked for it.
    public var screenControl: ScreenControlApproval?

    public init(
        tool: Tool,
        pathCheck: PathCheck? = nil,
        command: RunCodeInvocation? = nil,
        description: DescriptionState? = nil,
        installationID: String? = nil,
        push: GitPushTarget? = nil,
        gitSettings: String? = nil,
        workingDirectory: String = ".",
        toolchainSetup: ToolchainSetupApproval? = nil,
        sdkImport: SDKImportApproval? = nil,
        otherProject: OtherProjectApproval? = nil,
        runsAsRoot: Bool = false,
    ) {
        self.tool = tool
        self.pathCheck = pathCheck
        self.command = command
        self.description = description
        self.installationID = installationID
        self.push = push
        self.gitSettings = gitSettings
        self.workingDirectory = workingDirectory
        self.toolchainSetup = toolchainSetup
        self.sdkImport = sdkImport
        self.otherProject = otherProject
        self.runsAsRoot = runsAsRoot
    }
}

/// The remote a push goes to and the local branch it sends.
public struct GitPushTarget: Sendable, Hashable {
    public var remote: String
    /// nil when no branch is checked out; the host then refuses the push.
    public var branch: String?
    /// The address the remote is added at when the project does not have
    /// it yet; the host refuses one that differs from the remote's own.
    public var url: String?
    /// Why a push asked to be forced goes as an ordinary one: the remote's
    /// branch loses nothing to it. Told the model with the result.
    public var unforced: String?

    public init(remote: String, branch: String?, url: String? = nil, unforced: String? = nil) {
        self.remote = remote
        self.branch = branch
        self.url = url
        self.unforced = unforced
    }
}

public enum GateVerdict: Sendable, Hashable {
    case allow(ApprovalEvidence)
    case ask(reason: String, detail: ApprovalDetail)
    case deny(String)
}

/// The decision table of §7, as a pure function of mode, presets and the
/// facts of one call. The session host runs the same rules again on its
/// side; this copy is what makes the agent wait.
public struct ApprovalPolicy: Sendable, Hashable {
    public var mode: ApprovalMode
    public var presets: ApprovalPresets
    /// Ask Before Using the Screen, the app's setting (owner, 2026-10-30):
    /// on, the UI tree, every UI action and every command that runs icli
    /// ask each time, in every mode (`evaluateScreen`).
    public var asksBeforeScreen: Bool

    public init(mode: ApprovalMode, presets: ApprovalPresets = .default, asksBeforeScreen: Bool = true) {
        self.mode = mode
        self.presets = presets
        self.asksBeforeScreen = asksBeforeScreen
    }

    public func evaluate(_ facts: InvocationFacts, root: ScopedRoot) -> GateVerdict {
        // Leaving the project is refused in every mode: it is outside every
        // tool's capability, not a matter of asking.
        if case let .outside(path)? = facts.pathCheck {
            return .deny("\(path) is outside the project")
        }
        if let screen = evaluateScreen(facts) {
            return screen
        }
        // A forced push takes commits off the remote's branch: it asks every
        // time, in every mode — Full lifts root commands, not this —, the
        // card naming what is lost, and the host spends that one approval.
        if case .local(.gitPush) = facts.tool, let force = facts.forcePush {
            return .ask(reason: Self.forcePushReason(force), detail: .forcePush(force))
        }
        if case .local(.shellRun) = facts.tool, facts.runsAsRoot {
            return evaluateRoot(facts)
        }
        if mode != .confirm {
            return .allow(.relaxed)
        }

        switch facts.tool {
        case let .mcp(name):
            return .ask(reason: "\(name) is a tool from an MCP server. Review it before running.", detail: .none)
        case let .toolExtension(tool):
            // The extension runs as mobile, as this worker does: the host
            // starts it and passes the call on, deciding nothing again.
            return .ask(
                reason: "\(tool.name) is a tool of \(tool.extensionName) \(tool.extensionVersion), an agent tool extension that runs in its own process. Review it before running.",
                detail: .none,
            )
        case let .local(tool):
            return evaluateConfirm(tool, facts: facts, root: root)
        }
    }

    /// A command as root runs without asking only in Full; in Strict and
    /// Relaxed it asks every time, never as a preset, and the host
    /// decides again.
    private func evaluateRoot(_ facts: InvocationFacts) -> GateVerdict {
        if mode == .full {
            return .allow(.relaxed)
        }
        guard let command = facts.command else {
            return .ask(reason: "Apelin could not read this command. Review it before running.", detail: .none)
        }
        return .ask(
            reason: "Runs as root, with full control of this device. Each command that runs as root needs your approval.",
            detail: .rootCommand(command),
        )
    }

    /// While Ask Before Using the Screen is on, the UI tree, every UI
    /// action and every command that runs icli (or another of
    /// `ScreenConsent.programs`) ask each time, in every mode and whatever
    /// the presets say, the card saying what the call opens, reads or does
    /// there; the host spends that one approval. Nil leaves the call to the
    /// mode.
    private func evaluateScreen(_ facts: InvocationFacts) -> GateVerdict? {
        guard asksBeforeScreen else { return nil }
        switch facts.tool {
        case .local(.screenReadTree), .local(.screenInteract):
            break
        case .local(.shellRun):
            guard facts.command?.screenProgram != nil else { return nil }
        default:
            return nil
        }
        guard let use = facts.screenControl else {
            return .ask(reason: "What this call does on the screen could not be read. \(Self.screenNote)", detail: .none)
        }
        return .ask(reason: "\(Self.screenPhrase(use)) \(Self.screenNote)", detail: .screenControl(use))
    }

    static let screenNote = "Ask Before Using the Screen is on, so each use of the screen needs your approval, in every mode."

    /// What a use of the screen opens, reads or does, in a sentence.
    static func screenPhrase(_ use: ScreenControlApproval) -> String {
        switch use {
        case let .readTree(targetID):
            let app = targetID.map { "the app \($0)" } ?? "the app in front, whichever it is"
            return "Reads what is on the screen: the text and controls of \(app)."
        case let .interact(targetID, action):
            if case .pressButton = action {
                return actionPhrase(action) + "."
            }
            let app = targetID.map { "the app \($0)" } ?? "the app in front, whichever it is"
            return "\(actionPhrase(action)) in \(app)."
        case let .command(invocation, _):
            return commandPhrase(invocation)
        }
    }

    private static func actionPhrase(_ action: UIAction) -> String {
        switch action {
        case let .tap(x, y):
            "Taps the screen at \(point(x, y))"
        case let .tapElement(id):
            id.hasPrefix("text:") ? "Taps “\(id.dropFirst(5))”" : "Taps the element \(id)"
        case let .typeText(text):
            "Types “\(text.count > 200 ? String(text.prefix(200)) + "…" : text)”"
        case let .swipe(fromX, fromY, toX, toY, _):
            "Swipes from \(point(fromX, fromY)) to \(point(toX, toY))"
        case let .pressButton(button):
            switch button {
            case "wake": "Presses wake, which turns the screen on"
            case "home": "Presses Home, which sends the app in front to the home screen"
            case "lock": "Presses the side button, which turns the screen off and locks the device"
            default: "Presses \(button)"
            }
        }
    }

    private static func point(_ x: Double, _ y: Double) -> String {
        func number(_ value: Double) -> String {
            value.rounded() == value && abs(value) < 1e9 ? String(Int(value)) : String(value)
        }
        return "(\(number(x)), \(number(y)))"
    }

    /// A command that runs one of `ScreenConsent.programs`: icli's
    /// `url open` and `app launch` by what they open, anything else by the
    /// program it runs.
    private static func commandPhrase(_ invocation: RunCodeInvocation) -> String {
        if case let .argv(argv) = invocation, let program = argv.first,
           (program as NSString).lastPathComponent.lowercased() == "icli", argv.count >= 4,
           !argv[3].hasPrefix("-")
        {
            switch (argv[1], argv[2]) {
            case ("url", "open"):
                return "Opens \(argv[3]) on this device, in the app that handles it, which comes to the front."
            case ("app", "launch"):
                return "Opens the app \(argv[3]) on this device, which comes to the front."
            default:
                break
            }
        }
        switch invocation.screenProgram {
        case "uiopen":
            return "Runs uiopen, which opens an app or a link on this device and brings it to the front."
        case "uishoot":
            return "Runs uishoot, which takes a screenshot of whatever is on the screen."
        default:
            return "Runs icli, which can open apps and links, read what is on the screen and act on it, whatever app is in front."
        }
    }

    private func evaluateConfirm(_ tool: AgentToolName, facts: InvocationFacts, root: ScopedRoot) -> GateVerdict {
        // A conversation call into another project asks every time, naming
        // the project and what it sends there.
        if tool.isConversation, let reach = facts.otherProject {
            return .ask(reason: Self.otherProjectReason(reach), detail: .otherProject(reach))
        }
        switch tool {
        case .fileWrite, .fileEdit, .fileCreate, .memorySave, .memoryDelete:
            return .allow(.notRequired)

        // A banner from Apelin to the user, never a preset to edit away:
        // it reads, writes and runs nothing, and it shows only while Apelin
        // is not in front, plain, bounded and a few per turn
        // (`AgentNoticeRules`). Asking first would defeat it: the user it
        // is for is not looking.
        case .notificationSend:
            return .allow(.notRequired)

        // Instructions every later conversation, in every project, lists
        // and may follow: each change asks, the card showing the whole
        // skill, and none is granted for the session.
        case .skillSave, .skillRemove:
            guard let change = facts.skillChange else {
                return .ask(reason: "The skill to change could not be read.", detail: .none)
            }
            return .ask(reason: Self.skillReason(change), detail: .skillChange(change))

        // A field of the project's own apelin-project.json, which the file
        // tools edit as well: only a registered, checked, compatible
        // toolchain or SDK goes in. The binding is not part of the build
        // description digest, so the next build does not ask for it.
        case .projectSetEnvironment:
            return .allow(.notRequired)

        // Installed on the device for every project, a toolchain through
        // Irisin: every setup and import asks, naming what is downloaded.
        case .toolchainSetup:
            guard let setup = facts.toolchainSetup else {
                return .ask(reason: "The toolchain to set up could not be identified.", detail: .none)
            }
            return .ask(reason: Self.setupReason(setup), detail: .toolchainSetup(setup))

        case .sdkImport:
            guard let sdkImport = facts.sdkImport else {
                return .ask(reason: "The SDK to import could not be identified.", detail: .none)
            }
            return .ask(
                reason: "Imports the iPhoneOS \(sdkImport.version) SDK onto this device from \(sdkImport.source) (branch \(sdkImport.branch) of \(sdkImport.url)): one branch is downloaded, checked and registered for every project. Each import needs your approval.",
                detail: .sdkImport(sdkImport),
            )

        // Runs the toolchain's compilers and the programs they make, as
        // mobile, and records the results; it installs nothing.
        case .toolchainSelfTest:
            return .ask(
                reason: "Runs the toolchain's self-test again: small programs are compiled, signed and run as mobile, and the results recorded.",
                detail: .none,
            )

        // A new folder from a template: nothing in it runs, and its build
        // and packaging are the template's, which the host's ledger records.
        case .projectCreate:
            return .allow(.notRequired)

        // The session's own project's displayName, which the file tools may
        // write there anyway and no approval digest counts: like an edit.
        // Another project's asks every time, as any call into one does.
        case .projectRename:
            guard let rename = facts.projectRename else { return .allow(.notRequired) }
            return .ask(
                reason: "Renames the project \(rename.folder) (shown as “\(rename.currentName)”) to “\(rename.displayName)”. The folder and its identifiers stay. Each rename of another project needs your approval.",
                detail: .projectRename(rename),
            )

        // Another project, gone for good with its files and conversations:
        // every deletion asks, naming the project, and none is granted for
        // the session.
        case .projectDelete:
            guard let deletion = facts.projectDeletion else {
                return .ask(reason: "The project to delete could not be identified.", detail: .none)
            }
            return .ask(reason: Self.deletionReason(deletion), detail: .projectDelete(deletion))

        // The project's own repository, changed in the project: like an
        // edit, and nothing leaves the device. A fetch, pull or clone
        // only brings commits in; pull never merges, clone never
        // overwrites; init makes an empty repository where there is none.
        case .gitStage, .gitUnstage, .gitCommit, .gitInit, .gitFetch, .gitPull, .gitClone:
            return .allow(.notRequired)

        // Another conversation of the project, opened, sent to or stopped:
        // its agent runs under this session's mode, so whatever it does
        // that would ask, asks there.
        case .conversationCreate, .conversationSend, .conversationStop:
            return .allow(.notRequired)

        // Publishes commits with the user's credential: every push asks,
        // and the card names where it goes.
        case .gitPush:
            guard let target = facts.push else {
                return .ask(reason: "Where this push goes could not be read.", detail: .none)
            }
            let branch = target.branch ?? "the checked-out branch"
            let place = target.url.map { "\(target.remote) at \($0)" } ?? target.remote
            let unforced = target.unforced.map { " \($0)" } ?? ""
            return .ask(
                reason: "Pushing \(branch) to \(place) publishes its commits.\(unforced) Each push needs your approval.",
                detail: .gitPush(remote: target.remote, branch: target.branch),
            )

        // The project's own commits replaced by one, which the user may
        // have read or published: every squash asks, the card naming each
        // commit and the new message, and none is granted for the session.
        case .gitSquash:
            guard let squash = facts.squash else {
                return .ask(reason: "What this squash combines could not be read.", detail: .none)
            }
            return .ask(reason: Self.squashReason(squash), detail: .squash(squash))

        // A public issue under the user's GitHub account, as a push
        // publishes: every one asks, the card showing the whole text.
        case .feedbackSend:
            guard let feedback = facts.feedback else {
                return .ask(reason: "The feedback to send could not be read.", detail: .none)
            }
            return .ask(reason: Self.feedbackReason(feedback), detail: .feedback(feedback))

        // The same issue, changed in public: every edit asks, the card
        // showing the whole new text.
        case .feedbackEdit:
            guard let edit = facts.feedbackEdit else {
                return .ask(reason: "The edit to make could not be read.", detail: .none)
            }
            return .ask(reason: Self.feedbackEditReason(edit), detail: .feedbackEdit(edit))

        // A repository on GitHub under the user's account, which outlives
        // the conversation: every one asks, the card naming its owner, name
        // and visibility.
        case .gitCreateRepository:
            guard let repository = facts.repositoryCreate else {
                return .ask(reason: "The repository to create could not be read.", detail: .none)
            }
            return .ask(reason: Self.repositoryReason(repository), detail: .repositoryCreate(repository))

        // An issue under the user's GitHub account on a repository they
        // chose, as feedback is filed: every one asks, the card showing the
        // repository and the whole text.
        case .gitCreateIssue:
            guard let issue = facts.issueCreate else {
                return .ask(reason: "The issue to open could not be read.", detail: .none)
            }
            return .ask(reason: Self.issueReason(issue), detail: .issueCreate(issue))

        // Packages in the user's package repository, where anyone who adds
        // its source installs them, as a push publishes: every publication
        // asks, the card naming the repository and each package's digest.
        case .packagePublish:
            guard let publication = facts.packagePublish else {
                return .ask(reason: "The packages to publish could not be read.", detail: .none)
            }
            return .ask(reason: Self.publishReason(publication), detail: .packagePublish(publication))

        // The device's git settings, for every project: each change asks,
        // and a saved token is never on the card.
        case .gitSetAuthor, .gitSaveCredential, .gitRemoveCredential:
            let summary = facts.gitSettings ?? "a change to the git settings"
            return .ask(
                reason: "This changes \(summary) for every project. Each change needs your approval.",
                detail: .gitSettings(summary: summary),
            )

        case .fileRead, .fileList, .fileGrep, .fileFind, .fileShow, .sdkAnalyzeFramework, .sdkReadHeader,
             .packageList, .packageConfirmLoaded, .logRead, .crashList, .crashRead, .crashSymbolicate,
             .screenCapture, .screenReadTree, .memoryList, .skillList, .skillRead, .projectCheckDistribution,
             .templateList, .projectList, .gitStatus, .gitDiff, .gitReadSettings,
             .conversationList, .conversationRead, .toolchainList, .sdkList, .webFetch, .feedbackRead:
            if presets.readTools.contains(tool) {
                return .allow(.preset(tool.rawValue))
            }
            return .ask(reason: "This action is not in your approved presets. Review it before running.", detail: .none)

        case .deviceRespring, .screenInteract:
            if presets.systemTools.contains(tool) {
                return .allow(.preset(tool.rawValue))
            }
            return .ask(reason: "This action changes this device. Review it before running.", detail: .none)

        case .shellRun:
            guard let command = facts.command else {
                return .ask(reason: "Apelin could not read this command. Review it before running.", detail: .none)
            }
            if case let .argv(argv) = command,
               let preset = presets.commands.first(where: {
                   $0.matches(argv, root: root, workingDirectory: facts.workingDirectory)
               })
            {
                return .allow(.preset(preset.name))
            }
            switch command {
            case .argv:
                return .ask(
                    reason: "This command is not in your approved presets. Review it before running.",
                    detail: .command(command),
                )
            case .shell:
                return .ask(
                    reason: "This command uses shell features such as pipes or redirection. Review it before running.",
                    detail: .command(command),
                )
            case .script: return .ask(reason: "Scripts require approval each time they run.", detail: .command(command))
            }

        case .projectBuild, .packageInstall:
            // A workspace's build runs its own script, code from the
            // repository: every build asks, and is never granted for the
            // session.
            if tool == .projectBuild, let build = facts.externalBuild {
                return .ask(
                    reason: "Runs this workspace's own build script, \(build.script), as mobile with the prepared toolchain: it can run any code in the repository. Each build of a workspace needs your approval.",
                    detail: .externalBuild(build),
                )
            }
            let kind: DescriptionKind = tool == .projectBuild ? .build : .packaging
            guard let state = facts.description else {
                return .ask(reason: "The \(kind.rawValue) description could not be checked.", detail: .none)
            }
            switch state.baseline {
            case .matchesTemplate: return .allow(.templateMatch(digest: state.digest))
            case .approved: return .allow(.digestApproved(digest: state.digest))
            case let .changed(diff):
                return .ask(
                    reason: "The \(kind.rawValue) description changed since the template or your last approval. Review the changes before continuing.",
                    detail: .descriptionChanged(kind: kind, digest: state.digest, diff: diff),
                )
            }

        case .packageRemove:
            // The session host grants the removal from this detail alone
            // (`allowRemoval`), so a request without it could never be spent.
            guard let installationID = facts.installationID else {
                return .ask(reason: "The package to remove could not be identified.", detail: .none)
            }
            return .ask(
                reason: Self.removalReason(facts.removedPackage),
                detail: .packageRemoval(installationID: installationID),
            )
        }
    }

    /// Names what goes and whose build it was, which may be another
    /// project's: the host removes any installation it made.
    static func removalReason(_ removed: ListedInstallation?) -> String {
        guard let removed else { return "Removing a package requires your approval." }
        let project = removed.project ?? removed.projectID
        let installedBy = project.map { ", installed by the project \($0)," } ?? ""
        return "Removing \(removed.packageID) \(removed.version)\(installedBy) requires your approval."
    }

    static func setupReason(_ setup: ToolchainSetupApproval) -> String {
        let components = setup.components.contains("swift") ? "C and Swift" : "C"
        let size = setup.sizeBytes.map {
            " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))"
        } ?? ""
        return "Sets up Command Line Tools \(setup.version) (\(components)) on this device: Apple's package\(size) is downloaded from Apple, adapted, installed as a package through Irisin for every project and self-tested; if no registered SDK fits it, one is imported from an enabled SDK source first. Each install needs your approval."
    }

    static func deletionReason(_ deletion: ProjectDeleteApproval) -> String {
        "Deletes the project \(deletion.folder) (shown as “\(deletion.displayName)”) from this device: its folder with every file in it, and its conversations, which are closed first. This cannot be undone. Each deletion needs your approval."
    }

    static func feedbackReason(_ feedback: FeedbackApproval) -> String {
        "Posts this title and body as a public issue on \(feedback.repository) under your GitHub account, where anyone can read it; Apelin adds its version, the iOS version and the bootstrap below it. Each one needs your approval."
    }

    static func issueReason(_ issue: IssueCreateApproval) -> String {
        "Opens this issue on \(issue.repository) under your GitHub account, where everyone who can see that repository can read it; Apelin adds its version, the iOS version and the bootstrap below it. Each one needs your approval."
    }

    static func feedbackEditReason(_ edit: FeedbackEditApproval) -> String {
        let fields: [String] = [edit.title.map { _ in "title" }, edit.body.map { _ in "body" }].compactMap(\.self)
        return "Replaces the \(fields.joined(separator: " and ")) of issue #\(edit.number) on \(edit.repository), which your GitHub account opened and anyone can read, with the text below; the line Apelin added below the body stays as it is. Each edit needs your approval."
    }

    static func publishReason(_ publication: PackagePublishApproval) -> String {
        let packages = publication.packages.map { package in
            "\(package.packageID) \(package.version) for \(package.bootstrap) (\(package.architecture))"
        }
        let one = packages.count == 1
        let what = one ? "this package" : "these \(packages.count) packages"
        let source = publication.sourceURL.map { " (\($0))" } ?? ""
        return "Publishes \(what) to your package repository \(publication.repository) on GitHub, as \(one ? "its build" : "their builds") made \(one ? "it" : "them"): \(packages.joined(separator: "; ")). Anyone who adds its source\(source) can install \(one ? "it" : "them"), and a version published there cannot be published again with other contents. Each publication needs your approval."
    }

    static func repositoryReason(_ repository: RepositoryCreateApproval) -> String {
        let place = repository.owner.map { "\($0)/\(repository.name) on GitHub" }
            ?? "\(repository.name) on your GitHub account"
        let who = repository.visibility == .public ? "anyone can see it" : "only people given access can see it"
        return "Creates the empty \(repository.visibility.rawValue) repository \(place), where \(who). Each repository needs your approval."
    }

    static func skillReason(_ change: SkillChangeApproval) -> String {
        let what = change.action == "remove"
            ? "Removes the skill \(change.name) from the skills folder."
            : "Saves the skill \(change.name)\(change.replacing ? ", replacing the one of that name," : "") to the skills folder: every later conversation, in every project, lists it and may follow it."
        return what + " Each change to the skills needs your approval."
    }

    static func otherProjectReason(_ reach: OtherProjectApproval) -> String {
        // The whole text is in the call's arguments, which the card shows too.
        let full = reach.text ?? ""
        let text = full.count > 400 ? String(full.prefix(400)) + "…" : full
        let what = switch reach.action {
        case "create": "opens a conversation in the project \(reach.projectName) whose agent reads this as your message: “\(text)”"
        case "send": "sends a conversation of the project \(reach.projectName) this as your message: “\(text)”"
        case "list": "lists the conversations of the project \(reach.projectName)"
        default: "reads a conversation of the project \(reach.projectName)"
        }
        return "This \(what). Each call that reaches another project needs your approval."
    }
}

/// Binds an approval to tool, arguments, working directory, project, and
/// the description digest when there is one (an agent tool extension's id
/// and version for its tools).
public enum ApprovalFingerprint {
    public static func make(
        tool: String,
        arguments: JSONValue,
        workingDirectory: String,
        projectID: String,
        digest: String?,
    ) -> String {
        let material: JSONValue = .object([
            "tool": .string(tool),
            "arguments": arguments,
            "cwd": .string(workingDirectory),
            "project": .string(projectID),
            "digest": digest.map { .string($0) } ?? .null,
        ])
        let hash = SHA256.hash(data: Data(material.canonicalJSON.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
