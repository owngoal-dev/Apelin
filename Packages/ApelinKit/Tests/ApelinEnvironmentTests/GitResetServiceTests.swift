import ApelinCore
@testable import ApelinEnvironment
@testable import ApelinGit
import ApelinProject
@testable import ApelinProtocol
import Foundation
import XCTest

/// Issue #32's case through the service: a project with history and no
/// remote, made what a remote holds when the user asks, with its identity
/// kept and what it loses shown first.
final class GitResetServiceTests: XCTestCase {
    private let author = GitSignature(name: "Apelin Test", email: "test@apelin.invalid")
    private let localID = "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
    private let theirID = "5f0c2a8e-1b7d-4c39-9e46-0a1b2c3d4e5f"

    private func service(_ home: TemporaryHome) -> GitService {
        var git = GitService(layout: home.layout)
        git.acceptsLocalRemotes = true
        return git
    }

    private func manifest(id: String, kind: String = "tweak") -> String {
        """
        {
          "schemaVersion": 1,
          "projectID": "\(id)",
          "kind": "\(kind)",
          "displayName": "Pineora"
        }

        """
    }

    /// A bare repository whose main has `files`, and the seed that pushed it.
    private func remote(_ home: TemporaryHome, _ files: [String: String]) throws -> (url: String, seed: GitRepository) {
        let bare = home.home.appendingPathComponent("remote.git", isDirectory: true)
        try GitRepository.createBare(at: bare)
        let seed = try GitRepository.create(at: home.home.appendingPathComponent("seed", isDirectory: true))
        for (path, text) in files {
            let url = seed.workdir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try seed.stageAll()
        try seed.commit(message: "Pineora", author: author)
        try seed.addRemote("origin", url: bare.path)
        _ = try seed.push()
        return (bare.path, seed)
    }

    /// `Projects/Pineora` with a history of its own and no remote.
    private func project(_ home: TemporaryHome) throws -> URL {
        let root = home.layout.data.projects.appendingPathComponent("Pineora", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(manifest(id: localID).utf8).write(to: root.appendingPathComponent("apelin-project.json"))
        try Data("// mine\n".utf8).write(to: root.appendingPathComponent("Mine.m"))
        let repository = try GitRepository.create(at: root)
        try repository.stageAll()
        try repository.commit(message: "Mine", author: author)
        return root
    }

    private func preview(_ git: GitService, remote: String = "origin") throws -> GitResetPreview {
        let json = try git.resetPreview(git.prepareResetPreview(GitResetPreviewRequest(projectID: localID, remote: remote)), reporter: .silent)
        return try json.decode(GitResetPreview.self)
    }

    private func reset(_ git: GitService, _ shown: GitResetPreview, url: String? = nil) throws -> JSONValue {
        let request = GitResetToRemoteRequest(
            projectID: localID,
            remote: shown.remote,
            branch: shown.branch,
            expectedRemoteCommit: shown.remoteCommit,
            expectedHead: shown.head,
            expectedURL: url ?? shown.url,
        )
        return try git.reset(git.prepareReset(request), request, reporter: .silent)
    }

    func testAProjectWithNoRemoteIsMadeTheRemotesWithItsIdentityKept() throws {
        let home = try TemporaryHome(self)
        let (url, seed) = try remote(home, ["apelin-project.json": manifest(id: theirID), "Sources/Tweak.m": "// theirs\n"])
        let root = try project(home)
        let git = service(home)
        XCTAssertThrowsError(try git.prepareResetPreview(GitResetPreviewRequest(projectID: localID, remote: "origin"))) {
            XCTAssertEqual(($0 as? ApelinError)?.reason, .noSuchRemote, "no remote yet")
        }
        _ = try git.setRemote(GitRemoteSetRequest(projectID: localID, name: "origin", url: url))

        let shown = try preview(git)
        XCTAssertEqual(shown.branch, "main")
        XCTAssertEqual(shown.remoteCommit, seed.head().commit)
        XCTAssertTrue(shown.unrelatedHistories)
        XCTAssertEqual(shown.lostCommitCount, 1)
        XCTAssertEqual(shown.lostCommits.map(\.subject), ["Mine"])
        XCTAssertEqual(shown.projectFile, .repositoryWithProjectID)
        XCTAssertFalse(shown.upToDate)

        let result = try reset(git, shown)
        XCTAssertEqual(result["commit"]?.stringValue, shown.remoteCommit)
        XCTAssertEqual(result["projectFile"]?.stringValue, "repositoryWithProjectID")
        XCTAssertTrue(result["backupBranch"]?.stringValue?.hasPrefix("apelin-backup/") == true)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("apelin-project.json"), encoding: .utf8), manifest(id: localID))
        XCTAssertEqual(try ProjectLocator(layout: home.layout).locate(localID).root.path, root.path, "the project is still itself")
        XCTAssertNil(FileManager.default.contents(atPath: root.appendingPathComponent("Mine.m").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Sources/Tweak.m"), encoding: .utf8), "// theirs\n")
        let status = try git.status(GitStatusRequest(projectID: localID))
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.entries, [GitStatusEntry(path: "apelin-project.json", index: " ", worktree: "M")], "only the ID it kept")
    }

    func testARemoteWithoutAManifestLeavesTheProjectsOwnOutOfIt() throws {
        let home = try TemporaryHome(self)
        let (url, _) = try remote(home, ["README": "theirs\n"])
        let root = try project(home)
        let git = service(home)
        _ = try git.setRemote(GitRemoteSetRequest(projectID: localID, name: "origin", url: url))
        let shown = try preview(git)
        XCTAssertEqual(shown.projectFile, .project)
        _ = try reset(git, shown)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("apelin-project.json"), encoding: .utf8), manifest(id: localID))
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: localID)).entries, [], "kept out of the repository")
    }

    func testAResetIsHeldToWhatWasShown() throws {
        let home = try TemporaryHome(self)
        let (url, seed) = try remote(home, ["README": "theirs\n"])
        let root = try project(home)
        let git = service(home)
        _ = try git.setRemote(GitRemoteSetRequest(projectID: localID, name: "origin", url: url))
        let shown = try preview(git)

        // Another address than the one shown.
        XCTAssertThrowsError(try reset(git, shown, url: "https://example.com/else.git")) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict)
        }
        // The remote moved since.
        try Data("moved\n".utf8).write(to: seed.workdir.appendingPathComponent("README"))
        try seed.stageAll()
        try seed.commit(message: "Moved", author: author)
        _ = try seed.push()
        XCTAssertThrowsError(try reset(git, shown)) { XCTAssertEqual(($0 as? ApelinError)?.code, .conflict, "\($0)") }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Mine.m"), encoding: .utf8), "// mine\n", "nothing changed")

        for bad in [
            GitResetToRemoteRequest(projectID: localID, remote: "origin", branch: "main", expectedRemoteCommit: "HEAD", expectedHead: nil),
            GitResetToRemoteRequest(projectID: localID, remote: "origin", branch: "-x", expectedRemoteCommit: shown.remoteCommit, expectedHead: nil),
            GitResetToRemoteRequest(projectID: localID, remote: "https://example.com/a.git", branch: "main", expectedRemoteCommit: shown.remoteCommit, expectedHead: nil),
            GitResetToRemoteRequest(projectID: localID, remote: "--all", branch: "main", expectedRemoteCommit: shown.remoteCommit, expectedHead: nil),
        ] {
            XCTAssertThrowsError(try git.prepareReset(bad)) { XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest, "\($0)") }
        }
    }

    func testARemoteManifestThatDoesNotReadIsRefusedBeforeAnythingChanges() throws {
        let home = try TemporaryHome(self)
        let (url, _) = try remote(home, ["apelin-project.json": "[]"])
        let root = try project(home)
        let git = service(home)
        _ = try git.setRemote(GitRemoteSetRequest(projectID: localID, name: "origin", url: url))
        XCTAssertThrowsError(try preview(git)) { XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest, "\($0)") }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Mine.m"), encoding: .utf8), "// mine\n")
    }

    func testTheWorkerRunsBothAsTasks() async throws {
        let home = try TemporaryHome(self)
        let (url, _) = try remote(home, ["README": "theirs\n"])
        _ = try project(home)
        let log = EventLog()
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) {
            _, kind, payload in log.append(kind, payload)
        }
        worker.git.acceptsLocalRemotes = true
        _ = try worker.git.setRemote(GitRemoteSetRequest(projectID: localID, name: "origin", url: url))
        let request = try ChannelRequest(
            request: WireRequest(GitResetPreviewRequest(projectID: localID, remote: "origin")),
            descriptors: [],
            taskID: TaskID("preview"),
        )
        let (reply, _) = await worker.handle(request)
        XCTAssertNoThrow(try reply.result.get())
        for _ in 0 ..< 200 where !(log.last(TaskEvent.stateKind)?["state"]?.stringValue.map { TaskState(rawValue: $0)?.isTerminal == true } ?? false) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let state = try XCTUnwrap(log.last(TaskEvent.stateKind))
        XCTAssertEqual(state["state"]?.stringValue, TaskState.succeeded.rawValue, "\(log.kinds)")
        XCTAssertEqual(state["result"]?["branch"]?.stringValue, "main", "the preview is in the final state too")

        // A refused one is the reply, and no task runs.
        let refused = try ChannelRequest(
            request: WireRequest(GitResetToRemoteRequest(projectID: localID, remote: "nope", branch: "main", expectedRemoteCommit: String(repeating: "a", count: 40), expectedHead: nil)),
            descriptors: [],
            taskID: TaskID("reset"),
        )
        let (refusal, _) = await worker.handle(refused)
        XCTAssertThrowsError(try refusal.result.get()) { XCTAssertEqual(($0 as? ApelinError)?.reason, .noSuchRemote) }
    }
}
