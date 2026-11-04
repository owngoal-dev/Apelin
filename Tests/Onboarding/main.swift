import ApelinCore
import ApelinProtocol
import Foundation

@main struct Tests {
    static func main() {
        let source = SDKSourceStatus(name: "Test", url: "https://example.com/sdks", enabled: true, branches: ["sdk/iPhoneOS27.1", "sdk/iPhoneOS18.5", "sdk/iPhoneOS17.4", "sdk/iPhoneOS27.0", "sdk/iPhoneOSfoo"])
        let sdks = SDKListResponse(sources: [source])
        let c = ToolchainCatalogProduct(productID: "c", version: "28.0", size: 1, newestSDK: "27", supportsSwift: false)
        let swift = ToolchainCatalogProduct(productID: "swift", version: "27.0", size: 1, newestSDK: "27", supportsSwift: true, compatibility: .init(recommendedSDK: "27.0", recommendedSwiftSDK: "27.0"))
        let refused = ToolchainCatalogProduct(productID: "refused", version: "99.0", size: 1, unsupportedReason: "No host support", newestSDK: "27", supportsSwift: true)
        let unknown = ToolchainCatalogProduct(productID: "unknown", version: "unknown", size: 1, supportsSwift: true)
        let resolve = WelcomeEnvironmentRecommendation.resolve(catalog: [refused, c, swift, unknown], status: .init(), sdks: sdks)
        precondition(resolve?.toolchain.productID == "swift", "Supported Swift pair preferred over C-only newer release")
        precondition(resolve?.sdk.version == "27.0", "Reviewed pairing preferred to unverified point update")
        precondition(resolve?.sdk.installed == false)
        precondition(WelcomeEnvironmentRecommendation.resolve(catalog: [refused], status: .init(), sdks: sdks) == nil)
        // Every release refused for one reason (roothide Bootstrap, issue
        // #35): the page says it rather than pointing at Settings.
        var bootstrap = [refused, c, swift]
        for index in bootstrap.indices {
            bootstrap[index].unsupportedReason = HostSigning.bootstrapRefusal
        }
        precondition(WelcomeEnvironmentRecommendation.resolve(catalog: bootstrap, status: .init(), sdks: sdks) == nil)
        precondition(WelcomeEnvironmentRecommendation.commonRefusal(in: bootstrap) == HostSigning.bootstrapRefusal)
        precondition(WelcomeEnvironmentRecommendation.commonRefusal(in: [refused, c]) == nil, "One release is set up")
        precondition(WelcomeEnvironmentRecommendation.commonRefusal(in: [refused, bootstrap[1]]) == nil, "Two reasons")
        precondition(WelcomeEnvironmentRecommendation.commonRefusal(in: []) == nil)
        // ...and in place of its introduction, which promises Settings can
        // install the tools later: there every release is refused too.
        precondition(WelcomeEnvironmentIntroduction(catalog: bootstrap) == .refusal(HostSigning.bootstrapRefusal))
        precondition(WelcomeEnvironmentIntroduction(catalog: [refused]) == .refusal("No host support"), "A CPU's reason too")
        precondition(WelcomeEnvironmentIntroduction(catalog: [refused, c, swift]) == .recommendation)
        precondition(WelcomeEnvironmentIntroduction(catalog: []) == .recommendation, "An empty catalog is no refusal")
        // The app reads the service's refusal in the user's language only
        // while the catalogue has it as a key, word for word.
        let catalogue = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apelin/Resources/Localizable.xcstrings")
        let strings = (try? JSONSerialization.jsonObject(with: Data(contentsOf: catalogue)) as? [String: Any])?["strings"] as? [String: Any]
        precondition(strings?[HostSigning.bootstrapRefusal] != nil, "The catalogue keys roothide Bootstrap's refusal")
        precondition(WelcomeEnvironmentRecommendation.resolve(catalog: [swift], status: .init(), sdks: .init(sources: [.init(name: "Old", url: "https://example.com", enabled: true, branches: ["sdk/iPhoneOS18.5"])])) == nil, "Swift requires matching SDK major")
        let old = ToolchainCatalogProduct(productID: "old", version: "15.3", size: 1, newestSDK: "17.4", supportsSwift: false)
        let fallback = WelcomeEnvironmentRecommendation.resolve(catalog: [old], status: .init(), sdks: sdks)
        precondition(fallback?.sdk.version == "17.4", "SDK limit respected")
        let healthy = ToolchainRecord(id: "installed", version: "27.0", components: [.init(kind: .c, selfCheckPassed: true), .init(kind: .swift, selfCheckPassed: true)], origin: "swift https://example.com")
        let installedSDK = SDKRecord(id: "sdk", canonicalName: "iPhoneOS27.0", version: "27.0", path: "/fixture")
        let installed = WelcomeEnvironmentRecommendation.resolve(catalog: [swift], status: .init(toolchains: [healthy]), sdks: .init(sdks: [installedSDK], sources: [source]))
        precondition(installed?.isInstalled == true)
        var failed = healthy
        failed.components = [.init(kind: .c, selfCheckPassed: false), .init(kind: .swift, selfCheckPassed: true)]
        let unhealthy = WelcomeEnvironmentRecommendation.resolve(catalog: [swift], status: .init(toolchains: [failed]), sdks: .init(sdks: [installedSDK]))
        precondition(unhealthy?.isInstalled == false, "Failed installation never shown ready")
        for _ in 0 ..< 100 {
            let draft = ProjectCreationDraft()
            precondition(draft.isValid && ProjectName.validate(draft.name) == nil)
            precondition(draft.automaticallyName)
        }
        var draft = ProjectCreationDraft()
        let original = draft.name
        draft.avoidExisting([original.lowercased()])
        precondition(draft.name.caseInsensitiveCompare(original) != .orderedSame)
        draft.edit("My Project")
        draft.avoidExisting(["My Project"])
        precondition(draft.name == "My Project" && !draft.automaticallyName, "User name is never replaced")
        draft.edit(original)
        precondition(!draft.automaticallyName, "Retyping the fruit is still a user choice")
        draft.edit("../unsafe")
        precondition(!draft.isValid)
        draft.edit("  Good Name  ")
        precondition(draft.isValid && draft.trimmedName == "Good Name")
        print("ok: onboarding pairing and project naming behavior")

        // Distribute… and the distribution page's targets need a build
        // description apelin-build can package, or a workspace's own script.
        let build: JSONValue = .object(["steps": .array([.object(["type": .string("compile")])])])
        let tweak: JSONValue = .object(["projectID": .string("p"), "kind": .string("tweak"), "build": build])
        precondition(ProjectBuildMethod(manifest: tweak) == .description, "A template project has one")
        for kind in ["app", "cli", "preferences"] {
            precondition(ProjectBuildMethod(manifest: .object(["kind": .string(kind), "build": build])) == .description)
        }
        let script: JSONValue = .object(["script": .string("apelin/build.sh")])
        let workspace: JSONValue = .object([
            "projectID": .string("w"), "kind": .string("workspace"), "buildSystem": .string("external"),
        ])
        precondition(ProjectBuildMethod(manifest: workspace) == .missingScript, "An empty workspace has none")
        precondition(ProjectBuildMethod(manifest: .object([
            "kind": .string("workspace"), "buildSystem": .string("external"), "external": script,
        ])) == .script, "A workspace that declares its script is built by it")
        precondition(ProjectBuildMethod(manifest: .object(["kind": .string("workspace"), "external": script])) == .script,
                     "A workspace from before buildSystem with a script")
        precondition(ProjectBuildMethod(manifest: .object(["kind": .string("workspace")])) == .missingScript,
                     "A workspace from before buildSystem has none")
        precondition(ProjectBuildMethod(manifest: .object([
            "kind": .string("workspace"), "build": build,
        ])) == .missingScript, "A workspace is built by its own tools, whatever it holds")
        precondition(ProjectBuildMethod(manifest: .object([
            "kind": .string("tweak"), "buildSystem": .string("external"), "build": build,
        ])) == .missingScript, "An external build system is not apelin-build's")
        precondition(ProjectBuildMethod(manifest: .object([
            "kind": .string("workspace"), "external": .object(["script": .string("")]),
        ])) == .missingScript, "An empty script names nothing")
        precondition(ProjectBuildMethod(manifest: .object(["kind": .string("tweak")])) == .missingDescription,
                     "A manifest without a build has nothing to build")
        precondition(ProjectBuildMethod(manifest: .object(["kind": .string("tweak"), "build": .null])) == .missingDescription)
        precondition(ProjectBuildMethod(manifest: .object(["build": build])) == .missingDescription, "No kind, no build")
        precondition(ProjectBuildMethod(manifest: .array([])) == .missingDescription)
        precondition(ProjectBuildMethod.script.canBuild && ProjectBuildMethod.description.blocker == nil)
        precondition(!ProjectBuildMethod.missingScript.canBuild && ProjectBuildMethod.missingScript.shortBlocker != nil)
        print("ok: distribution needs a build description or a workspace's script")
    }
}
