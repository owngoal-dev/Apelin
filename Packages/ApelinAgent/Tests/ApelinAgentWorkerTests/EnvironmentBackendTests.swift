import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("ChannelHostBackend's toolchain, SDK and other-project calls")
struct EnvironmentBackendTests {
    static let manifest = """
    {"projectID": "6f1c5b0e-0000-4000-8000-000000000001", "environment": {"toolchain": {"id": "clt-16.4-c", "digest": "sha256:1"}, "sdk": {"id": "iPhoneOS18.2-aaaaaaaa", "digest": "sha256:2"}}}
    """

    static func toolchain(_ id: String, version: String, newestSDK: String?, productID: String) -> ToolchainRecord {
        ToolchainRecord(
            id: id,
            version: version,
            components: [ToolchainComponent(kind: .c, selfCheckPassed: true), ToolchainComponent(kind: .swift, selfCheckPassed: false)],
            selfTests: [
                ToolchainSelfTestResult(language: "c", architecture: "arm64", passed: true),
                ToolchainSelfTestResult(language: "swift", architecture: "arm64e", passed: false, detail: "dyld: missing symbol"),
            ],
            origin: "\(productID) https://swcdn.apple.com/x.pkg",
            newestSDK: newestSDK,
            selfTestSDK: "18.2",
        )
    }

    @Test
    func `apelin_toolchain_list carries each release's requirements and this project's binding`() async throws {
        let fixture = try Fixture(manifest: Self.manifest)
        fixture.host.on(.toolchainStatus, reply: ToolchainStatusResponse(
            toolchains: [Self.toolchain("clt-16.4-c", version: "16.4", newestSDK: "18.5", productID: "082-16")],
            defaultID: "clt-16.4-c",
        ))
        fixture.host.on(.toolchainCatalog, reply: ToolchainCatalogResponse(products: [
            ToolchainCatalogProduct(
                productID: "082-27",
                version: "27.0",
                size: 900,
                unsupportedReason: "This toolchain requires iOS 26.0 or later.",
                newestSDK: "27",
                supportsSwift: false,
                compatibility: ToolchainCompatibility(minimumHost: "26.0", cpuFeatures: ["FEAT_LRCPC", "FEAT_SHA3"], recommendedSDK: "27.0"),
            ),
            ToolchainCatalogProduct(
                productID: "082-16",
                version: "16.4",
                size: 800,
                newestSDK: "18.5",
                supportsSwift: true,
                swiftRequirements: SwiftToolchainRequirements(version: "6.1.2", minimumHost: "17.3.1", cpuFeatures: []),
            ),
        ]))
        let list = try await fixture.backend.toolchains(context: fixture.context())
        #expect(list.project == ProjectEnvironmentSummary(toolchainID: "clt-16.4-c", sdkID: "iPhoneOS18.2-aaaaaaaa"))
        let installed = try #require(list.installed.first)
        #expect(installed.components == ["c"], "a component counts once its self-check passed")
        #expect(installed.selfTests == "1 of 2 passed against iPhoneOS 18.2" && installed.isDefault && installed.boundByThisProject)
        // Registered before the retarget scheme was recorded: scheme 2, without otool-classic and ranlib.
        #expect(installed.outdated == InstalledToolchain.earlierRetargetNote && installed.problem == nil)
        var current = Self.toolchain("clt-16.4-c", version: "16.4", newestSDK: "18.5", productID: "082-16")
        current.retargetScheme = ToolchainRecord.currentRetargetScheme
        #expect(ChannelHostBackend.installed(current, defaultID: nil, boundID: nil).outdated == nil)
        #expect(list.available.map(\.productID) == ["082-27", "082-16"])
        let newest = list.available[0]
        #expect(newest.unavailable == "This toolchain requires iOS 26.0 or later." && newest.minimumIOS == "26.0")
        #expect(newest.cpuFeatures == ["FEAT_LRCPC", "FEAT_SHA3"] && newest.recommendedSDK == "27.0" && newest.sizeBytes == 900)
        #expect(list.available[1].swift == "Swift 6.1.2" && list.available[1].installedAs == ["clt-16.4-c"])
    }

