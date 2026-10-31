import ApelinCore
@testable import ApelinEnvironment
import ApelinGit
import ApelinProject
@testable import ApelinProtocol
import CryptoKit
import Foundation
import XCTest

// MARK: - The fake backend's transfer half

extension FakeBackend {
    /// Release `9.9` stands for one this Apelin no longer supports.
    static let unsupportedVersion = "9.9"

    private func prepared(_ tree: URL, version: String = FakeBackend.newest.version) -> PreparedToolchain {
        var product = FakeBackend.newest
        product.version = version
        let facts = #"{"retargetSchemeVersion": 2, "sourceSHA256": "\#(String(repeating: "ab", count: 32))", "minimumOS": "16.0"}"#
        return PreparedToolchain(
            id: Self.id, product: product, components: [.c], tree: tree,
            files: ["usr/bin/clang": "digest"],
            installRelativePath: "usr/lib/apelin/toolchains/\(Self.id)",
            manifest: Data(facts.utf8),
        )
    }

    func exportTree(installed: URL, into destination: URL) throws -> PreparedToolchain {
        guard FileManager.default.contents(atPath: installed.appendingPathComponent("usr/bin/clang").path) == Self.tool else {
            throw ApelinError(.conflict, "the installed toolchain was changed")
        }
        try FileManager.default.copyItem(at: installed, to: destination)
        return prepared(destination)
    }

    func importTree(_ tree: URL) throws -> PreparedToolchain {
        guard FileManager.default.contents(atPath: tree.appendingPathComponent("usr/bin/clang").path) == Self.tool else {
            throw ApelinError(.badRequest, "the toolchain's files do not match its manifest")
        }
        return prepared(tree)
    }

    func importRefusal(_ toolchain: TransferToolchain) -> String? {
        toolchain.record.version == Self.unsupportedVersion ? "Command Line Tools 9.9 is not a release this Apelin supports." : nil
    }
}

// MARK: - Tests

final class TransferTests: XCTestCase {
    /// A device: its data folder, an install root, a registered SDK and no
    /// SDK source.
    private func device(registerSDK: Bool = true) async throws -> TemporaryHome {
        let home = try TemporaryHome(self)
        try FileManager.default.createDirectory(atPath: home.layout.installRoot, withIntermediateDirectories: true)
        try home.layout.make(home.layout.environment)
        try JSONFile.write(SDKSourceList(), to: home.layout.sdkSources)
        if registerSDK {
            try SDKFixture.make(at: home.inbox.appendingPathComponent("iPhoneOS99.0.sdk"))
            let manager = SDKManager(layout: home.layout)
            let prepared = try manager.prepare(SDKImportRequest(source: .inbox(path: "iPhoneOS99.0.sdk")), descriptors: [])
            _ = try await manager.run(prepared, staging: home.layout.makeStaging("sdk"), hasSwiftToolchain: false, reporter: .silent)
            try FileManager.default.removeItem(at: home.inbox.appendingPathComponent("iPhoneOS99.0.sdk"))
        }
        return home
    }

    private func service(_ home: TemporaryHome) -> TransferService {
        let toolchains = ToolchainService(layout: home.layout, backend: FakeBackend())
        return TransferService(layout: home.layout, toolchains: toolchains, sdk: SDKManager(layout: home.layout))
    }

    private func export(_ home: TemporaryHome, _ kind: TransferKind, _ id: String, log: EventLog = EventLog()) async throws -> TransferExport {
        let transfers = service(home)
        let prepared = try transfers.prepareExport(TransferExportRequest(kind: kind, id: id, createdBy: "Apelin 0.1.0 (1)"))
        return try await transfers.export(prepared, staging: home.layout.makeStaging("export-\(UUID().uuidString)"), reporter: log.reporter)
    }

    private func descriptor(_ path: String) throws -> OwnedDescriptor {
        let raw = open(path, O_RDONLY | O_CLOEXEC)
        guard raw >= 0 else { throw ApelinError(.notFound, path) }
        return OwnedDescriptor(adopting: raw)
    }

    /// Imports `path` on `home` as the app does: by descriptor and name.
    private func importFile(
        _ path: String,
        on home: TemporaryHome,
        named fileName: String? = nil,
        projectName: String? = nil,
        installer: FakeInstaller? = nil,
        log: EventLog = EventLog(),
    ) async throws -> JSONValue {
        let transfers = service(home)
        let request = TransferImportRequest(
            source: .file(DescriptorSlot(index: 0)),
            fileName: fileName ?? (path as NSString).lastPathComponent,
            projectName: projectName,
        )
        let prepared = try transfers.prepareImport(request, descriptors: [descriptor(path)])
        return try await transfers.runImport(
            prepared,
            staging: home.layout.makeStaging("import-\(UUID().uuidString)"),
            taskID: TaskID("import"),
            installer: installer ?? FakeInstaller(installRoot: home.layout.installRoot),
            reporter: log.reporter,
        )
    }

