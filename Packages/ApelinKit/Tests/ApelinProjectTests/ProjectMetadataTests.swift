import ApelinCore
import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

final class ProjectMetadataTests: XCTestCase {
    func testInitialMetadataIsTheTemplateInTheWrittenForm() throws {
        let original = Data("{\n  \"projectID\": \"stable\",\n  \"section\": \"Tweaks\"\n}\n".utf8)
        XCTAssertEqual(try ProjectMetadata.initial(original, name: "Manual", automaticallyName: false), original, "byte for byte")
        let oneLine = Data(#"{"projectID": "stable", "section": "Tweaks"}"#.utf8)
        XCTAssertEqual(try ProjectMetadata.initial(oneLine, name: "Manual", automaticallyName: false), original)
        let automatic = try ProjectMetadata.initial(original, name: "Apple", automaticallyName: true)
        XCTAssertEqual(
            String(decoding: automatic, as: UTF8.self),
            "{\n  \"displayName\": \"Apple\",\n  \"autoName\": true,\n  \"projectID\": \"stable\",\n  \"section\": \"Tweaks\"\n}\n",
            "the generated name first",
        )
        let parsed = try StrictJSON.parse(automatic)
        XCTAssertEqual(parsed["displayName"]?.stringValue, "Apple")
        XCTAssertEqual(parsed["autoName"]?.boolValue, true)
        let updated = try ProjectMetadata.initial(automatic, name: "Orange", automaticallyName: true)
        XCTAssertEqual(try StrictJSON.parse(updated)["displayName"]?.stringValue, "Orange")
    }

    func testAutomaticNameIsReplacedOnceAndManualNameWins() throws {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = DataFolder(home: home.path)
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        let store = ProjectStore(dataFolder: folder)
        let created = try store.createEmpty(name: "Apple", automaticallyName: true)
        let initial = try StrictJSON.parse(contentsOf: URL(fileURLWithPath: created.path).appendingPathComponent("apelin-project.json"))
        XCTAssertEqual(initial["autoName"]?.boolValue, true)
        let first = try ProjectMetadata.rename(.init(projectID: created.projectID, displayName: "Weather Widget", onlyIfAutomatic: true), in: folder)
        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.projectID, created.projectID)
        XCTAssertEqual(try store.root(of: created.projectID).root.path, created.path)
        let second = try ProjectMetadata.rename(.init(projectID: created.projectID, displayName: "Wrong Candidate", onlyIfAutomatic: true), in: folder)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.displayName, "Weather Widget")
        _ = try ProjectMetadata.rename(.init(projectID: "Apple", displayName: "My Own Name"), in: folder)
        let final = try StrictJSON.parse(contentsOf: URL(fileURLWithPath: created.path).appendingPathComponent("apelin-project.json"))
        XCTAssertEqual(final["displayName"]?.stringValue, "My Own Name")
        XCTAssertEqual(final["autoName"]?.boolValue, false)
        XCTAssertEqual(final["projectID"]?.stringValue, created.projectID)
    }

    func testManualCreationAndManifestLinksAreNotOverwritten() throws {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = DataFolder(home: home.path)
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        let created = try ProjectStore(dataFolder: folder).createEmpty(name: "Manual")
        let result = try ProjectMetadata.rename(.init(projectID: created.projectID, displayName: "Candidate", onlyIfAutomatic: true), in: folder)
        XCTAssertFalse(result.changed)
        let manifest = URL(fileURLWithPath: created.path).appendingPathComponent("apelin-project.json")
        let outside = home.appendingPathComponent("outside.json")
        let original = try Data(contentsOf: manifest)
        try original.write(to: outside)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
        XCTAssertThrowsError(try ProjectMetadata.rename(.init(projectID: "Manual", displayName: "Escape"), in: folder))
        XCTAssertEqual(try Data(contentsOf: outside), original)
        XCTAssertThrowsError(try ProjectMetadata.rename(.init(projectID: "../outside", displayName: "Escape"), in: folder))
        XCTAssertThrowsError(try ProjectMetadata.rename(.init(projectID: "Manual", displayName: "Two\nLines"), in: folder))
    }

    func testAnExternallyEditedDisplayNameBeatsTheAutomaticCandidate() throws {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = DataFolder(home: home.path)
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        let created = try ProjectStore(dataFolder: folder).createEmpty(name: "Orange", automaticallyName: true)
        let file = URL(fileURLWithPath: created.path).appendingPathComponent("apelin-project.json")
        var document = try XCTUnwrap(StrictJSON.parse(contentsOf: file).objectValue)
        document["displayName"] = .string("Chosen Outside the App")
        try Data(JSONDocument.object(document).description.utf8).write(to: file, options: .atomic)
        let result = try ProjectMetadata.rename(.init(projectID: created.projectID, displayName: "Candidate", onlyIfAutomatic: true), in: folder)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.displayName, "Chosen Outside the App")
    }

    func testModelCandidateIsShortAndSingleLine() {
        XCTAssertEqual(ProjectDisplayName.candidate("  Weather\n Widget  "), "Weather Widget")
        XCTAssertNil(ProjectDisplayName.candidate(" \n "))
        XCTAssertNil(ProjectDisplayName.candidate("Bad\0Name"))
        XCTAssertEqual(ProjectDisplayName.candidate("one two three four five six seven eight nine"), "one two three four five six seven eight")
    }
}
