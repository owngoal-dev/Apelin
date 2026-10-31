import enum ApelinCore.ProjectDisplayName
import enum ApelinProtocol.AgentToolName
import enum ApelinProtocol.FeedbackRules
import struct ApelinProtocol.GitIssueCreateRequest
import struct ApelinProtocol.GitRepositoryCreateRequest
import enum ApelinProtocol.GitRepositoryVisibility
import Foundation
import KWWKAI

extension ToolRunner {
    func gatherFacts(_ tool: InvocationFacts.Tool, arguments: JSONValue) async throws -> InvocationFacts {
        guard case let .local(name) = tool else { return InvocationFacts(tool: tool) }
        var facts = InvocationFacts(tool: tool)
        if GitRemoteTools.namingRemote.contains(name) {
            try GitRemoteTools.checkName(arguments.argNonEmptyString("remote"))
        }
        switch name {
        case .fileWrite, .fileEdit, .fileCreate:
            let path = try arguments.requireString("path")
            // No project walk for .git files here: a git directory does not
            // change the gate's answer, and the tool's own resolution walks.
            facts.pathCheck = check { _ = try root.resolveForWrite(path, findingGitPointers: false) }
        case .fileRead:
            let path = try arguments.requireString("path")
            facts.pathCheck = check { _ = try readRoot(for: path).resolveExisting(path) }
        case .fileList, .fileGrep, .fileFind:
            let path = arguments.argString("path") ?? "."
            facts.pathCheck = check { _ = try readRoot(for: path).resolveExisting(path) }
        case .fileShow:
            // The first path that leaves the project, if one does.
            let checks = (arguments.argStrings("paths") ?? []).map { path in check { _ = try root.resolveExisting(path) } }
            facts.pathCheck = checks.first { $0 != .inside } ?? .inside
        case .shellRun:
            let command = try CommandClassifier.classify(arguments)
            facts.command = command
            facts.runsAsRoot = arguments.argBool("root") ?? false
            let cwd = arguments.argString("cwd") ?? "."
            facts.pathCheck = root.mayReach(cwd) ? .inside : .outside(cwd)
            facts.workingDirectory = cwd
            if command.screenProgram != nil {
                facts.screenControl = .command(command, asRoot: facts.runsAsRoot)
            }
        // What the call does on the screen, as the host is asked for it:
        // what Ask Before Using the Screen's card names.
        case .screenReadTree:
            facts.screenControl = .readTree(targetID: arguments.argString("target_id"))
        case .screenInteract:
            facts.screenControl = try .interact(targetID: arguments.argString("target_id"), action: Self.uiAction(arguments))
        case .projectBuild:
            if let script = ProjectBuildSystem.externalScript(in: root) {
                facts.externalBuild = ExternalBuildApproval(
                    projectID: project.id,
                    script: script,
                    configuration: arguments.argNonEmptyString("configuration") ?? "debug",
                    bootstrap: arguments.argNonEmptyString("bootstrap"),
                )
            } else {
                facts.description = try? await digests.state(of: .build, for: project)
            }
        case .packageInstall:
            // A workspace has no packaging description: the package it built
            // is judged by its own (apelin-build's ExternalBuild).
            if ProjectBuildSystem.read(in: root) == .external {
                let artifact = try arguments.requireString("artifact_id")
                guard let state = try? await digests.packagingState(ofArtifact: artifact, for: project) else {
                    throw ToolArgumentError("No build of this workspace made a package \(artifact): build it again with apelin_project_build, then install the artifact that build answers.")
                }
                facts.description = state
            } else {
                facts.description = try? await digests.state(of: .packaging, for: project)
            }
        case .packageRemove:
            let removal = try await removalToAsk(arguments)
            facts.installationID = removal.installationID
            facts.removedPackage = removal.listed
        case .webFetch:
            // An address that would never be fetched is refused before
            // anyone is asked about it.
            _ = try WebFetch.target(arguments.requireString("url"))
        case .gitRemoteSet:
            try GitRemoteTools.checkSet(arguments)
        case .gitResetToRemote:
            facts.resetToRemote = try await resetToAsk(arguments)
        case .gitRemoteRemove:
            try GitRemoteTools.checkName(arguments.argNonEmptyString("name"))
        case .gitPush:
            // The branch the card names is the one pushed: an omitted one is
            // read now and sent explicitly.
            var branch = arguments.argNonEmptyString("branch")
            if branch == nil {
                let status = try? await backend.gitStatus(GitStatusToolRequest(context: HostCallContext(
                    sessionID: sessionID,
                    project: project,
                    toolCallID: "",
                    approval: .notRequired,
                )))
                branch = status?.branch
            }
            var target = GitPushTarget(
                remote: arguments.argNonEmptyString("remote") ?? "origin",
                branch: branch,
                url: arguments.argNonEmptyString("url"),
            )
            // A forced push asks what the remote has first, and is one only
            // when the remote's branch would lose commits to it.
            if arguments.argBool("force_with_lease") == true {
                switch try await forcePush(target) {
                case let .force(force):
                    facts.forcePush = force
                case let .unforced(why):
                    target.unforced = why
                }
            }
            facts.push = target
        case .gitSquash:
            facts.squash = try await squashPlan(arguments)
        case .gitSetAuthor:
            facts.gitSettings = "the commit author"
        case .gitSaveCredential:
            let host = arguments.argString("host") ?? ""
            // github.com is the user's Sign In with GitHub, never a token
            // passed through the conversation; refused before anyone is asked.
            guard host.trimmingCharacters(in: .whitespaces).lowercased() != "github.com" else {
                throw ToolArgumentError("github.com takes no token here: ask the user to sign in with Sign In with GitHub in Settings ▸ Git.")
            }
            let username = arguments.argString("username") ?? ""
            facts.gitSettings = "the credential for \(host) (user \(username))"
        case .gitRemoveCredential:
            facts.gitSettings = "the credential for \(arguments.argString("host") ?? "")"
        case .gitCreateRepository:
            // Checked before anyone is asked, and again by apelin-environment;
            // the card names what is created. The visibility has no default:
            // it is the user's to choose.
            guard let visibility = arguments.argString("visibility").flatMap(GitRepositoryVisibility.init(rawValue:)) else {
                throw ToolArgumentError("Not created: visibility is public or private, as the user chose; ask them when they have not said.")
            }
            let request = try GitRepositoryCreateRequest(
                name: arguments.requireString("name").trimmingCharacters(in: .whitespaces),
                visibility: visibility,
                owner: arguments.argNonEmptyString("owner"),
                description: arguments.argNonEmptyString("description"),
            )
            if let problem = request.problem {
                throw ToolArgumentError("Not created: \(problem)")
            }
            facts.repositoryCreate = RepositoryCreateApproval(
                owner: request.owner,
                name: request.name,
                visibility: request.visibility,
                description: request.description,
            )
        case .gitCreateIssue:
            // Checked before anyone is asked, and again by apelin-environment;
            // the card names the repository and the text that is sent.
            // Apelin's own feedback is apelin_feedback_send's.
            let request = try GitIssueCreateRequest(
                repository: arguments.requireString("repository").trimmingCharacters(in: .whitespaces),
                title: arguments.requireString("title").trimmingCharacters(in: .whitespaces),
                body: arguments.requireString("body"),
            )
            if let problem = request.problem {
                throw ToolArgumentError("Nothing was posted: \(problem)")
            }
            guard request.repository.lowercased() != FeedbackRules.repository.lowercased() else {
                throw ToolArgumentError("Nothing was posted: feedback about Apelin itself goes to \(FeedbackRules.repository) with apelin_feedback_send.")
            }
            if let problem = FeedbackRules.problem(title: request.title, body: request.body) {
                throw ToolArgumentError("Nothing was posted: \(problem).")
            }
            facts.issueCreate = IssueCreateApproval(repository: request.repository, title: request.title, body: request.body)
        case .packageConfirmLoaded where arguments.argBool("respring") == true:
            // It resprings the device, so it is gated as respring is.
            facts.tool = .local(.deviceRespring)
        case .conversationCreate, .conversationSend, .conversationList, .conversationRead:
            try await gatherProjectReach(name, arguments: arguments, into: &facts)
        case .toolchainSetup:
            facts.toolchainSetup = try await setupToAsk(arguments)
        case .sdkImport:
            facts.sdkImport = try await importToAsk(arguments)
        case .projectRename:
            try await gatherRename(arguments, into: &facts)
        case .projectDelete:
            facts.projectDeletion = try await deletionToAsk(arguments)
        case .skillSave:
            facts.skillChange = try skillTools().change(saving: arguments)
        case .skillRemove:
            facts.skillChange = try skillTools().change(removing: arguments)
        case .feedbackSend:
            // Checked before anyone is asked; the card shows the text that
            // is sent, which apelin-environment checks again.
            let title = try arguments.requireString("title").trimmingCharacters(in: .whitespaces)
            let body = try arguments.requireString("body")
            if let problem = FeedbackRules.problem(title: title, body: body) {
                throw ToolArgumentError("Not sent: \(problem).")
            }
            facts.feedback = FeedbackApproval(repository: FeedbackRules.repository, title: title, body: body)
        case .feedbackEdit:
            // The issue is read again before anyone is asked: an edit made
            // against an older text, or another account's issue, is refused
            // here, and the card names the text that is sent.
            let number = try FeedbackEdit.number(arguments)
            let issue: FeedbackReadToolResponse
            do {
                issue = try await backend.readFeedback(FeedbackReadToolRequest(context: probeContext, number: number))
            } catch let failure as FeedbackToolFailure {
                throw FeedbackToolFailure(message: "Nothing was changed: " + failure.message)
            }
            facts.feedbackEdit = try FeedbackEdit.approval(for: arguments, issue: issue)
        case .packagePublish:
            // Read and checked before anyone is asked; the card names what
            // is sent, which the host and apelin-environment check again.
            let ids = try PackagePublish.buildIDs(arguments)
            let publication = try await backend.packagePublication(PackagePublicationRequest(context: probeContext, buildIDs: ids))
            facts.packagePublish = try PackagePublish.approval(for: ids, publication: publication)
        case .projectSetEnvironment:
            facts.pathCheck = check { _ = try root.resolveForWrite(ProjectEnvironmentEdit.fileName, findingGitPointers: false) }
        default:
            break
        }
        return facts
    }