    private func inspect(_ path: String, on home: TemporaryHome, named fileName: String? = nil) throws -> TransferInspection {
        try service(home).inspect(
            TransferInspectRequest(source: .file(DescriptorSlot(index: 0)), fileName: fileName ?? (path as NSString).lastPathComponent),
            descriptors: [descriptor(path)],
        )
    }

    private func code(_ body: () async throws -> Void) async -> ApelinError.Code? {
        do {
            try await body()
            return nil
        } catch {
            return (error as? ApelinError)?.code ?? .internal
        }
    }

    // MARK: SDK

    func testAnSDKGoesFromOneDeviceToAnotherAndOnlyOnce() async throws {
        let first = try await device()
        let second = try await device(registerSDK: false)
        let record = try XCTUnwrap(SDKStore(layout: first.layout).list().first)

        let log = EventLog()
        let export = try await export(first, .sdk, record.id, log: log)
        XCTAssertEqual(export.fileName, "iPhoneOS 99.0 SDK.apesdk")
        XCTAssertEqual(export.exportedPath, "sdk-\(record.id)/iPhoneOS 99.0 SDK.apesdk")
        XCTAssertTrue(export.path.hasPrefix(first.layout.exports.path + "/"))
        XCTAssertEqual(export.summary.kind, .sdk)
        XCTAssertEqual(export.summary.sdk?.record.path, "", "the exporting device's path stays there")
        XCTAssertEqual(export.summary.createdBy, "Apelin 0.1.0 (1)")
        XCTAssertEqual(log.events.filter { $0.0 == "stage" }.compactMap { $0.1?["stage"]?.stringValue }, ["collecting", "hashing", "packing", "verifying"])
        let attributes = try FileManager.default.attributesOfItem(atPath: export.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, export.size)

        let inspection = try inspect(export.path, on: second)
        XCTAssertTrue(inspection.importable, "\(inspection.problems)")
        XCTAssertEqual(inspection.summary.id, record.id)
        XCTAssertEqual(inspection.fileSize, export.size)

        let result = try await importFile(export.path, on: second)
        let imported = try XCTUnwrap(result["sdk"]).decode(SDKRecord.self)
        XCTAssertEqual(imported.id, record.id)
        XCTAssertEqual(imported.digest, record.digest)
        XCTAssertEqual(imported.targets, record.targets)
        XCTAssertTrue(imported.origin?.hasPrefix("transfer iPhoneOS 99.0 SDK.apesdk") == true)
        XCTAssertEqual(SDKStore(layout: second.layout).list().map(\.id), [record.id])

        // The same SDK again: said before, refused cleanly.
        let again = try inspect(export.path, on: second)
        XCTAssertFalse(again.importable)
        XCTAssertEqual(again.existingID, record.id)
        let refusal = await code { _ = try await self.importFile(export.path, on: second) }
        XCTAssertEqual(refusal, .conflict)
    }

