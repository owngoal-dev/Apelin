import ApelinCore
@testable import ApelinEnvironment
@testable import ApelinGit
import ApelinProject
@testable import ApelinProtocol
import Foundation
import XCTest

/// A repository that carries its own `apelin-project.json` imported into a
/// new workspace (issue #32): the repository's file wins over the
/// workspace's, which holds nothing but its identity, and the identity in
/// it is settled.
final class GitImportManifestTests: XCTestCase {
    private let author = GitSignature(name: "Apelin Test", email: "test@apelin.invalid")
    private let theirID = "5f0c2a8e-1b7d-4c39-9e46-0a1b2c3d4e5f"

    private func service(_ home: TemporaryHome) -> GitService {
        var git = GitService(layout: home.layout)
        git.acceptsLocalRemotes = true
        return git
    }

    /// A tweak project's description as another device pushed it.
    private func description(id: String) -> String {
        """
        {
          "schemaVersion": 1,
          "projectID": "\(id)",
          "kind": "tweak",
          "displayName": "Pineora"
        }

        """
    }

    /// A bare repository whose main has `files`.
    private func remote(_ home: TemporaryHome, _ files: [String: String]) throws -> String {
        let bare = home.home.appendingPathComponent("remote-\(UUID().uuidString).git", isDirectory: true)
        try GitRepository.createBare(at: bare)
        let seed = try GitRepository.create(at: home.home.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true))
        for (path, text) in files {
            let url = seed.workdir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try seed.stageAll()
        try seed.commit(message: "Pineora", author: author)
        try seed.addRemote("origin", url: bare.path)
        _ = try seed.push()
        return bare.path
    }

    private func workspace(_ home: TemporaryHome, name: String = "Space") throws -> (id: String, root: URL) {
        let created = try ProjectStore(dataFolder: home.layout.data).createEmpty(name: name, automaticallyName: true)
        return (created.projectID, URL(fileURLWithPath: created.path, isDirectory: true))
    }

    private func importing(_ url: String, into id: String, _ git: GitService) throws -> JSONValue {
        let request = GitCloneIntoRequest(projectID: id, url: url)
        return try git.cloneInto(request, into: git.checkCloneInto(request), reporter: .silent)
    }

