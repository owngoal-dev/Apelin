import ApelinCore
@testable import ApelinEnvironment
@testable import ApelinProtocol
import Foundation
import XCTest

/// One record this version cannot read never costs the others, nor what
/// they name (issue #33's audit).
final class PreservedRecordsTests: XCTestCase {
    func testAToolchainRecordThatDoesNotReadSurvivesASave() throws {
        let home = try TemporaryHome(self)
        let layout = home.layout
        try layout.make(layout.toolchains)
        let good = ToolchainRecord(id: "good", version: "27.0", components: [ToolchainComponent(kind: .c, selfCheckPassed: true)])
        let goodJSON = try String(decoding: JSONCoding.encode(good), as: UTF8.self)
        let unknown = #"{"id":"newer","version":"28.0","components":[{"kind":"rust"}]}"#
        try Data(#"{"defaultID":"newer","toolchains":[\#(goodJSON),\#(unknown)]}"#.utf8).write(to: layout.toolchainRegistry)

        var registry = ToolchainRegistry.load(layout)
        XCTAssertEqual(registry.toolchains.map(\.id), ["good"])
        registry.toolchains.append(ToolchainRecord(id: "added", version: "16.4", components: []))
        try registry.save(layout)

        let saved = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: layout.toolchainRegistry))
        guard case let .array(items)? = saved["toolchains"] else { return XCTFail("no toolchains array") }
        let ids = items.compactMap { $0["id"]?.stringValue }
        XCTAssertEqual(ids, ["good", "added", "newer"])
        XCTAssertEqual(saved["defaultID"]?.stringValue, "newer")
    }

    func testARegistryThatDoesNotReadIsSetAsideBeforeASave() throws {
        let home = try TemporaryHome(self)
        let layout = home.layout
        try layout.make(layout.toolchains)
        try Data("{\"toolchains\":[".utf8).write(to: layout.toolchainRegistry)
        var registry = ToolchainRegistry.load(layout)
        XCTAssertTrue(registry.toolchains.isEmpty)
        registry.toolchains.append(ToolchainRecord(id: "added", version: "16.4", components: []))
        try registry.save(layout)
        let names = try FileManager.default.contentsOfDirectory(atPath: layout.toolchains.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("registry.json.unreadable-") })
    }

    func testTheSweepKeepsAnSDKWhoseRecordDoesNotRead() throws {
        let home = try TemporaryHome(self)
        let layout = home.layout
        let store = SDKStore(layout: layout)
        try layout.make(layout.sdkRegistry)
        for name in ["kept-sdk", "orphan-sdk"] {
            try FileManager.default.createDirectory(at: layout.sdks.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("{\"id\":\"kept-sdk\"".utf8).write(to: layout.sdkRegistry.appendingPathComponent("kept-sdk.json"))
        XCTAssertTrue(store.list().isEmpty)
        store.sweepOrphans()
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.sdks.appendingPathComponent("kept-sdk").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.sdks.appendingPathComponent("orphan-sdk").path))
    }
}
