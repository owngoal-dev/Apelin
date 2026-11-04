import ApelinCore
import ApelinDebArchive
@testable import ApelinEnvironment
@testable import ApelinProtocol
import Foundation
import XCTest

// MARK: - Fakes

/// Stands in for Packages/ApelinToolchain, holding to its contract: setup
/// "retargets" into a tree of one file; installAndValidate runs the install
/// step only when the bytes under the install root do not match, checks
/// them after, and "self-tests" the installed copy.
struct FakeBackend: ToolchainBackend {
    var failPrepare = false
    var failSelfTest = false
    /// Runs as the self-test starts: a test cancels the setup here.
    var onSelfTest: (@Sendable () -> Void)?
    /// What the catalog lists instead of `26.4` and `newest`.
    var products: [ToolchainProduct]?
    /// Told the SDK the self-test is handed.
    var onSDK: (@Sendable (URL) -> Void)?
    /// The Swift cases, when the setup asked for Swift.
    var swiftResults: [ToolchainSelfTestResult] = ["Swift", "Swift dylib", "Swift async"].map {
        ToolchainSelfTestResult(language: $0, architecture: "arm64e", passed: true)
    }

    var isAvailable: Bool {
        true
    }

    static let id = "0123456789abcdef01234567"
    static let newest = ToolchainProduct(productID: "001-00002", version: "27.0", url: "https://example.invalid/27.pkg", size: 1)
    static let tool = Data("#!/bin/sh\necho apelin-ok\n".utf8)

    func catalog() async throws -> [ToolchainProduct] {
        products ?? [
            ToolchainProduct(productID: "001-00001", version: "26.4", url: "https://example.invalid/26.pkg", size: 1),
            Self.newest,
        ]
    }

    func prepare(product: ToolchainProduct, components: [ToolchainComponentKind], staging: URL, output: URL, progress: @escaping @Sendable (ToolchainBackendProgress) -> Void) async throws -> PreparedToolchain {
        for stage in ["downloading", "extracting", "adapting"] {
            progress(ToolchainBackendProgress(stage: stage, detail: product.productID))
        }
        // A marker the resume test looks for: the staging survives a failure.
        FileManager.default.createFile(atPath: staging.appendingPathComponent("download").path, contents: Data("pkg".utf8))
        if failPrepare {
            throw ApelinError(.unavailable, "network down")
        }
        try FileManager.default.createDirectory(at: output.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
        try Self.tool.write(to: output.appendingPathComponent("usr/bin/clang"))
        progress(ToolchainBackendProgress(stage: "packaging"))
        return PreparedToolchain(id: Self.id, product: product, components: components, tree: output, files: ["usr/bin/clang": "digest"], installRelativePath: "usr/lib/apelin/toolchains/\(Self.id)", manifest: Data("{}".utf8))
    }

    func installAndValidate(_ prepared: PreparedToolchain, installRoot: URL, sdk: URL, journal _: URL, scratch _: URL, install: @escaping ToolchainInstallStep, progress: @escaping @Sendable (ToolchainBackendProgress) -> Void) async throws -> [ToolchainSelfTestResult] {
        XCTAssertEqual(sdk.path, CanonicalPath.resolve(sdk.path), "the SDK is handed over as its physical path")
        onSDK?(sdk)
        let installed = installRoot.appendingPathComponent(prepared.installRelativePath + "/usr/bin/clang")
        progress(ToolchainBackendProgress(stage: "installing"))
        if FileManager.default.contents(atPath: installed.path) != Self.tool {
            try await install(prepared)
        }
        guard FileManager.default.contents(atPath: installed.path) == Self.tool else { throw ApelinError(.internal, "digest mismatch") }
        progress(ToolchainBackendProgress(stage: "validating"))
        onSelfTest?()
        return [
            ToolchainSelfTestResult(language: "C", architecture: "arm64", passed: !failSelfTest),
            ToolchainSelfTestResult(language: "ObjC", architecture: "arm64e", passed: true),
        ] + (prepared.components.contains(.swift) ? swiftResults : [])
    }

    /// Run Again: the installed tree tested where it lies, against the SDK
    /// handed over; a failing case comes back failed, not thrown.
    func selfTest(installed: URL, sdk _: URL, scratch: URL, progress: @escaping @Sendable (ToolchainBackendProgress) -> Void) async throws -> [ToolchainSelfTestResult] {
        guard FileManager.default.contents(atPath: installed.appendingPathComponent("usr/bin/clang").path) == Self.tool else {
            throw ApelinError(.internal, "not the installed tree")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path), "a scratch folder of the task's own")
        progress(ToolchainBackendProgress(stage: "validating"))
        return [
            ToolchainSelfTestResult(language: "C", architecture: "arm64", passed: !failSelfTest, seconds: 0.5),
            ToolchainSelfTestResult(language: "ObjC", architecture: "arm64e", passed: true, seconds: 0.5),
        ]
    }
}

/// The install bridge, as far as the worker can tell: "installs" a toolchain
/// package by putting its tree under the install root, removes it again.
final class FakeInstaller: PackageInstaller, @unchecked Sendable {
    let installRoot: String?
    private let lock = NSLock()
    private var installedArtifacts: [LocalArtifact] = []
    private var removedIDs: [String] = []
    var delay: UInt64 = 0
    var removalFailure: ApelinError?
    private var installStarted = false

    init(installRoot: String? = nil) {
        self.installRoot = installRoot
    }

    var installed: [LocalArtifact] {
        lock.withLock { installedArtifacts }
    }

    var removed: [String] {
        lock.withLock { removedIDs }
    }

    var started: Bool {
        lock.withLock { installStarted }
    }

    private func folder(_ id: String) -> String? {
        installRoot.map { $0 + "/usr/lib/apelin/toolchains/" + id }
    }

