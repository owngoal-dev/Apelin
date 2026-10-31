import ApelinCore
@testable import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

/// `apelin-project.json`'s written form (Documents/Schemas/README.md ▸
/// Written form): the vectors both implementations are held to, the
/// digests it cannot move, every writer writing it, and the build's
/// rewrite of a file written otherwise.
final class ProjectManifestFormatTests: XCTestCase {
    /// The document as written, member order and all: `JSONDocument ==`
    /// compares objects regardless of order.
    private func written(_ data: Data) throws -> String {
        try StrictJSON.parse(data).description
    }

    func testVectors() throws {
        let vectors = try XCTUnwrap(StrictJSON.parse(contentsOf: Repository.fixtures.appendingPathComponent("manifest-format.json")).arrayValue)
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let name = vector["name"]?.stringValue ?? "?"
            let text = try Data(XCTUnwrap(vector["text"]?.stringValue).utf8)
            let actual = ProjectManifestFormat.formatted(text)
            XCTAssertEqual(actual.map { String(decoding: $0, as: UTF8.self) }, vector["formatted"]?.stringValue, name)
            guard let actual else { continue }
            XCTAssertEqual(ProjectManifestFormat.formatted(actual), actual, "\(name): formatting the written form changes nothing")
            XCTAssertEqual(try written(actual), try written(text), "\(name): the same document, member order included")
        }
    }

    func testOnlyTheTextChanges() throws {
        let text = #"{"z":{"b":[3,1,2],"a":"é \/ \u0007"},"a":[{}],"m":-0}"#
        let formatted = try XCTUnwrap(ProjectManifestFormat.formatted(Data(text.utf8)))
        XCTAssertEqual(String(decoding: formatted, as: UTF8.self), """
        {
          "z": {
            "b": [
              3,
              1,
              2
            ],
            "a": "é / \\u0007"
          },
          "a": [
            {}
          ],
          "m": 0
        }

        """)
        XCTAssertEqual(try StrictJSON.parse(formatted).objectValue?.keys, ["z", "a", "m"], "never sorted")
        XCTAssertNil(ProjectManifestFormat.formatted(Data(#"{"version": 1.0}"#.utf8)), "a file that does not read is left as it is")
    }

    /// The approval digests are over canonical JSON: a manifest on one line
    /// and in the written form are the same descriptions.
    func testFormattingMovesNeitherDigest() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("project")
        try FileManager.default.copyItem(at: Repository.fixtures.appendingPathComponent("digest/cli-with-script/project"), to: root)
        let manifest = root.appendingPathComponent(ProjectStore.projectFileName)
        let oneLine = try Data((StrictJSON.parse(contentsOf: manifest).description + "\n").utf8)
        // Written afresh, so it takes its folder's group: the copy can leave
        // it /private/tmp's, which this user may not set, and the build's
        // formatting keeps the owner or writes nothing.
        try FileManager.default.removeItem(at: manifest)
        try oneLine.write(to: manifest)
        let before = try ApprovalDigests.compute(projectAt: root)
        XCTAssertTrue(try ProjectManifestFormat.formatFile(in: root))
        XCTAssertNotEqual(try Data(contentsOf: manifest), oneLine)
        let after = try ApprovalDigests.compute(projectAt: root)
        XCTAssertEqual(after.build.digest, before.build.digest)
        XCTAssertEqual(after.packaging.digest, before.packaging.digest)
        XCTAssertEqual(after, before)
    }

    /// The build's rewrite: once, in place of the file, its mode kept; not
    /// at all for a file already in the form, one that does not read, or a
    /// link, whose target is never written.
    func testFormatFileRewritesOnlyWhatIsNotFormatted() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let manifest = scratch.appendingPathComponent(ProjectStore.projectFileName)
        let oneLine = Data(#"{"schemaVersion":1,"projectID":"p","kind":"workspace","buildSystem":"external"}"#.utf8)
        try oneLine.write(to: manifest)
        XCTAssertEqual(chmod(manifest.path, 0o640), 0)

        XCTAssertTrue(try ProjectManifestFormat.formatFile(in: scratch))
        let formatted = try Data(contentsOf: manifest)
        XCTAssertEqual(formatted, ProjectManifestFormat.formatted(oneLine))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: manifest.path)[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [ProjectStore.projectFileName], "no temporary file left")

        let inode = try FileManager.default.attributesOfItem(atPath: manifest.path)[.systemFileNumber] as? Int
        XCTAssertFalse(try ProjectManifestFormat.formatFile(in: scratch), "already in the form")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: manifest.path)[.systemFileNumber] as? Int, inode, "not written again")
        XCTAssertEqual(try Data(contentsOf: manifest), formatted)

        let unreadable = Data(#"{"schemaVersion": 1.0}"#.utf8)
        try unreadable.write(to: manifest)
        XCTAssertFalse(try ProjectManifestFormat.formatFile(in: scratch))
        XCTAssertEqual(try Data(contentsOf: manifest), unreadable)

        let outside = scratch.appendingPathComponent("outside.json")
        try oneLine.write(to: outside)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(atPath: manifest.path, withDestinationPath: outside.path)
        XCTAssertThrowsError(try ProjectManifestFormat.formatFile(in: scratch))
        XCTAssertEqual(try Data(contentsOf: outside), oneLine, "never written through a link")
    }

    /// A project folder that is a link out of `Projects/` is not written
    /// through, nor is a manifest past the size every other reader takes,
    /// and a FIFO in the manifest's place neither hangs nor is written.
    func testFormatFileLeavesWhatItShouldNotTouch() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let oneLine = Data(#"{"schemaVersion":1,"projectID":"p","kind":"workspace","buildSystem":"external"}"#.utf8)
        let projects = scratch.appendingPathComponent("Projects")
        let elsewhere = scratch.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try oneLine.write(to: elsewhere.appendingPathComponent(ProjectStore.projectFileName))
        let linked = projects.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try ProjectManifestFormat.formatFile(in: linked))
        XCTAssertEqual(try Data(contentsOf: elsewhere.appendingPathComponent(ProjectStore.projectFileName)), oneLine)

        let large = projects.appendingPathComponent("Large")
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
        let padding = String(repeating: "x", count: ProjectManifestFormat.maximumBytes)
        let big = Data(#"{"schemaVersion":1,"note":"\#(padding)"}"#.utf8)
        try big.write(to: large.appendingPathComponent(ProjectStore.projectFileName))
        XCTAssertFalse(try ProjectManifestFormat.formatFile(in: large))
        XCTAssertEqual(try Data(contentsOf: large.appendingPathComponent(ProjectStore.projectFileName)), big)

        let piped = projects.appendingPathComponent("Piped")
        try FileManager.default.createDirectory(at: piped, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(piped.appendingPathComponent(ProjectStore.projectFileName).path, 0o644), 0)
        XCTAssertThrowsError(try ProjectManifestFormat.formatFile(in: piped), "refused at once, not held open")
    }

    /// A `\u` escape is four hex digits and no sign, as JSON says.
    func testAUnicodeEscapeTakesNoSign() {
        XCTAssertNil(ProjectManifestFormat.formatted(Data(#"{"a":"\u+041"}"#.utf8)))
        XCTAssertNil(ProjectManifestFormat.formatted(Data(#"{"a":"\u-000"}"#.utf8)))
        XCTAssertNotNil(ProjectManifestFormat.formatted(Data(#"{"a":"A"}"#.utf8)))
    }

    /// Every writer of the file writes the form: a template project, an
    /// empty workspace, a generated name and a rename.
    func testEveryWriterWritesTheForm() throws {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = DataFolder(home: home.path)
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        let store = ProjectStore(dataFolder: folder)
        func manifest(_ path: String) throws -> Data {
            try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(ProjectStore.projectFileName))
        }
        func assertFormatted(_ data: Data, _ label: String) {
            XCTAssertEqual(ProjectManifestFormat.formatted(data), data, label)
        }

        let catalog = ExtensionCatalog(directory: Repository.extensions)
        for item in catalog.usable {
            let extensionManifest = try XCTUnwrap(item.manifest)
            for template in extensionManifest.templates {
                let qualified = "\(extensionManifest.id)/\(template.id)"
                for automatic in [false, true] {
                    let created = try store.create(
                        templateID: qualified,
                        name: "\(template.id) \(automatic)",
                        values: [:],
                        catalog: catalog,
                        registry: sampleRegistry(),
                        automaticallyName: automatic,
                    )
                    let data = try manifest(created.root.path)
                    assertFormatted(data, "\(qualified), automatically named \(automatic)")
                    XCTAssertEqual(try StrictJSON.parse(data)["autoName"]?.boolValue, automatic ? true : nil)
                }
            }
        }

        let workspace = try store.createEmpty(name: "Apple", automaticallyName: true)
        let initial = try manifest(workspace.path)
        assertFormatted(initial, "an empty workspace")
        XCTAssertEqual(try StrictJSON.parse(initial).objectValue?.keys, [
            "schemaVersion", "projectID", "kind", "buildSystem", "displayName", "autoName",
        ])
        XCTAssertEqual(try StrictJSON.parse(initial)["schemaVersion"], .integer(1))

        // A rename of a file written on one line writes it in the form.
        let file = URL(fileURLWithPath: workspace.path).appendingPathComponent(ProjectStore.projectFileName)
        try Data(StrictJSON.parse(initial).description.utf8).write(to: file)
        _ = try ProjectMetadata.rename(.init(projectID: workspace.projectID, displayName: "Weather Widget"), in: folder)
        let renamed = try manifest(workspace.path)
        assertFormatted(renamed, "a rename")
        XCTAssertEqual(try StrictJSON.parse(renamed).objectValue?.keys, [
            "schemaVersion", "projectID", "kind", "buildSystem", "displayName", "autoName",
        ], "renamed in place")
        XCTAssertEqual(try StrictJSON.parse(renamed)["displayName"]?.stringValue, "Weather Widget")
    }
}
