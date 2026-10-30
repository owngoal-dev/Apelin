@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

/// Talks to OpenCode Go for real. Skipped unless APELIN_LIVE_OAUTH_PATH
/// names a kwwk-format credential file with an `opencode-go` entry. The file
/// is read only through kwwk's own loader (`OAuthStore(url:)`), its entry is
/// handed to the session in memory, and nothing from it is printed or
/// written anywhere.
private enum OpenCodeGoLiveCredential {
    static var present: Bool {
        guard let path = ProcessInfo.processInfo.environment["APELIN_LIVE_OAUTH_PATH"],
              let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return root["opencode-go"] != nil
    }
}

@Suite("Live: OpenCode Go", .serialized, .enabled(if: OpenCodeGoLiveCredential.present))
struct OpenCodeGoLiveTests {
    /// Both a Chat Completions model and an Anthropic Messages model, so the
    /// session header and two of Go's wires are exercised.
    static let models = ["glm-5.2", "claude-haiku-5-5"]

    @Test(arguments: models)
    func `one tool-call round trip on each Go wire`(model: String) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["APELIN_LIVE_OAUTH_PATH"])
        let store = try OAuthStore(url: URL(fileURLWithPath: path))
        let entry = try #require(await store.credentials(for: CredentialProviderID.openCodeGo), "no opencode-go entry")
        let credentials = DeliveredCredentialSource([CredentialProviderID.openCodeGo: entry])

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
                provider: .stored(storeID: CredentialProviderID.openCodeGo, model: model),
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
            case let .error(message): errors.append(message)
            case let .finished(reason): finish = reason
            default: break
            }
            if finish != nil {
                break
            }
        }
        await session.close()

        #expect(errors.isEmpty, "\(model): \(errors)")
        #expect(finish == .completed, "\(model) did not finish")
        #expect(toolCalls.contains("file_read"), "\(model) made no tool call")
        #expect(finalText.contains(word), "\(model) did not read the word")
    }
}