    private var tasks: [String: LocalArtifact] = [:]
    /// Packages handed to the "bridge", whether or not followed to the end.
    var submitted: Int {
        lock.withLock { tasks.count }
    }

    func startInstall(_ artifact: LocalArtifact) async throws -> TaskHandle {
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path), "the deb is there while the bridge reads it")
        return lock.withLock {
            let id = "install-\(tasks.count + 1)"
            tasks[id] = artifact
            return TaskHandle(taskID: TaskID(id), kind: .install)
        }
    }

    func finishInstall(_ handle: TaskHandle, reporter _: TaskReporter) async throws -> InstallResult {
        guard let artifact = lock.withLock({ tasks[handle.taskID.rawValue] }) else { throw ApelinError(.notFound, "no task \(handle.taskID.rawValue)") }
        lock.withLock { installStarted = true }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        let count = lock.withLock { () -> Int in
            installedArtifacts.append(artifact)
            return installedArtifacts.count
        }
        if let folder = folder(String(artifact.artifactID.dropFirst("toolchain-".count))) {
            try FileManager.default.createDirectory(atPath: folder + "/usr/bin", withIntermediateDirectories: true)
            try FakeBackend.tool.write(to: URL(fileURLWithPath: folder + "/usr/bin/clang"))
        }
        return InstallResult(installationID: "inst-\(count)", transactionID: "tx-\(count)", packageID: artifact.packageID, version: artifact.version)
    }

    func remove(installationID: String, reporter _: TaskReporter) async throws {
        if let removalFailure {
            throw removalFailure
        }
        lock.withLock { removedIDs.append(installationID) }
        if let folder = folder(FakeBackend.id) {
            try? FileManager.default.removeItem(atPath: folder)
        }
    }
}

// MARK: - ToolchainService

final class ToolchainServiceTests: XCTestCase {
    private func registerSDK(_ home: TemporaryHome) async throws {
        try SDKFixture.make(at: home.inbox.appendingPathComponent("iPhoneOS99.0.sdk"))
        let manager = SDKManager(layout: home.layout)
        let prepared = try manager.prepare(SDKImportRequest(source: .inbox(path: "iPhoneOS99.0.sdk")), descriptors: [])
        _ = try await manager.run(prepared, staging: home.layout.makeStaging("sdk"), hasSwiftToolchain: false, reporter: .silent)
    }

    private func ready(_ test: XCTestCase) async throws -> TemporaryHome {
        let home = try TemporaryHome(test)
        try FileManager.default.createDirectory(atPath: home.layout.installRoot, withIntermediateDirectories: true)
        try home.layout.make(home.layout.environment)
        try JSONFile.write(SDKSourceList(), to: home.layout.sdkSources)
        try await registerSDK(home)
        return home
    }

    private func jobFolder(_ home: TemporaryHome) -> URL {
        let product = FakeBackend.newest
        return home.layout.toolchainJobs.appendingPathComponent(ToolchainService.jobKey(product: product, components: [.c]))
    }

    private func installedPath(_ home: TemporaryHome) -> String {
        home.layout.installRoot + "/usr/lib/apelin/toolchains/" + FakeBackend.id
    }

    func testSetDefaultPersistsWithoutChangingRecordsAndRejectsUnknownIDs() throws {
        let home = try TemporaryHome(self)
        let records = [
            ToolchainRecord(id: "first", version: "16.4", components: [.init(kind: .c)]),
            ToolchainRecord(id: "second", version: "27.0", components: [.init(kind: .c), .init(kind: .swift)]),
        ]
        try ToolchainRegistry(toolchains: records, defaultID: "first").save(home.layout)
        let service = ToolchainService(layout: home.layout, backend: UnavailableToolchainBackend())
        try service.setDefault(id: "second")
        let saved = ToolchainRegistry.load(home.layout)
        XCTAssertEqual(saved.defaultID, "second")
        XCTAssertEqual(saved.toolchains, records)
        try service.setDefault(id: "second")
        XCTAssertThrowsError(try service.setDefault(id: "missing")) { error in
            XCTAssertEqual((error as? ApelinError)?.code, .notFound)
        }
        XCTAssertEqual(ToolchainRegistry.load(home.layout), saved)
    }

    func testUnavailableBackendRefusesSetupButStatusWorks() throws {
        let home = try TemporaryHome(self)
        let service = ToolchainService(layout: home.layout, backend: UnavailableToolchainBackend())
        XCTAssertThrowsError(try service.prepare(ToolchainSetupRequest())) { XCTAssertEqual(($0 as? ApelinError)?.code, .unavailable) }
        XCTAssertEqual(service.status(activeTasks: []), ToolchainStatusResponse())
    }

