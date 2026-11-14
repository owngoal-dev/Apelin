@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

/// Talks to GitHub Copilot for real. Skipped unless APELIN_LIVE_OAUTH_PATH
/// names a kwwk-format credential file with a `github-copilot` entry. The
/// file is read only through kwwk's own loader (`OAuthStore(url:)`), its
/// entry is handed to the session in memory, and nothing from it is printed
/// or written anywhere.
@Suite("Live: Copilot", .enabled(if: ProcessInfo.processInfo.environment["APELIN_LIVE_OAUTH_PATH"] != nil))
struct CopilotLiveTests {
    static let model = "claude-sonnet-5.5"

    @Test(.timeLimit(.minutes(3)))
    func `one tool-call round trip with Claude Sonnet 5.5 through Copilot`() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["APELIN_LIVE_OAUTH_PATH"])
        let store = try OAuthStore(url: URL(fileURLWithPath: path))
        let entry = try #require(await store.credentials(for: CredentialProviderID.githubCopilot), "no github-copilot entry")
        let credentials = DeliveredCredentialSource([CredentialProviderID.githubCopilot: entry])

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let dataRoot = ApelinDataRoot(home: home)
        let project = try ProjectIdentity(id: "live", name: ProjectName("Live"))
        let projectURL = dataRoot.project(named: project.name)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let word = "pelican-\(Int.random(in: 1000 ... 9999))"
        try "\(word)\n".write(to: projectURL.appendingPathComponent("secret-word.txt"), atomically: true, encoding: .utf8)

        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: project,
                provider: .githubCopilot(model: Self.model),
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: dataRoot,
                maxTurns: 4,
            ),
            backend: NoHostBackend(),
            digests: NoDigests(),
            credentials: credentials,
        )
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("Use the file_read tool to read secret-word.txt, then reply with only the word it contains.")

        var toolCalls: [String] = []
        var finalText = ""
        var errors: [String] = []
        var finish: FinishReason?
        for await record in stream {
            switch record.event {
            case let .toolCallStarted(call): toolCalls.append(call.name)
            case let .messageFinished(text): if !text.isEmpty {
                    finalText = text
                }
            case let .error(message, _): errors.append(message)
            case let .finished(reason): finish = reason
            default: break
            }
            if finish != nil {
                break
            }
        }
        await session.close()

        #expect(errors.isEmpty, "\(errors)")
        #expect(finish == .completed)
        #expect(toolCalls.contains("file_read"))
        #expect(finalText.contains(word))
    }
}

/// The live test needs no host capability; any call is a failure.
struct NoHostBackend: AgentHostBackend {
    struct Unexpected: Error {}
    func runCode(_: RunCodeRequest) async throws -> RunCodeResponse {
        throw Unexpected()
    }

    func build(_: BuildRequest) async throws -> BuildResponse {
        throw Unexpected()
    }

    func install(_: InstallRequest) async throws -> InstallResponse {
        throw Unexpected()
    }

    func removePackage(_: RemovePackageRequest) async throws -> RemovePackageResponse {
        throw Unexpected()
    }

    func respring(_: RespringRequest) async throws -> RespringResponse {
        throw Unexpected()
    }

    func confirmLoaded(_: ConfirmLoadedRequest) async throws -> ConfirmLoadedResponse {
        throw Unexpected()
    }

    func readLogs(_: ReadLogsRequest) async throws -> ReadLogsResponse {
        throw Unexpected()
    }

    func listCrashes(_: ListCrashesRequest) async throws -> ListCrashesResponse {
        throw Unexpected()
    }

    func readCrash(_: ReadCrashRequest) async throws -> ReadCrashResponse {
        throw Unexpected()
    }

    func symbolicateCrash(_: SymbolicateCrashRequest) async throws -> SymbolicateCrashResponse {
        throw Unexpected()
    }

    func captureScreen(_: CaptureScreenRequest) async throws -> CaptureScreenResponse {
        throw Unexpected()
    }

    func readUITree(_: ReadUITreeRequest) async throws -> ReadUITreeResponse {
        throw Unexpected()
    }

    func uiAction(_: UIActionRequest) async throws -> UIActionResponse {
        throw Unexpected()
    }

    func registeredSDK(_: RegisteredSDKRequest) async throws -> RegisteredSDKResponse {
        throw Unexpected()
    }

    func checkDistribution(_: DistributionCheckRequest) async throws -> DistributionCheckResponse {
        throw Unexpected()
    }

    func projectTemplates() async throws -> ProjectTemplateListResponse {
        throw Unexpected()
    }

    func createProject(_: ProjectCreateToolRequest) async throws -> ProjectCreateToolResponse {
        throw Unexpected()
    }

    func gitStatus(_: GitStatusToolRequest) async throws -> GitStatusToolResponse {
        throw Unexpected()
    }

    func gitDiff(_: GitDiffToolRequest) async throws -> GitDiffToolResponse {
        throw Unexpected()
    }

    func gitStage(_: GitPathsToolRequest) async throws -> GitPathsToolResponse {
        throw Unexpected()
    }

    func gitUnstage(_: GitPathsToolRequest) async throws -> GitPathsToolResponse {
        throw Unexpected()
    }

    func gitCommit(_: GitCommitToolRequest) async throws -> GitCommitToolResponse {
        throw Unexpected()
    }

    func gitInit(_: GitInitToolRequest) async throws -> GitInitToolResponse {
        throw Unexpected()
    }

    func gitFetch(_: GitRemoteToolRequest) async throws -> GitTaskToolResponse {
        throw Unexpected()
    }

    func gitPull(_: GitRemoteToolRequest) async throws -> GitTaskToolResponse {
        throw Unexpected()
    }

    func gitPush(_: GitRemoteToolRequest) async throws -> GitTaskToolResponse {
        throw Unexpected()
    }

    func gitClone(_: GitCloneToolRequest) async throws -> GitTaskToolResponse {
        throw Unexpected()
    }

    func gitSettings(context _: HostCallContext) async throws -> GitSettingsToolResponse {
        throw Unexpected()
    }

    func gitSetAuthor(_: GitAuthorToolRequest) async throws -> GitSettingsToolResponse {
        throw Unexpected()
    }

    func gitSaveCredential(_: GitCredentialToolRequest) async throws -> GitSettingsToolResponse {
        throw Unexpected()
    }

    func gitRemoveCredential(_: GitCredentialRemoveToolRequest) async throws -> GitSettingsToolResponse {
        throw Unexpected()
    }

    func conversationCreate(_: ConversationCreateToolRequest) async throws -> ConversationCreateToolResponse {
        throw Unexpected()
    }

    func conversationSend(_: ConversationSendToolRequest) async throws -> ConversationActionToolResponse {
        throw Unexpected()
    }

    func conversationList(_: ConversationListToolRequest) async throws -> ConversationListToolResponse {
        throw Unexpected()
    }

    func conversationRead(_: ConversationReadToolRequest) async throws -> ConversationReadToolResponse {
        throw Unexpected()
    }

    func conversationStop(_: ConversationStopToolRequest) async throws -> ConversationActionToolResponse {
        throw Unexpected()
    }
}

struct NoDigests: ApprovalDigestStore {
    func state(of _: DescriptionKind, for _: ProjectIdentity) async throws -> DescriptionState {
        DescriptionState(digest: "", baseline: .changed(diff: ""))
    }
}
