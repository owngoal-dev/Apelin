import ApelinCore
import ApelinProtocol
import Darwin
import Foundation
import XCTest

/// Every typed `ApelinService` method, called once against a fake transport.
///
/// `row(for:)` switches over `AppOperation` with no default, so an operation
/// added without a method and a row here does not compile; the test then
/// checks each method sends its own operation, with a payload that decodes
/// as that operation's request type, and the descriptors it promises.
final class ServiceTableTests: XCTestCase {
    private struct Row {
        /// What the fake answers: a value of the operation's response type.
        var reply: any Encodable
        var call: (ApelinService) async throws -> Void
        /// Descriptors the method sends beside the request.
        var descriptors = 0
    }

    private static let handle = TaskHandle(taskID: TaskID("task"), kind: .build)
    private static let batch = TaskEventBatch(taskID: TaskID("task"), events: [], state: .running, lastSeq: .start, finished: false)
    private static let version = FileVersion(device: 1, inode: 2, size: 3, modified: 4)
    private static let slot = DescriptorSlot(index: 0)

    private func row(for operation: AppOperation) -> Row {
        let handle = Self.handle
        let batch = Self.batch
        let ack = Acknowledged()
        let id = TaskID("task")
        switch operation {
        case .hello:
            return Row(reply: HelloResponse(installRoot: "/var/jb")) { _ = try await $0.hello() }
        case .toolchainStatus:
            return Row(reply: ToolchainStatusResponse()) { _ = try await $0.toolchainStatus() }
        case .toolchainCatalog:
            return Row(reply: ToolchainCatalogResponse()) { _ = try await $0.toolchainCatalog() }
        case .toolchainSetup:
            return Row(reply: handle) { _ = try await $0.toolchainSetup(ToolchainSetupRequest()) }
        case .toolchainRemove:
            return Row(reply: handle) { _ = try await $0.toolchainRemove(id: "toolchain") }
        case .toolchainSetDefault:
            return Row(reply: ack) { try await $0.toolchainSetDefault(id: "toolchain") }
        case .toolchainSelfTest:
            return Row(reply: handle) { _ = try await $0.toolchainSelfTest(id: "toolchain") }
        case .sdkList:
            return Row(reply: SDKListResponse()) { _ = try await $0.sdkList(includeSources: true) }
        case .sdkImport:
            return Row(reply: handle) { _ = try await $0.sdkImport(.inbox(path: "iPhoneOS.sdk")) }
        case .sdkRemove:
            return Row(reply: ack) { try await $0.sdkRemove(id: "sdk") }
        case .environmentAttach:
            return Row(reply: batch) { _ = try await $0.environmentAttach(EnvironmentAttachRequest(taskID: id)) }
        case .environmentCancel:
            return Row(reply: ack) { try await $0.environmentCancel(taskID: id) }
        case .extensionList:
            return Row(reply: ExtensionListResponse()) { _ = try await $0.extensionList() }
        case .projectCreate:
            return Row(reply: ProjectCreateResponse(projectID: "p", name: "Hello", path: "/p")) {
                _ = try await $0.projectCreate(ProjectCreateRequest(templateID: "wiki.qaq.apelin.dev.tweak/objc-hook", name: "Hello"))
            }
        case .projectCheck:
            return Row(reply: ProjectCheckResponse(passed: true)) { _ = try await $0.projectCheck(projectID: "p") }
        case .projectRename:
            return Row(reply: ProjectRenameResponse(projectID: "p", displayName: "Hello", changed: true)) { _ = try await $0.projectRename(.init(projectID: "p", displayName: "Hello")) }
        case .projectDelete:
            return Row(reply: ProjectDeleteResponse(projectID: "p", projectName: "Hello")) { _ = try await $0.projectDelete(.init(projectID: "p")) }
        case .buildStart:
            return Row(reply: handle) { _ = try await $0.buildStart(projectID: "p") }
        case .buildAttach:
            return Row(reply: batch) { _ = try await $0.buildAttach(BuildAttachRequest(taskID: id)) }
        case .buildCancel:
            return Row(reply: ack) { try await $0.buildCancel(taskID: id) }
        case .installPackage:
            return Row(reply: handle) { _ = try await $0.installPackage(artifactID: "a", digest: String(repeating: "0", count: 64)) }
        case .removePackage:
            return Row(reply: handle) { _ = try await $0.removePackage(installationID: "i") }
        case .installationList:
            return Row(reply: InstallationListResponse(installations: [])) {
                _ = try await $0.installationList(packageID: "local.apelin.hello")
            }
        case .respring:
            return Row(reply: ack) { try await $0.respring() }
        case .approvalDigestState:
            return Row(reply: ApprovalDigestStateResponse(baseline: .matchesTemplate, templateDigest: nil, lastApprovedDigest: nil)) {
                _ = try await $0.approvalDigestState(projectID: "p", kind: .build, digest: "sha256:00")
            }
        case .fileRead:
            return Row(reply: FileReadResponse(descriptor: Self.slot, version: Self.version, path: "/p/f")) {
                _ = try await $0.fileRead(scopeID: "p", relativePath: "f")
            }
        case .protectedEditOpen:
            return Row(reply: ProtectedEditOpenResponse(grantID: "g", expiresIn: 60, descriptor: Self.slot, path: "/etc/f", version: Self.version)) {
                _ = try await $0.protectedEditOpen(path: "/etc/f")
            }
        case .protectedEditCommit:
            return Row(reply: ProtectedEditCommitResponse(version: Self.version, backupID: "b"), call: { service in
                let contents = OwnedDescriptor(adopting: open("/dev/null", O_RDONLY))
                _ = try await service.protectedEditCommit(grantID: "g", contents: contents, expectedVersion: Self.version)
            }, descriptors: 1)
        case .ptyOpen:
            return Row(reply: PtyOpenResponse(sessionID: "s", task: TaskHandle(taskID: id, kind: .terminal))) { _ = try await $0.ptyOpen() }
        case .ptyAttach:
            return Row(reply: batch) { _ = try await $0.ptyAttach(taskID: id) }
        case .ptyResize:
            return Row(reply: ack) { try await $0.ptyResize(sessionID: "s", columns: 100, rows: 30) }
        case .ptyClose:
            return Row(reply: ack) { try await $0.ptyClose(sessionID: "s") }
        case .logStream:
            return Row(reply: batch) { _ = try await $0.logStream(LogStreamRequest(filter: LogFilter(windowSeconds: 5))) }
        case .crashList:
            return Row(reply: CrashListResponse()) { _ = try await $0.crashList(process: "SpringBoard") }
        case .crashOpen:
            return Row(reply: CrashOpenResponse(descriptor: Self.slot, size: 0)) { _ = try await $0.crashOpen(id: "c") }
        case .crashSymbolicate:
            return Row(reply: CrashSymbolicateResponse(id: "c", process: "SpringBoard")) { _ = try await $0.crashSymbolicate(id: "c", projectID: "p") }
        case .confirmLoaded:
            return Row(reply: TaskHandle(taskID: id, kind: .confirmLoaded)) {
                _ = try await $0.confirmLoadedStart(ConfirmLoadedRequest(buildID: "b", targetID: "com.apple.springboard", trigger: .respring))
            }
        case .confirmLoadedAttach:
            return Row(reply: batch) { _ = try await $0.confirmLoadedAttach(ConfirmLoadedAttachRequest(taskID: id)) }
        case .captureScreen:
            return Row(reply: CaptureScreenResponse(image: Self.slot, width: 1, height: 1)) { _ = try await $0.captureScreen() }
        case .readUITree:
            return Row(reply: ReadUITreeResponse(tree: .object([:]))) { _ = try await $0.readUITree() }
        case .uiAction:
            return Row(reply: UIActionResponse()) { _ = try await $0.uiAction(.tap(x: 1, y: 2)) }
        case .agentOpen:
            return Row(reply: AgentOpenResponse(sessionID: "s", task: TaskHandle(taskID: id, kind: .agent))) {
                _ = try await $0.agentOpen(AgentOpenRequest(projectName: "Hello"))
            }
        case .agentPrompt:
            return Row(reply: ack) { try await $0.agentPrompt(sessionID: "s", text: "hi") }
        case .agentSteer:
            return Row(reply: ack) { try await $0.agentSteer(sessionID: "s", text: "stop") }
        case .agentAbort:
            return Row(reply: ack) { try await $0.agentAbort(sessionID: "s") }
        case .agentCompact:
            return Row(reply: ack) { try await $0.agentCompact(sessionID: "s") }
        case .agentApprove:
            return Row(reply: ack) { try await $0.agentApprove(sessionID: "s", approvalID: "a", decision: .deny) }
        case .agentAttach:
            return Row(reply: batch) { _ = try await $0.agentAttach(AgentAttachRequest(taskID: id)) }
        case .agentList:
            return Row(reply: AgentListResponse()) { _ = try await $0.agentList() }
        case .agentClose:
            return Row(reply: ack) { try await $0.agentClose(sessionID: "s") }
        case .agentRunCode:
            return Row(reply: AgentRunCodeResponse(exitCode: 0, stdout: "", stderr: "")) {
                _ = try await $0.agentRunCode(AgentRunCodeRequest(sessionID: "s", spec: .argv(["true"]), approval: .relaxed))
            }
        case .agentCredentialImport:
            return Row(reply: AgentCredentialImportResponse()) { _ = try await $0.agentCredentialImport() }
        case .agentAccountList:
            return Row(reply: AgentAccountListResponse(accounts: [
                AgentAccount(provider: .githubCopilot, method: .deviceCode, signedIn: true),
            ])) { _ = try await $0.agentAccountList() }
        case .agentSkillList:
            return Row(reply: AgentSkillListResponse(skills: [
                AgentSkill(name: "example", description: "An example.", source: .builtIn, body: "Do it."),
            ])) { _ = try await $0.agentSkillList() }
        case .agentSignIn:
            return Row(reply: TaskHandle(taskID: id, kind: .signIn)) { _ = try await $0.agentSignIn(provider: .githubCopilot) }
        case .agentAPIConfiguration:
            return Row(reply: AgentAPIConfigurationResponse(values: [:])) { _ = try await $0.agentAPIConfiguration(provider: .anthropic) }
        case .agentModelList:
            return Row(reply: AgentModelListResponse(models: ["example"])) { _ = try await $0.agentModelList(provider: .anthropic) }
        case .agentModelActivate:
            return Row(reply: TaskHandle(taskID: id, kind: .signIn)) { _ = try await $0.agentModelActivate(provider: .anthropic, models: ["example"]) }
        case .agentSignInRespond:
            return Row(reply: ack) { try await $0.agentSignInRespond(taskID: id, fields: [.apiKey: "key"]) }
        case .agentSignInCancel:
            return Row(reply: ack) { try await $0.agentSignInCancel(taskID: id) }
        case .agentSignOut:
            return Row(reply: ack) { try await $0.agentSignOut(provider: .anthropic) }
        case .distributionRepositoryList:
            return Row(reply: DistributionRepositoryListResponse()) { _ = try await $0.distributionRepositoryList() }
        case .distributionRepositoryCreate:
            return Row(reply: handle) { _ = try await $0.distributionRepositoryCreate(name: "packages") }
        case .distributionRepositoryLink:
            return Row(reply: handle) { _ = try await $0.distributionRepositoryLink(fullName: "someone/packages") }
        case .distributionRepositoryUnlink:
            return Row(reply: ack) { try await $0.distributionRepositoryUnlink() }
        case .distributionPublish:
            return Row(reply: handle) { _ = try await $0.distributionPublish(files: ["/tmp/a.deb"]) }
        case .feedbackSend:
            return Row(reply: FeedbackSendResponse(number: 1, url: "https://github.com/owngoal-dev/Apelin/issues/1")) {
                _ = try await $0.feedbackSend(title: "t", body: "b")
            }
        case .feedbackRead:
            let issue = FeedbackReadResponse(
                number: 1, url: "https://github.com/owngoal-dev/Apelin/issues/1", title: "t", body: "b",
                footer: nil, author: "someone", state: "open", isAuthor: true,
            )
            return Row(reply: issue) { _ = try await $0.feedbackRead(number: 1) }
        case .feedbackEdit:
            return Row(reply: FeedbackEditResponse(number: 1, url: "https://github.com/owngoal-dev/Apelin/issues/1", title: "t", body: "c")) {
                _ = try await $0.feedbackEdit(FeedbackEditRequest(number: 1, title: nil, body: "c", expectedTitle: "t", expectedBody: "b"))
            }
        case .feedbackStarState:
            return Row(reply: FeedbackStarResponse(repository: "owngoal-dev/Apelin", starred: false)) {
                _ = try await $0.feedbackStarState()
            }
        case .feedbackStar:
            return Row(reply: FeedbackStarResponse(repository: "owngoal-dev/Apelin", starred: true)) {
                _ = try await $0.feedbackStar()
            }
        case .transferExport:
            return Row(reply: handle) { _ = try await $0.transferExport(kind: .sdk, id: "sdk", createdBy: "Apelin") }
        case .transferInspect:
            let summary = TransferSummary(formatVersion: 1, kind: .sdk, id: "sdk", name: "iPhoneOS 99.0", createdBy: "Apelin", created: Date(timeIntervalSince1970: 0), fileCount: 0, payloadBytes: 0)
            return Row(reply: TransferInspection(summary: summary, fileSize: 1, importable: true), call: {
                _ = try await $0.transferInspect(.file(Self.slot), fileName: "x.apesdk", descriptors: [OwnedDescriptor(adopting: open("/dev/null", O_RDONLY))])
            }, descriptors: 1)
        case .transferImport:
            return Row(reply: handle, call: {
                _ = try await $0.transferImport(TransferImportRequest(source: .file(Self.slot), fileName: "x.apesdk"), descriptors: [OwnedDescriptor(adopting: open("/dev/null", O_RDONLY))])
            }, descriptors: 1)
        case .toolHostOpen:
            return Row(reply: ToolHostOpenResponse(sessionID: "s")) { _ = try await $0.toolHostOpen(id: "wiki.qaq.apelin.tools.disassembler") }
        case .toolHostClose:
            return Row(reply: ack) { try await $0.toolHostClose(sessionID: "s") }
        case .toolHostCall:
            return Row(reply: ToolHostCallResponse(text: "")) { _ = try await $0.toolHostCall(ToolHostCallRequest(sessionID: "s", tool: "t")) }
        case .gitStatus:
            return Row(reply: GitStatusResponse()) { _ = try await $0.gitStatus(projectID: "p") }
        case .gitDiff:
            return Row(reply: GitDiffResponse(diff: "")) { _ = try await $0.gitDiff(projectID: "p", staged: true) }
        case .gitStage:
            return Row(reply: ack) { try await $0.gitStage(projectID: "p", paths: ["f"]) }
        case .gitUnstage:
            return Row(reply: ack) { try await $0.gitUnstage(projectID: "p", paths: ["f"]) }
        case .gitCommit:
            return Row(reply: GitCommitResponse(commitID: "c")) { _ = try await $0.gitCommit(GitCommitRequest(projectID: "p", message: "m")) }
        case .gitInit:
            return Row(reply: GitInitResponse(branch: "main")) { _ = try await $0.gitInit(projectID: "p") }
        case .gitClone:
            return Row(reply: handle) { _ = try await $0.gitClone(url: "https://example.com/r.git", branch: "main", projectName: "R") }
        case .gitCloneInto:
            return Row(reply: handle) { _ = try await $0.gitCloneInto(GitCloneIntoRequest(projectID: "p", url: "https://example.com/r.git")) }
        case .gitFetch:
            return Row(reply: handle) { _ = try await $0.gitFetch(projectID: "p") }
        case .gitPull:
            return Row(reply: handle) { _ = try await $0.gitPull(projectID: "p") }
        case .gitPush:
            return Row(reply: handle) { _ = try await $0.gitPush(GitPushRequest(projectID: "p")) }
        case .gitSettings:
            return Row(reply: GitSettingsResponse()) { _ = try await $0.gitSettings() }
        case .gitAuthorSet:
            return Row(reply: ack) { try await $0.gitAuthorSet(name: "n", email: "e@example.com") }
        case .gitCredentialSet:
            return Row(reply: ack) { try await $0.gitCredentialSet(GitCredentialSetRequest(host: "example.com", username: "u", token: "t")) }
        case .gitCredentialRemove:
            return Row(reply: ack) { try await $0.gitCredentialRemove(host: "example.com") }
        case .gitRepositoryCreate:
            let created = GitRepositoryCreateResponse(
                fullName: "u/r",
                cloneURL: "https://github.com/u/r.git",
                url: "https://github.com/u/r",
            )
            return Row(reply: created) { _ = try await $0.gitRepositoryCreate(GitRepositoryCreateRequest(name: "r", visibility: .private)) }
        case .gitIssueCreate:
            return Row(reply: GitIssueCreateResponse(number: 1, url: "https://github.com/u/r/issues/1", repository: "u/r")) {
                _ = try await $0.gitIssueCreate(repository: "u/r", title: "t", body: "b")
            }
        case .gitSquash:
            let squashed = GitSquashResponse(branch: "main", previousHead: "h", base: "b", commits: [], count: 2)
            return Row(reply: squashed) { _ = try await $0.gitSquash(GitSquashRequest(projectID: "p", count: 2, preview: true)) }
        case .gitRemoteList:
            return Row(reply: GitRemoteListResponse(remotes: [])) { _ = try await $0.gitRemoteList(projectID: "p") }
        case .gitRemoteSet:
            let set = GitRemoteSetResponse(remote: GitRemoteSummary(name: "origin", url: "https://example.com/r.git"))
            return Row(reply: set) { _ = try await $0.gitRemoteSet(projectID: "p", name: "origin", url: "https://example.com/r.git") }
        case .gitRemoteRemove:
            return Row(reply: ack) { try await $0.gitRemoteRemove(projectID: "p", name: "origin") }
        }
    }