    func testSetupNeedsAnSDKOrAnEnabledSource() throws {
        let home = try TemporaryHome(self)
        try home.layout.make(home.layout.environment)
        try JSONFile.write(SDKSourceList(), to: home.layout.sdkSources)
        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        XCTAssertThrowsError(try service.prepare(ToolchainSetupRequest())) { XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest) }
    }

    func testSetupPackagesInstallsThroughTheBridgeAndRegisters() async throws {
        let home = try await ready(self)
        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let log = EventLog()
        let record = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("t1"), installer: installer, reporter: log.reporter)

        XCTAssertEqual(record.version, "27.0", "the newest product")
        XCTAssertEqual(record.components, [ToolchainComponent(kind: .c, selfCheckPassed: true)])
        XCTAssertEqual(record.installationID, "inst-1")
        XCTAssertEqual(record.packageID, "wiki.qaq.apelin.toolchain.0123456789abcdef01234567")
        XCTAssertEqual(record.path, installedPath(home))
        XCTAssertEqual(record.contentDigest, ToolchainService.contentDigest(["usr/bin/clang": "digest"]))
        let stages = log.events.filter { $0.0 == "stage" }.compactMap { $0.1?["stage"]?.stringValue }
        XCTAssertEqual(stages, ["downloading", "extracting", "adapting", "packaging", "installing", "validating", "ready"])

        // The deb handed to the bridge, gone once the bridge has its copy.
        let artifact = try XCTUnwrap(installer.installed.first)
        XCTAssertEqual(installer.installed.count, 1)
        XCTAssertEqual(artifact.artifactID, "toolchain-0123456789abcdef01234567")
        XCTAssertEqual(artifact.digest.count, 64)
        XCTAssertEqual(artifact.version, "27.0+01234567")
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))

        let status = service.status(activeTasks: [])
        XCTAssertEqual(status.defaultID, record.id)
        XCTAssertEqual(status.toolchains.map(\.id), [record.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobFolder(home).path), "the job folder goes once ready")

        // What apelin-build reads, and what a project binds.
        let stores = try EnvironmentStoresReader(home: home).toolchains()
        XCTAssertEqual(stores, try [record.id: "sha256:" + XCTUnwrap(record.contentDigest)])

        // Set up again: the registered install is reused, not repeated.
        _ = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("t2"), installer: installer, reporter: .silent)
        XCTAssertEqual(installer.installed.count, 1)

        // Removal goes through the bridge too, and checks projects first.
        let project = home.layout.data.projects.appendingPathComponent("Uses")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"projectID": "p", "environment": {"toolchain": {"id": "\#(record.id)", "digest": "d"}, "sdk": {"id": "s", "digest": "d"}}}"#.utf8)
            .write(to: project.appendingPathComponent("apelin-project.json"))
        XCTAssertThrowsError(try service.prepareRemoval(ToolchainRemoveRequest(id: record.id))) { XCTAssertEqual(($0 as? ApelinError)?.code, .conflict) }
        try FileManager.default.removeItem(at: project)
        try await service.remove(service.prepareRemoval(ToolchainRemoveRequest(id: record.id)), installer: installer, reporter: .silent)
        XCTAssertEqual(installer.removed, ["inst-1"])
        XCTAssertEqual(service.status(activeTasks: []), ToolchainStatusResponse())
    }

    // MARK: Releases and the SDKs they read

    private static let older = ToolchainProduct(
        productID: "001-00016", version: "16.4", url: "https://example.invalid/16.pkg", size: 1, newestSDK: "18.5",
    )
    private static let refused = ToolchainProduct(
        productID: "001-00012", version: "12.4", url: "https://example.invalid/12.pkg", size: 1,
        unsupportedReason: "Command Line Tools 12.4 cannot be set up: a reason.", reviewed: false,
    )
    /// A kept release this device cannot run: listed, struck through, with why.
    private static let cannotRun = ToolchainProduct(
        productID: "001-00027", version: "27.0", url: "https://example.invalid/27b.pkg", size: 1,
        unsupportedReason: "This toolchain requires CPU features this device lacks: FEAT_LRCPC.", reviewed: true,
    )

    /// The picker lists only releases Apelin sets up: an unreviewed or
    /// dropped one is left out, a kept one this device cannot run stays with
    /// its reason, and setup still refuses the left-out one by ID.
    func testTheCatalogLeavesOutReleasesApelinDoesNotSetUp() async throws {
        let home = try await ready(self)
        let service = ToolchainService(
            layout: home.layout,
            backend: FakeBackend(products: [Self.refused, Self.cannotRun, FakeBackend.newest, Self.older]),
        )
        let listed = try await service.catalog().products
        XCTAssertFalse(listed.contains { $0.productID == Self.refused.productID })
        XCTAssertEqual(Set(listed.map(\.productID)), [Self.cannotRun.productID, FakeBackend.newest.productID, Self.older.productID])
        XCTAssertEqual(listed.first { $0.productID == Self.cannotRun.productID }?.unsupportedReason, Self.cannotRun.unsupportedReason)
        XCTAssertNil(listed.first { $0.productID == FakeBackend.newest.productID }?.unsupportedReason)
    }

    /// roothide Bootstrap runs no ad hoc signature (issue #35: CLT 16.4 was
    /// downloaded, installed and then failed its self-test). Every release
    /// is listed with that reason, and setup is refused before the task is
    /// accepted, so nothing downloads.
    func testRoothideBootstrapRefusesEveryReleaseBeforeAnyDownload() async throws {
        let home = try await ready(self)
        let root = home.home.appendingPathComponent(".jbroot-F1E6FD3C82204430", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent(".thebootstrapped").path, contents: Data("1900".utf8))
        let layout = EnvironmentLayout(data: home.layout.data, installRoot: root.path, home: home.home.path)
        let service = ToolchainService(
            layout: layout,
            backend: FakeBackend(products: [Self.cannotRun, FakeBackend.newest, Self.older]),
        )
        let listed = try await service.catalog().products
        XCTAssertEqual(listed.count, 3)
        XCTAssertEqual(Set(listed.map(\.unsupportedReason)), [HostSigning.bootstrapRefusal])
        for product in [FakeBackend.newest, Self.older] {
            XCTAssertThrowsError(try service.prepare(ToolchainSetupRequest(source: .appleCatalog(productID: product.productID)))) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .unavailable)
                XCTAssertEqual(($0 as? ApelinError)?.message, HostSigning.bootstrapRefusal)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.toolchainJobs.path))
    }

    private func registerSDK(_ home: TemporaryHome, version: String) async throws {
        let name = "iPhoneOS\(version).sdk"
        try SDKFixture.make(at: home.inbox.appendingPathComponent(name), canonicalName: "iphoneos\(version)", version: version)
        let manager = SDKManager(layout: home.layout)
        let prepared = try manager.prepare(SDKImportRequest(source: .inbox(path: name)), descriptors: [])
        _ = try await manager.run(prepared, staging: home.layout.makeStaging("sdk-\(version)"), hasSwiftToolchain: false, reporter: .silent)
    }

    func testARefusedReleaseIsABadRequestBeforeAnyDownload() async throws {
        let home = try await ready(self)
        let service = ToolchainService(layout: home.layout, backend: FakeBackend(products: [Self.refused, FakeBackend.newest]))
        let request = ToolchainSetupRequest(source: .appleCatalog(productID: Self.refused.productID))
        do {
            _ = try await service.setup(service.prepare(request), taskID: TaskID("t"), installer: FakeInstaller(installRoot: home.layout.installRoot), reporter: .silent)
            XCTFail("a refused release must not set up")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .badRequest)
            XCTAssertEqual(error.message, Self.refused.unsupportedReason)
        }
        let key = ToolchainService.jobKey(product: Self.refused, components: [.c])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.layout.toolchainJobs.appendingPathComponent(key).path))
    }

    func testWithoutAProductTheNewestReleaseApelinTakesIsPicked() async throws {
        let home = try await ready(self)
        let newestRefused = ToolchainProduct(productID: "001-00099", version: "99.0", url: "https://example.invalid/99.pkg", size: 1, unsupportedReason: "not tested")
        let service = ToolchainService(layout: home.layout, backend: FakeBackend(products: [newestRefused, FakeBackend.newest]))
        let record = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("t"), installer: FakeInstaller(installRoot: home.layout.installRoot), reporter: .silent)
        XCTAssertEqual(record.version, "27.0")
    }

    func testTheSelfTestCompilesAgainstTheNewestSDKTheReleaseReads() async throws {
        let home = try await ready(self) // iPhoneOS 99.0
        try await registerSDK(home, version: "17.4")
        try await registerSDK(home, version: "18.2")
        let seen = EventLog()
        let backend = FakeBackend(products: [Self.older], onSDK: { seen.append("sdk", .string($0.lastPathComponent)) })
        let service = ToolchainService(layout: home.layout, backend: backend)
        let request = ToolchainSetupRequest(source: .appleCatalog(productID: Self.older.productID))
        let record = try await service.setup(service.prepare(request), taskID: TaskID("t"), installer: FakeInstaller(installRoot: home.layout.installRoot), reporter: .silent)
        XCTAssertEqual(seen.events.first?.1?.stringValue.map { $0.hasPrefix("iphoneos18.2-") }, true)
        XCTAssertEqual(record.newestSDK, "18.5")
        XCTAssertEqual(service.status(activeTasks: []).toolchains.first?.newestSDK, "18.5")
    }

    /// Every Swift case counts for the Swift component — `Swift dylib` and
    /// `Swift async` too — and one failing case is enough to fail it.
    func testTheSwiftComponentPassesOnlyWhenEverySwiftCaseDoes() async throws {
        let home = try await ready(self)
        let request = ToolchainSetupRequest(source: .appleCatalog(productID: FakeBackend.newest.productID), components: [.c, .swift])
        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        let record = try await service.setup(service.prepare(request), taskID: TaskID("t"), installer: FakeInstaller(installRoot: home.layout.installRoot), reporter: .silent)
        XCTAssertEqual(record.components.map(\.kind), [.c, .swift])
        XCTAssertEqual(record.components.last?.selfCheckPassed, true)
        XCTAssertNil(record.components.last?.problem)

        var failing = FakeBackend()
        failing.swiftResults[2].passed = false
        let other = try await ready(self)
        let failed = try await ToolchainService(layout: other.layout, backend: failing)
            .setup(ToolchainService(layout: other.layout, backend: failing).prepare(request), taskID: TaskID("t"), installer: FakeInstaller(installRoot: other.layout.installRoot), reporter: .silent)
        XCTAssertEqual(failed.components.last?.selfCheckPassed, false)
        XCTAssertNotNil(failed.components.last?.problem)
    }

    func testSwiftNeedsAnSDKOfTheReleasesOwnMajor() async throws {
        let home = try await ready(self) // iPhoneOS 99.0, which 27.0 does not read
        try await registerSDK(home, version: "18.5")
        let release = ToolchainProduct(productID: "001-00027", version: "27.0", url: "https://example.invalid/27.pkg", size: 1, newestSDK: "27.0")
        let seen = EventLog()
        let service = ToolchainService(layout: home.layout, backend: FakeBackend(products: [release], onSDK: { seen.append("sdk", .string($0.lastPathComponent)) }))
        let request = ToolchainSetupRequest(source: .appleCatalog(productID: release.productID), components: [.c, .swift])
        do {
            _ = try await service.setup(service.prepare(request), taskID: TaskID("t"), installer: FakeInstaller(installRoot: home.layout.installRoot), reporter: .silent)
            XCTFail("Swift against an 18.5 SDK")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .badRequest)
            XCTAssertTrue(error.message.contains("iPhoneOS 27 SDK"), error.message)
        }
        try await registerSDK(home, version: "27.0")
        _ = try await service.setup(service.prepare(request), taskID: TaskID("t2"), installer: FakeInstaller(installRoot: home.layout.installRoot), reporter: .silent)
        XCTAssertEqual(seen.events.first?.1?.stringValue.map { $0.hasPrefix("iphoneos27.0-") }, true)
    }

    func testSDKVersionLimitComparesMajorAndMinor() {
        XCTAssertTrue(SDKVersionLimit.allows(sdkVersion: "18.2.1", newestSDK: "18.2"))
        XCTAssertTrue(SDKVersionLimit.allows(sdkVersion: "17.4", newestSDK: "18.2"))
        XCTAssertTrue(SDKVersionLimit.allows(sdkVersion: "99.0", newestSDK: nil))
        XCTAssertFalse(SDKVersionLimit.allows(sdkVersion: "18.5", newestSDK: "18.2"))
        XCTAssertFalse(SDKVersionLimit.allows(sdkVersion: "27.0", newestSDK: "18.5"))
    }

    func testSDKVersionLimitOfAMajorTakesItsPointReleases() {
        XCTAssertTrue(SDKVersionLimit.allows(sdkVersion: "27.1", newestSDK: "27"))
        XCTAssertTrue(SDKVersionLimit.allows(sdkVersion: "27.4.1", newestSDK: "27"))
        XCTAssertTrue(SDKVersionLimit.allows(sdkVersion: "18.5", newestSDK: "27"))
        XCTAssertFalse(SDKVersionLimit.allows(sdkVersion: "28.0", newestSDK: "27"))
    }

    func testNoSDKTheReleaseReadsIsABadRequestNamingTheLimit() async throws {
        let home = try await ready(self) // only iPhoneOS 99.0
        let service = ToolchainService(layout: home.layout, backend: FakeBackend(products: [Self.older]))
        let request = ToolchainSetupRequest(source: .appleCatalog(productID: Self.older.productID))
        do {
            _ = try await service.setup(service.prepare(request), taskID: TaskID("t"), installer: FakeInstaller(installRoot: home.layout.installRoot), reporter: .silent)
            XCTFail("no SDK the release reads")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .badRequest)
            XCTAssertTrue(error.message.contains("up to 18.5"), error.message)
            XCTAssertTrue(error.message.contains("99.0"), error.message)
        }
    }

    func testAFailedSetupLeavesItsStageRecordAndResumes() async throws {
        let home = try await ready(self)
        let failing = ToolchainService(layout: home.layout, backend: FakeBackend(failPrepare: true))
        do {
            _ = try await failing.setup(failing.prepare(ToolchainSetupRequest()), taskID: TaskID("first"), installer: FakeInstaller(installRoot: home.layout.installRoot), reporter: .silent)
            XCTFail("setup should fail")
        } catch {}
        let folder = jobFolder(home)
        let job = try XCTUnwrap(try JSONFile.read(ToolchainJob.self, at: folder.appendingPathComponent("job.json")))
        XCTAssertEqual(job.stage, "adapting")
        XCTAssertEqual(job.taskID, "first")
        XCTAssertNotNil(job.failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("staging/download").path))

        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        let log = EventLog()
        _ = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("second"), installer: FakeInstaller(installRoot: home.layout.installRoot), reporter: log.reporter)
        XCTAssertEqual(log.last("resumed")?["stage"]?.stringValue, "adapting")
        XCTAssertEqual(log.last("resumed")?["previousTask"]?.stringValue, "first")
    }

    /// A worker that stopped after irisind answered: job.json keeps the
    /// installation, and the next setup registers it without installing again.
    func testAnInstallTheJobRecordedIsResumedNotRepeated() async throws {
        let home = try await ready(self)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let earlier = try await installer.install(LocalArtifact(artifactID: "toolchain-" + FakeBackend.id, path: home.home.path, digest: "", packageID: ToolchainPackager.packageID(for: FakeBackend.id), version: "27.0+01234567"), reporter: .silent)
        let folder = jobFolder(home)
        try home.layout.make(folder)
        let product = FakeBackend.newest
        try JSONFile.write(ToolchainJob(key: folder.lastPathComponent, productID: product.productID, components: [.c], stage: "installing", taskID: "killed", toolchainID: FakeBackend.id, installationID: earlier.installationID, updated: Date()), to: folder.appendingPathComponent("job.json"))

        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        let log = EventLog()
        let record = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("again"), installer: installer, reporter: log.reporter)
        XCTAssertEqual(installer.installed.count, 1, "nothing installed twice")
        XCTAssertEqual(record.installationID, earlier.installationID)
        XCTAssertEqual(log.last("resumed")?["previousTask"]?.stringValue, "killed")
    }

    /// An install an earlier run of the job made and never registered is
    /// this setup's too: a cancel during the self-test removes it through
    /// the bridge rather than dropping job.json, its only record.
    func testACancelRemovesTheInstallAnEarlierRunOfTheJobMade() async throws {
        let home = try await ready(self)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let earlier = try await installer.install(
            LocalArtifact(
                artifactID: "toolchain-" + FakeBackend.id,
                path: home.home.path,
                digest: "",
                packageID: ToolchainPackager.packageID(for: FakeBackend.id),
                version: "27.0+01234567",
            ),
            reporter: .silent,
        )
        let folder = jobFolder(home)
        try home.layout.make(folder)
        try JSONFile.write(
            ToolchainJob(
                key: folder.lastPathComponent,
                productID: FakeBackend.newest.productID,
                components: [.c],
                stage: "installing",
                taskID: "killed",
                toolchainID: FakeBackend.id,
                installationID: earlier.installationID,
                updated: Date(),
            ),
            to: folder.appendingPathComponent("job.json"),
        )

        let flag = CancellationFlag()
        let service = ToolchainService(layout: home.layout, backend: FakeBackend(onSelfTest: { flag.cancel() }))
        let reporter = TaskReporter(cancellation: flag) { _, _ in }
        do {
            _ = try await service.setup(
                service.prepare(ToolchainSetupRequest()),
                taskID: TaskID("again"),
                installer: installer,
                reporter: reporter,
            )
            XCTFail("setup should be cancelled")
        } catch {}
        XCTAssertEqual(installer.installed.count, 1, "nothing installed twice")
        XCTAssertEqual(installer.removed, [earlier.installationID], "the earlier run's install is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedPath(home)))
        XCTAssertEqual(service.status(activeTasks: []).toolchains, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// A re-setup of a registered toolchain whose earlier run installed and
    /// died before registering: when this run fails before it reaches the
    /// registry itself, the install is still handed to the registered
    /// toolchain, never removed from under it.
    func testAnEarlyFailureHandsAnEarlierRunsInstallToTheRegisteredToolchain() async throws {
        let home = try await ready(self)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        let registered = try await service.setup(
            service.prepare(ToolchainSetupRequest()),
            taskID: TaskID("first"),
            installer: installer,
            reporter: .silent,
        )
        let earlier = try await installer.install(
            LocalArtifact(
                artifactID: "toolchain-" + FakeBackend.id,
                path: home.home.path,
                digest: "",
                packageID: ToolchainPackager.packageID(for: FakeBackend.id),
                version: "27.0+01234567",
            ),
            reporter: .silent,
        )
        let folder = jobFolder(home)
        try home.layout.make(folder)
        try JSONFile.write(
            ToolchainJob(
                key: folder.lastPathComponent,
                productID: FakeBackend.newest.productID,
                components: [.c],
                stage: "installing",
                taskID: "killed",
                toolchainID: FakeBackend.id,
                installationID: earlier.installationID,
                updated: Date(),
            ),
            to: folder.appendingPathComponent("job.json"),
        )

        let failing = ToolchainService(layout: home.layout, backend: FakeBackend(failPrepare: true))
        do {
            _ = try await failing.setup(
                failing.prepare(ToolchainSetupRequest()),
                taskID: TaskID("again"),
                installer: installer,
                reporter: .silent,
            )
            XCTFail("setup should fail")
        } catch {}
        XCTAssertEqual(installer.removed, [], "the registered toolchain's package stays installed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedPath(home)))
        let toolchains = ToolchainRegistry.load(home.layout).toolchains
        XCTAssertEqual(toolchains.map(\.id), [registered.id])
        XCTAssertEqual(toolchains.first?.installationID, earlier.installationID, "the newer install is the record's")
        let job = try XCTUnwrap(try JSONFile.read(ToolchainJob.self, at: folder.appendingPathComponent("job.json")))
        XCTAssertNil(job.installationID)
    }

    /// A setup stopped while the host's install task ran — and asked again,
    /// by the user or by the host re-sending it under the same task ID —
    /// follows that task instead of handing the package over twice.
    func testAPendingInstallTaskIsFollowedNotSubmittedAgain() async throws {
        let home = try await ready(self)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let pending = try await installer.startInstall(LocalArtifact(artifactID: "toolchain-" + FakeBackend.id, path: home.home.path, digest: "", packageID: ToolchainPackager.packageID(for: FakeBackend.id), version: "27.0+01234567"))
        let folder = jobFolder(home)
        try home.layout.make(folder)
        try JSONFile.write(ToolchainJob(key: folder.lastPathComponent, productID: FakeBackend.newest.productID, components: [.c], stage: "installing", taskID: "same", toolchainID: FakeBackend.id, installTaskID: pending.taskID.rawValue, updated: Date()), to: folder.appendingPathComponent("job.json"))

        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        let log = EventLog()
        let record = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("same"), installer: installer, reporter: log.reporter)
        XCTAssertEqual(installer.submitted, 1, "the package went to the bridge once")
        XCTAssertEqual(installer.installed.count, 1)
        XCTAssertEqual(record.installationID, "inst-1")
        XCTAssertEqual(log.last("installResumed")?["installTask"]?.stringValue, pending.taskID.rawValue)

        // A task that is gone (the host could not resume it): installed afresh.
        try await service.remove(record, installer: installer, reporter: .silent)
        try home.layout.make(folder)
        try JSONFile.write(ToolchainJob(key: folder.lastPathComponent, productID: FakeBackend.newest.productID, components: [.c], stage: "installing", taskID: "x", toolchainID: FakeBackend.id, installTaskID: "lost", updated: Date()), to: folder.appendingPathComponent("job.json"))
        let again = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("y"), installer: installer, reporter: .silent)
        XCTAssertEqual(installer.submitted, 2)
        XCTAssertEqual(again.installationID, "inst-2")
    }

    /// Bytes nobody installed through the bridge (a tree copied by hand) give
    /// removal nothing to act on: they go through the bridge again.
    func testMatchingBytesWithoutARecordAreInstalledThroughTheBridge() async throws {
        let home = try await ready(self)
        try FileManager.default.createDirectory(atPath: installedPath(home) + "/usr/bin", withIntermediateDirectories: true)
        try FakeBackend.tool.write(to: URL(fileURLWithPath: installedPath(home) + "/usr/bin/clang"))
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        let record = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("t"), installer: installer, reporter: .silent)
        XCTAssertEqual(installer.installed.count, 1)
        XCTAssertEqual(record.installationID, "inst-1")
    }

    /// A failed self-test registers nothing and leaves nothing installed;
    /// the job stays, with its failure, for a retry.
    func testAFailedSelfTestRollsTheInstallBack() async throws {
        let home = try await ready(self)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let service = ToolchainService(layout: home.layout, backend: FakeBackend(failSelfTest: true))
        do {
            _ = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("t"), installer: installer, reporter: .silent)
            XCTFail("setup should fail")
        } catch {
            XCTAssertTrue("\(error)".contains("C self-test"), "\(error)")
        }
        XCTAssertEqual(installer.removed, ["inst-1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedPath(home)))
        XCTAssertEqual(service.status(activeTasks: []).toolchains, [])
        let job = try XCTUnwrap(try JSONFile.read(ToolchainJob.self, at: jobFolder(home).appendingPathComponent("job.json")))
        XCTAssertNotNil(job.failure)
        XCTAssertNil(job.installationID)
    }

    /// A cancel during the install waits for the bridge's answer, then
    /// removes what it installed and the job's own folder.
    func testACancelDuringTheInstallSettlesThenRollsBack() async throws {
        let home = try await ready(self)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        installer.delay = 300_000_000
        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        let flag = CancellationFlag()
        let log = EventLog()
        let reporter = TaskReporter(cancellation: flag) { log.append($0, $1) }
        let prepared = try service.prepare(ToolchainSetupRequest())
        let task = Task { try await service.setup(prepared, taskID: TaskID("t"), installer: installer, reporter: reporter) }
        for _ in 0 ..< 200 where !installer.started {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        flag.cancel()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("setup should be cancelled")
        } catch {}
        XCTAssertEqual(installer.installed.count, 1, "the install ran to its end")
        XCTAssertEqual(installer.removed, ["inst-1"], "and was removed again")
        XCTAssertEqual(service.status(activeTasks: []).toolchains, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobFolder(home).path))
    }

    /// A package removed outside Apelin: the bridge refuses, the tree is
    /// gone, and only the record is left to drop.
    func testRemovalOfAPackageRemovedOutsideUnregistersIt() async throws {
        let home = try await ready(self)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        let record = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("t"), installer: installer, reporter: .silent)

        installer.removalFailure = ApelinError(.conflict, "no longer installed")
        // While the tree is there, the refusal stands.
        do {
            try await service.remove(record, installer: installer, reporter: .silent)
            XCTFail("removal should be refused")
        } catch {}
        XCTAssertEqual(service.status(activeTasks: []).toolchains.count, 1)

        try FileManager.default.removeItem(atPath: installedPath(home))
        let log = EventLog()
        try await service.remove(record, installer: installer, reporter: log.reporter)
        XCTAssertNotNil(log.last("warning"))
        XCTAssertEqual(service.status(activeTasks: []).toolchains, [])
    }

    /// Run Again tests the installed tree once more and the registry keeps
    /// what it found, a failure included; a toolchain whose files are gone
    /// is refused before anything runs.
    func testSelfTestAgainKeepsTheNewResults() async throws {
        let home = try await ready(self)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        let record = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("t"), installer: installer, reporter: .silent)

        let tested = try await service.selfTest(
            service.prepareSelfTest(ToolchainSelfTestRequest(id: record.id)),
            taskID: TaskID("again"),
            reporter: .silent,
        )
        XCTAssertEqual(tested.selfTests?.map(\.seconds), [0.5, 0.5])
        XCTAssertEqual(service.status(activeTasks: []).toolchains.first?.selfTests?.map(\.seconds), [0.5, 0.5])

        var failing = FakeBackend()
        failing.failSelfTest = true
        let log = EventLog()
        let again = try await ToolchainService(layout: home.layout, backend: failing).selfTest(record, taskID: TaskID("fail"), reporter: log.reporter)
        XCTAssertEqual(again.selfTests?.first?.passed, false)
        XCTAssertNotNil(log.last("warning"))
        XCTAssertEqual(service.status(activeTasks: []).toolchains.count, 1, "a failure never unregisters")

        try FileManager.default.removeItem(atPath: installedPath(home))
        XCTAssertThrowsError(try service.prepareSelfTest(ToolchainSelfTestRequest(id: record.id)))
        XCTAssertThrowsError(try service.prepareSelfTest(ToolchainSelfTestRequest(id: "no-such-toolchain")))
    }

    /// The same on roothide, where a package manager's removal leaves every
    /// folder behind with the `.jbroot` link roothide puts in it (seen on an
    /// iPhone 15 Pro and an A12Z iPad, 2026-10-21): no file is left, so the
    /// tree is gone, status says so, and the record can be dropped.
    func testRemovalLeavingRoothideFoldersStillUnregisters() async throws {
        let home = try await ready(self)
        let installer = FakeInstaller(installRoot: home.layout.installRoot)
        let service = ToolchainService(layout: home.layout, backend: FakeBackend())
        let record = try await service.setup(service.prepare(ToolchainSetupRequest()), taskID: TaskID("t"), installer: installer, reporter: .silent)
        XCTAssertNil(service.status(activeTasks: []).toolchains.first?.components.first?.problem)

        let tree = installedPath(home)
        try FileManager.default.removeItem(atPath: tree + "/usr/bin/clang")
        for folder in ["/usr/bin", "/usr/lib"] {
            try FileManager.default.createDirectory(atPath: tree + folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: tree + folder + "/.jbroot", withDestinationPath: "//")
        }
        XCTAssertEqual(
            service.status(activeTasks: []).toolchains.first?.components.first?.problem,
            "not found at its installed path",
        )
        installer.removalFailure = ApelinError(.conflict, "no longer installed")
        let log = EventLog()
        try await service.remove(record, installer: installer, reporter: log.reporter)
        XCTAssertNotNil(log.last("warning"))
        XCTAssertEqual(service.status(activeTasks: []).toolchains, [])
    }
}