    private func manifest(_ root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent("apelin-project.json"), encoding: .utf8)
    }

    func testTheRepositorysFileWinsWithItsIDWhenNothingNamesEither() throws {
        let home = try TemporaryHome(self)
        let url = try remote(home, ["apelin-project.json": description(id: theirID), "Sources/Tweak.m": "int x;\n"])
        let (workspaceID, root) = try workspace(home)
        let git = service(home)

        let result = try importing(url, into: workspaceID, git)
        XCTAssertEqual(result["projectFile"]?.stringValue, "repository")
        XCTAssertEqual(result["projectID"]?.stringValue, theirID)
        XCTAssertEqual(try manifest(root), description(id: theirID), "byte for byte")
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: theirID)).entries, [], "nothing shows as changed")
        XCTAssertEqual(try ProjectLocator(layout: home.layout).locate(theirID).root.path, root.path, "the project has its ID now")
        let exclude = try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        XCTAssertFalse(exclude.contains("/apelin-project.json\n"), "the file is the repository's, never kept out of it")
        XCTAssertTrue(exclude.contains("/apelin-icon.png\n"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("apelin-replaced") }, [])
    }

    func testAnIDAnotherProjectHasGivesWayToTheWorkspaces() throws {
        let home = try TemporaryHome(self)
        let url = try remote(home, ["apelin-project.json": description(id: theirID)])
        let other = home.layout.data.projects.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(description(id: theirID).utf8).write(to: other.appendingPathComponent("apelin-project.json"))
        let (workspaceID, root) = try workspace(home)
        let git = service(home)

        let result = try importing(url, into: workspaceID, git)
        XCTAssertEqual(result["projectFile"]?.stringValue, "repositoryWithProjectID")
        XCTAssertEqual(result["projectID"]?.stringValue, workspaceID)
        XCTAssertEqual(try manifest(root), description(id: workspaceID), "the ID and nothing else")
        let status = try git.status(GitStatusRequest(projectID: workspaceID))
        XCTAssertEqual(status.entries, [GitStatusEntry(path: "apelin-project.json", index: " ", worktree: "M")])
    }

    /// A workspace whose conversation runs the import is named by that
    /// conversation's session, which must open again later: it keeps its ID.
    func testAWorkspaceAConversationNamesKeepsItsID() throws {
        let home = try TemporaryHome(self)
        let url = try remote(home, ["apelin-project.json": description(id: theirID)])
        let (workspaceID, root) = try workspace(home)
        let session = home.layout.data.sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data(#"{"id":"s","project":{"id":"\#(workspaceID)","name":"Space"}}"#.utf8)
            .write(to: session.appendingPathComponent("session.json"))

        let result = try importing(url, into: workspaceID, service(home))
        XCTAssertEqual(result["projectFile"]?.stringValue, "repositoryWithProjectID")
        XCTAssertEqual(try manifest(root), description(id: workspaceID))
    }

    /// An ID this device knew — a deleted project's builds, conversation or
    /// memory — is not taken again.
    func testAnIDLeftByADeletedProjectIsNotTakenAgain() throws {
        for leftover in ["builds", "session", "memory"] {
            let home = try TemporaryHome(self)
            let url = try remote(home, ["apelin-project.json": description(id: theirID)])
            switch leftover {
            case "builds":
                try FileManager.default.createDirectory(
                    at: home.layout.data.root.appendingPathComponent("Builds/\(theirID)"),
                    withIntermediateDirectories: true,
                )
            case "session":
                let session = home.layout.data.sessions.appendingPathComponent("old", isDirectory: true)
                try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
                try Data(#"{"project":{"id":"\#(theirID)","name":"Gone"}}"#.utf8).write(to: session.appendingPathComponent("session.json"))
            default:
                let store = MemoryStore(root: home.layout.data.root)
                _ = try store.save(MemoryRecord(title: "Hooks", body: "SpringBoard", projectID: theirID), revision: store.read().revision)
            }
            let (workspaceID, root) = try workspace(home)
            let result = try importing(url, into: workspaceID, service(home))
            XCTAssertEqual(result["projectFile"]?.stringValue, "repositoryWithProjectID", leftover)
            XCTAssertEqual(try manifest(root), description(id: workspaceID), leftover)
        }
    }

    func testAnIDNotShapedAsApelinsIsReplaced() throws {
        let home = try TemporaryHome(self)
        let url = try remote(home, ["apelin-project.json": description(id: "Builds")])
        let (workspaceID, root) = try workspace(home)
        let result = try importing(url, into: workspaceID, service(home))
        XCTAssertEqual(result["projectFile"]?.stringValue, "repositoryWithProjectID")
        XCTAssertEqual(try manifest(root), description(id: workspaceID))
    }

    func testAFileThatIsNoManifestIsRefusedAndTheWorkspaceStaysAsItWas() throws {
        let unreadable = ["[1, 2]", #"{"kind": "tweak"}"#, "not json", #"{"projectID": ""}"#]
        for text in unreadable + [#"{"projectID": "5f0c2a8e-1b7d-4c39-9e46-0a1b2c3d4e5f", "note": "5f0c2a8e-1b7d-4c39-9e46-0a1b2c3d4e5f"}"#] {
            let home = try TemporaryHome(self)
            let other = home.layout.data.projects.appendingPathComponent("Original", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try Data(description(id: theirID).utf8).write(to: other.appendingPathComponent("apelin-project.json"))
            let url = try remote(home, ["apelin-project.json": text, "README": "hello\n"])
            let (workspaceID, root) = try workspace(home)
            let before = try manifest(root)
            XCTAssertThrowsError(try importing(url, into: workspaceID, service(home)), text) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest, "\($0)")
                XCTAssertTrue("\($0)".contains("apelin-project.json"), "\($0)")
            }
            XCTAssertEqual(try manifest(root), before, text)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), [".git", "apelin-project.json"], text)
            XCTAssertTrue(try GitRepository(at: root).isUntouched, "the untouched repository is back")
        }
    }

    func testAFileInASubfolderIsAnyFile() throws {
        let home = try TemporaryHome(self)
        let url = try remote(home, ["Tweak/apelin-project.json": description(id: theirID)])
        let (workspaceID, root) = try workspace(home)
        let before = try manifest(root)
        let result = try importing(url, into: workspaceID, service(home))
        XCTAssertEqual(result["projectFile"]?.stringValue, "project")
        XCTAssertEqual(result["projectID"]?.stringValue, workspaceID)
        XCTAssertEqual(try manifest(root), before)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Tweak/apelin-project.json"), encoding: .utf8), description(id: theirID))
        let exclude = try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        XCTAssertTrue(exclude.contains("/apelin-project.json\n"))
    }

    /// A workspace whose manifest says more than its identity (a declared
    /// build, say) takes no repository that has one, as before.
    func testAWorkspaceWithMoreThanItsIdentityClashesAsBefore() throws {
        let home = try TemporaryHome(self)
        let url = try remote(home, ["apelin-project.json": description(id: theirID)])
        let (workspaceID, root) = try workspace(home)
        let declared = #"{"schemaVersion":1,"projectID":"\#(workspaceID)","kind":"workspace","external":{"script":"build.sh"}}"#
        try Data(declared.utf8).write(to: root.appendingPathComponent("apelin-project.json"))
        XCTAssertThrowsError(try importing(url, into: workspaceID, service(home))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict, "\($0)")
        }
        XCTAssertEqual(try manifest(root), declared)
    }
}
