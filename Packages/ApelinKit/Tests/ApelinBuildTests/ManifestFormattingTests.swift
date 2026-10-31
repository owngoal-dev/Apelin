@testable import ApelinBuild
import ApelinProject
import Foundation
import XCTest

/// A build leaves the manifest as it is when the build or the package
/// takes it as a file: those bytes are the ones the check digested, and
/// formatting them would fail the package's check and move its digest.
final class ManifestFormattingTests: XCTestCase {
    func testAManifestThePackageCarriesIsLeftAsItIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent(ProjectStore.projectFileName)
        let oneLine = Data(#"{"schemaVersion":1,"projectID":"p","kind":"workspace","buildSystem":"external"}"#.utf8)
        try oneLine.write(to: manifest)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("self.json").path,
            withDestinationPath: ProjectStore.projectFileName,
        )

        for checked in [[ProjectStore.projectFileName: "sha256:x"], ["self.json": "sha256:x"]] {
            let line = ManifestFormatting.run(projectRoot: root, checkedFiles: checked)
            XCTAssertEqual(line, "apelin-project.json was left as it is: the build or the package takes it as a file")
            XCTAssertEqual(try Data(contentsOf: manifest), oneLine)
        }
        let line = ManifestFormatting.run(projectRoot: root, checkedFiles: ["Sources/Tweak.m": "sha256:x"])
        XCTAssertEqual(line?.hasPrefix("formatted apelin-project.json"), true)
        XCTAssertEqual(try Data(contentsOf: manifest), ProjectManifestFormat.formatted(oneLine))
    }
}
