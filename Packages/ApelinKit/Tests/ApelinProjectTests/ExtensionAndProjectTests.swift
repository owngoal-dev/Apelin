import ApelinCore
@testable import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

/// The shipped extensions through the scanner, projects created from every
/// template and compared byte for byte with the reference implementation's
/// `instantiate`, the creation rules, and projectCheck.
final class ExtensionAndProjectTests: XCTestCase {
    func testShippedExtensionsAreUsable() throws {
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        // The repository folder also holds Packaging/, which no package
        // installs; the scanner sets it aside like any folder without a manifest.
        XCTAssertEqual(catalog.extensions.map(\.folderName).sorted(), [
            "Packaging", "wiki.qaq.apelin.dev.app", "wiki.qaq.apelin.dev.cli", "wiki.qaq.apelin.dev.preferences", "wiki.qaq.apelin.dev.tweak",
        ])
        XCTAssertFalse(try XCTUnwrap(catalog.extensions.first { $0.folderName == "Packaging" }?.isUsable))
        for item in catalog.extensions where item.folderName != "Packaging" {
            XCTAssertEqual(item.problems, [], item.folderName)
        }
        XCTAssertNotNil(catalog.template("wiki.qaq.apelin.dev.tweak/objc-hook"))
        XCTAssertNil(catalog.template("wiki.qaq.apelin.dev.tweak/nope"))
    }

    /// A bad manifest isolates only itself; a duplicate id isolates both.
    func testIsolation() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tweak = Repository.extensions.appendingPathComponent("wiki.qaq.apelin.dev.tweak")
        try FileManager.default.copyItem(at: tweak, to: scratch.appendingPathComponent("wiki.qaq.apelin.dev.tweak"))
        try FileManager.default.copyItem(at: Repository.extensions.appendingPathComponent("wiki.qaq.apelin.dev.cli"), to: scratch.appendingPathComponent("wiki.qaq.apelin.dev.cli"))
        // a copy under another folder name claims the same id
        try FileManager.default.copyItem(at: tweak, to: scratch.appendingPathComponent("com.example.copy"))
        // broken JSON
        let broken = scratch.appendingPathComponent("com.example.broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent("manifest.json"))
        // an undeclared template file
        let cli = scratch.appendingPathComponent("wiki.qaq.apelin.dev.cli")
        try Data("x".utf8).write(to: cli.appendingPathComponent("templates/c/Sources/extra.c"))

        let catalog = ExtensionCatalog(directory: scratch)
        let byName = Dictionary(uniqueKeysWithValues: catalog.extensions.map { ($0.folderName, $0) })
        XCTAssertFalse(try XCTUnwrap(byName["com.example.broken"]?.isUsable))
        XCTAssertTrue(try XCTUnwrap(byName["wiki.qaq.apelin.dev.cli"]?.problems.contains { $0.contains("extra.c is not listed") }))
        XCTAssertTrue(try XCTUnwrap(byName["wiki.qaq.apelin.dev.tweak"]?.problems.contains { $0.contains("both are set aside") }))
        XCTAssertTrue(try XCTUnwrap(byName["com.example.copy"]?.problems.contains { $0.contains("differs from the folder name") }))
        XCTAssertTrue(catalog.usable.isEmpty)
    }