    /// The project a conversation call names, resolved before asking: none
    /// (or this one) keeps the call in the session's project; another one is
    /// what the card names and where the call goes. General Chat names one,
    /// except to list: the host then lists every project's it may reach.
    private func gatherProjectReach(
        _ name: AgentToolName,
        arguments: JSONValue,
        into facts: inout InvocationFacts,
    ) async throws {
        guard let reference = arguments.argNonEmptyString("project") else {
            if project.isTemporary, name != .conversationList {
                throw ToolArgumentError("General Chat has no conversations of its own: name the project with project (its projectID or folder name; apelin_conversation_list gives each conversation's, apelin_project_list every project's)")
            }
            return
        }
        let target = try await backend.resolveProject(reference)
        guard target.id != project.id else { return }
        guard !target.isTemporary else { throw ToolDeniedError(message: "a temporary chat's conversations are the user's alone") }
        facts.targetProject = target
        let action = switch name {
        case .conversationCreate: "create"
        case .conversationSend: "send"
        case .conversationList: "list"
        default: "read"
        }
        facts.otherProject = OtherProjectApproval(
            action: action,
            projectID: target.id,
            projectName: target.name.rawValue,
            sessionID: arguments.argNonEmptyString("session_id"),
            text: name == .conversationCreate ? arguments.argString("prompt")
                : name == .conversationSend ? arguments.argString("text") : nil,
        )
    }