    func testAKindNamedOtherwiseOrUnexpectedIsRefused() async throws {
        let first = try await device()
        let record = try XCTUnwrap(SDKStore(layout: first.layout).list().first)
        let export = try await export(first, .sdk, record.id)
        let second = try await device(registerSDK: false)
        // An SDK file named as a toolchain.
        let renamed = await code { _ = try self.inspect(export.path, on: second, named: "Tools.apetc") }
        XCTAssertEqual(renamed, .badRequest)
        let unknown = await code { _ = try self.inspect(export.path, on: second, named: "Tools.zip") }
        XCTAssertEqual(unknown, .badRequest)
        // The caller asked for a toolchain.
        let transfers = service(second)
        XCTAssertThrowsError(try transfers.prepareImport(
            TransferImportRequest(source: .file(DescriptorSlot(index: 0)), fileName: export.fileName, kind: .toolchain),
            descriptors: [descriptor(export.path)],
        )) { XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest) }
        // Read where an export left it.
        let fromExports = try service(first).inspect(TransferInspectRequest(source: .exported(path: export.exportedPath)), descriptors: [])
        XCTAssertEqual(fromExports.summary.id, record.id)
        let byFolder = try service(first).inspect(TransferInspectRequest(source: .exported(path: "sdk-\(record.id)")), descriptors: [])
        XCTAssertEqual(byFolder.summary.id, record.id, "the export's folder names its one file")
        XCTAssertThrowsError(try service(first).inspect(TransferInspectRequest(source: .exported(path: "../SDKs/x")), descriptors: []))
    }

    // MARK: Toolchain

    /// Sets a toolchain up on `home` through the fake backend and bridge.
    private func setUpToolchain(_ home: TemporaryHome) async throws -> ToolchainRecord {
        let toolchains = ToolchainService(layout: home.layout, backend: FakeBackend())
        return try await toolchains.setup(
            toolchains.prepare(ToolchainSetupRequest()),
            taskID: TaskID("setup"),
            installer: FakeInstaller(installRoot: home.layout.installRoot),
            reporter: .silent,
        )
    }

    func testAToolchainIsInstalledThroughTheBridgeSelfTestedAndRegisteredOnTheOtherDevice() async throws {
        let first = try await device()
        let record = try await setUpToolchain(first)
        let export = try await export(first, .toolchain, record.id)
        XCTAssertEqual(export.fileName, "Command Line Tools 27.0.apetc")
        let facts = try XCTUnwrap(export.summary.toolchain)
        XCTAssertNil(facts.record.path)
        XCTAssertNil(facts.record.installationID)
        XCTAssertEqual(facts.bootstrap, "rootless")
        XCTAssertEqual(facts.retargetScheme, 2)

        let second = try await device()
        let inspection = try inspect(export.path, on: second)
        XCTAssertTrue(inspection.importable, "\(inspection.problems)")
        let installer = FakeInstaller(installRoot: second.layout.installRoot)
        let log = EventLog()
        let result = try await importFile(export.path, on: second, installer: installer, log: log)
        let imported = try XCTUnwrap(result["toolchain"]).decode(ToolchainRecord.self)
        XCTAssertEqual(imported.id, record.id)
        XCTAssertEqual(imported.installationID, "inst-1")
        XCTAssertEqual(imported.path, second.layout.installRoot + "/usr/lib/apelin/toolchains/" + FakeBackend.id)
        XCTAssertEqual(imported.components, [ToolchainComponent(kind: .c, selfCheckPassed: true)])
        XCTAssertEqual(installer.installed.map(\.packageID), ["wiki.qaq.apelin.toolchain.\(FakeBackend.id)"])
        let stages = log.events.filter { $0.0 == "stage" }.compactMap { $0.1?["stage"]?.stringValue }
        XCTAssertEqual(stages, ["reading", "packaging", "installing", "validating"])
        XCTAssertEqual(ToolchainService(layout: second.layout, backend: FakeBackend()).status(activeTasks: []).toolchains.map(\.id), [record.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.layout.toolchainJobs.appendingPathComponent("import-\(FakeBackend.id)").path))

        // Already set up: said by the inspection, refused by the import.
        let again = try inspect(export.path, on: second)
        XCTAssertEqual(again.existingID, record.id)
        XCTAssertFalse(again.importable)
        let refusal = await code { _ = try await self.importFile(export.path, on: second) }
        XCTAssertEqual(refusal, .conflict)
    }

    func testAToolchainWhoseSelfTestFailsIsRemovedThroughTheBridgeAndNotRegistered() async throws {
        let first = try await device()
        let record = try await setUpToolchain(first)
        let export = try await export(first, .toolchain, record.id)
        let second = try await device()
        let transfers = TransferService(
            layout: second.layout,
            toolchains: ToolchainService(layout: second.layout, backend: FakeBackend(failSelfTest: true)),
            sdk: SDKManager(layout: second.layout),
        )
        let installer = FakeInstaller(installRoot: second.layout.installRoot)
        let prepared = try transfers.prepareImport(
            TransferImportRequest(source: .file(DescriptorSlot(index: 0)), fileName: export.fileName),
            descriptors: [descriptor(export.path)],
        )
        do {
            _ = try await transfers.runImport(prepared, staging: second.layout.makeStaging("i"), taskID: TaskID("i"), installer: installer, reporter: .silent)
            XCTFail("a toolchain that fails its self-test is not registered")
        } catch {}
        XCTAssertEqual(installer.removed, ["inst-1"])
        XCTAssertTrue(ToolchainRegistry.load(second.layout).toolchains.isEmpty)
    }

    func testAToolchainFromTheOtherBootstrapIsPackagedForThisOne() async throws {
        let first = try await device()
        let record = try await setUpToolchain(first)
        let export = try await export(first, .toolchain, record.id)
        // A roothide device: mobile's home inside the install root.
        let base = try TemporaryHome(self)
        let root = base.home.appendingPathComponent("jbroot", isDirectory: true)
        let mobile = root.appendingPathComponent("var/mobile").path
        let data = DataFolder(home: mobile)
        try FileManager.default.createDirectory(at: data.root, withIntermediateDirectories: true)
        let layout = EnvironmentLayout(data: data, installRoot: root.path, home: mobile)
        XCTAssertTrue(layout.isRoothide)
        try layout.make(layout.environment)
        try JSONFile.write(SDKSourceList(), to: layout.sdkSources)
        try layout.make(layout.inbox)
        try SDKFixture.make(at: layout.inbox.appendingPathComponent("iPhoneOS99.0.sdk"))
        let manager = SDKManager(layout: layout)
        _ = try await manager.run(
            manager.prepare(SDKImportRequest(source: .inbox(path: "iPhoneOS99.0.sdk")), descriptors: []),
            staging: layout.makeStaging("sdk"), hasSwiftToolchain: false, reporter: .silent,
        )
        let transfers = TransferService(layout: layout, toolchains: ToolchainService(layout: layout, backend: FakeBackend()), sdk: manager)
        let inspection = try transfers.inspect(
            TransferInspectRequest(source: .file(DescriptorSlot(index: 0)), fileName: export.fileName),
            descriptors: [descriptor(export.path)],
        )
        XCTAssertTrue(inspection.importable, "\(inspection.problems)")
        XCTAssertTrue(inspection.notes.contains { $0.contains("packaged again for this roothide one") }, "\(inspection.notes)")
        let installer = FakeInstaller(installRoot: root.path)
        let prepared = try transfers.prepareImport(
            TransferImportRequest(source: .file(DescriptorSlot(index: 0)), fileName: export.fileName),
            descriptors: [descriptor(export.path)],
        )
        let log = EventLog()
        _ = try await transfers.runImport(prepared, staging: layout.makeStaging("i"), taskID: TaskID("i"), installer: installer, reporter: log.reporter)
        XCTAssertEqual(installer.installed.count, 1)
        // The deb this device built: roothide's architecture.
        XCTAssertEqual(log.last("artifact")?["packageID"]?.stringValue, "wiki.qaq.apelin.toolchain.\(FakeBackend.id)")
    }

    func testAToolchainOfAReleaseThisApelinDoesNotSupportIsRefusedBeforeReading() async throws {
        let second = try await device()
        var record = ToolchainRecord(id: FakeBackend.id, version: FakeBackend.unsupportedVersion, components: [ToolchainComponent(kind: .c, selfCheckPassed: true)])
        record.contentDigest = "x"
        let manifest = TransferManifest(
            kind: .toolchain, id: FakeBackend.id, name: "Command Line Tools 9.9", createdBy: "test",
            members: [TransferMember(path: "usr", kind: .directory)],
            toolchain: TransferToolchain(record: record, retargetScheme: 2, productID: "001", sourceSHA256: "ab", bootstrap: "rootless", architecture: "iphoneos-arm64", minimumOS: "16.0"),
        )
        let file = try craft(manifest, payload: [("payload/usr", nil)], on: second, named: "Old.apetc")
        let inspection = try inspect(file.path, on: second)
        XCTAssertFalse(inspection.importable)
        XCTAssertEqual(inspection.problems.first, "Command Line Tools 9.9 is not a release this Apelin supports.")
        let refusal = await code { _ = try await self.importFile(file.path, on: second) }
        XCTAssertEqual(refusal, .badRequest)
    }

    // MARK: Damaged and hostile files

    /// A transfer file written by hand: `manifest` first, then `payload` in
    /// order (a nil data is a folder).
    private func craft(
        _ manifest: TransferManifest,
        payload: [(String, Data?)],
        on home: TemporaryHome,
        named name: String,
    ) throws -> URL {
        var entries = try [ArchiveFixture.Entry(name: TransferManifest.fileName, data: JSONCoding.encode(manifest))]
        for (path, data) in payload {
            entries.append(data.map { ArchiveFixture.Entry(name: path, data: $0) } ?? ArchiveFixture.Entry(name: path, directory: true))
        }
        let url = home.home.appendingPathComponent(name)
        try ArchiveFixture.write(entries, kind: .tarZstd, to: url)
        return url
    }

    private func sdkManifest(_ members: [TransferMember]) -> TransferManifest {
        TransferManifest(
            kind: .sdk, id: "iphoneos99.0-00000000", name: "iPhoneOS 99.0", createdBy: "test", members: members,
            sdk: TransferSDK(record: SDKRecord(id: "iphoneos99.0-00000000", canonicalName: "iphoneos99.0", version: "99.0", path: "")),
        )
    }

    private static func sha(_ data: Data) -> String {
        TransferDigest.hex(SHA256.hash(data: data))
    }

    func testATamperedMemberFailsTheImportAndRegistersNothing() async throws {
        let home = try await device(registerSDK: false)
        let original = Data("{\"CanonicalName\": \"iphoneos99.0\"}".utf8)
        let manifest = sdkManifest([TransferMember(path: "SDKSettings.json", kind: .file, size: Int64(original.count), sha256: Self.sha(original))])
        let tampered = Data("{\"CanonicalName\": \"iphoneos66.6\"}".utf8)
        let file = try craft(manifest, payload: [("payload/SDKSettings.json", tampered)], on: home, named: "Bad.apesdk")
        XCTAssertTrue(try inspect(file.path, on: home).importable, "the manifest alone is fine")
        do {
            _ = try await importFile(file.path, on: home)
            XCTFail("a member that does not match its digest is refused")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .badRequest)
            XCTAssertTrue(error.message.contains("damaged or was changed"), error.message)
        }
        XCTAssertTrue(SDKStore(layout: home.layout).list().isEmpty)
    }

    func testAMemberThatLeadsOutsideIsRefusedBeforeAnythingIsWritten() async throws {
        let home = try await device(registerSDK: false)
        let data = Data("x".utf8)
        for path in ["../escape", "/etc/escape", "a/../../escape"] {
            let manifest = sdkManifest([TransferMember(path: path, kind: .file, size: 1, sha256: Self.sha(data))])
            let file = try craft(manifest, payload: [("payload/" + path, data)], on: home, named: "Escape.apesdk")
            let refusal = await code { _ = try self.inspect(file.path, on: home) }
            XCTAssertEqual(refusal, .badRequest, path)
        }
        // A link out, and a member the manifest does not list.
        let outward = sdkManifest([TransferMember(path: "out", kind: .link, target: "../../etc")])
        let link = try craft(outward, payload: [], on: home, named: "Link.apesdk")
        let linkRefusal = await code { _ = try self.inspect(link.path, on: home) }
        XCTAssertEqual(linkRefusal, .badRequest)
        let listed = sdkManifest([TransferMember(path: "a", kind: .file, size: 1, sha256: Self.sha(data))])
        let extra = try craft(listed, payload: [("payload/a", data), ("payload/b", data)], on: home, named: "Extra.apesdk")
        let extraRefusal = await code { _ = try await self.importFile(extra.path, on: home) }
        XCTAssertEqual(extraRefusal, .badRequest)
        let missing = try craft(listed, payload: [], on: home, named: "Missing.apesdk")
        let missingRefusal = await code { _ = try await self.importFile(missing.path, on: home) }
        XCTAssertEqual(missingRefusal, .badRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.home.appendingPathComponent("escape").path))
    }

    func testAFileFromANewerApelinOrNotATransferFileIsRefused() async throws {
        let home = try await device(registerSDK: false)
        var manifest = sdkManifest([])
        manifest.formatVersion = TransferManifest.currentFormatVersion + 1
        let newer = try craft(manifest, payload: [], on: home, named: "Newer.apesdk")
        let newerRefusal = await code { _ = try self.inspect(newer.path, on: home) }
        XCTAssertEqual(newerRefusal, .badRequest)
        let plain = home.home.appendingPathComponent("Plain.apesdk")
        try ArchiveFixture.write([ArchiveFixture.Entry(name: "README", data: Data("hi".utf8))], kind: .tarZstd, to: plain)
        let plainRefusal = await code { _ = try self.inspect(plain.path, on: home) }
        XCTAssertEqual(plainRefusal, .badRequest)
    }

    // MARK: Project

    private func makeProject(_ home: TemporaryHome, name: String = "Hello Tweak", id: String = "8a6f3c1e-0000-4000-8000-0000000000aa") throws -> URL {
        let root = home.layout.data.projects.appendingPathComponent(name, isDirectory: true)
        let repository = try GitRepository.create(at: root)
        let description = """
        {
          "schemaVersion": 1,
          "projectID": "\(id)",
          "environment": {"toolchain": {"id": "missing-toolchain", "digest": "sha256:0"}, "sdk": {"id": "missing-sdk", "digest": "sha256:0"}}
        }
        """
        try Data(description.utf8).write(to: root.appendingPathComponent("apelin-project.json"))
        try Data("int main(void) { return 0; }\n".utf8).write(to: root.appendingPathComponent("main.c"))
        try Data("build/\n*.o\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try repository.stage(["apelin-project.json", "main.c", ".gitignore"])
        _ = try repository.commit(message: "Start", author: GitSignature(name: "A", email: "a@apelin.invalid"))
        // Work in progress, and what the ignore rules name.
        try Data("// new\n".utf8).write(to: root.appendingPathComponent("new.c"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: root.appendingPathComponent("build/out.bin"))
        try Data("obj".utf8).write(to: root.appendingPathComponent("main.o"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        // What would run on the other device.
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: root.appendingPathComponent(".git/hooks/pre-commit"))
        try repository.setLocalConfigValue("https://example.invalid/hello.git", for: "remote.origin.url")
        try repository.setLocalConfigValue("/tmp/evil", for: "core.fsmonitor")
        return root
    }

    func testAProjectTravelsWithItsHistoryUnderANewIDAndNothingThatWouldRun() async throws {
        let first = try await device()
        let oldID = "8a6f3c1e-0000-4000-8000-0000000000aa"
        let root = try makeProject(first)
        let head = try GitRepository(at: root).head().commit
        let export = try await export(first, .project, "Hello Tweak")
        XCTAssertEqual(export.fileName, "Hello Tweak.apeproj")
        let project = try XCTUnwrap(export.summary.project)
        XCTAssertEqual(project.projectID, oldID)
        XCTAssertTrue(project.includesRepository)
        XCTAssertEqual(project.remoteURL, "https://example.invalid/hello.git")

        let manifest = try service(first).inspect(TransferInspectRequest(source: .exported(path: export.exportedPath)), descriptors: [])
        XCTAssertEqual(manifest.summary.kind, .project)
        let paths = try TransferArchiveReader().manifest(.path(export.path)).members.map(\.path)
        XCTAssertTrue(paths.contains("main.c") && paths.contains("new.c") && paths.contains(".gitignore") && paths.contains(".git/HEAD"))
        for leftOut in ["build", "build/out.bin", "main.o", ".DS_Store", ".git/hooks", ".git/hooks/pre-commit", ".git/config"] {
            XCTAssertFalse(paths.contains(leftOut), leftOut)
        }

        let second = try await device()
        let inspection = try inspect(export.path, on: second)
        XCTAssertTrue(inspection.importable)
        XCTAssertEqual(inspection.suggestedName, "Hello Tweak")
        let result = try await importFile(export.path, on: second)
        let imported = try XCTUnwrap(result["project"]).decode(TransferProjectResult.self)
        XCTAssertEqual(imported.name, "Hello Tweak")
        XCTAssertEqual(imported.previousProjectID, oldID)
        XCTAssertNotEqual(imported.projectID, oldID)
        XCTAssertTrue(imported.includesRepository)
        let placed = second.layout.data.projects.appendingPathComponent("Hello Tweak")
        let description = try Data(contentsOf: placed.appendingPathComponent("apelin-project.json"))
        let sent = try String(contentsOf: root.appendingPathComponent("apelin-project.json"), encoding: .utf8)
        XCTAssertEqual(
            description,
            ProjectManifestFormat.formatted(Data(sent.replacingOccurrences(of: oldID, with: imported.projectID).utf8)),
            "only the ID changed, in the written form",
        )
        XCTAssertFalse(String(decoding: description, as: UTF8.self).contains(oldID))
        XCTAssertEqual(try String(contentsOf: placed.appendingPathComponent("new.c"), encoding: .utf8), "// new\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: placed.appendingPathComponent(".git/hooks/pre-commit").path))
        let repository = try GitRepository(at: placed)
        XCTAssertEqual(repository.head().commit, head)
        XCTAssertEqual(repository.remoteURL(), "https://example.invalid/hello.git")
        XCTAssertNil(repository.localConfigValue("core.fsmonitor"))
        XCTAssertEqual(ProjectLocator(layout: second.layout).all().first?.projectID, imported.projectID)

        // Again: under the next free name, unless a taken name is asked for.
        let next = try await importFile(export.path, on: second)
        XCTAssertEqual(try XCTUnwrap(next["project"]).decode(TransferProjectResult.self).name, "Hello Tweak 2")
        XCTAssertEqual(try inspect(export.path, on: second).suggestedName, "Hello Tweak 3")
        let taken = await code { _ = try await self.importFile(export.path, on: second, projectName: "Hello Tweak") }
        XCTAssertEqual(taken, .conflict)
        let renamed = try await importFile(export.path, on: second, projectName: "Copy")
        XCTAssertEqual(try XCTUnwrap(renamed["project"]).decode(TransferProjectResult.self).name, "Copy")
    }

    func testProjectIgnoreRulesCoverNestedDirectoriesNegationAndTrackedFiles() async throws {
        let home = try await device(registerSDK: false)
        let root = try makeProject(home)
        let repository = try GitRepository(at: root)
        func write(_ path: String, _ text: String = "contents") throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("tracked/keep.bin")
        try repository.stage(["tracked/keep.bin"])
        try write(".gitignore", """
        build/
        *.o
        tracked/
        cache/*
        !cache/keep.txt
        blocked/
        !blocked/keep.txt
        /root-only.txt
        *.tmp
        \\#literal
        escaped\\ name
        """)
        try write(".git/info/exclude", "local.secret\n")
        for path in ["tracked/drop.bin", "cache/drop.txt", "cache/keep.txt", "blocked/keep.txt", "root-only.txt", "deep/root-only.txt", "local.secret", "#literal", "escaped name", "line\nbreak.tmp"] {
            try write(path)
        }
        try write("deep/.gitignore", "*.log\n!keep.log\n/generated/\n")
        for path in ["deep/drop.log", "deep/keep.log", "deep/generated/file.c", "deep/nested/generated/file.c"] {
            try write(path)
        }
        let exported = try await export(home, .project, "Hello Tweak")
        let paths = try Set(TransferArchiveReader().manifest(.path(exported.path)).members.map(\.path))
        for kept in ["tracked/keep.bin", "cache/keep.txt", "deep/root-only.txt", "deep/keep.log", "deep/nested/generated/file.c", "deep/.gitignore"] {
            XCTAssertTrue(paths.contains(kept), kept)
        }
        for excluded in ["tracked/drop.bin", "cache/drop.txt", "blocked", "root-only.txt", "local.secret", "#literal", "escaped name", "line\nbreak.tmp", "deep/drop.log", "deep/generated"] {
            XCTAssertFalse(paths.contains(excluded), excluded)
        }
        let other = try await device(registerSDK: false)
        _ = try await importFile(exported.path, on: other)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.layout.data.projects.appendingPathComponent("Hello Tweak/cache/keep.txt").path))
    }

    func testFolderWithoutGitUsesIgnoreRulesAndAlwaysKeepsProjectDescription() async throws {
        let home = try await device(registerSDK: false)
        let root = try makeProject(home)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        try Data("*.json\n*.o\nbuild/\nnew.c\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("junk.json"))
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("*.cache\n!keep.cache\n".utf8).write(to: sources.appendingPathComponent(".gitignore"))
        try Data("keep".utf8).write(to: sources.appendingPathComponent("keep.cache"))
        try Data("drop".utf8).write(to: sources.appendingPathComponent("drop.cache"))
        let exported = try await export(home, .project, "Hello Tweak")
        let paths = try Set(TransferArchiveReader().manifest(.path(exported.path)).members.map(\.path))
        XCTAssertTrue(paths.contains("apelin-project.json"))
        XCTAssertTrue(paths.contains("main.c"))
        XCTAssertTrue(paths.contains("Sources/keep.cache"))
        for excluded in ["junk.json", "main.o", "build", "new.c", ".git", "Sources/drop.cache"] {
            XCTAssertFalse(paths.contains(excluded), excluded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path), "export must not initialize the source folder")
        XCTAssertFalse(try XCTUnwrap(exported.summary.project).includesRepository)
        let other = try await device(registerSDK: false)
        _ = try await importFile(exported.path, on: other)
        XCTAssertNotNil(ProjectLocator(layout: other.layout).all().first)
    }

    func testLargeProjectReportsMeasuredProgressAndCancellationCleansPartialFiles() async throws {
        let home = try await device(registerSDK: false)
        let root = try makeProject(home)
        let file = root.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let writer = try FileHandle(forWritingTo: file)
        let chunk = Data(repeating: 0xA5, count: 1 << 20)
        for _ in 0 ..< 16 {
            try writer.write(contentsOf: chunk)
        }
        try writer.close()

        var bytesBeforeCancel: Int64 = 0
        XCTAssertThrowsError(try TransferDigest.file(file) { count in
            bytesBeforeCancel = count
            throw ApelinError(.cancelled, "cancelled")
        }) { XCTAssertEqual(($0 as? ApelinError)?.code, .cancelled) }
        XCTAssertEqual(bytesBeforeCancel, 1 << 20, "a large file can stop after its first chunk")

        let log = EventLog()
        let exported = try await export(home, .project, "Hello Tweak", log: log)
        for stage in ["collecting", "hashing", "packing", "verifying"] {
            let samples = log.events.filter { $0.0 == "progress" && $0.1?["stage"]?.stringValue == stage }.compactMap(\.1)
            let completed = samples.compactMap { $0["completed"]?.doubleValue }
            XCTAssertFalse(completed.isEmpty, stage)
            XCTAssertEqual(completed, completed.sorted(), "\(stage) must be monotonic")
            XCTAssertEqual(completed.first, 0, stage)
            if stage != "collecting" {
                let totals = samples.compactMap { $0["total"]?.doubleValue }
                XCTAssertEqual(Set(totals).count, 1, "\(stage) has one measured denominator")
                XCTAssertEqual(completed.last, totals.last, stage)
            }
        }
        XCTAssertTrue(log.events.contains { $0.0 == "progress" && $0.1?["stage"]?.stringValue == "hashing" && ($0.1?["completed"]?.doubleValue ?? 0) > 0 && ($0.1?["completed"]?.doubleValue ?? 0) < ($0.1?["total"]?.doubleValue ?? 0) })
        let other = try await device(registerSDK: false)
        _ = try await importFile(exported.path, on: other)
        let restored = other.layout.data.projects.appendingPathComponent("Hello Tweak/large.bin")
        XCTAssertEqual(try TransferDigest.file(restored).sha256, try TransferDigest.file(file).sha256)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: exported.path).deletingLastPathComponent())

        for stage in ["collecting", "hashing", "packing", "verifying"] {
            let cancellation = CancellationFlag()
            let reporter = TaskReporter(cancellation: cancellation) { kind, payload in
                if kind == "progress", payload?["stage"]?.stringValue == stage,
                   (payload?["completed"]?.doubleValue ?? 0) > 0
                {
                    cancellation.cancel()
                }
            }
            let transfers = service(home)
            let prepared = try transfers.prepareExport(TransferExportRequest(kind: .project, id: "Hello Tweak"))
            let outcome = await code {
                _ = try await transfers.export(prepared, staging: home.layout.makeStaging("cancel-\(stage)"), reporter: reporter)
            }
            XCTAssertEqual(outcome, .cancelled, stage)
            let files = (try? FileManager.default.subpathsOfDirectory(atPath: home.layout.exports.path)) ?? []
            XCTAssertFalse(files.contains { $0.hasSuffix(".partial") || $0.hasSuffix(".apeproj") }, stage)
        }
        _ = try await export(home, .project, "Hello Tweak")
    }

    func testDirectoryReplacedWithOutsideLinkBetweenStagesIsRefused() async throws {
        for stage in ["hashing", "packing"] {
            let home = try await device(registerSDK: false)
            let root = try makeProject(home)
            let source = root.appendingPathComponent("source")
            let outside = home.inbox.appendingPathComponent("outside")
            for folder in [source, outside] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("same bytes".utf8).write(to: folder.appendingPathComponent("file.txt"))
            }
            let reporter = TaskReporter { kind, payload in
                guard kind == "stage", payload?["stage"]?.stringValue == stage else { return }
                try? FileManager.default.moveItem(at: source, to: root.appendingPathComponent("original"))
                try? FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
            }
            let transfers = service(home)
            let prepared = try transfers.prepareExport(TransferExportRequest(kind: .project, id: "Hello Tweak"))
            let outcome = await code {
                _ = try await transfers.export(prepared, staging: home.layout.makeStaging("changed-source"), reporter: reporter)
            }
            XCTAssertEqual(outcome, .conflict, stage)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), outside.path)
            let files = (try? FileManager.default.subpathsOfDirectory(atPath: home.layout.exports.path)) ?? []
            XCTAssertFalse(files.contains { $0.hasSuffix(".partial") || $0.hasSuffix(".apeproj") }, stage)
        }
    }

    func testAProjectCarryingARepositoryInsideItselfIsRefused() async throws {
        let home = try await device(registerSDK: false)
        let description = Data(#"{"projectID": "p-1"}"#.utf8)
        let config = Data("[core]\n\tfsmonitor = /tmp/evil\n".utf8)
        let manifest = TransferManifest(
            kind: .project, id: "p-1", name: "Nested", createdBy: "test",
            members: [
                TransferMember(path: "apelin-project.json", kind: .file, size: Int64(description.count), sha256: Self.sha(description)),
                TransferMember(path: "vendor", kind: .directory),
                TransferMember(path: "vendor/.GIT", kind: .directory),
                TransferMember(path: "vendor/.GIT/config", kind: .file, size: Int64(config.count), sha256: Self.sha(config)),
            ],
            project: TransferProject(projectID: "p-1", name: "Nested"),
        )
        let file = try craft(manifest, payload: [
            ("payload/apelin-project.json", description), ("payload/vendor", nil), ("payload/vendor/.GIT", nil), ("payload/vendor/.GIT/config", config),
        ], on: home, named: "Nested.apeproj")
        let refusal = await code { _ = try await self.importFile(file.path, on: home) }
        XCTAssertEqual(refusal, .badRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.layout.data.projects.appendingPathComponent("Nested").path))
    }
}
