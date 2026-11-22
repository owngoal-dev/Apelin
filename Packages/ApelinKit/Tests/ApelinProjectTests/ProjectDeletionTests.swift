import ApelinCore
import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

/// `projectDelete` as apelin-build serves it: the real folder that holds
/// the id asked for, gone whole, a link inside it removed and never
/// followed; anything else refused with nothing removed.
final class ProjectDeletionTests: XCTestCase {
    func testTheFolderThatHoldsTheIdGoesWholeAndALinkInsideIsNotFollowed() throws {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = DataFolder(home: home.path)
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        let store = ProjectStore(dataFolder: folder)
        let doomed = try store.createEmpty(name: "Weather")
        let kept = try store.createEmpty(name: "Clock")
        let outside = home.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: URL(fileURLWithPath: doomed.path).appendingPathComponent("link"),
            withDestinationURL: outside,
        )

        let instructions = CustomInstructionsStore(root: folder.root)
        try instructions.save("Package each patch alone.", for: .project(doomed.projectID), replacing: "")
        try instructions.save("Keep the alarm loud.", for: .project(kept.projectID), replacing: "")

        let deleted = try ProjectDeletion.delete(ProjectDeleteRequest(projectID: doomed.projectID, projectName: "Weather"), in: folder)
        XCTAssertEqual(deleted, ProjectDeleteResponse(projectID: doomed.projectID, projectName: "Weather"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8), "what a link inside named stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertEqual(instructions.read(.project(doomed.projectID)), SavedInstructions.none, "the user's custom instructions for it went with it")
        XCTAssertEqual(instructions.read(.project(kept.projectID)), .text("Keep the alarm loud."))

        // By id alone, the folder that holds it.
        _ = try ProjectDeletion.delete(ProjectDeleteRequest(projectID: kept.projectID), in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path))
    }

    func testAnotherIdALinkOrAMissingManifestIsRefusedAndNothingIsRemoved() throws {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = DataFolder(home: home.path)
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        let store = ProjectStore(dataFolder: folder)
        let weather = try store.createEmpty(name: "Weather")
        let clock = try store.createEmpty(name: "Clock")
        // A project kept outside Projects/, reached through a link in it.
        let elsewhere = home.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: clock.path), to: elsewhere)
        try FileManager.default.createSymbolicLink(at: folder.projects.appendingPathComponent("Linked"), withDestinationURL: elsewhere)
        try FileManager.default.createDirectory(at: folder.projects.appendingPathComponent("Bare"), withIntermediateDirectories: true)

        func code(_ request: ProjectDeleteRequest) -> ApelinError.Code? {
            do {
                _ = try ProjectDeletion.delete(request, in: folder)
                return nil
            } catch {
                return (error as? ApelinError)?.code
            }
        }
        XCTAssertEqual(code(ProjectDeleteRequest(projectID: clock.projectID, projectName: "Weather")), .conflict, "a folder holding another id")
        XCTAssertEqual(code(ProjectDeleteRequest(projectID: clock.projectID, projectName: "Linked")), .badRequest, "a link in Projects/")
        XCTAssertEqual(code(ProjectDeleteRequest(projectID: clock.projectID, projectName: "Bare")), .badRequest, "a folder with no manifest")
        XCTAssertEqual(code(ProjectDeleteRequest(projectID: clock.projectID, projectName: "Gone")), .notFound, "a folder that is not there")
        XCTAssertEqual(code(ProjectDeleteRequest(projectID: clock.projectID, projectName: "../Elsewhere")), .badRequest, "a name that leaves Projects/")
        XCTAssertEqual(code(ProjectDeleteRequest(projectID: "no-such-project")), .notFound, "an id no project has")
        for kept in [weather.path, clock.path, elsewhere.path, folder.projects.appendingPathComponent("Bare").path] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept), kept)
        }
    }
}