    /// The project a rename names, resolved before asking: this session's
    /// when none is named (General Chat has none), else the one named,
    /// whose card says what it is called now and what it becomes.
    private func gatherRename(_ arguments: JSONValue, into facts: inout InvocationFacts) async throws {
        let name = try arguments.requireString("display_name").trimmingCharacters(in: .whitespaces)
        guard ProjectDisplayName.isValid(name) else {
            throw ToolArgumentError("The name is 1 to \(ProjectDisplayName.maximumLength) characters on one line.")
        }
        let target: ProjectIdentity
        if let reference = arguments.argNonEmptyString("project") {
            target = try await backend.resolveProject(reference)
        } else if project.isTemporary {
            throw ToolArgumentError("General Chat has no project of its own: name it with project (its projectID or folder name, as apelin_project_list answers them)")
        } else {
            target = project
        }
        guard !target.isTemporary else { throw ToolDeniedError(message: "a temporary chat has no project to rename") }
        facts.renamedProject = target
        guard target.id != project.id else { return }
        if arguments.argBool("automatic") == true {
            throw ToolArgumentError("automatic naming is for this conversation's own project; rename another only when the user asks, without automatic")
        }
        let listed = try? await backend.projects().projects.first { $0.projectID == target.id }
        facts.projectRename = ProjectRenameApproval(
            projectID: target.id,
            folder: target.name.rawValue,
            currentName: listed?.displayName ?? target.name.rawValue,
            displayName: name,
        )
    }