    func testStaleDigestAndSymlinkIsolate() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("wiki.qaq.apelin.dev.tweak")
        try FileManager.default.copyItem(at: Repository.extensions.appendingPathComponent("wiki.qaq.apelin.dev.tweak"), to: root)
        let source = root.appendingPathComponent("templates/objc-hook/Sources/Tweak.m")
        try (String(contentsOf: source, encoding: .utf8) + "\n// edited\n").write(to: source, atomically: true, encoding: .utf8)
        XCTAssertTrue(ExtensionCatalog(directory: scratch).extensions[0].problems.contains { $0.contains("digest is") })
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "/etc/hosts")
        XCTAssertTrue(ExtensionCatalog(directory: scratch).extensions[0].problems.contains { $0.contains("is a symbolic link") })
    }

    /// Every template, made by both implementations with the same values:
    /// the same files, byte for byte, and the same digests.
    func testCreationMatchesTheReferenceImplementation() throws {
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        for item in catalog.usable {
            let manifest = try XCTUnwrap(item.manifest)
            for template in manifest.templates {
                let scratch = try scratchDirectory()
                defer { try? FileManager.default.removeItem(at: scratch) }
                let home = scratch.appendingPathComponent("home")
                try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents/wiki.qaq.apelin"), withIntermediateDirectories: true)
                let store = ProjectStore(dataFolder: DataFolder(home: home.path))
                let projectID = "00000000-0000-4000-8000-000000000001"
                let name = "Sample \(template.id)"
                let created = try store.create(templateID: "\(manifest.id)/\(template.id)", name: name, values: [
                    "packageID": .string("com.example.sample"), "bundleID": .string("com.example.sample"),
                ], catalog: catalog, registry: sampleRegistry(), projectID: projectID)
                XCTAssertEqual(created.root.lastPathComponent, name)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.projectsDirectory.path), [name], "staging left behind")
                // a package manager shows the extension's own icon, from Pages
                XCTAssertEqual(
                    try store.locate(projectID).project.package.icon,
                    "https://owngoal-dev.github.io/Apelin/icons/\(manifest.id).png",
                    template.id,
                )

                let reference = scratch.appendingPathComponent("reference")
                let architectures = JSONWriter.compact(.object(JSONObject(Bootstrap.allCases.compactMap { bootstrap in
                    manifest.requirements.architectures[bootstrap].map { (bootstrap.rawValue, .array($0.map { .string($0.rawValue) })) }
                })))
                // Apelin names the product after the project, as it fills
                // bundleID and packageID; the reference is given the same.
                let productName = template.parameters.contains { $0.name == "productName" }
                    ? ", \"productName\": \(CanonicalJSON.quote(ProjectStore.identifier(name)!))" : ""
                let values = """
                {"projectName": \(CanonicalJSON.quote(name)), "projectID": "\(projectID)", "bundleID": "com.example.sample",
                 "packageID": "com.example.sample", "deploymentTarget": "16.0", "architectures": \(String(decoding: architectures, as: UTF8.self)),
                 "templateExtensionID": "\(manifest.id)", "templateID": "\(template.id)", "templateVersion": "\(manifest.version)",
                 "templateDigest": "\(template.digest)", "toolchainID": "clt-27.0-sample", "toolchainDigest": "sha256:\(String(repeating: "1", count: 64))",
                 "sdkID": "iPhoneOS27.0-00000000", "sdkDigest": "sha256:\(String(repeating: "2", count: 64))"\(productName)}
                """
                let output = try runReference("""
                import json, apelin_schema as s
                from pathlib import Path
                ext = Path(sys.argv[2]); m = s.load_json(ext / 'manifest.json')
                t = next(t for t in m['templates'] if t['id'] == sys.argv[3])
                s.instantiate(ext, m, t, json.loads(sys.argv[4]), Path(sys.argv[5]))
                print(json.dumps(s.project_digests(Path(sys.argv[5]))))
                """, arguments: [item.root.path, template.id, values, reference.path])
                let expected = try StrictJSON.parse(Data(output.utf8))
                XCTAssertEqual(created.baseline.build.digest, expected["build"]?["digest"]?.stringValue, template.id)
                XCTAssertEqual(created.baseline.packaging.digest, expected["packaging"]?["digest"]?.stringValue, template.id)
                XCTAssertEqual(created.baseline.build.canonical, expected["build"]?["canonical"]?.stringValue, template.id)
                try assertSameTree(created.root, reference, template.id)
                // the repository is Apelin's, not the template's
                XCTAssertEqual(
                    try String(contentsOf: created.root.appendingPathComponent(".git/HEAD"), encoding: .utf8),
                    "ref: refs/heads/main\n",
                    template.id,
                )
                // and keeps Apelin's own files out of it
                XCTAssertEqual(
                    try String(contentsOf: created.root.appendingPathComponent(".git/info/exclude"), encoding: .utf8),
                    "/Attachments/\n/.apelin-metadata-*\n.*.apelin-*\n",
                    template.id,
                )
            }
        }
    }

    /// The template's files, both ways; the repository a project starts
    /// with is left out.
    private func assertSameTree(_ a: URL, _ b: URL, _ label: String) throws {
        func files(_ root: URL) -> [String] {
            (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { path in
                guard path != ".git", !path.hasPrefix(".git/") else { return false }
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory)
                return !isDirectory.boolValue
            }.sorted()
        }
        XCTAssertEqual(files(a), files(b), label)
        for path in files(a) {
            let left = try Data(contentsOf: a.appendingPathComponent(path))
            let right = try Data(contentsOf: b.appendingPathComponent(path))
            XCTAssertEqual(left, right, "\(label)/\(path)")
            let modeA = try FileManager.default.attributesOfItem(atPath: a.appendingPathComponent(path).path)[.posixPermissions] as? Int
            let modeB = try FileManager.default.attributesOfItem(atPath: b.appendingPathComponent(path).path)[.posixPermissions] as? Int
            XCTAssertEqual(modeA, modeB, "\(label)/\(path) mode")
        }
    }

    func testCreationRules() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Documents/wiki.qaq.apelin"), withIntermediateDirectories: true)
        let store = ProjectStore(dataFolder: DataFolder(home: scratch.path))
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let template = "wiki.qaq.apelin.dev.tweak/objc-hook"
        for name in ["", ".", "..", ".hidden", "a/b", "a\u{0}b"] {
            XCTAssertThrowsError(try store.create(templateID: template, name: name, values: [:], catalog: catalog, registry: sampleRegistry()), name)
        }
        XCTAssertThrowsError(try store.create(templateID: template, name: "x", values: ["projectID": .string("a")], catalog: catalog, registry: sampleRegistry()))
        XCTAssertThrowsError(try store.create(templateID: template, name: "x", values: ["nope": .string("a")], catalog: catalog, registry: sampleRegistry()))
        XCTAssertThrowsError(try store.create(templateID: template, name: "x", values: ["productName": .string("not an identifier")], catalog: catalog, registry: sampleRegistry()))
        XCTAssertThrowsError(try store.create(templateID: template, name: "x", values: [:], catalog: catalog, registry: StaticEnvironmentRegistry(toolchains: [], sdks: [])))
        // a display name that would break out of a C string or JSON is escaped, not refused
        let created = try store.create(templateID: template, name: "Hello", values: ["displayName": .string(#"Quote " and \ back"#)], catalog: catalog, registry: sampleRegistry())
        let project = try ProjectStore(dataFolder: store.dataFolder).locate(created.projectID)
        XCTAssertEqual(project.project.package.name, #"Quote " and \ back"#)
        XCTAssertEqual(project.project.package.id, "local.apelin.hello")
        XCTAssertThrowsError(try store.create(templateID: template, name: "Hello", values: [:], catalog: catalog, registry: sampleRegistry())) { error in
            XCTAssertTrue(String(describing: error).contains("already exists"))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.projectsDirectory.path)
        XCTAssertEqual(leftovers, ["Hello"])
    }

    /// Two tweak projects made with the template's defaults installed the
    /// same `ApelinTweak.dylib`, and irisind refused the second (iOS 26.4
    /// vphone, 2026-10-17): the product is named after the project unless the
    /// request names it.
    func testTheProductIsNamedAfterTheProject() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Documents/wiki.qaq.apelin"), withIntermediateDirectories: true)
        let store = ProjectStore(dataFolder: DataFolder(home: scratch.path))
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let template = "wiki.qaq.apelin.dev.tweak/objc-hook"
        func productName(_ name: String, _ values: [String: JSONDocument] = [:]) throws -> String? {
            let created = try store.create(templateID: template, name: name, values: values, catalog: catalog, registry: sampleRegistry())
            return try store.locate(created.projectID).project.products.first?.name
        }
        XCTAssertEqual(try productName("I3 Chain Tweak"), "I3ChainTweak")
        XCTAssertEqual(try productName("console build-check"), "ConsoleBuildCheck")
        XCTAssertEqual(try productName("3D touch"), "_3DTouch")
        XCTAssertEqual(try productName("Named", ["productName": .string("Chosen")]), "Chosen")
        XCTAssertEqual(try productName("…"), "ApelinTweak", "a name with nothing usable keeps the template's default")
    }

    /// An older Command Line Tools release reads SDKs only up to the one its
    /// Xcode shipped with: a new project binds the newest of those, and the
    /// check names a newer one as an error.
    func testAnOlderToolchainBindsAnSDKItReads() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Documents/wiki.qaq.apelin"), withIntermediateDirectories: true)
        let store = ProjectStore(dataFolder: DataFolder(home: scratch.path))
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let template = "wiki.qaq.apelin.dev.tweak/objc-hook"
        let toolchain = RegisteredToolchain(id: "clt-16.4", digest: "sha256:" + String(repeating: "1", count: 64), version: "16.4", path: "/nonexistent", components: ["c-family"], newestSDK: "18.5")
        func sdk(_ version: String) -> RegisteredSDK {
            RegisteredSDK(id: "iPhoneOS\(version)-00000000", digest: "sha256:" + String(repeating: "2", count: 64), version: version, path: "/nonexistent")
        }
        let registry = StaticEnvironmentRegistry(toolchains: [toolchain], sdks: [sdk("27.0"), sdk("18.2"), sdk("17.4")])
        let created = try store.create(templateID: template, name: "Older", values: [:], catalog: catalog, registry: registry)
        XCTAssertEqual(try store.locate(created.projectID).project.environment.sdk.id, "iPhoneOS18.2-00000000")
        XCTAssertFalse(ProjectCheck(store: store, catalog: catalog, registry: registry).run(projectID: created.projectID).diagnostics.contains { $0.code == "environment.sdk.tooNewForToolchain" })

        let newer = try store.create(templateID: template, name: "Newer", values: ["sdkID": .string("iPhoneOS27.0-00000000")], catalog: catalog, registry: registry)
        let result = ProjectCheck(store: store, catalog: catalog, registry: registry).run(projectID: newer.projectID)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "environment.sdk.tooNewForToolchain" && $0.severity == .error }, "\(result.diagnostics)")

        let none = StaticEnvironmentRegistry(toolchains: [toolchain], sdks: [sdk("27.0")])
        XCTAssertThrowsError(try store.create(templateID: template, name: "None", values: [:], catalog: catalog, registry: none)) { error in
            XCTAssertTrue(String(describing: error).contains("up to 18.5"), "\(error)")
        }

        // An older pairing (14.2 on a 15.5 SDK) can target iOS 16 using older APIs;
        // the SDK version is not the minimum OS the output may request.
        var olderToolchain = toolchain
        olderToolchain.version = "14.2"
        olderToolchain.newestSDK = "16.2"
        let older = StaticEnvironmentRegistry(toolchains: [olderToolchain], sdks: [sdk("15.5")])
        let legacy = try store.create(templateID: template, name: "Legacy Headers", values: [:], catalog: catalog, registry: older)
        let warning = ProjectCheck(store: store, catalog: catalog, registry: older).run(projectID: legacy.projectID)
            .diagnostics.first { $0.code == "environment.sdk.tooOld" }
        XCTAssertEqual(warning?.severity, .warning)
    }

    /// A switch is checked before anything is written: the candidate binding
    /// takes the registry's digests, an unregistered component is refused,
    /// and an SDK newer than the toolchain reads fails with the same
    /// diagnostic a project bound to it gets.
    func testACandidateBindingIsCheckedBeforeASwitch() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Documents/wiki.qaq.apelin"), withIntermediateDirectories: true)
        let store = ProjectStore(dataFolder: DataFolder(home: scratch.path))
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let toolchain = RegisteredToolchain(id: "clt-16.4", digest: "sha256:" + String(repeating: "1", count: 64), version: "16.4", path: "/nonexistent", components: ["c-family"], newestSDK: "18.5")
        func sdk(_ version: String, _ fill: Character) -> RegisteredSDK {
            RegisteredSDK(id: "iPhoneOS\(version)-00000000", digest: "sha256:" + String(repeating: fill, count: 64), version: version, path: "/nonexistent")
        }
        let registry = StaticEnvironmentRegistry(toolchains: [toolchain], sdks: [sdk("27.0", "3"), sdk("18.2", "2")])
        let created = try store.create(templateID: "wiki.qaq.apelin.dev.tweak/objc-hook", name: "Switching", values: [:], catalog: catalog, registry: registry)
        let check = ProjectCheck(store: store, catalog: catalog, registry: registry)
        let current = try store.locate(created.projectID).project.environment
        XCTAssertEqual(current.sdk.id, "iPhoneOS18.2-00000000")

        let newer = try check.binding(ProjectEnvironmentChoice(sdkID: "iPhoneOS27.0-00000000"), replacing: current)
        XCTAssertEqual(newer.sdk.digest, "sha256:" + String(repeating: "3", count: 64), "the digest is the registry's")
        XCTAssertEqual(newer.toolchain, current.toolchain, "a component not named stays")
        let refused = check.run(projectID: created.projectID, environment: newer)
        XCTAssertTrue(refused.diagnostics.contains { $0.code == "environment.sdk.tooNewForToolchain" && $0.severity == .error }, "\(refused.diagnostics)")
        XCTAssertEqual(refused.project?.environment, newer, "the check ran with the candidate")
        XCTAssertFalse(check.run(projectID: created.projectID).diagnostics.contains { $0.code == "environment.sdk.tooNewForToolchain" }, "the project itself is unchanged")
        XCTAssertEqual(refused.digests?.build.digest, created.baseline.build.digest, "the binding is not in the build description")

        XCTAssertThrowsError(try check.binding(ProjectEnvironmentChoice(toolchainID: "clt-99.0"), replacing: current)) { error in
            XCTAssertEqual((error as? ApelinError)?.code, .notFound)
        }
    }

    /// A Swift project on an SDK of another major than its toolchain's, or
    /// on an architecture the SDK has no Swift interface for, is told so.
    func testSwiftProjectsAreWarnedAboutTheirSDK() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Documents/wiki.qaq.apelin"), withIntermediateDirectories: true)
        let store = ProjectStore(dataFolder: DataFolder(home: scratch.path))
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let sdkRoot = scratch.appendingPathComponent("iPhoneOS18.5.sdk")
        let module = sdkRoot.appendingPathComponent("usr/lib/swift/Swift.swiftmodule")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try Data().write(to: module.appendingPathComponent("arm64e-apple-ios.swiftinterface"))
        let toolchain = RegisteredToolchain(id: "clt-27.0-swift", digest: "sha256:" + String(repeating: "1", count: 64), version: "27.0", path: "/nonexistent", components: ["c-family", "swift"], newestSDK: "27.0")
        let sdk = RegisteredSDK(id: "iPhoneOS18.5-00000000", digest: "sha256:" + String(repeating: "2", count: 64), version: "18.5", path: sdkRoot.path)
        let registry = StaticEnvironmentRegistry(toolchains: [toolchain], sdks: [sdk])
        let created = try store.create(templateID: "wiki.qaq.apelin.dev.app/uikit-swift", name: "Swifty", values: [:], catalog: catalog, registry: registry)
        let diagnostics = ProjectCheck(store: store, catalog: catalog, registry: registry).run(projectID: created.projectID).diagnostics
        XCTAssertTrue(diagnostics.contains { $0.code == "environment.sdk.swiftMacros" && $0.severity == .warning }, "\(diagnostics)")
        let architectures = diagnostics.filter { $0.code == "environment.sdk.noSwiftArchitecture" }
        XCTAssertEqual(architectures.map(\.field), ["/architectures/rootless"], "rootless asks for arm64, which the SDK lacks")
    }

    /// On roothide Bootstrap no toolchain runs (issue #35), whatever the
    /// project binds: the check says why, field by field, as it does for a
    /// CPU that cannot run one.
    func testTheCheckSaysWhyNothingBuildsOnRoothideBootstrap() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Documents/wiki.qaq.apelin"), withIntermediateDirectories: true)
        let store = ProjectStore(dataFolder: DataFolder(home: scratch.path))
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(templateID: "wiki.qaq.apelin.dev.tweak/objc-hook", name: "Signed", values: [:], catalog: catalog, registry: sampleRegistry())
        let root = scratch.appendingPathComponent(".jbroot-F1E6FD3C82204430", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let elsewhere = ProjectCheck(store: store, catalog: catalog, registry: sampleRegistry(), installRoot: root.path)
        XCTAssertFalse(elsewhere.run(projectID: created.projectID).diagnostics.contains { $0.code == "environment.device.toolchain" })

        FileManager.default.createFile(atPath: root.appendingPathComponent(".thebootstrapped").path, contents: Data("1900".utf8))
        let bootstrap = ProjectCheck(store: store, catalog: catalog, registry: sampleRegistry(), installRoot: root.path)
        let result = bootstrap.run(projectID: created.projectID)
        XCTAssertFalse(result.passed)
        let refusal = result.diagnostics.first { $0.code == "environment.device.toolchain" }
        XCTAssertEqual(refusal?.severity, .error)
        XCTAssertEqual(refusal?.message, HostSigning.bootstrapRefusal)
        XCTAssertEqual(refusal?.field, "/environment/toolchain")
    }

    func testProjectCheck() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Documents/wiki.qaq.apelin"), withIntermediateDirectories: true)
        let store = ProjectStore(dataFolder: DataFolder(home: scratch.path))
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(templateID: "wiki.qaq.apelin.dev.tweak/objc-hook", name: "Checked", values: [:], catalog: catalog, registry: sampleRegistry())
        // The sample registry's toolchain path does not exist: the check says so.
        var result = ProjectCheck(store: store, catalog: catalog, registry: sampleRegistry()).run(projectID: created.projectID)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "environment.toolchain.incomplete" })
        XCTAssertEqual(result.digests?.build.digest, created.baseline.build.digest)

        // A real toolchain and SDK (the Mac's), and the check passes.
        if let registry = try? macRegistry() {
            let rebound = try store.create(templateID: "wiki.qaq.apelin.dev.tweak/objc-hook", name: "Bound", values: [:], catalog: catalog, registry: registry)
            result = ProjectCheck(store: store, catalog: catalog, registry: registry).run(projectID: rebound.projectID)
            XCTAssertTrue(result.passed, "\(result.diagnostics)")
        }

        // Without the tweak extension the project is still found and the
        // missing support is an error naming the fix, not a crash.
        let empty = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        result = ProjectCheck(store: store, catalog: ExtensionCatalog(directory: empty), registry: sampleRegistry()).run(projectID: created.projectID)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "extension.support.missing" && $0.fixes == ["installExtension"] })

        // A source glob that matches nothing, and a broken document.
        let projectFile = created.root.appendingPathComponent("apelin-project.json")
        try FileManager.default.removeItem(at: created.root.appendingPathComponent("Sources/Tweak.m"))
        result = ProjectCheck(store: store, catalog: catalog, registry: sampleRegistry()).run(projectID: created.projectID)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "project.glob.empty" && $0.field == "/products/0/sources" })
        var text = try String(contentsOf: projectFile, encoding: .utf8)
        text = text.replacingOccurrences(of: #""section": "Tweaks""#, with: #""section": "Nope""#)
        try text.write(to: projectFile, atomically: true, encoding: .utf8)
        result = ProjectCheck(store: store, catalog: catalog, registry: sampleRegistry()).run(root: created.root)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "project.invalid" && $0.field == "/package/section" })

        XCTAssertThrowsError(try store.locate("00000000-0000-4000-8000-00000000dead"))
    }
}

/// Xcode's tools and iPhoneOS SDK as a registry, when this Mac has them.
func macRegistry() throws -> StaticEnvironmentRegistry {
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let clang = try run(["--sdk", "iphoneos", "--find", "clang"])
    let toolchain = URL(fileURLWithPath: clang).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    let sdk = try run(["--sdk", "iphoneos", "--show-sdk-path"])
    let version = try run(["--sdk", "iphoneos", "--show-sdk-version"])
    return StaticEnvironmentRegistry(
        toolchains: [RegisteredToolchain(id: "xcode-default", digest: "sha256:" + String(repeating: "a", count: 64), version: "xcode", path: toolchain, components: ["c-family", "swift"])],
        sdks: [RegisteredSDK(id: "iPhoneOS\(version)-xcode", digest: "sha256:" + String(repeating: "b", count: 64), version: version, path: sdk)],
    )
}