/// apelin-build's view of the registry, read as EnvironmentStores reads it
/// (ApelinProject is not linked here): id → binding digest.
struct EnvironmentStoresReader {
    let home: TemporaryHome

    func toolchains() throws -> [String: String] {
        let data = try Data(contentsOf: home.layout.toolchainRegistry)
        let file = try JSONCoding.decode(ToolchainRegistry.self, from: data)
        var result: [String: String] = [:]
        for record in file.toolchains where record.components.contains(where: { $0.kind == .c && $0.selfCheckPassed == true }) {
            if let path = record.path, let digest = record.contentDigest, !path.isEmpty {
                result[record.id] = "sha256:" + digest
            }
        }
        return result
    }
}

// MARK: - The local package

final class ToolchainPackagerTests: XCTestCase {
    private func tree(_ home: TemporaryHome) throws -> URL {
        let tree = home.home.appendingPathComponent("tree", isDirectory: true)
        let bin = tree.appendingPathComponent("usr/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: bin.appendingPathComponent("clang"))
        chmod(bin.appendingPathComponent("clang").path, 0o4777)
        try Data("{}".utf8).write(to: tree.appendingPathComponent("manifest.json"))
        chmod(tree.appendingPathComponent("manifest.json").path, 0o600)
        chmod(bin.path, 0o700)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("cc").path, withDestinationPath: "clang")
        return tree
    }

