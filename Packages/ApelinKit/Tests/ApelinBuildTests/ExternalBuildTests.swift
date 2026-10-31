@testable import ApelinBuild
import ApelinCore
import ApelinDebArchive
import ApelinDebian
import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

/// A workspace's own build (`ExternalBuild`): the declaration read strictly,
/// the script run with what it is promised, and the one package it writes
/// checked and registered, or the build failed with why.
final class ExternalBuildTests: XCTestCase {
    private typealias Events = BuildWorkerTests.Events

    private var scratch: URL!
    private var worker: BuildWorker!

    override func setUpWithError() throws {
        scratch = try scratchDirectory("apelin-external-build")
        let (home, _) = try makeHome(in: scratch)
        // The Mac's own /bin/sh stands in for the bootstrap's.
        worker = BuildWorker(installRoot: "/", home: home.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// An empty workspace with `apelin/build.sh` as `script`, declared with
    /// `external` unless that is nil.
    private func workspace(script: String, external: String? = #"{"script": "apelin/build.sh"}"#) throws -> (id: String, root: URL) {
        let template = try XCTUnwrap(worker.extensionList().extensions.first { $0.kind == .workspace }?.templates.first)
        let created = try worker.projectCreate(ProjectCreateRequest(templateID: template.id, name: "Imported \(UUID().uuidString.prefix(8))"))
        let root = URL(fileURLWithPath: created.path, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("apelin"), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: root.appendingPathComponent("apelin/build.sh"))
        if let external {
            let manifest = root.appendingPathComponent("apelin-project.json")
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
            document["external"] = try JSONSerialization.jsonObject(with: Data(external.utf8), options: .fragmentsAllowed)
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: manifest)
        }
        return (created.projectID, root)
    }

    /// A tweak package, written outside the project for a script to copy.
    private func package(
        _ layout: PackageLayout,
        id: String = "com.example.imported",
        version: String = "1.0.1",
        depends: String = "mobilesubstrate",
        name: String = "sample.deb",
    ) throws -> URL {
        var control = DebianControlFile(package: id, version: version, architecture: layout.architecture, description: "Imported")
        control["Depends"] = depends
        var writer = DebPackageWriter(control: control)
        writer.entries = try [
            .file(layout.tweakLibrary(named: "Imported"), contents: Data(repeating: 0xCF, count: 64), mode: 0o755),
            .file(layout.tweakFilter(named: "Imported"), contents: Data("{ Filter = { Bundles = ( \"com.apple.springboard\" ); }; }\n".utf8)),
        ]
        let url = scratch.appendingPathComponent(UUID().uuidString + "-" + name)
        try writer.write(toPath: url.path)
        return url
    }

    private func build(
        _ projectID: String,
        configuration: BuildConfiguration = .debug,
        bootstrap: BuildBootstrap = .roothide,
    ) throws -> (TaskID, Events) {
        let events = Events()
        let taskID = TaskID.make()
        try worker.buildStart(BuildStartRequest(projectID: projectID, configuration: configuration, bootstrap: bootstrap), taskID: taskID) {
            events.append($0, $1, $2)
        }
        XCTAssertEqual(events.finished.wait(timeout: .now() + 60), .success)
        return (taskID, events)
    }

    func testDeclarationIsReadStrictly() throws {
        let root = scratch.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("exit 0\n".utf8).write(to: root.appendingPathComponent("scripts/build.sh"))
        func read(_ external: String) throws -> ExternalBuildDeclaration? {
            try ExternalBuildDeclaration.read(StrictJSON.parse(Data(#"{"kind": "workspace", "external": \#(external)}"#.utf8)), root: root)
        }
        XCTAssertEqual(
            try read(#"{"script": "scripts/build.sh", "interpreter": "bash", "arguments": ["--fast"]}"#),
            ExternalBuildDeclaration(script: "scripts/build.sh", interpreter: .bash, arguments: ["--fast"]),
        )
        XCTAssertEqual(try read(#"{"script": "scripts/build.sh"}"#)?.interpreter, .sh, "sh by default")
        XCTAssertNil(try ExternalBuildDeclaration.read(StrictJSON.parse(Data(#"{"kind": "workspace"}"#.utf8)), root: root))
        for (external, field) in [
            (#""scripts/build.sh""#, "/external "),
            (#"{"interpreter": "sh"}"#, "/external/script"),
            (#"{"script": "../outside.sh"}"#, "/external/script"),
            (#"{"script": "/bin/sh"}"#, "/external/script"),
            (#"{"script": ".hidden/build.sh"}"#, "/external/script"),
            (#"{"script": "scripts/missing.sh"}"#, "/external/script"),
            (#"{"script": "scripts"}"#, "/external/script"),
            (#"{"script": "scripts/build.sh", "command": "make"}"#, "/external/command"),
            (#"{"script": "scripts/build.sh", "interpreter": "ruby"}"#, "/external/interpreter"),
            (#"{"script": "scripts/build.sh", "arguments": "--fast"}"#, "/external/arguments"),
            (#"{"script": "scripts/build.sh", "arguments": ["a\nb"]}"#, "/external/arguments/0"),
        ] {
            XCTAssertThrowsError(try read(external), external) { error in
                XCTAssertTrue("\(error)".contains(field), "\(external): \(error)")
            }
        }
        let many = "[" + Array(repeating: #""x""#, count: 33).joined(separator: ",") + "]"
        XCTAssertThrowsError(try read(#"{"script": "scripts/build.sh", "arguments": \#(many)}"#))
    }

    func testCheckSaysExternalAndWhetherABuildIsDeclared() throws {
        let undeclared = try workspace(script: "exit 0\n", external: nil)
        let bare = try worker.projectCheck(ProjectCheckRequest(projectID: undeclared.id))
        XCTAssertEqual(bare.buildSystem, .external)
        XCTAssertFalse(bare.passed)
        XCTAssertEqual(bare.diagnostics.first?.field, "/external")
        XCTAssertNil(bare.descriptionDigests)

        let declared = try workspace(script: "exit 0\n")
        let checked = try worker.projectCheck(ProjectCheckRequest(projectID: declared.id))
        XCTAssertEqual(checked.buildSystem, .external)
        XCTAssertTrue(checked.passed, "\(checked.diagnostics)")
        XCTAssertNil(checked.descriptionDigests, "a workspace has no description to digest")

        // An undeclared workspace's build is refused before a task exists.
        XCTAssertThrowsError(try worker.buildStart(BuildStartRequest(projectID: undeclared.id), taskID: TaskID.make()) { _, _, _ in }) { error in
            XCTAssertEqual((error as? ApelinError)?.code, .badRequest)
        }
    }

    /// A workspace rewritten by hand as a description lacks what only
    /// projectCreate writes. A switch of its SDK is answered with the check
    /// that says so, field by field, and no binding, not refused unread.
    func testASwitchOnAWorkspaceRewrittenAsADescriptionAnswersItsCheck() throws {
        let imported = try workspace(script: "exit 0\n")
        let manifest = imported.root.appendingPathComponent("apelin-project.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        document["kind"] = "tweak"
        document["buildSystem"] = nil
        document["external"] = nil
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: manifest)

        let check = try worker.projectCheck(ProjectCheckRequest(
            projectID: imported.id,
            environment: ProjectEnvironmentChoice(sdkID: "iPhoneOS18.2-aaaaaaaa"),
        ))
        XCTAssertFalse(check.passed)
        XCTAssertNil(check.environment, "the project file did not read")
        XCTAssertNil(check.buildSystem)
        let invalid = check.diagnostics.filter { $0.code == "project.invalid" }
        for missing in ["missing template", "missing environment"] {
            XCTAssertTrue(invalid.contains { $0.field == "/" && $0.message == missing }, "\(missing): \(check.diagnostics)")
        }
    }

    func testBuildRunsTheScriptAndRegistersItsOnePackage() throws {
        let deb = try package(.roothide)
        let project = try workspace(
            script: "env > \"$APELIN_PROJECT_ROOT/env.txt\"\necho building\ncp \"$1\" \"$APELIN_PACKAGE_DIR/\"\n",
            external: #"{"script": "apelin/build.sh", "arguments": ["\#(deb.path)"]}"#,
        )
        let (taskID, events) = try build(project.id)
        let last = try XCTUnwrap(events.last)
        XCTAssertEqual(last["state"]?.stringValue, "succeeded", "\(last) \(events.payloads("log"))")
        XCTAssertEqual(last["artifactID"]?.stringValue, taskID.rawValue)
        XCTAssertEqual(last["packageID"]?.stringValue, "com.example.imported")
        XCTAssertEqual(last["version"]?.stringValue, "1.0.1")
        XCTAssertEqual(last["bootstrap"]?.stringValue, "roothide")
        XCTAssertEqual(events.payloads("stage").compactMap { $0["stage"]?.stringValue }, ["script", "verify"])
        XCTAssertTrue(events.payloads("log").contains { $0["line"]?.stringValue == "building" }, "the script's output is the build log")

        let artifact = try XCTUnwrap(events.payloads("artifact").first).decode(BuildArtifact.self)
        XCTAssertEqual(artifact.projectID, project.id)
        XCTAssertEqual(artifact.buildID, taskID.rawValue)
        let work = worker.store.buildsDirectory.appendingPathComponent(project.id).appendingPathComponent(taskID.rawValue)
        XCTAssertEqual(artifact.path, work.appendingPathComponent("package/\(deb.lastPathComponent)").path, "the package stays in the build's folder")
        XCTAssertEqual(artifact.digest, try CanonicalJSON.sha256Tag(Data(contentsOf: deb)))
        XCTAssertEqual(
            artifact.packageFiles,
            ["/Library/MobileSubstrate/DynamicLibraries/Imported.dylib", "/Library/MobileSubstrate/DynamicLibraries/Imported.plist"],
            "the workspace's own package is listed for the host, folders left out",
        )

        let record = try ArtifactStore(store: worker.store).load(taskID.rawValue)
        XCTAssertEqual(record.buildSystem, .external)
        XCTAssertNil(record.buildDigest)
        XCTAssertEqual(record.packagingDigest, artifact.packagingDigest)
        XCTAssertEqual(record.architecture, "iphoneos-arm64e")
        let check = try XCTUnwrap(record.loadCheck)
        XCTAssertEqual(check.marker, "ApelinLoaded \(taskID.rawValue)")
        XCTAssertEqual(check.markerSubsystem, "com.example.imported")
        XCTAssertEqual(check.dylibLogicalPath, "/Library/MobileSubstrate/DynamicLibraries/Imported.dylib")
        XCTAssertEqual(check.dylibInstalledPath, "/Library/MobileSubstrate/DynamicLibraries/Imported.dylib")
        XCTAssertEqual(check.bundles, ["com.apple.springboard"])

        let environment = try String(contentsOf: project.root.appendingPathComponent("env.txt"), encoding: .utf8)
        for line in [
            "APELIN_BUILD_ID=\(taskID.rawValue)", "APELIN_BOOTSTRAP=roothide", "APELIN_ARCHITECTURE=iphoneos-arm64e",
            "APELIN_PREFIX=", "APELIN_CONFIGURATION=debug", "APELIN_PACKAGE_DIR=\(work.appendingPathComponent("package").path)",
        ] {
            XCTAssertTrue(environment.split(separator: "\n").contains(Substring(line)), "\(line) in\n\(environment)")
        }
    }

    /// A manifest written on one line (as `workspace` writes it, and as a
    /// rename did) is put into its written form by the first build, before
    /// the script runs, its mode kept and its document unchanged; the next
    /// build leaves the file alone.
    func testABuildFormatsTheManifestOnceAndThenLeavesItAlone() throws {
        let deb = try package(.roothide)
        let project = try workspace(
            script: "cp apelin-project.json \"$APELIN_PACKAGE_DIR/../seen.json\"\ncp \"$1\" \"$APELIN_PACKAGE_DIR/\"\n",
            external: #"{"script": "apelin/build.sh", "arguments": ["\#(deb.path)"]}"#,
        )
        let manifest = project.root.appendingPathComponent("apelin-project.json")
        XCTAssertEqual(chmod(manifest.path, 0o640), 0)
        let oneLine = try Data(contentsOf: manifest)
        let expected = try XCTUnwrap(ProjectManifestFormat.formatted(oneLine))
        XCTAssertNotEqual(oneLine, expected, "the test starts from a file on one line")
        func formattedLines(_ events: Events) -> [String] {
            events.payloads("log").compactMap { $0["line"]?.stringValue }.filter { $0.contains("apelin-project.json") }
        }

        let (taskID, first) = try build(project.id)
        XCTAssertEqual(first.last?["state"]?.stringValue, "succeeded", "\(first.payloads("log"))")
        XCTAssertEqual(formattedLines(first), ["formatted apelin-project.json: two spaces a level, one member a line; no value changed"])
        XCTAssertEqual(try Data(contentsOf: manifest), expected)
        XCTAssertEqual(try StrictJSON.parse(expected).description, try StrictJSON.parse(oneLine).description)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: manifest.path)[.posixPermissions] as? Int, 0o640)
        let work = worker.store.buildsDirectory.appendingPathComponent(project.id).appendingPathComponent(taskID.rawValue)
        XCTAssertEqual(try Data(contentsOf: work.appendingPathComponent("seen.json")), expected, "formatted before the script ran")
        let log = try String(contentsOf: work.appendingPathComponent("build.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("formatted apelin-project.json"), "and said so in build.log too")

        let inode = try FileManager.default.attributesOfItem(atPath: manifest.path)[.systemFileNumber] as? Int
        let (_, second) = try build(project.id)
        XCTAssertEqual(second.last?["state"]?.stringValue, "succeeded", "\(second.payloads("log"))")
        XCTAssertEqual(formattedLines(second), [], "nothing to say the second time")
        XCTAssertEqual(try Data(contentsOf: manifest), expected)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: manifest.path)[.systemFileNumber] as? Int, inode, "not written again")
    }

    /// Either build's record lists what the deb installs for the host: no
    /// folder, links too, fewest components first, so a list cut at its
    /// limit keeps an app's executable before its resources.
    func testPackageFilesKeepTheShallowestWhenCapped() throws {
        var writer = DebPackageWriter(control: DebianControlFile(package: "com.example.big", version: "1", architecture: "iphoneos-arm64e", description: "Big"))
        writer.entries = (0 ..< 300).map { .file(String(format: "/Applications/Big.app/Assets/a%03d", $0), contents: Data()) }
            + [.file("/Applications/Big.app/Big", contents: Data(), mode: 0o755), .symbolicLink("/usr/bin/big", target: "../../Applications/Big.app/Big")]
        let files = try ArtifactRecord.packageFiles(of: DebArchiveReader.contents(of: .data(writer.data())))
        XCTAssertEqual(files.count, BuildArtifact.maximumPackageFiles)
        XCTAssertEqual(Array(files.prefix(3)), ["/Applications/Big.app/Big", "/usr/bin/big", "/Applications/Big.app/Assets/a000"])
        XCTAssertFalse(files.contains("/Applications/Big.app"), "a folder is no one's file")
    }

    /// A workspace has no description for the distribution check to read,
    /// so its release build reads the package: a made-up identifier, a
    /// version already packaged for the target, and a package other than
    /// the other target's latest release. A debug build says nothing.
    func testReleaseBuildReportsWhatThePackageShouldNotCarry() throws {
        let local = try package(.roothide, id: "local.apelin.imported")
        let rootless = try package(.rootless, id: "com.example.other")
        let project = try workspace(
            script: "if [ \"$APELIN_BOOTSTRAP\" = rootless ]; then cp \"$2\" \"$APELIN_PACKAGE_DIR/\"; else cp \"$1\" \"$APELIN_PACKAGE_DIR/\"; fi\n",
            external: #"{"script": "apelin/build.sh", "arguments": ["\#(local.path)", "\#(rootless.path)"]}"#,
        )
        func findings(_ events: Events) -> [String] {
            XCTAssertEqual(events.last?["state"]?.stringValue, "succeeded", "\(events.payloads("log"))")
            return events.payloads("diagnostic").compactMap { $0["code"]?.stringValue }.filter { $0.hasPrefix("distribution.") }
        }
        XCTAssertEqual(try findings(build(project.id).1), [], "a debug build is not for distribution")
        XCTAssertEqual(try findings(build(project.id, configuration: .release).1), ["distribution.package.id.local"])
        XCTAssertEqual(
            try findings(build(project.id, configuration: .release).1),
            ["distribution.package.id.local", "distribution.version.packaged"],
        )
        let other = try build(project.id, configuration: .release, bootstrap: .rootless).1
        XCTAssertEqual(findings(other), ["distribution.package.id.differs"])
        XCTAssertEqual(other.payloads("diagnostic").first?["severity"]?.stringValue, "warning", "never stops the build")
    }

    func testPackagingDigestIgnoresTheVersionButNotTheControlOrPaths() throws {
        func digest(_ url: URL) throws -> String {
            let contents = try DebArchiveReader.contents(of: .path(url.path))
            return try ExternalBuild.packagingDigest(control: contents.control(), contents: contents)
        }
        let first = try digest(package(.roothide))
        XCTAssertEqual(try digest(package(.roothide, version: "1.0.2")), first, "a version bump never asks")
        XCTAssertNotEqual(try digest(package(.roothide, depends: "mobilesubstrate, preferenceloader")), first)
        XCTAssertNotEqual(try digest(package(.rootless)), first, "other paths and architecture")
    }

    func testBuildFailsWithWhy() throws {
        let roothide = try package(.roothide)
        let rootless = try package(.rootless)
        for (script, arguments, expected) in [
            ("echo broken >&2\nexit 3\n", "[]", "apelin/build.sh failed with status 3"),
            ("exit 0\n", "[]", "wrote no package"),
            ("cp \"$1\" \"$APELIN_PACKAGE_DIR/a.deb\"\ncp \"$1\" \"$APELIN_PACKAGE_DIR/b.deb\"\n", #"["\#(roothide.path)"]"#, "wrote 2 packages"),
            ("cp \"$1\" \"$APELIN_PACKAGE_DIR/\"\n", #"["\#(rootless.path)"]"#, "is for iphoneos-arm64, not iphoneos-arm64e"),
            ("echo not a package > \"$APELIN_PACKAGE_DIR/x.deb\"\n", "[]", "is not a package Apelin can read"),
        ] {
            let project = try workspace(script: script, external: #"{"script": "apelin/build.sh", "arguments": \#(arguments)}"#)
            let (_, events) = try build(project.id)
            XCTAssertEqual(events.last?["state"]?.stringValue, "failed", script)
            let message = events.last?["message"]?.stringValue ?? ""
            XCTAssertTrue(message.contains(expected), "\(script): \(message)")
        }
    }

    func testTheTimeoutStopsTheScript() throws {
        let project = try workspace(script: "sleep 30\n")
        let inputs = ExternalBuild.Inputs(
            buildID: TaskID.make().rawValue,
            projectID: project.id,
            projectRoot: project.root,
            declaration: ExternalBuildDeclaration(script: "apelin/build.sh"),
            configuration: .debug,
            bootstrap: .roothide,
            workDirectory: scratch.appendingPathComponent("timeout-work"),
            installRoot: "/",
            home: scratch.appendingPathComponent("home").path,
            timeout: 1,
        )
        let started = Date()
        XCTAssertThrowsError(try ExternalBuild.run(inputs: inputs, store: worker.store, reporter: Collector(), cancellation: BuildCancellation())) { error in
            XCTAssertEqual("\(error)", "apelin/build.sh ran past 1 seconds and was stopped")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }
}