    /// The project a deletion names, resolved before asking: another one
    /// than this session's, which it runs in, and never a temporary chat's.
    /// The card names it by its folder and the name the sidebar shows, and
    /// the host deletes that one only.
    private func deletionToAsk(_ arguments: JSONValue) async throws -> ProjectDeleteApproval {
        let target = try await backend.resolveProject(arguments.requireString("project"))
        guard !target.isTemporary else { throw ToolDeniedError(message: "a temporary chat has no project to delete") }
        guard target.id != project.id else {
            throw ToolDeniedError(message: "this conversation's own project cannot be deleted from here, since this conversation runs in it: the user deletes it in Projects ▸ All Projects…, or asks from General Chat or another project's conversation")
        }
        let listed = try? await backend.projects().projects.first { $0.projectID == target.id }
        return ProjectDeleteApproval(
            projectID: target.id,
            folder: target.name.rawValue,
            displayName: listed?.displayName ?? target.name.rawValue,
        )
    }

    /// The release a setup takes, resolved in Apple's catalog before asking:
    /// the version or product named, else the newest this device can take.
    /// One this device cannot take, or Swift where the release offers none,
    /// is refused here with the catalog's reason.
    private func setupToAsk(_ arguments: JSONValue) async throws -> ToolchainSetupApproval {
        let listed = try await backend.toolchains(context: probeContext)
        if let problem = listed.catalogProblem, listed.available.isEmpty {
            throw ToolDeniedError(message: "Apple's catalog could not be read: \(problem)")
        }
        let product: AvailableToolchain
        if let id = arguments.argNonEmptyString("product_id") {
            guard let match = listed.available.first(where: { $0.productID == id }) else {
                throw ToolArgumentError("no release \(id) in apelin_toolchain_list's available")
            }
            product = match
        } else if let version = arguments.argNonEmptyString("version") {
            guard let match = listed.available.first(where: { $0.version == version }) else {
                throw ToolArgumentError("no Command Line Tools \(version) in apelin_toolchain_list's available")
            }
            product = match
        } else {
            guard let newest = listed.available.first(where: { $0.unavailable == nil }) else {
                throw ToolDeniedError(message: "no release in Apple's catalog can be set up on this device")
            }
            product = newest
        }
        if let reason = product.unavailable {
            throw ToolDeniedError(message: "Command Line Tools \(product.version) cannot be set up here: \(reason)")
        }
        let swift = arguments.argBool("swift") ?? false
        if swift, product.swift == nil {
            throw ToolDeniedError(message: product.swiftUnavailable
                ?? "Command Line Tools \(product.version) offers no Swift on this device; set it up without Swift or choose another release")
        }
        let components = swift ? ["c", "swift"] : ["c"]
        if let installed = listed.installed.first(where: { record in
            record.version == product.version && components.allSatisfy(record.components.contains) && record.problem == nil
        }) {
            throw ToolArgumentError("Command Line Tools \(product.version) is already set up as \(installed.id); bind it with apelin_project_set_environment")
        }
        return ToolchainSetupApproval(
            productID: product.productID,
            version: product.version,
            components: components,
            sizeBytes: product.sizeBytes > 0 ? product.sizeBytes : nil,
        )
    }

    /// The source and branch an import takes, resolved before asking among
    /// what the enabled sources offer; the model never passes an address.
    private func importToAsk(_ arguments: JSONValue) async throws -> SDKImportApproval {
        let version = try arguments.requireString("version").trimmingCharacters(in: .whitespaces)
        let listed = try await backend.sdks(context: probeContext)
        if let registered = listed.installed.first(where: { $0.version == version }) {
            throw ToolArgumentError("iPhoneOS \(version) is already registered as \(registered.id); bind it with apelin_project_set_environment")
        }
        let source = arguments.argNonEmptyString("source")
        guard let offer = listed.available.first(where: {
            $0.version == version && (source == nil || $0.source == source)
        }) else {
            let problems = listed.sourceProblems.isEmpty ? "" : " (\(listed.sourceProblems.joined(separator: "; ")))"
            throw ToolArgumentError("no enabled source offers iPhoneOS \(version)\(source.map { " in \($0)" } ?? "")\(problems); apelin_sdk_list names what they offer")
        }
        return SDKImportApproval(source: offer.source, url: offer.sourceURL, branch: offer.branch, version: offer.version)
    }

