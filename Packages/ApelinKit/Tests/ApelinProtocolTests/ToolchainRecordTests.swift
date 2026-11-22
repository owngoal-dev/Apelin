import ApelinCore
@testable import ApelinProtocol
import Foundation
import XCTest

/// A toolchain's retarget scheme: a record written before the field is a
/// scheme 2 tree, which builds but lacks what scheme 3 added, and a release
/// set up again under a later scheme takes the place of its earlier one.
final class ToolchainRecordTests: XCTestCase {
    private func record(_ id: String, _ version: String, _ kinds: [ToolchainComponentKind], scheme: Int?) -> ToolchainRecord {
        ToolchainRecord(
            id: id,
            version: version,
            components: kinds.map { ToolchainComponent(kind: $0, selfCheckPassed: true) },
            retargetScheme: scheme,
        )
    }

    func testARecordWrittenBeforeTheSchemeDecodesAsAnEarlierOne() throws {
        let data = Data(#"{"id":"a","version":"15.3","components":[{"kind":"c","selfCheckPassed":true}]}"#.utf8)
        let earlier = try JSONCoding.decode(ToolchainRecord.self, from: data)
        XCTAssertNil(earlier.retargetScheme)
        XCTAssertTrue(earlier.predatesCurrentRetarget)
        XCTAssertFalse(record("b", "15.3", [.c], scheme: ToolchainRecord.currentRetargetScheme).predatesCurrentRetarget)
        let encoded = try JSONCoding.encode(record("b", "15.3", [.c], scheme: 3))
        XCTAssertEqual(try JSONCoding.decode(ToolchainRecord.self, from: encoded).retargetScheme, 3)
    }

    func testOnlyTheSameReleaseWithNoFewerComponentsSupersedes() {
        let earlier = record("a", "15.3", [.c, .swift], scheme: nil)
        XCTAssertTrue(record("b", "15.3", [.c, .swift], scheme: 3).supersedes(earlier))
        XCTAssertFalse(record("b", "15.3", [.c], scheme: 3).supersedes(earlier), "Swift would go")
        XCTAssertFalse(record("b", "27.2", [.c, .swift], scheme: 3).supersedes(earlier), "another release")
        XCTAssertFalse(record("b", "15.3", [.c, .swift], scheme: 2).supersedes(earlier), "the same scheme")
        XCTAssertFalse(record("a", "15.3", [.c, .swift], scheme: 3).supersedes(earlier), "itself")
        XCTAssertFalse(earlier.supersedes(record("b", "15.3", [.c, .swift], scheme: 3)))
    }
}