    func testEveryOperationHasATypedMethodThatSendsIt() async throws {
        for operation in AppOperation.allCases {
            let row = row(for: operation)
            let fake = FakeTransport()
            fake.reply(operation, with: row.reply)
            do {
                try await row.call(ApelinService(transport: fake))
            } catch {
                XCTFail("\(operation.rawValue): \(error)")
                continue
            }
            let calls = fake.calls
            XCTAssertEqual(calls.map(\.operation), [operation], "\(operation.rawValue) sent \(calls.map(\.operation.rawValue))")
            guard let call = calls.first else { continue }
            XCTAssertEqual(call.descriptorCount, row.descriptors, "\(operation.rawValue) descriptors")
            XCTAssertNoThrow(try Self.decode(operation.requestType, call.payload), "\(operation.rawValue) payload")
        }
    }

    /// Every kind of task is read through its own attach, and a reattach
    /// asks only for what it has not seen.
    func testEventsAttachThroughEachKindsOperation() async throws {
        for kind in [TaskKind.environment, .build, .install, .agent, .terminal, .logStream, .signIn] {
            let fake = FakeTransport()
            fake.task("t", events: [.log(1, "one"), .log(2, "two"), .state(3, .succeeded)], state: .succeeded)
            let service = ApelinService(transport: fake)
            var seen: [UInt64] = []
            for try await event in service.events(of: TaskHandle(taskID: TaskID("t"), kind: kind), afterSeq: EventSeq(1)) {
                seen.append(event.seq.rawValue)
            }
            XCTAssertEqual(seen, [2, 3], "\(kind)")
            XCTAssertEqual(fake.operations, [kind.attachOperation], "\(kind)")
            XCTAssertEqual(fake.calls.first?.payload["afterSeq"], .number(1), "\(kind)")
        }
    }

    /// A reply that is an error comes back as that `ApelinError`.
    func testErrorsComeBackTyped() async {
        let fake = FakeTransport()
        fake.fail(.sdkRemove, ApelinError(.notFound, "no such SDK"))
        do {
            try await ApelinService(transport: fake).sdkRemove(id: "x")
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? ApelinError, ApelinError(.notFound, "no such SDK"))
        }
    }

    private static func decode<R: OperationRequest>(_: R.Type, _ payload: JSONValue) throws {
        _ = try payload.decode(R.self)
    }
}