    private func prepared(_ tree: URL) -> PreparedToolchain {
        PreparedToolchain(id: FakeBackend.id, product: ToolchainProduct(productID: "001", version: "27.0", url: "https://example.invalid/x.pkg", size: 1),
                          components: [.c], tree: tree, files: [:], installRelativePath: "usr/lib/apelin/toolchains/\(FakeBackend.id)", manifest: Data())
    }

    func testThePackageIsWhatTheBridgeAcceptsInBothLayouts() throws {
        let home = try TemporaryHome(self)
        let tree = try tree(home)
        // roothide: mobile's home inside the install root.
        let roothide = EnvironmentLayout(data: home.layout.data, installRoot: home.home.path, home: home.home.appendingPathComponent("var/mobile").path)
        let rootless = EnvironmentLayout(data: home.layout.data, installRoot: "/var/jb", home: home.home.path)
        for (layout, prefix, architecture) in [(roothide, "", "iphoneos-arm64e"), (rootless, "/var/jb", "iphoneos-arm64")] {
            let artifact = try ToolchainPackager(layout: layout).package(prepared(tree))
            XCTAssertEqual(artifact.path, layout.artifacts.appendingPathComponent("toolchain-\(FakeBackend.id).deb").path)
            XCTAssertEqual(artifact.digest, try ToolchainPackager.sha256(URL(fileURLWithPath: artifact.path)))
            let contents = try DebArchiveReader.contents(of: .path(artifact.path))
            XCTAssertEqual(contents.members.first, "debian-binary")
            XCTAssertTrue(contents.members.contains("control.tar.gz"), "a control member the host reads: \(contents.members)")
            let control = try contents.control()
            XCTAssertEqual(control.package, "wiki.qaq.apelin.toolchain." + FakeBackend.id)
            XCTAssertEqual(control.architecture, architecture)
            XCTAssertNil(control["Depends"])
            XCTAssertEqual(control["Icon"], "https://owngoal-dev.github.io/Apelin/icons/wiki.qaq.apelin.toolchain.png")
            XCTAssertEqual(control["Name"]?.hasPrefix("Command Line Tools "), true)
            XCTAssertEqual(control["Name"]?.hasSuffix(" (Apelin)"), true)
            XCTAssertEqual(Set(contents.controlFiles.keys), ["control"], "no maintainer scripts")

            let root = prefix + "/usr/lib/apelin/toolchains/" + FakeBackend.id
            let entries = Dictionary(uniqueKeysWithValues: contents.entries.map { ($0.path, $0) })
            XCTAssertTrue(contents.entries.allSatisfy { $0.path == root || $0.path.hasPrefix(root + "/") || root.hasPrefix($0.path) }, "\(contents.entries.map(\.path))")
            XCTAssertTrue(contents.entries.allSatisfy { $0.userID == 0 && $0.groupID == 0 }, "root's")
            XCTAssertEqual(entries[root + "/usr/bin"]?.mode, 0o755)
            XCTAssertEqual(entries[root + "/usr/bin/clang"]?.mode, 0o755, "no setuid, no group or other write")
            XCTAssertEqual(entries[root + "/manifest.json"]?.mode, 0o644, "readable by mobile")
            XCTAssertEqual(entries[root + "/usr/bin/cc"]?.kind, .symbolicLink(target: "clang"))
        }
    }

