import ApelinCore
@testable import ApelinEnvironment
@testable import ApelinGit
import ApelinProject
@testable import ApelinProtocol
import Foundation
import XCTest

/// A project's remotes listed, added, pointed elsewhere and removed (issue
/// #32), and an address given where a remote's name goes.
final class GitRemoteSetTests: XCTestCase {
    private func service(_ home: TemporaryHome) -> GitService {
        var git = GitService(layout: home.layout)
        git.acceptsLocalRemotes = true
        return git
    }

    private func workspace(_ home: TemporaryHome) throws -> (id: String, root: URL) {
        let created = try ProjectStore(dataFolder: home.layout.data).createEmpty(name: "Pineora")
        return (created.projectID, URL(fileURLWithPath: created.path, isDirectory: true))
    }

    func testRemotesAreAddedPointedElsewhereAndRemoved() throws {
        let home = try TemporaryHome(self)
        let (id, root) = try workspace(home)
        let git = service(home)
        XCTAssertEqual(try git.remotes(GitRemoteListRequest(projectID: id)).remotes, [])

        let added = try git.setRemote(GitRemoteSetRequest(projectID: id, name: "origin", url: "https://github.com/owngoal-dev/Pineora.git"))
        XCTAssertEqual(added, GitRemoteSetResponse(remote: GitRemoteSummary(name: "origin", url: "https://github.com/owngoal-dev/Pineora.git")))
        _ = try git.setRemote(GitRemoteSetRequest(projectID: id, name: "upstream", url: "https://example.com/upstream.git"))
        XCTAssertEqual(try git.remotes(GitRemoteListRequest(projectID: id)).remotes.map(\.name), ["origin", "upstream"])

        // Pointed elsewhere, its own push address goes too.
        let repository = try GitRepository(at: root)
        try repository.setLocalConfigValue("https://example.com/push.git", for: "remote.origin.pushurl")
        XCTAssertEqual(try git.remotes(GitRemoteListRequest(projectID: id)).remotes.first?.pushURL, "https://example.com/push.git")
        let moved = try git.setRemote(GitRemoteSetRequest(projectID: id, name: "origin", url: "https://example.com/moved.git"))
        XCTAssertEqual(moved.previousURL, "https://github.com/owngoal-dev/Pineora.git")
        XCTAssertEqual(moved.remote, GitRemoteSummary(name: "origin", url: "https://example.com/moved.git"))
        XCTAssertNil(repository.localConfigValue("remote.origin.pushurl"))
        XCTAssertEqual(repository.remotePushURL("origin"), "https://example.com/moved.git")

        // Removed with its upstream record; a second removal finds none.
        try repository.setLocalConfigValue("upstream", for: "branch.main.remote")
        _ = try git.removeRemote(GitRemoteRemoveRequest(projectID: id, name: "upstream"))
        XCTAssertEqual(try git.remotes(GitRemoteListRequest(projectID: id)).remotes.map(\.name), ["origin"])
        XCTAssertNil(repository.localConfigValue("branch.main.remote"))
        XCTAssertThrowsError(try git.removeRemote(GitRemoteRemoveRequest(projectID: id, name: "upstream"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .notFound)
            XCTAssertEqual(($0 as? ApelinError)?.reason, .noSuchRemote)
        }
    }

    func testOnlyANameAndAnHTTPSAddressWithNothingSecretInItAreTaken() throws {
        let home = try TemporaryHome(self)
        let (id, root) = try workspace(home)
        let git = GitService(layout: home.layout)
        let refusedURLs = [
            "http://example.com/a.git", "ssh://example.com/a.git", "git@github.com:a/b.git", "/tmp/a.git",
            "https://user:token@example.com/a.git", "https://token@example.com/a.git",
            "https://example.com/a.git?access_token=x", "https://example.com/a.git#frag",
            "https://example.com/a b.git", "https://example.com/a.git\n[core]", "https://",
        ]
        for url in refusedURLs {
            XCTAssertThrowsError(try git.setRemote(GitRemoteSetRequest(projectID: id, name: "origin", url: url)), url) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest, url)
                XCTAssertFalse("\($0)".contains("token@"), "the refusal never quotes a credential")
            }
        }
        let refusedNames = [
            "", "-x", "--upload-pack=evil", ".hidden", "a..b", "../x", "/abs", "a/b", "x.lock", "x.", "with space",
            "https://example.com/a.git", "git@github.com:a/b", String(repeating: "a", count: 65), "a\0b",
        ]
        for name in refusedNames {
            XCTAssertThrowsError(try git.setRemote(GitRemoteSetRequest(projectID: id, name: name, url: "https://example.com/a.git")), name) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest, name)
            }
            XCTAssertThrowsError(try git.removeRemote(GitRemoteRemoveRequest(projectID: id, name: name)), name)
        }
        XCTAssertNil(try GitRepository(at: root).remoteURL(), "nothing was added")
        XCTAssertNoThrow(try git.setRemote(GitRemoteSetRequest(projectID: id, name: "up_stream-2.x", url: "https://example.com:8443/a.git")))
    }

    func testAListNeverShowsACredentialTheConfigurationHolds() throws {
        let home = try TemporaryHome(self)
        let (id, root) = try workspace(home)
        let repository = try GitRepository(at: root)
        try repository.addRemote("origin", url: "https://ada:ghp_secret@github.com/a/b.git?token=x")
        let listed = try service(home).remotes(GitRemoteListRequest(projectID: id)).remotes
        XCTAssertEqual(listed, [GitRemoteSummary(name: "origin", url: "https://github.com/a/b.git", hidesCredential: true)])
        XCTAssertFalse(try String(decoding: JSONCoding.encode(listed), as: UTF8.self).contains("secret"))
        let moved = try service(home).setRemote(GitRemoteSetRequest(projectID: id, name: "origin", url: "https://github.com/a/b.git"))
        XCTAssertEqual(moved.previousURL, "https://github.com/a/b.git", "the old address is shown without it too")
    }

    func testAnAddressWhereARemoteNameGoesSaysHowToAddIt() throws {
        let home = try TemporaryHome(self)
        let (id, _) = try workspace(home)
        let git = service(home)
        for request in [GitFetchRequest(projectID: id, remote: "https://github.com/owngoal-dev/Pineora.git")] {
            XCTAssertThrowsError(try git.prepareFetch(request)) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
                XCTAssertTrue("\($0)".contains("is an address, not a remote's name"), "\($0)")
            }
        }
        XCTAssertThrowsError(try git.preparePull(GitPullRequest(projectID: id, remote: "https://github.com/owngoal-dev/Pineora.git"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
            XCTAssertNil(($0 as? ApelinError)?.reason, "not “no such remote”")
        }
        XCTAssertThrowsError(try git.preparePull(GitPullRequest(projectID: id, remote: "upstream"))) {
            XCTAssertEqual(($0 as? ApelinError)?.reason, .noSuchRemote, "a name it lacks is still that")
        }
    }

    func testTheWorkerServesTheRemotes() async throws {
        let home = try TemporaryHome(self)
        let (id, _) = try workspace(home)
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) { _, _, _ in }
        let set = GitRemoteSetRequest(projectID: id, name: "origin", url: "https://example.com/a.git")
        let (saved, _) = try await worker.handle(ChannelRequest(request: WireRequest(set), descriptors: [], taskID: nil))
        XCTAssertNoThrow(try saved.result.get())
        let (reply, _) = try await worker.handle(ChannelRequest(request: WireRequest(GitRemoteListRequest(projectID: id)), descriptors: [], taskID: nil))
        let listed = try JSONCoding.decode(GitRemoteListResponse.self, from: reply.result.get())
        XCTAssertEqual(listed.remotes, [GitRemoteSummary(name: "origin", url: "https://example.com/a.git")])
        let remove = GitRemoteRemoveRequest(projectID: id, name: "origin")
        let (removed, _) = try await worker.handle(ChannelRequest(request: WireRequest(remove), descriptors: [], taskID: nil))
        XCTAssertNoThrow(try removed.result.get())
    }
}
