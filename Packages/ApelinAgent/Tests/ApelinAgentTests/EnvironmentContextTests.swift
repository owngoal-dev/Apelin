@testable import ApelinAgent
import Darwin
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// What the model is told about the device before it does anything: the
/// environment in the system prompt, the same for every prompt while it
/// does not change, and the project's description and file tree once, with
/// the first message.
@Suite("Environment and project context")
struct EnvironmentContextTests {
    static let toolchainID = "clt-27.0-c-swift-2-0123abcd"
    static let sdkID = "iphoneos27.0-1a2b3c4d"
    static let olderSDKID = "iphoneos17.0-5e6f7a8b"

    /// A registered toolchain and two SDKs in the home's data folder, the
    /// way apelin-environment writes them, and a project bound to them.
    /// Answers the canonical tool and SDK folders.
    @discardableResult
    static func register(in home: TemporaryHome, deploymentTarget: String = "15.0") throws -> (bin: String, sdk: String) {
        let manager = FileManager.default
        let toolchain = home.home.appendingPathComponent("jb/usr/lib/apelin/toolchains/\(toolchainID)")
        try manager.createDirectory(at: toolchain.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
        let sdk = home.dataRoot.url.appendingPathComponent("SDKs/\(sdkID)")
        let older = home.dataRoot.url.appendingPathComponent("SDKs/\(olderSDKID)")
        let registry = home.dataRoot.url.appendingPathComponent("SDKs/.registry")
        for folder in [sdk, older, registry] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let toolchains = home.dataRoot.url.appendingPathComponent("Environment/Toolchains")
        try manager.createDirectory(at: toolchains, withIntermediateDirectories: true)
        try """
        {"defaultID":"\(toolchainID)","toolchains":[{"id":"\(toolchainID)","version":"27.0","retargetScheme":3,
        "components":[{"kind":"c","selfCheckPassed":true},{"kind":"swift","selfCheckPassed":true}],
        "path":"\(toolchain.path)","contentDigest":"abc","installationID":"secret-installation-id",
        "selfTests":[{"language":"C","architecture":"arm64","passed":true,"detail":"","seconds":1.25},
        {"language":"Swift","architecture":"arm64e","passed":true,"detail":"","seconds":31.5}],
        "newestSDK":"27","selfTestSDK":"27.0",
        "swiftRequirements":{"version":"6.4","minimumHost":"26.0","cpuFeatures":["FEAT_SHA3","FEAT_DotProd"]},
        "compatibility":{"revision":1,"sourceProductIDs":[],"hostArchitecture":"arm64","minimumHost":"16.0",
        "cpuFeatures":["FEAT_LRCPC"],"recommendedSDK":"27.0","verifiedSDKs":[],"verifiedSwiftSDKs":[],
        "swiftVerifiedHosts":[],"staticInstructionFeatures":[],"notes":[]}}]}
        """.write(to: toolchains.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)
        for (id, version, path) in [(sdkID, "27.0", sdk.path), (olderSDKID, "17.0", older.path)] {
            try """
            {"id":"\(id)","canonicalName":"\(id.prefix(12))","version":"\(version)","path":"\(path)",
            "targets":["arm64e-ios"],"warnings":[],"digest":"1a2b"}
            """.write(to: registry.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
        }
        try home.write("apelin-project.json", """
        {"schemaVersion":1,"projectID":"\(home.project.id)","kind":"tweak","language":"objc",
        "deploymentTarget":"\(deploymentTarget)",
        "template":{"extensionID":"wiki.qaq.apelin.dev.tweak","templateID":"tweak","version":"1.0.0","digest":"x"},
        "environment":{"toolchain":{"id":"\(toolchainID)","digest":"sha256:abc"},
        "sdk":{"id":"\(sdkID)","digest":"sha256:1a2b"}},
        "architectures":{"rootless":["arm64","arm64e"],"roothide":["arm64e"]},
        "products":[{"id":"Tweak","type":"dylib","name":"Tweak","sources":["Sources/*.x"]}],
        "build":{"steps":[{"compile":{"product":"Tweak"}},{"link":{"product":"Tweak"}}]},
        "package":{"id":"local.apelin.hello","version":"0.0.1"}}
        """)
        return (canonical(toolchain.path + "/usr/bin"), canonical(sdk.path))
    }

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The system prompt and the user messages' text of every model call.
    actor Calls {
        var systemPrompts: [String] = []
        var userTexts: [[String]] = []

        func add(_ context: Context) {
            systemPrompts.append(context.systemPrompt ?? "")
            userTexts.append(context.messages.compactMap { message -> String? in
                guard case let .user(user) = message else { return nil }
                return user.content.compactMap { block -> String? in
                    if case let .text(content) = block {
                        return content.text
                    }
                    return nil
                }.joined()
            })
        }
    }

    static func recording(_ faux: FauxProviderRegistration, _ calls: Calls, replies: Int) {
        faux.setResponses((0 ..< replies).map { index in
            .factory { context, _, _, _ in
                await calls.add(context)
                return fauxAssistantMessage("Reply \(index).")
            }
        })
    }

    static func session(
        _ home: TemporaryHome,
        _ faux: FauxProviderRegistration,
        id: String = UUID().uuidString,
        project: ProjectIdentity? = nil,
        temporaryID: String? = nil,
    ) async throws -> AgentSession {
        try await AgentSession(
            configuration: AgentSessionConfiguration(
                id: id,
                project: project ?? home.project,
                temporaryID: temporaryID,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
    }

    // MARK: The environment

    @Test(.timeLimit(.minutes(1)))
    func `the system prompt names the device, toolchains and SDKs, says shell_run is prepared, and does not change between prompts`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let (bin, sdk) = try Self.register(in: home)
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let calls = Calls()
        Self.recording(faux, calls, replies: 2)
        let session = try await Self.session(home, faux)
        try await session.prompt("build it", messageID: UUID())
        await session.waitForIdle()
        try await session.prompt("and again", messageID: UUID())
        await session.waitForIdle()
        await session.close()

        let prompts = await calls.systemPrompts
        #expect(prompts.count == 2)
        #expect(prompts.first == prompts.last, "the environment adds nothing that changes between prompts")
        let prompt = try #require(prompts.first)
        #expect(prompt.contains("# Environment"))
        #expect(prompt.contains("- Device: "))
        #expect(prompt.contains("  - \(Self.toolchainID): Command Line Tools 27.0; C, C++, Objective-C, Swift 6.4; runs on iOS 16.0+ (Swift on 26.0+); reads SDKs up to 27; self-test 2/2 passed against SDK 27.0. Default, this project's, prepared. Tools: \(bin)"))
        #expect(prompt.contains("  - \(Self.sdkID): iOS 27.0 at "))
        #expect(prompt.contains("This project's, prepared."))
        #expect(prompt.contains("  - \(Self.olderSDKID): iOS 17.0 at "))
        let newer = try #require(prompt.range(of: Self.sdkID)), older = try #require(prompt.range(of: Self.olderSDKID))
        #expect(newer.lowerBound < older.lowerBound, "SDKs are listed newest first")
        #expect(prompt.contains("IPHONEOS_DEPLOYMENT_TARGET=15.0 (this project's deployment target)"))
        #expect(prompt.contains("swiftc takes the SDK too but needs -target arm64-apple-ios15.0"))
        #expect(prompt.contains("never set up or import again a toolchain or SDK listed here"))
        #expect(!prompt.contains("secret-installation-id") && !prompt.contains("31.5"), "no record field that is not needed, no duration")
        #expect(!sdk.isEmpty)
    }

    // MARK: The project's context

    @Test(.timeLimit(.minutes(1)))
    func `the first message carries the project and its tree once, and a reopened session does not repeat it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try Self.register(in: home)
        try home.write("Sources/Tweak.x", "%hook SpringBoard\n%end\n")
        try home.write("Resources/Info.plist", "<plist/>")
        try home.write(".gitignore", "build/\n*.log\n!keep.log\n")
        try home.write("build/out.o", "")
        try home.write("debug.log", "")
        try home.write("keep.log", "")
        try home.write("Sources/.gitignore", "/generated.m\n")
        try home.write("Sources/generated.m", "")
        try home.write("Builds/stale.deb", "")
        try home.write(".git/HEAD", "ref: refs/heads/main\n")
        try home.write(".git/refs/heads/main", "0123456789abcdef0123456789abcdef01234567\n")
        try home.write(".git/config", "[core]\n")
        try FileManager.default.createSymbolicLink(atPath: home.projectURL.appendingPathComponent("outside").path, withDestinationPath: "/etc")
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let calls = Calls()
        Self.recording(faux, calls, replies: 3)
        let id = UUID().uuidString
        var session = try await Self.session(home, faux, id: id)
        try await session.prompt("hello", messageID: UUID())
        await session.waitForIdle()
        try await session.prompt("next", messageID: UUID())
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        await session.close()

        session = try await Self.session(home, faux, id: id)
        try await session.prompt("after reopening", messageID: UUID())
        await session.waitForIdle()
        await session.close()

        let texts = await calls.userTexts
        #expect(texts.count == 3)
        let first = try #require(texts.first?.first)
        #expect(first.hasPrefix("<project-context>\n"))
        #expect(first.contains("</project-context>\n\n<system-state>\n"), "the moment follows the context")
        #expect(first.hasSuffix("</system-state>\n\nhello"), "the user's words follow both")
        #expect(first.contains("Project Hello (id \(home.project.id))"))
        #expect(first.contains("- Kind: tweak; Objective-C; deployment target 15.0; architectures roothide arm64e, rootless arm64 arm64e"))
        #expect(first.contains("- Template: wiki.qaq.apelin.dev.tweak tweak 1.0.0"))
        #expect(first.contains("- Build: Apelin's build tool, 2 steps; products Tweak (dylib)"))
        #expect(first.contains("- Package: local.apelin.hello 0.0.1"))
        #expect(first.contains("- Git: on branch main at abc123; nothing to commit."), "as the host's git status answered")
        let tree = first.components(separatedBy: "\n")
        for line in ["Sources/", "  Tweak.x", "Resources/", "  Info.plist", "apelin-project.json", ".gitignore", "keep.log", "outside@"] {
            #expect(tree.contains(line), "the tree lists \(line)")
        }
        for name in ["out.o", "debug.log", "generated.m", "stale.deb", "HEAD", "hosts"] {
            #expect(!first.contains(name), "the tree leaves out \(name)")
        }
        #expect(!tree.contains(".git/") && !tree.contains("build/") && !tree.contains("Builds/"))
        for call in texts {
            #expect(call.joined().components(separatedBy: "<project-context>").count == 2, "the context is in the conversation exactly once")
        }
        let typed = "</system-state>\n\n"
        #expect(texts[1].last?.hasSuffix(typed + "next") == true && texts[2].last?.hasSuffix(typed + "after reopening") == true, "later messages are as typed, after their own moment")
        #expect(texts[2].count == 3 && texts[2][1] == texts[1].last, "a reopened session reads every earlier run back as it went, not just the last")
        let shown = events.compactMap { event -> String? in
            if case let .userMessage(_, text, _) = event {
                return text
            }
            return nil
        }
        #expect(shown == ["hello", "next"], "the app is shown the messages as typed")
    }

    @Test(.timeLimit(.minutes(1)))
    func `a project of thousands of files is listed to the cap, breadth first`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        for folder in 0 ..< 30 {
            for file in 0 ..< 100 {
                try home.write("Module\(folder)/Sub/File\(file).c", "")
            }
        }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let calls = Calls()
        Self.recording(faux, calls, replies: 1)
        let session = try await Self.session(home, faux)
        try await session.prompt("hi", messageID: UUID())
        await session.waitForIdle()
        await session.close()
        let first = try #require(await calls.userTexts.first?.first)
        let lines = first.components(separatedBy: "\n")
        let entries = lines.filter { $0.hasPrefix("Module") || $0.hasPrefix("  ") }
        #expect(entries.count <= 200 + 30, "at most the cap, and a … line per folder cut short")
        #expect(lines.filter { $0.hasPrefix("Module") }.count == 30, "every top-level folder is listed before anything deeper")
        #expect(first.contains("(The listing stops at 200 entries; list or find shows the rest.)"))
        #expect(first.utf8.count < 16 * 1024)
    }

    @Test(.timeLimit(.minutes(1)))
    func `General Chat's first message carries no project context`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let folder = home.dataRoot.url.appendingPathComponent("Temporary/" + id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let calls = Calls()
        Self.recording(faux, calls, replies: 1)
        let session = try await Self.session(home, faux, project: ProjectIdentity(id: "temporary:" + id, name: ProjectName(id)), temporaryID: id)
        try await session.prompt("hi", messageID: UUID())
        await session.waitForIdle()
        await session.close()
        let first = try #require(await calls.userTexts.first)
        #expect(first.count == 1 && first[0].hasPrefix("<system-state>\n") && first[0].hasSuffix("</system-state>\n\nhi"))
        #expect(!first[0].contains("<project-context>"))
        #expect(await calls.systemPrompts.first?.contains("# Environment") == true)
    }
}