    func testALinkOutOfTheTreeIsRefused() throws {
        let home = try TemporaryHome(self)
        let tree = try tree(home)
        for target in ["/usr/bin/clang", "../../../../etc/passwd"] {
            let link = tree.appendingPathComponent("usr/bin/out")
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            XCTAssertThrowsError(try ToolchainPackager(layout: home.layout).package(prepared(tree)), target)
        }
    }

    /// Each link stays inside on its own, lexically, but followed as the
    /// kernel follows them they climb out: `s -> .` makes `s/s/s/..` the
    /// parent of `usr/bin`, not of `usr/bin/s/s/s`.
    func testChainedLinksThatResolveOutOfTheTreeAreRefused() throws {
        let home = try TemporaryHome(self)
        let tree = try tree(home)
        let bin = tree.appendingPathComponent("usr/bin")
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("s").path, withDestinationPath: ".")
        let escape = bin.appendingPathComponent("e")
        try FileManager.default.createSymbolicLink(atPath: escape.path, withDestinationPath: "s/s/s/../../..")
        XCTAssertEqual(
            CanonicalPath.resolve(escape.path),
            CanonicalPath.resolve(tree.deletingLastPathComponent().path),
            "the link really resolves above the tree",
        )
        XCTAssertThrowsError(try ToolchainPackager(layout: home.layout).package(prepared(tree)))
    }

    /// Links through links that stay inside pass, as a real Command Line
    /// Tools tree's do; a loop, which nothing can follow, does not.
    func testChainedLinksThatStayInsidePass() throws {
        let home = try TemporaryHome(self)
        let tree = try tree(home)
        let usr = tree.appendingPathComponent("usr")
        let lib = usr.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: lib.appendingPathComponent("bin").path, withDestinationPath: "../bin")
        try FileManager.default.createSymbolicLink(atPath: lib.appendingPathComponent("cc").path, withDestinationPath: "bin/cc")
        try FileManager.default.createSymbolicLink(
            atPath: lib.appendingPathComponent("up").path,
            withDestinationPath: "bin/../../manifest.json",
        )
        try FileManager.default.createSymbolicLink(atPath: lib.appendingPathComponent("gone").path, withDestinationPath: "nothing/here")
        XCTAssertNoThrow(try ToolchainPackager(layout: home.layout).package(prepared(tree)))

        try FileManager.default.createSymbolicLink(atPath: usr.appendingPathComponent("a").path, withDestinationPath: "b")
        try FileManager.default.createSymbolicLink(atPath: usr.appendingPathComponent("b").path, withDestinationPath: "a")
        XCTAssertThrowsError(try ToolchainPackager(layout: home.layout).package(prepared(tree)))
    }
}