    /// The installation a removal takes, found before asking: the one
    /// installation_id names, or the one Apelin can remove of the package
    /// package_id names. One the list shows as not removable, or does not
    /// show at all, is refused here, with why, so the user is never asked
    /// about a removal the host would refuse. Its row in apelin_package_list
    /// is what the card names; without the whole list the host decides.
    private func removalToAsk(_ arguments: JSONValue) async throws -> (installationID: String, listed: ListedInstallation?) {
        switch (arguments.argNonEmptyString("installation_id"), arguments.argNonEmptyString("package_id")) {
        case (nil, nil):
            throw ToolArgumentError("Give installation_id, from apelin_package_install or apelin_package_list, or package_id.")
        case (.some, .some):
            throw ToolArgumentError("Give installation_id or package_id, not both.")
        case let (installationID?, nil):
            guard let all = try? await backend.installations(InstallationListToolRequest()) else {
                return (installationID, nil)
            }
            guard let listed = all.installations.first(where: { $0.installationID == installationID }) else {
                if all.truncated {
                    return (installationID, nil)
                }
                throw ToolDeniedError(message: "Apelin has no installation \(installationID) it can remove: the package is gone, a later install replaced it, or the id is not one apelin_package_install or apelin_package_list gave." + Self.removable(in: all.installations))
            }
            guard listed.removable else {
                throw ToolDeniedError(message: Self.notRemovable(listed))
            }
            return (installationID, listed)
        case let (nil, packageID?):
            let rows = try await backend.installations(InstallationListToolRequest(packageID: packageID)).installations
            guard let row = rows.first(where: \.removable) else {
                throw ToolDeniedError(message: rows.first.map(Self.notRemovable)
                    ?? "Apelin has no installation of \(packageID) on this device: it did not install it, or the package is gone. A package installed some other way is the user's to remove with their package manager; apelin_package_list lists what Apelin installed.")
            }
            return (row.installationID, row)
        }
    }

    private static func notRemovable(_ listed: ListedInstallation) -> String {
        "Apelin cannot remove \(listed.packageID) \(listed.version) (installation \(listed.installationID)): \(listed.reason ?? "it is not removable now.")"
    }

    /// For a host's refusal of an installation id, stale or mistaken: the
    /// ones apelin_package_remove can take instead.
    func removableInstead() async -> String {
        guard let listed = try? await backend.installations(InstallationListToolRequest()).installations else { return "" }
        return Self.removable(in: listed)
    }

    private static func removable(in listed: [ListedInstallation]) -> String {
        let removable = listed.filter(\.removable)
        guard !removable.isEmpty else { return " Apelin has no installation it can remove on this device." }
        let shown = removable.prefix(10).map { row in
            "\(row.installationID) (\(row.packageID) \(row.version)\(row.project.map { ", project \($0)" } ?? ""))"
        }
        let more = removable.count > shown.count ? "; more in apelin_package_list" : ""
        return " Apelin can remove: \(shown.joined(separator: "; "))\(more)."
    }

    /// A context for reads made while gathering facts, before any approval.
    private nonisolated var probeContext: HostCallContext {
        HostCallContext(sessionID: sessionID, project: project, toolCallID: "", approval: .notRequired)
    }

    /// The project's repository for the first message's context: nil when
    /// it has none, or when the host has not answered within `seconds`,
    /// which is as long as the message waits for it.
    nonisolated func repositoryStatus(within seconds: Double) async -> GitStatusToolResponse? {
        let backend = backend
        let context = probeContext
        let answer = FirstAnswer<GitStatusToolResponse?>()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            Task { await answer.give(try? backend.gitStatus(GitStatusToolRequest(context: context))) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                answer.give(nil)
            }
        }
    }

    /// `.outside` when resolution refuses the path as leaving the project
    /// (including a symbolic link it will not write through); `.inside`
    /// otherwise — a missing file is the tool's error to report.
    private func check(_ resolve: () throws -> Void) -> InvocationFacts.PathCheck {
        do {
            try resolve()
            return .inside
        } catch let error as PathPolicyError {
            switch error {
            case let .outsideRoot(path), let .symlinkRefused(path): return .outside(path)
            case .embeddedNUL: return .outside("a path with a NUL byte")
            default: return .inside
            }
        } catch {
            return .inside
        }
    }
}

/// Resumes its continuation with the first value given, once.
private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Value, Never>?
    private var answered = false

    var continuation: CheckedContinuation<Value, Never>? {
        get { lock.withLock { waiting } }
        set { lock.withLock { waiting = newValue } }
    }

    func give(_ value: Value) {
        let continuation: CheckedContinuation<Value, Never>? = lock.withLock {
            guard !answered, let waiting else { return nil }
            answered = true
            self.waiting = nil
            return waiting
        }
        continuation?.resume(returning: value)
    }
}
