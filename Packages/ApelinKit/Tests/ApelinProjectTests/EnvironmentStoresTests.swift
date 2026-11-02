import ApelinCore
@testable import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

/// apelin-build reads apelin-environment's files as that worker writes them.
final class EnvironmentStoresTests: XCTestCase {
    func testSwiftRequirementsSurviveTheRegistryBoundary() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let data = DataFolder(home: home.path)
        let requirements = SwiftToolchainRequirements(version: "5.7.2", minimumHost: "17.3.1", cpuFeatures: ["FEAT_LRCPC"])
        let compatibility = ToolchainCompatibility(recommendedSDK: "16.2", verifiedSDKs: ["16.1", "16.2"])
        let record = ToolchainRecord(
            id: "legacy-swift", version: "14.2", components: [.init(kind: .c, selfCheckPassed: true), .init(kind: .swift, selfCheckPassed: true)],
            path: "/installed", contentDigest: String(repeating: "a", count: 64), newestSDK: "16.2",
            swiftRequirements: requirements, clangModuleCPUFeatures: [], compatibility: compatibility,
        )
        try FileManager.default.createDirectory(at: data.toolchainRegistry.deletingLastPathComponent(), withIntermediateDirectories: true)
        struct Registry: Encodable { let toolchains: [ToolchainRecord] }
        try JSONEncoder().encode(Registry(toolchains: [record])).write(to: data.toolchainRegistry)
        let read = try XCTUnwrap(EnvironmentStores(dataFolder: data).toolchains().first)
        XCTAssertEqual(read.swiftRequirements, requirements)
        XCTAssertEqual(read.clangModuleCPUFeatures, [])
        XCTAssertEqual(read.compatibility, compatibility)
    }

    func testReadsTheToolchainRegistryAndSDKRecords() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let data = DataFolder(home: scratch.path)
        let toolchains = data.environment.appendingPathComponent("Toolchains")
        let sdkRegistry = data.sdks.appendingPathComponent(".registry")
        try FileManager.default.createDirectory(at: toolchains, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sdkRegistry, withIntermediateDirectories: true)

        let installed = ToolchainRecord(id: "clt-27.0-abcdef01", version: "27.0", components: [
            ToolchainComponent(kind: .c, selfCheckPassed: true),
            ToolchainComponent(kind: .swift, selfCheckPassed: false, problem: "Swift did not pass its self-test"),
        ], path: "/var/jb/usr/lib/apelin/toolchains/clt-27.0-abcdef01", contentDigest: String(repeating: "c", count: 64))
        let unfinished = ToolchainRecord(id: "clt-26.0", version: "26.0", components: [ToolchainComponent(kind: .c)])
        let registry: JSONValue = try .object([
            "toolchains": .array([JSONValue(encoding: installed), JSONValue(encoding: unfinished)]),
            "defaultID": .string(installed.id),
        ])
        try JSONCoding.encode(registry).write(to: toolchains.appendingPathComponent("registry.json"))
        for (version, hex) in [("26.0", "d"), ("27.0", "e")] {
            let record = SDKRecord(id: "iPhoneOS\(version)-\(String(repeating: hex, count: 8))", canonicalName: "iphoneos\(version)", version: version, path: data.sdks.path + "/iPhoneOS\(version)", targets: ["arm64e-ios"], digest: String(repeating: hex, count: 64))
            try JSONCoding.encode(record).write(to: sdkRegistry.appendingPathComponent(record.id + ".json"))
        }
        try Data("{".utf8).write(to: sdkRegistry.appendingPathComponent(".pending.json"))

        let stores = EnvironmentStores(dataFolder: data)
        let found = try stores.toolchains()
        XCTAssertEqual(found, try [RegisteredToolchain(id: installed.id, digest: "sha256:" + String(repeating: "c", count: 64), version: "27.0", path: XCTUnwrap(installed.path), components: ["c-family"])])
        XCTAssertEqual(try stores.defaultToolchainID(), installed.id)
        XCTAssertEqual(try stores.sdks().map(\.digest), ["sha256:" + String(repeating: "d", count: 64), "sha256:" + String(repeating: "e", count: 64)])
        XCTAssertEqual(try stores.defaultSDKID(), "iPhoneOS27.0-eeeeeeee")
        XCTAssertEqual(found[0].tool("clang").path, try XCTUnwrap(installed.path) + "/usr/bin/clang")
    }

    func testAToolchainKeepsTheNewestSDKItReads() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let data = DataFolder(home: scratch.path)
        let toolchains = data.environment.appendingPathComponent("Toolchains")
        try FileManager.default.createDirectory(at: toolchains, withIntermediateDirectories: true)
        let older = ToolchainRecord(id: "clt-16.4", version: "16.4", components: [ToolchainComponent(kind: .c, selfCheckPassed: true)], path: "/x", contentDigest: String(repeating: "a", count: 64), newestSDK: "18.5")
        let registry: JSONValue = try .object(["toolchains": .array([JSONValue(encoding: older)])])
        try JSONCoding.encode(registry).write(to: toolchains.appendingPathComponent("registry.json"))
        let found = try XCTUnwrap(EnvironmentStores(dataFolder: data).toolchains().first)
        XCTAssertEqual(found.newestSDK, "18.5")
        XCTAssertTrue(found.reads(sdkVersion: "18.5"))
        XCTAssertTrue(found.reads(sdkVersion: "17.0"))
        XCTAssertFalse(found.reads(sdkVersion: "27.0"))
    }

    func testEmptyWhenNothingIsRegistered() throws {
        let stores = EnvironmentStores(dataFolder: DataFolder(home: "/nonexistent-apelin-home"))
        XCTAssertEqual(try stores.toolchains(), [])
        XCTAssertEqual(try stores.sdks(), [])
        XCTAssertNil(try stores.defaultSDKID())
    }

    /// Issue #34: roothide renamed its root on a reboot; the records still
    /// name the old one, and the trees are under the new one.
    func testRecordsMoveToTheRootTheDataFolderIsUnderNow() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let old = scratch.path + "/.jbroot-F1E6FD3C82204430"
        let new = scratch.appendingPathComponent(".jbroot-809D56B82B2E1CEA")
        let data = DataFolder(home: new.appendingPathComponent("var/mobile").path)
        let toolchainID = "clt-27.0-abcdef01"
        let sdkID = "iPhoneOS27.0-eeeeeeee"
        try FileManager.default.createDirectory(at: data.toolchainRegistry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data.sdkRegistry, withIntermediateDirectories: true)

        let toolchain = ToolchainRecord(
            id: toolchainID, version: "27.0", components: [ToolchainComponent(kind: .c, selfCheckPassed: true)],
            path: old + "/usr/lib/apelin/toolchains/" + toolchainID, contentDigest: String(repeating: "c", count: 64),
        )
        struct Registry: Encodable { let toolchains: [ToolchainRecord] }
        try JSONEncoder().encode(Registry(toolchains: [toolchain])).write(to: data.toolchainRegistry)
        let sdk = SDKRecord(
            id: sdkID, canonicalName: "iphoneos27.0", version: "27.0",
            path: old + "/var/mobile/Documents/wiki.qaq.apelin/SDKs/" + sdkID,
            targets: ["arm64e-ios"], digest: String(repeating: "e", count: 64),
        )
        try JSONCoding.encode(sdk).write(to: data.sdkRegistry.appendingPathComponent(sdkID + ".json"))

        let stores = EnvironmentStores(dataFolder: data)
        XCTAssertEqual(try stores.toolchains().first?.path, new.path + "/usr/lib/apelin/toolchains/" + toolchainID)
        XCTAssertEqual(try stores.sdks().first?.path, data.sdks.path + "/" + sdkID)

        let registered = RegisteredEnvironment.read(data)
        XCTAssertEqual(registered.toolchains.first?.path, new.path + "/usr/lib/apelin/toolchains/" + toolchainID)
        XCTAssertEqual(registered.sdks.first?.path, data.sdks.path + "/" + sdkID)
    }
}
