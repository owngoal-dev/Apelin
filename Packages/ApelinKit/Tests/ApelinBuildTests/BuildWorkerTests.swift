import ApelinBuild
import ApelinCore
import ApelinDebArchive
import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

/// apelin-build's operations as the session host reaches them: the event
/// stream a build task produces, and a cancel.
final class BuildWorkerTests: XCTestCase {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [(TaskID, String, JSONValue?)] = []
        let finished = DispatchSemaphore(value: 0)

        func append(_ taskID: TaskID, _ kind: String, _ payload: JSONValue?) {
            lock.lock()
            all.append((taskID, kind, payload))
            lock.unlock()
            if kind == TaskEvent.stateKind {
                finished.signal()
            }
        }

        var kinds: [String] {
            lock.lock(); defer { lock.unlock() }; return all.map(\.1)
        }

        var last: JSONValue? {
            lock.lock(); defer { lock.unlock() }; return all.last?.2
        }

        func payloads(_ kind: String) -> [JSONValue] {
            lock.lock(); defer { lock.unlock() }; return all.filter { $0.1 == kind }.compactMap(\.2)
        }
    }

    func testEmptyWorkspaceNeedsNoEnvironmentAndNeverOverwritesAProject() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, _) = try makeHome(in: scratch)
        let worker = BuildWorker(installRoot: "/nonexistent", home: home.path)
        let template = try XCTUnwrap(worker.extensionList().extensions.first { $0.kind == .workspace }?.templates.first)
        XCTAssertEqual(template.byteCount, 0)
        let request = ProjectCreateRequest(templateID: template.id, name: "Empty Workspace")
        let created = try worker.projectCreate(request)
        XCTAssertNil(created.baseline)
        XCTAssertEqual(try worker.store.root(of: created.projectID).name, request.name)
        // its description and the empty repository on main it starts with
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: created.path).sorted(), [".git", "apelin-project.json"])
        XCTAssertEqual(
            try String(contentsOfFile: created.path + "/.git/HEAD", encoding: .utf8),
            "ref: refs/heads/main\n",
        )
        XCTAssertThrowsError(try worker.projectCreate(request))
        XCTAssertThrowsError(try worker.projectCreate(ProjectCreateRequest(templateID: template.id, name: "../outside")))
    }

    func testCatalogReportsTemplateSourceSizesWithoutAnEnvironment() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, _) = try makeHome(in: scratch)
        let worker = BuildWorker(installRoot: "/nonexistent", home: home.path, extensionDirectory: Repository.extensions)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        for item in worker.extensionList().extensions where item.kind != .workspace && item.problems.isEmpty {
            for template in item.templates {
                let (found, _, definition) = try XCTUnwrap(catalog.template(template.id))
                let directory = found.root.appendingPathComponent(definition.directory)
                let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]))
                var expected: Int64 = 0
                for case let file as URL in enumerator {
                    let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if values.isRegularFile == true {
                        expected += Int64(values.fileSize ?? 0)
                    }
                }
                XCTAssertEqual(template.byteCount, expected, template.id)
                XCTAssertGreaterThan(expected, 0)
            }
        }
    }

    func testCreateCheckBuildAsTheHostSeesIt() throws {
        guard let registry = macRegistry() else { throw XCTSkip("no iPhoneOS SDK on this Mac") }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, _) = try makeHome(in: scratch)
        let worker = BuildWorker(installRoot: "/var/jb", home: home.path, registry: registry, extensionDirectory: Repository.extensions)

        let list = worker.extensionList()
        XCTAssertTrue(list.extensions.contains { $0.id == "wiki.qaq.apelin.dev.tweak" && $0.kind == .tweak && $0.problems.isEmpty })
        let tweak = try XCTUnwrap(list.extensions.first { $0.id == "wiki.qaq.apelin.dev.tweak" }?.templates.first)
        XCTAssertEqual(tweak.id, "wiki.qaq.apelin.dev.tweak/objc-hook")
        XCTAssertEqual(tweak.parameters.first { $0.name == "filterBundles" }?.defaultValue, .array([.string("com.apple.springboard")]))

        let created = try worker.projectCreate(ProjectCreateRequest(templateID: tweak.id, name: "Worker Tweak", values: ["displayName": .string("Worker Tweak")]))
        XCTAssertEqual(created.baseline?.projectID, created.projectID)
        XCTAssertEqual(created.descriptionDigests?.build, created.baseline?.build.digest)
        XCTAssertEqual(created.descriptionDigests?.packaging, created.baseline?.packaging.digest)
        // what the host reads off the wire, by name
        let createdJSON = try JSONValue(encoding: created)
        XCTAssertNotNil(createdJSON["descriptionDigests"]?["build"]?.stringValue)
        XCTAssertEqual(created.path, home.path + "/Documents/wiki.qaq.apelin/Projects/Worker Tweak")
        let check = try worker.projectCheck(ProjectCheckRequest(projectID: created.projectID))
        XCTAssertTrue(check.passed, "\(check.diagnostics)")
        XCTAssertEqual(check.descriptionDigests, created.descriptionDigests)

        let events = Events()
        let taskID = TaskID.make()
        try worker.buildStart(BuildStartRequest(projectID: created.projectID, configuration: .debug), taskID: taskID) { events.append($0, $1, $2) }
        XCTAssertEqual(events.finished.wait(timeout: .now() + 120), .success)
        let last = try XCTUnwrap(events.last)
        XCTAssertEqual(last["state"]?.stringValue, "succeeded", "\(events.payloads("log").suffix(20))")
        XCTAssertEqual(last["artifactID"]?.stringValue, taskID.rawValue)
        XCTAssertEqual(last["buildID"]?.stringValue, taskID.rawValue)
        XCTAssertEqual(last["bootstrap"]?.stringValue, "rootless")
        XCTAssertTrue(events.kinds.contains("artifact"))
        XCTAssertEqual(events.payloads("stage").compactMap { $0["stage"]?.stringValue }, ["check", "compile", "link", "lipo", "dsym", "strip", "sign", "package", "verify"])
        XCTAssertFalse(
            events.payloads("log").contains { $0["line"]?.stringValue?.contains("apelin-project.json") == true },
            "a manifest already in the written form is left alone",
        )
        let artifact = try XCTUnwrap(events.payloads("artifact").first).decode(BuildArtifact.self)
        XCTAssertEqual(artifact.digest, last["digest"]?.stringValue)
        XCTAssertEqual(artifact.projectID, created.projectID)
        XCTAssertEqual(artifact.packagingDigest, created.descriptionDigests?.packaging)
        let debPath = try XCTUnwrap(artifact.path)
        XCTAssertTrue(debPath.hasPrefix(home.path + "/Documents/wiki.qaq.apelin/Builds/"), debPath)
        XCTAssertEqual(try CanonicalJSON.sha256Tag(Data(contentsOf: URL(fileURLWithPath: debPath))), artifact.digest)
        let members = try DebArchiveReader.contents(of: .path(debPath), contentsLimit: 0).members
        XCTAssertTrue(members.contains("control.tar.gz"), "\(members)")
        let record = try ArtifactStore(store: worker.store).load(artifact.artifactID)
        XCTAssertEqual(record.loadCheck?.marker, "ApelinLoaded \(taskID.rawValue)")
        XCTAssertEqual(record.loadCheck?.dylibInstalledPath, "/var/jb/Library/MobileSubstrate/DynamicLibraries/WorkerTweak.dylib")

        // The host restarted while this build ran: it sends the same task
        // again, resumed. The lost run's folder and record go; the build
        // starts over and keeps its ID.
        let work = worker.store.buildsDirectory.appendingPathComponent(created.projectID).appendingPathComponent(taskID.rawValue)
        try Data("left by the lost run".utf8).write(to: work.appendingPathComponent("stale"))
        let resumed = Events()
        try worker.buildStart(BuildStartRequest(projectID: created.projectID, configuration: .debug), taskID: taskID, resumed: true) { resumed.append($0, $1, $2) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ArtifactStore(store: worker.store).url(of: taskID.rawValue).path), "the lost run's record is removed first")
        XCTAssertEqual(resumed.finished.wait(timeout: .now() + 120), .success)
        XCTAssertEqual(resumed.last?["state"]?.stringValue, "succeeded", "\(resumed.payloads("log").suffix(20))")
        XCTAssertEqual(resumed.last?["buildID"]?.stringValue, taskID.rawValue)
        XCTAssertEqual(resumed.payloads("stage").first?["stage"]?.stringValue, "check")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("stale").path), "the build starts over in a clean folder")
        XCTAssertEqual(try ArtifactStore(store: worker.store).load(taskID.rawValue).buildID, taskID.rawValue)

        // A cancel stops the next build where it stands.
        let cancelled = Events()
        let second = TaskID.make()
        try worker.buildStart(BuildStartRequest(projectID: created.projectID), taskID: second) { cancelled.append($0, $1, $2) }
        worker.cancel(second)
        XCTAssertEqual(cancelled.finished.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(cancelled.last?["state"]?.stringValue, "cancelled")
    }

    /// The host's Confirm check approved one build digest; a description
    /// that reads differently by the time the build checks it does not build.
    func testABuildApprovedForAnotherDescriptionStopsAtTheCheck() throws {
        guard let registry = macRegistry() else { throw XCTSkip("no iPhoneOS SDK on this Mac") }
        let scratch = try scratchDirectory("apelin-approved-digest")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, _) = try makeHome(in: scratch)
        let worker = BuildWorker(installRoot: "/var/jb", home: home.path, registry: registry, extensionDirectory: Repository.extensions)
        let project = try worker.projectCreate(ProjectCreateRequest(templateID: "wiki.qaq.apelin.dev.cli/c", name: "Approved"))
        let approved = try XCTUnwrap(project.descriptionDigests?.build)
        // On one line, as a rename wrote it before: the same descriptions,
        // so the approval still holds and the build formats the file.
        let manifest = URL(fileURLWithPath: project.path).appendingPathComponent("apelin-project.json")
        let formatted = try Data(contentsOf: manifest)
        XCTAssertEqual(ProjectManifestFormat.formatted(formatted), formatted, "a new project is in the written form")
        let oneLine = try Data((StrictJSON.parse(formatted).description + "\n").utf8)
        try oneLine.write(to: manifest)
        XCTAssertEqual(try worker.projectCheck(ProjectCheckRequest(projectID: project.projectID)).descriptionDigests, project.descriptionDigests)

        let stale = Events()
        let request = BuildStartRequest(projectID: project.projectID, approvedBuildDigest: "sha256:" + String(repeating: "0", count: 64))
        try worker.buildStart(request, taskID: TaskID.make()) { stale.append($0, $1, $2) }
        XCTAssertEqual(stale.finished.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(stale.last?["state"]?.stringValue, "failed")
        XCTAssertTrue(stale.last?["message"]?.stringValue?.contains("changed after it was approved") == true, "\(String(describing: stale.last))")
        XCTAssertEqual(stale.payloads("stage").compactMap { $0["stage"]?.stringValue }, ["check"], "no step runs")
        XCTAssertFalse(stale.kinds.contains("artifact"))
        XCTAssertEqual(try Data(contentsOf: manifest), oneLine, "nor is the file formatted")

        let current = Events()
        try worker.buildStart(BuildStartRequest(projectID: project.projectID, approvedBuildDigest: approved), taskID: TaskID.make()) { current.append($0, $1, $2) }
        XCTAssertEqual(current.finished.wait(timeout: .now() + 120), .success)
        XCTAssertEqual(current.last?["state"]?.stringValue, "succeeded", "\(current.payloads("log").suffix(20))")
        XCTAssertTrue(current.payloads("log").contains { $0["line"]?.stringValue?.hasPrefix("formatted apelin-project.json") == true })
        XCTAssertEqual(try Data(contentsOf: manifest), formatted)
        XCTAssertEqual(try worker.projectCheck(ProjectCheckRequest(projectID: project.projectID)).descriptionDigests, project.descriptionDigests)
    }

    func testDistributionCheckWarnsAboutWhatTheTemplateLeft() throws {
        guard let registry = macRegistry() else { throw XCTSkip("no iPhoneOS SDK on this Mac") }
        let scratch = try scratchDirectory("apelin-distribution-check")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, _) = try makeHome(in: scratch)
        let worker = BuildWorker(installRoot: "/var/jb", home: home.path, registry: registry, extensionDirectory: Repository.extensions)
        let created = try worker.projectCreate(ProjectCreateRequest(templateID: "wiki.qaq.apelin.dev.app/uikit-objc", name: "Shipping"))
        func codes() throws -> Set<String> {
            let check = try worker.projectCheck(ProjectCheckRequest(projectID: created.projectID, purpose: .distribution))
            XCTAssertTrue(check.passed, "\(check.diagnostics)")
            XCTAssertTrue(check.diagnostics.filter { $0.code.hasPrefix("distribution.") }.allSatisfy { $0.severity == .warning })
            return Set(check.diagnostics.map(\.code).filter { $0.hasPrefix("distribution.") })
        }
        XCTAssertEqual(try codes(), [
            "distribution.package.name.template", "distribution.package.description.template",
            "distribution.package.author.template", "distribution.package.version.template",
            "distribution.package.id.local", "distribution.bundleID.local", "distribution.icon.missing",
        ])
        XCTAssertFalse(
            try worker.projectCheck(ProjectCheckRequest(projectID: created.projectID)).diagnostics.contains { $0.code.hasPrefix("distribution.") },
            "an ordinary check stays as it was",
        )

        let root = URL(fileURLWithPath: created.path)
        let manifest = root.appendingPathComponent("apelin-project.json")
        var text = try String(contentsOf: manifest, encoding: .utf8)
        for (old, new) in [
            ("\"Apelin App\"", "\"Shipping Notes\""), ("Built on this device with Apelin.", "Notes that ship."),
            ("\"Apelin User\"", "\"Ada\""), ("\"0.0.1\"", "\"1.0.0\""), ("local.apelin.shipping", "wiki.example.shipping"),
        ] {
            XCTAssertTrue(text.contains(old), old)
            text = text.replacingOccurrences(of: old, with: new)
        }
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        let plistURL = root.appendingPathComponent("Resources/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        plist["CFBundleIdentifier"] = "wiki.example.shipping"
        plist["CFBundleIcons"] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        XCTAssertEqual(try codes(), [])
    }

    func testDistributionBuildsDistinctBootstrapArtifacts() throws {
        guard let registry = macRegistry() else { throw XCTSkip("no iPhoneOS SDK on this Mac") }
        let scratch = try scratchDirectory("apelin-distribution")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, _) = try makeHome(in: scratch)
        let worker = BuildWorker(installRoot: "/var/jb", home: home.path, registry: registry, extensionDirectory: Repository.extensions)
        let project = try worker.projectCreate(ProjectCreateRequest(templateID: "wiki.qaq.apelin.dev.cli/c", name: "Distribution"))
        var digests = Set<String>()
        for target in BuildBootstrap.allCases {
            let events = Events()
            let id = TaskID.make()
            try worker.buildStart(BuildStartRequest(projectID: project.projectID, configuration: .release, bootstrap: target), taskID: id) { events.append($0, $1, $2) }
            XCTAssertEqual(events.finished.wait(timeout: .now() + 120), .success)
            XCTAssertEqual(events.last?["state"]?.stringValue, "succeeded", "\(events.payloads("log").suffix(20))")
            let artifact = try XCTUnwrap(events.payloads("artifact").first).decode(BuildArtifact.self)
            XCTAssertEqual(artifact.bootstrap, target.rawValue)
            let path = try XCTUnwrap(artifact.path)
            let contents = try DebArchiveReader.contents(of: .path(path))
            XCTAssertEqual(try contents.control().architecture, target == .rootless ? "iphoneos-arm64" : "iphoneos-arm64e")
            XCTAssertTrue(contents.files.contains(target == .rootless ? "/var/jb/usr/bin/Distribution" : "/usr/bin/Distribution"), "\(contents.files)")
            XCTAssertEqual(events.payloads("stage").last?["stage"]?.stringValue, "verify")
            XCTAssertEqual(try CanonicalJSON.sha256Tag(Data(contentsOf: URL(fileURLWithPath: path))), artifact.digest)
            digests.insert(artifact.digest)
        }
        XCTAssertEqual(digests.count, 2, "the two outputs must be independently built packages")
        for target in BuildBootstrap.allCases {
            let check = try worker.projectCheck(ProjectCheckRequest(projectID: project.projectID, purpose: .distribution, bootstrap: target))
            XCTAssertTrue(check.diagnostics.contains { $0.code == "distribution.version.packaged" && $0.message.contains(target.rawValue) }, "\(check.diagnostics)")
            XCTAssertTrue(check.passed, "distribution findings never fail the check")
        }
        let legacy = try JSONCoding.decode(BuildStartRequest.self, from: Data(#"{"projectID":"legacy","configuration":"debug"}"#.utf8))
        XCTAssertNil(legacy.bootstrap)
        XCTAssertNil(legacy.approvedBuildDigest)
    }
}
