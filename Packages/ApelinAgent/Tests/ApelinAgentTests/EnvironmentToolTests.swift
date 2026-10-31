@testable import ApelinAgent
import enum ApelinProject.ProjectManifestFormat
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("toolchain and SDK tools")
struct EnvironmentToolTests {
    static let tools: [AgentToolName] = [
        .toolchainList, .sdkList, .toolchainSetup, .sdkImport, .toolchainSelfTest, .projectSetEnvironment,
    ]

    func text(_ result: AgentToolResult) -> String {
        result.content.compactMap {
            if case let .text(text) = $0 {
                text.text
            } else {
                nil
            }
        }.joined()
    }

    // MARK: Catalog

    @Test
    func `the catalog names them with their risks`() {
        #expect(Self.tools.map(\.rawValue) == [
            "apelin_toolchain_list", "apelin_sdk_list", "apelin_toolchain_setup", "apelin_sdk_import", "apelin_toolchain_self_test", "apelin_project_set_environment",
        ])
        #expect(AgentToolName.toolchainList.risk == .readOnly && AgentToolName.sdkList.risk == .readOnly)
        for tool in [AgentToolName.toolchainSetup, .sdkImport, .toolchainSelfTest] {
            #expect(tool.risk == .system, "\(tool.rawValue)")
        }
        #expect(AgentToolName.projectSetEnvironment.risk == .writeProject)
        #expect(AgentToolName.projectSetEnvironment.isProjectOnly)
        for tool in Self.tools {
            #expect(!tool.summary.isEmpty)
        }
    }

    @Test
    func `General Chat sets up the device but switches no project`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let runner = try ToolRunner(
            sessionID: UUID().uuidString,
            project: ProjectIdentity(id: "temporary:" + id, name: ProjectName(id)),
            root: ScopedRoot(home.projectURL),
            policy: ApprovalPolicy(mode: .confirm),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            gate: ApprovalGate { _ in },
        )
        let offered = Set(runner.agentTools(mcp: []).map(\.name))
        for tool in [AgentToolName.toolchainList, .sdkList, .toolchainSetup, .sdkImport, .toolchainSelfTest] {
            #expect(offered.contains(tool.rawValue), "\(tool.rawValue)")
        }
        #expect(!offered.contains("apelin_project_set_environment"))
    }

    @Test
    func `the prompt says when to reach for them`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, skills: [], mcpServers: [])
        #expect(prompt.contains("environment.* errors") && prompt.contains("apelin_project_set_environment"))
        #expect(prompt.contains("apelin_toolchain_setup or apelin_sdk_import") && prompt.contains("toolchain and SDK installs"))
    }

    // MARK: Approval

    @Test
    func `Strict reads the lists freely, asks for every install and the self-test, and lets a switch through`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let root = try ScopedRoot(home.projectURL)
        let policy = ApprovalPolicy(mode: .confirm)
        for tool in [AgentToolName.toolchainList, .sdkList] {
            #expect(policy.evaluate(InvocationFacts(tool: .local(tool)), root: root) == .allow(.preset(tool.rawValue)))
        }
        #expect(policy.evaluate(InvocationFacts(tool: .local(.projectSetEnvironment), pathCheck: .inside), root: root) == .allow(.notRequired))
        let setup = ToolchainSetupApproval(productID: "082-16", version: "16.4", components: ["c", "swift"], sizeBytes: 812_000_000)
        guard case let .ask(reason, detail) = policy.evaluate(InvocationFacts(tool: .local(.toolchainSetup), toolchainSetup: setup), root: root) else {
            Issue.record("a setup asks")
            return
        }
        #expect(detail == .toolchainSetup(setup))
        #expect(reason.contains("Command Line Tools 16.4") && reason.contains("C and Swift") && reason.contains("MB"), "\(reason)")
        let sdkImport = SDKImportApproval(source: "OwnGoal iOS SDKs", url: "https://github.com/owngoal-dev/iOS-SDKs.git", branch: "sdk/iPhoneOS17.5", version: "17.5")
        guard case let .ask(importReason, importDetail) = policy.evaluate(InvocationFacts(tool: .local(.sdkImport), sdkImport: sdkImport), root: root) else {
            Issue.record("an import asks")
            return
        }
        #expect(importDetail == .sdkImport(sdkImport) && importReason.contains("sdk/iPhoneOS17.5"))
        guard case .ask = policy.evaluate(InvocationFacts(tool: .local(.toolchainSelfTest)), root: root) else {
            Issue.record("a self-test asks")
            return
        }
        // Never for the session, whatever the card holds.
        #expect(!ToolRunner.allowsSessionScope(.local(.toolchainSetup), detail: .toolchainSetup(setup)))
        #expect(!ToolRunner.allowsSessionScope(.local(.sdkImport), detail: .sdkImport(sdkImport)))
        #expect(!ToolRunner.allowsSessionScope(.local(.toolchainSetup), detail: .none))
        #expect(ToolRunner.allowsSessionScope(.local(.toolchainSelfTest), detail: .none))
        // Presets cannot let an install through.
        let lax = ApprovalPresets(readTools: [], systemTools: [.toolchainSetup, .sdkImport], commands: [])
        guard case .ask = ApprovalPolicy(mode: .confirm, presets: lax).evaluate(InvocationFacts(tool: .local(.toolchainSetup), toolchainSetup: setup), root: root) else {
            Issue.record("a preset does not cover a setup")
            return
        }
    }

    // MARK: Running

    @Test(.timeLimit(.minutes(1)))
    func `the lists are one backend call each and ask nothing`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let (toolchains, asked) = try await harness.run(.toolchainList, [:])
        let (sdks, askedToo) = try await harness.run(.sdkList, [:])
        #expect(asked.isEmpty && askedToo.isEmpty)
        #expect(text(toolchains).contains("082-15") && text(sdks).contains("sdk/iPhoneOS17.5"))
        #expect(await harness.backend.calls == [.toolchains, .sdks])
    }

    @Test(.timeLimit(.minutes(1)))
    func `a setup resolves the release, asks naming it and its size, and sends it by product id`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let (result, asked) = try await harness.run(.toolchainSetup, ["version": "15.3", "swift": true])
        #expect(asked.count == 1)
        #expect(asked.first?.tool == "apelin_toolchain_setup" && asked.first?.allowsSessionScope == false)
        #expect(asked.first?.detail == .toolchainSetup(ToolchainSetupApproval(productID: "082-15", version: "15.3", components: ["c", "swift"], sizeBytes: 700_000_000)))
        #expect(asked.first?.reason.contains("700") == true, "\(asked.first?.reason ?? "")")
        #expect(text(result).contains("\"succeeded\" : true"))
        let calls = await harness.backend.calls
        #expect(calls.last == .toolchainSetup(productID: "082-15", components: ["c", "swift"], evidence: .user(requestID: asked[0].id, fingerprint: asked[0].fingerprint)))

        // Omitted: the newest this device can take — 16.4, not 27.0 — which
        // is set up already.
        do {
            _ = try await harness.run(.toolchainSetup, [:])
            Issue.record("16.4 is set up already")
        } catch let error as ToolArgumentError {
            #expect(error.message.contains("16.4") && error.message.contains("clt-16.4-c"), "\(error.message)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a setup this device cannot take, or one already done, is refused before asking`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await #expect(throws: ToolDeniedError.self) { _ = try await harness.run(.toolchainSetup, ["version": "27.0"]) }
        await #expect(throws: ToolDeniedError.self) { _ = try await harness.run(.toolchainSetup, ["version": "16.4", "swift": true]) }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.toolchainSetup, ["version": "16.4"]) }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.toolchainSetup, ["version": "9.9"]) }
        #expect(await harness.backend.calls.allSatisfy { $0 == .toolchains }, "nothing was set up")
        #expect(await harness.events.events.isEmpty, "and nothing asked")
    }

    @Test(.timeLimit(.minutes(1)))
    func `an import takes an offered branch of an enabled source, never an address the model wrote`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let (_, asked) = try await harness.run(.sdkImport, ["version": "17.5", "url": "https://evil.example/sdk.git"])
        #expect(asked.count == 1 && asked.first?.allowsSessionScope == false)
        let sent = await harness.backend.calls.last
        #expect(sent == .sdkImport(
            url: "https://github.com/owngoal-dev/iOS-SDKs.git",
            branch: "sdk/iPhoneOS17.5",
            evidence: .user(requestID: asked[0].id, fingerprint: asked[0].fingerprint),
        ))
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.sdkImport, ["version": "18.2"]) }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.sdkImport, ["version": "16.0"]) }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a declined install does not run`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await #expect(throws: ToolDeniedError.self) {
            _ = try await harness.run(.sdkImport, ["version": "17.5"], answering: .deny(reason: nil))
        }
        #expect(await !harness.backend.calls.contains {
            if case .sdkImport = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func `Relaxed sets up without asking`() async throws {
        let harness = try DigestApprovalTests.Harness(mode: .relaxed)
        defer { harness.home.remove() }
        let (_, asked) = try await harness.run(.toolchainSetup, ["version": "15.3"])
        #expect(asked.isEmpty)
        #expect(await harness.backend.calls.last == .toolchainSetup(productID: "082-15", components: ["c"], evidence: .relaxed))
    }

    // MARK: Switching

    static let manifest = """
    {
      "schemaVersion": 1,
      "projectID": "p",
      "environment": {
        "toolchain": { "id": "clt-16.4-c", "digest": "sha256:old-toolchain" },
        "sdk": { "id": "iPhoneOS18.2-aaaaaaaa", "digest": "sha256:old-sdk" }
      },
      "language": "objc",
      "package": { "id": "local.apelin.hello", "description": "sdk \\"quoted\\" — ünïcode" }
    }

    """

    @Test(.timeLimit(.minutes(1)))
    func `a switch is checked, then written with the registry's digests and nothing else changed`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest)
        let (result, asked) = try await harness.run(.projectSetEnvironment, ["sdk_id": "iPhoneOS17.5-bbbbbbbb"])
        #expect(asked.isEmpty, "a switch is a project edit")
        #expect(await harness.backend.calls == [.checkEnvironment(toolchainID: nil, sdkID: "iPhoneOS17.5-bbbbbbbb")])
        let written = try harness.home.read("apelin-project.json")
        #expect(written == """
        {
          "schemaVersion": 1,
          "projectID": "p",
          "environment": {
            "toolchain": {
              "id": "clt-16.4-c",
              "digest": "sha256:clt-16.4-c"
            },
            "sdk": {
              "id": "iPhoneOS17.5-bbbbbbbb",
              "digest": "sha256:iPhoneOS17.5-bbbbbbbb"
            }
          },
          "language": "objc",
          "package": {
            "id": "local.apelin.hello",
            "description": "sdk \\"quoted\\" — ünïcode"
          }
        }

        """, "the four strings, then the file in the written form")
        #expect(text(result).contains("\"changed\" : [\n    \"toolchain\",\n    \"sdk\"\n  ]"), "\(text(result))")
    }

    @Test(.timeLimit(.minutes(1)))
    func `an SDK newer than the toolchain reads is refused with the check's reason, and nothing is written`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        try harness.home.write("apelin-project.json", Self.manifest)
        let reason = "toolchain clt-16.4-c (Command Line Tools 16.4) supports iPhoneOS SDKs up to 18.5; SDK 27.0 is outside that supported range"
        await harness.backend.setFindings([
            EnvironmentDiagnostic(code: "environment.sdk.tooNewForToolchain", severity: "error", message: reason),
        ], forSDK: "iPhoneOS27.0-cccccccc")
        do {
            _ = try await harness.run(.projectSetEnvironment, ["sdk_id": "iPhoneOS27.0-cccccccc"])
            Issue.record("the switch is refused")
        } catch let refusal as ToolDeniedError {
            #expect(refusal.message.contains(reason))
        }
        #expect(try harness.home.read("apelin-project.json") == Self.manifest)
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.projectSetEnvironment, [:]) }
    }

    @Test
    func `the rewrite changes those four strings alone, writes the written form and refuses a manifest it cannot read`() throws {
        let toolchain = ComponentBinding(id: "clt-15.3-c-swift", digest: "sha256:t")
        let sdk = ComponentBinding(id: "iPhoneOS17.5-bbbbbbbb", digest: "sha256:s")
        let edited = try ProjectEnvironmentEdit.rebind(Data(Self.manifest.utf8), toolchain: toolchain, sdk: sdk)
        #expect(edited.changed == ["toolchain", "sdk"])
        #expect(ProjectManifestFormat.formatted(edited.data) == edited.data)
        let same = try ProjectEnvironmentEdit.rebind(edited.data, toolchain: toolchain, sdk: sdk)
        #expect(same.changed.isEmpty && same.data == edited.data)
        // The same document on one line comes out the same.
        let oneLine = #"{"schemaVersion":1,"projectID":"p","environment":{"toolchain":{"id":"clt-16.4-c","digest":"sha256:old-toolchain"},"sdk":{"id":"iPhoneOS18.2-aaaaaaaa","digest":"sha256:old-sdk"}},"language":"objc","package":{"id":"local.apelin.hello","description":"sdk \"quoted\" — ünïcode"}}"#
        #expect(try ProjectEnvironmentEdit.rebind(Data(oneLine.utf8), toolchain: toolchain, sdk: sdk).data == edited.data)
        // One the strict reader refuses is written as the edit left it.
        let lenient = #"{"schemaVersion": 1.0, "environment": {"toolchain": {"id": "a", "digest": "b"}, "sdk": {"id": "c", "digest": "d"}}}"#
        let spliced = #"{"schemaVersion": 1.0, "environment": {"toolchain": {"id": "clt-15.3-c-swift", "digest": "sha256:t"}, "sdk": {"id": "iPhoneOS17.5-bbbbbbbb", "digest": "sha256:s"}}}"#
        #expect(try ProjectEnvironmentEdit.rebind(Data(lenient.utf8), toolchain: toolchain, sdk: sdk).data == Data(spliced.utf8))
        #expect(throws: ToolArgumentError.self) {
            try ProjectEnvironmentEdit.rebind(Data(#"{"environment": {"toolchain": {"id": "a"}}}"#.utf8), toolchain: toolchain, sdk: sdk)
        }
        #expect(throws: ToolArgumentError.self) {
            try ProjectEnvironmentEdit.rebind(Data(#"{"environment": "#.utf8), toolchain: toolchain, sdk: sdk)
        }
        let twice = #"{"environment":{"toolchain":{"id":"a","digest":"b"},"sdk":{"id":"c","digest":"d"},"sdk":{"id":"e","digest":"f"}}}"#
        #expect(throws: ToolArgumentError.self) {
            try ProjectEnvironmentEdit.rebind(Data(twice.utf8), toolchain: toolchain, sdk: sdk)
        }
    }
}