    @Test
    func `apelin_toolchain_list still answers when Apple's catalog cannot be read`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.toolchainStatus, reply: ToolchainStatusResponse())
        fixture.host.on(.toolchainCatalog) { _ in throw ApelinError(.unavailable, "offline") }
        let list = try await fixture.backend.toolchains(context: fixture.context())
        #expect(list.catalogProblem == "offline" && list.available.isEmpty && list.project == nil)
    }

    @Test
    func `apelin_sdk_list offers the enabled sources' branches not yet registered, with the toolchains that read each`() async throws {
        let fixture = try Fixture(manifest: Self.manifest)
        fixture.host.on(.sdkList) { request in
            let asked = try request.decode(SDKListRequest.self)
            #expect(asked.includeSources == true && asked.readSources == true)
            return (SDKListResponse(
                sdks: [SDKRecord(id: "iPhoneOS18.2-aaaaaaaa", canonicalName: "iPhoneOS18.2", version: "18.2", path: "/x")],
                sources: [
                    SDKSourceStatus(name: "OwnGoal iOS SDKs", url: "https://github.com/owngoal-dev/iOS-SDKs.git", enabled: true, branches: ["sdk/iPhoneOS17.5", "sdk/iPhoneOS18.2", "sdk/iPhoneOS27.0", "sdk/notes"]),
                    SDKSourceStatus(name: "Off", url: "https://example.com/x.git", enabled: false, branches: ["sdk/iPhoneOS16.0"]),
                    SDKSourceStatus(name: "Broken", url: "https://example.com/y.git", enabled: true, problem: "timed out"),
                ],
            ), [])
        }
        fixture.host.on(.toolchainStatus, reply: ToolchainStatusResponse(toolchains: [
            Self.toolchain("clt-16.4-c", version: "16.4", newestSDK: "18.5", productID: "082-16"),
        ]))
        let list = try await fixture.backend.sdks(context: fixture.context())
        #expect(list.installed.first?.boundByThisProject == true && list.installed.first?.readBy == ["clt-16.4-c"])
        #expect(list.available.map(\.version) == ["27.0", "17.5"], "newest first, the registered one and other branches left out")
        #expect(list.available.first { $0.version == "27.0" }?.readBy == [], "16.4 reads up to 18.5")
        #expect(list.available.first { $0.version == "17.5" }?.sourceURL == "https://github.com/owngoal-dev/iOS-SDKs.git")
        #expect(list.sourceProblems == ["Broken: timed out"])
    }

    @Test
    func `apelin_toolchain_setup starts the named catalog product and reads its task to the end, keeping only the stages`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.toolchainSetup, reply: TaskHandle(taskID: TaskID("setup-task"), kind: .environment))
        try fixture.host.on(.environmentAttach, reply: batch("setup-task", [
            ("stage", .object(["stage": .string("downloading")])),
            ("progress", .object(["stage": .string("downloading"), "completed": .number(1)])),
            ("progress", .object(["stage": .string("downloading"), "completed": .number(2)])),
            ("stage", .object(["stage": .string("installing")])),
            ("install.irisin", .object(["message": .string("…")])),
            ("warning", .object(["message": .string("1 of 2 self-test cases failed")])),
            ("result", .object(["toolchain": ApelinCore.JSONValue(encoding: Self.toolchain("clt-15.3-c-swift", version: "15.3", newestSDK: "17.4", productID: "082-15"))])),
            stateEvent(.succeeded),
        ]))
        let result = try await fixture.backend.toolchainSetup(ToolchainSetupToolRequest(context: fixture.context(), productID: "082-15", components: ["c", "swift"]))
        let sent = try #require(fixture.host.requests(ToolchainSetupRequest.self).first)
        #expect(sent.source == .appleCatalog(productID: "082-15") && sent.components == [.c, .swift])
        #expect(fixture.host.requests.map(\.operation) == [.toolchainSetup, .environmentAttach])
        #expect(result.succeeded && result.stages == ["downloading", "installing"])
        #expect(result.toolchain?.id == "clt-15.3-c-swift" && result.failedTests == ["The swift self-test failed on arm64e.\ndyld: missing symbol"])
        #expect(result.warnings == ["1 of 2 self-test cases failed"] && result.message == nil)
    }

    @Test
    func `a setup the host stopped says the next one goes on from it`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.toolchainSetup, reply: TaskHandle(taskID: TaskID("setup-task"), kind: .environment))
        try fixture.host.on(.environmentAttach, reply: batch("setup-task", [stateEvent(.interrupted, "The agent session has ended.")]))
        let result = try await fixture.backend.toolchainSetup(ToolchainSetupToolRequest(context: fixture.context(), productID: "082-15", components: ["c"]))
        #expect(!result.succeeded && result.message?.contains("goes on from it") == true)
    }

    @Test
    func `apelin_sdk_import imports the source's branch and reads its task`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.sdkImport, reply: TaskHandle(taskID: TaskID("import-task"), kind: .environment))
        try fixture.host.on(.environmentAttach, reply: batch("import-task", [
            ("stage", .object(["stage": .string("fetching")])),
            ("result", .object(["sdk": ApelinCore.JSONValue(encoding: SDKRecord(id: "iPhoneOS17.5-bbbbbbbb", canonicalName: "iPhoneOS17.5", version: "17.5", path: "/x"))])),
            stateEvent(.succeeded),
        ]))
        let result = try await fixture.backend.sdkImport(SDKImportToolRequest(context: fixture.context(), url: "https://github.com/owngoal-dev/iOS-SDKs.git", branch: "sdk/iPhoneOS17.5"))
        #expect(fixture.host.requests(SDKImportRequest.self).first?.source == .repository(url: "https://github.com/owngoal-dev/iOS-SDKs.git", branch: "sdk/iPhoneOS17.5"))
        #expect(result.succeeded && result.sdk?.id == "iPhoneOS17.5-bbbbbbbb" && result.stages == ["fetching"])
    }

    @Test
    func `a switch is checked by projectCheck with the candidate, its environment findings and the registry's binding`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.projectCheck) { request in
            let check = try request.decode(ProjectCheckRequest.self)
            #expect(check.projectID == "6f1c5b0e-0000-4000-8000-000000000001")
            #expect(check.environment == ProjectEnvironmentChoice(toolchainID: nil, sdkID: "iPhoneOS27.0-cccccccc"))
            return (ProjectCheckResponse(
                passed: false,
                diagnostics: [
                    ProjectDiagnostic(code: "environment.sdk.tooNewForToolchain", severity: .error, message: "supports iPhoneOS SDKs up to 18.5"),
                    ProjectDiagnostic(code: "project.file.missing", severity: .error, message: "Sources/x.m"),
                ],
                environment: ProjectEnvironmentBinding(
                    toolchain: ProjectComponentBinding(id: "clt-16.4-c", digest: "sha256:1"),
                    sdk: ProjectComponentBinding(id: "iPhoneOS27.0-cccccccc", digest: "sha256:3"),
                ),
            ), [])
        }
        let checked = try await fixture.backend.checkEnvironment(EnvironmentCheckToolRequest(context: fixture.context(), toolchainID: nil, sdkID: "iPhoneOS27.0-cccccccc"))
        #expect(checked.sdk == ComponentBinding(id: "iPhoneOS27.0-cccccccc", digest: "sha256:3"))
        #expect(checked.diagnostics == [EnvironmentDiagnostic(code: "environment.sdk.tooNewForToolchain", severity: "error", message: "supports iPhoneOS SDKs up to 18.5")], "only the environment's findings decide a switch")
    }

    @Test
    func `a switch on a description apelin_project_create never wrote says it is none, and what builds a workspace`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.projectCheck, reply: ProjectCheckResponse(passed: false, diagnostics: [
            ProjectDiagnostic(code: "project.invalid", severity: .error, message: "missing template", file: "apelin-project.json", field: "/"),
            ProjectDiagnostic(code: "project.invalid", severity: .error, message: "missing environment", file: "apelin-project.json", field: "/"),
        ]))
        let request = EnvironmentCheckToolRequest(context: fixture.context(), toolchainID: nil, sdkID: "iPhoneOS27.0-cccccccc")
        let failure = await #expect(throws: EnvironmentToolFailure.self) { _ = try await fixture.backend.checkEnvironment(request) }
        let message = failure?.message ?? ""
        #expect(message.contains("(/: missing template; /: missing environment)"), "\(message)")
        #expect(message.contains("not an Apelin build description") && message.contains("apelin-external-build"), "\(message)")

        fixture.host.on(.projectCheck, reply: ProjectCheckResponse(passed: false, diagnostics: [
            ProjectDiagnostic(code: "project.invalid", severity: .error, message: "unknown member", file: "apelin-project.json", field: "/configurations/Debug/linkerFlags"),
        ]))
        let misspelled = await #expect(throws: EnvironmentToolFailure.self) { _ = try await fixture.backend.checkEnvironment(request) }
        #expect(misspelled?.message.contains("(/configurations/Debug/linkerFlags: unknown member)") == true)
        #expect(misspelled?.message.contains("apelin-project.schema.json") == true)
        #expect(misspelled?.message.contains("not an Apelin build description") == false)
    }

    @Test
    func `another project is opened, listed and read by its id, resolved from its folder`() async throws {
        let fixture = try Fixture()
        let far = fixture.projectURL.deletingLastPathComponent().appendingPathComponent("Far", isDirectory: true)
        try FileManager.default.createDirectory(at: far, withIntermediateDirectories: true)
        try #"{"projectID": "far-id"}"#.write(to: far.appendingPathComponent("apelin-project.json"), atomically: true, encoding: .utf8)
        let byName = try await fixture.backend.resolveProject("Far")
        let byID = try await fixture.backend.resolveProject("far-id")
        #expect(byName == byID && byName.id == "far-id" && byName.name.rawValue == "Far")
        await #expect(throws: ConversationToolFailure.self) { _ = try await fixture.backend.resolveProject("../Far") }
        await #expect(throws: ConversationToolFailure.self) { _ = try await fixture.backend.resolveProject("Nowhere") }

        fixture.host.on(.agentOpen, reply: AgentOpenResponse(sessionID: "child", task: TaskHandle(taskID: TaskID("t"), kind: .agent)))
        let opened = try await fixture.backend.conversationCreate(ConversationCreateToolRequest(context: fixture.context(), prompt: "Build it", target: byName))
        let open = try #require(fixture.host.requests(AgentOpenRequest.self).first)
        #expect(open.projectID == "far-id" && open.projectName == "Far")
        #expect(opened.link == "apelin://conversation/child" && opened.projectLink == "apelin://project/far-id" && opened.project == "Far")
        fixture.host.on(.agentList, reply: AgentListResponse(sessions: []))
        _ = try await fixture.backend.conversationList(ConversationListToolRequest(context: fixture.context(), target: byName))
        #expect(fixture.host.requests(AgentListRequest.self).last?.projectID == "far-id")
        let own = try await fixture.backend.conversationList(ConversationListToolRequest(context: fixture.context()))
        #expect(own.conversations.isEmpty && fixture.host.requests(AgentListRequest.self).last?.projectID == nil)
    }

    @Test
    func `the approval events carry what the host matches a setup, an import and another project's call to`() {
        func detail(_ value: ApelinAgent.ApprovalDetail) -> ApelinCore.JSONValue? {
            EventRelay.approvalPayload(ApprovalRequest(
                id: "a",
                toolCallID: "c",
                tool: "t",
                arguments: "{}",
                workingDirectory: ".",
                projectID: "p",
                fingerprint: "f",
                reason: "r",
                detail: value,
                allowsSessionScope: false,
            ))["detail"]
        }
        let setup = detail(.toolchainSetup(ToolchainSetupApproval(productID: "082-15", version: "15.3", components: ["c", "swift"], sizeBytes: 7)))
        #expect(setup?["toolchainSetup"]?["productID"]?.stringValue == "082-15")
        #expect(setup?["toolchainSetup"]?["components"] == .array([.string("c"), .string("swift")]))
        let sdk = detail(.sdkImport(SDKImportApproval(source: "S", url: "https://h/r.git", branch: "sdk/iPhoneOS17.5", version: "17.5")))
        #expect(sdk?["sdkImport"]?["url"]?.stringValue == "https://h/r.git" && sdk?["sdkImport"]?["branch"]?.stringValue == "sdk/iPhoneOS17.5")
        let reach = detail(.otherProject(OtherProjectApproval(action: "send", projectID: "far-id", projectName: "Far", sessionID: "s", text: "go")))
        #expect(reach?["otherProject"]?["action"]?.stringValue == "send" && reach?["otherProject"]?["projectID"]?.stringValue == "far-id")
        #expect(reach?["otherProject"]?["sessionID"]?.stringValue == "s" && reach?["otherProject"]?["text"]?.stringValue == "go")
        let build = detail(.externalBuild(ExternalBuildApproval(projectID: "w", script: "apelin/build.sh", configuration: "debug", bootstrap: nil)))
        #expect(build?["externalBuild"]?["projectID"]?.stringValue == "w" && build?["externalBuild"]?["configuration"]?.stringValue == "debug")
        #expect(build?["externalBuild"]?["bootstrap"] == nil, "no bootstrap named, none written: the host matches it to none")
    }
}
