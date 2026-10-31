import ApelinCore
@testable import ApelinEnvironment
@testable import ApelinGit
import ApelinProject
@testable import ApelinProtocol
import Foundation
import XCTest

/// The git service's remote operations and settings: against a bare
/// repository on disk (`acceptsLocalRemotes`), with credentials in memory.
final class GitRemoteServiceTests: XCTestCase {
    private let author = GitSignature(name: "Apelin Test", email: "test@apelin.invalid")

    private func service(_ home: TemporaryHome, store: any GitCredentialStore = MemoryGitCredentialStore()) -> GitService {
        var git = GitService(layout: home.layout, credentials: store)
        git.acceptsLocalRemotes = true
        return git
    }

    /// A bare repository outside the data folder with one commit on main.
    private func bareRemote(_ home: TemporaryHome) throws -> (url: String, seed: GitRepository) {
        let bare = home.home.appendingPathComponent("remote.git", isDirectory: true)
        try GitRepository.createBare(at: bare)
        let seed = try GitRepository.create(at: home.home.appendingPathComponent("seed", isDirectory: true))
        try Data("one\n".utf8).write(to: seed.workdir.appendingPathComponent("README"))
        try seed.stage(["README"])
        try seed.commit(message: "First", author: author)
        try seed.addRemote("origin", url: bare.path)
        _ = try seed.push()
        return (bare.path, seed)
    }

    /// `Projects/<name>/` with a description of `kind`.
    @discardableResult
    private func project(_ home: TemporaryHome, name: String, id: String, kind: String) throws -> URL {
        let root = home.layout.data.projects.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let description = #"{"schemaVersion": 1, "projectID": "\#(id)", "kind": "\#(kind)", "buildSystem": "external"}"#
        try Data(description.utf8).write(to: root.appendingPathComponent("apelin-project.json"))
        return root
    }

    // MARK: Clone into a workspace

    func testCloneIntoAWorkspace() throws {
        let home = try TemporaryHome(self)
        let (url, seed) = try bareRemote(home)
        let id = "8a6f3c1e-0000-4000-8000-000000000101"
        let root = try project(home, name: "Space", id: id, kind: "workspace")
        try Data("icon".utf8).write(to: root.appendingPathComponent("apelin-icon.png"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("Attachments/x"))
        let git = service(home)

        let request = GitCloneIntoRequest(projectID: id, url: url)
        let log = EventLog()
        let result = try git.cloneInto(request, into: git.checkCloneInto(request), reporter: log.reporter)
        let commit = try XCTUnwrap(seed.head().commit)
        XCTAssertEqual(result, .object([
            "branch": .string("main"), "commit": .string(commit), "projectID": .string(id), "projectFile": .string("project"),
        ]))
        XCTAssertEqual(log.events.first?.0, "stage")
        XCTAssertEqual(log.events.first?.1?["stage"]?.stringValue, "fetching")
        for (kind, payload) in log.events where kind == "progress" {
            XCTAssertEqual(payload?["stage"]?.stringValue, "fetching")
        }
        let status = try git.status(GitStatusRequest(projectID: id))
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.entries, [], "Apelin's own files are excluded")
        let exclude = try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        for pattern in GitService.apelinFiles {
            XCTAssertTrue(exclude.contains(pattern + "\n"), pattern)
        }

        // A second import is refused before it starts.
        XCTAssertThrowsError(try git.checkCloneInto(request)) { XCTAssertEqual(($0 as? ApelinError)?.code, .conflict) }
    }

    func testCloneIntoIsCheckedBeforeItStarts() throws {
        let home = try TemporaryHome(self)
        let tweak = "8a6f3c1e-0000-4000-8000-000000000102"
        try project(home, name: "Tweak", id: tweak, kind: "tweak")
        let space = "8a6f3c1e-0000-4000-8000-000000000103"
        let root = try project(home, name: "Space", id: space, kind: "workspace")
        var git = GitService(layout: home.layout)

        XCTAssertThrowsError(try git.checkCloneInto(GitCloneIntoRequest(projectID: tweak, url: "https://example.com/a.git"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
        }
        for url in ["http://example.com/a.git", "ssh://example.com/a.git", "/tmp/a.git", "https://u:p@example.com/a.git"] {
            XCTAssertThrowsError(try git.checkCloneInto(GitCloneIntoRequest(projectID: space, url: url)), url) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
            }
        }
        XCTAssertThrowsError(try git.checkCloneInto(GitCloneIntoRequest(projectID: space, url: "https://example.com/a.git", branch: "-x")))
        XCTAssertNoThrow(try git.checkCloneInto(GitCloneIntoRequest(projectID: space, url: "https://example.com/a.git")))
        git.acceptsLocalRemotes = true
        XCTAssertNoThrow(try git.checkCloneInto(GitCloneIntoRequest(projectID: space, url: "/tmp/a.git")))

        // The untouched repository a new workspace starts with is taken; one
        // with a commit is not.
        let repository = try GitRepository.create(at: root)
        XCTAssertTrue(repository.isUntouched)
        XCTAssertNoThrow(try git.checkCloneInto(GitCloneIntoRequest(projectID: space, url: "https://example.com/a.git")))
        try Data("x\n".utf8).write(to: root.appendingPathComponent("x"))
        try repository.stage(["x"])
        XCTAssertFalse(repository.isUntouched, "something staged")
        try repository.commit(message: "Mine", author: author)
        XCTAssertThrowsError(try git.checkCloneInto(GitCloneIntoRequest(projectID: space, url: "https://example.com/a.git"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict)
        }
    }

    func testCloneIntoReplacesTheUntouchedRepositoryANewWorkspaceHas() throws {
        let home = try TemporaryHome(self)
        let (url, seed) = try bareRemote(home)
        let id = "8a6f3c1e-0000-4000-8000-000000000106"
        let root = try project(home, name: "Space", id: id, kind: "workspace")
        _ = try GitRepository.create(at: root)
        let git = service(home)
        let request = GitCloneIntoRequest(projectID: id, url: url)
        let result = try git.cloneInto(request, into: git.checkCloneInto(request), reporter: .silent)
        XCTAssertEqual(result["commit"]?.stringValue, seed.head().commit)
        XCTAssertEqual(try GitRepository(at: root).remoteURL(), url)
    }

    func testCloneIntoThatClashesPutsTheUntouchedRepositoryBack() throws {
        let home = try TemporaryHome(self)
        let (url, _) = try bareRemote(home)
        let id = "8a6f3c1e-0000-4000-8000-000000000107"
        let root = try project(home, name: "Space", id: id, kind: "workspace")
        _ = try GitRepository.create(at: root)
        try Data("mine\n".utf8).write(to: root.appendingPathComponent("README"))
        let git = service(home)
        let request = GitCloneIntoRequest(projectID: id, url: url)
        XCTAssertThrowsError(try git.cloneInto(request, into: git.checkCloneInto(request), reporter: .silent)) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict, "\($0)")
        }
        let back = try GitRepository(at: root)
        XCTAssertTrue(back.isUntouched)
        XCTAssertEqual(back.head().branch, "main")
        XCTAssertNil(back.remoteURL())
    }

    // MARK: Init and commit everything

    /// A project Apelin makes is a repository on main from the start, which
    /// libgit2 opens as git init would have left it, and a workspace's can
    /// still take an import.
    func testANewProjectStartsAsAnUntouchedRepositoryOnMain() throws {
        let home = try TemporaryHome(self)
        let created = try ProjectStore(dataFolder: home.layout.data).createEmpty(name: "Fresh")
        let root = URL(fileURLWithPath: created.path, isDirectory: true)
        let repository = try GitRepository(at: root)
        XCTAssertTrue(repository.isUntouched)
        XCTAssertEqual(repository.head(), GitHead(branch: "main", commit: nil))
        let git = service(home)
        let status = try git.status(GitStatusRequest(projectID: created.projectID))
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.entries.map(\.path), ["apelin-project.json"])
        XCTAssertNoThrow(try git.checkCloneInto(GitCloneIntoRequest(projectID: created.projectID, url: "/tmp/a.git")))
    }

    func testInitMakesARepositoryOnMainOnce() throws {
        let home = try TemporaryHome(self)
        let id = "8a6f3c1e-0000-4000-8000-000000000108"
        let root = try project(home, name: "Plain", id: id, kind: "tweak")
        let git = service(home)
        XCTAssertThrowsError(try git.status(GitStatusRequest(projectID: id))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .notFound)
            XCTAssertEqual(($0 as? ApelinError)?.reason, .notARepository, "the agent is told to run git_init")
        }
        XCTAssertEqual(try git.initialize(GitInitRequest(projectID: id)), GitInitResponse(branch: "main"))
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: id)).branch, "main")
        XCTAssertTrue(try GitRepository(at: root).isUntouched)
        XCTAssertThrowsError(try git.initialize(GitInitRequest(projectID: id))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict)
        }
    }

    // MARK: Apelin's own files

    /// The chat's attachments and the file tools' temporary files sit in the
    /// project folder, but are no change of the project's.
    func testANewProjectKeepsApelinsOwnFilesOutOfItsRepository() throws {
        let home = try TemporaryHome(self)
        let created = try ProjectStore(dataFolder: home.layout.data).createEmpty(name: "Fresh")
        let root = URL(fileURLWithPath: created.path, isDirectory: true)
        try writeApelinFiles(in: root)
        let git = service(home)
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: created.projectID)).entries.map(\.path), ["apelin-project.json"])
        XCTAssertFalse(try git.diff(GitDiffRequest(projectID: created.projectID)).diff.contains("Attachments"))

        _ = try git.commit(GitCommitRequest(
            projectID: created.projectID, message: "First", authorName: "A", authorEmail: "a@apelin.invalid", all: true,
        ))
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: created.projectID)).entries, [])
        // Had it been committed, its removal would be a change.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Attachments"))
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: created.projectID)).entries, [], "the attachment was never committed")
    }

    func testInitKeepsApelinsOwnFilesOut() throws {
        let home = try TemporaryHome(self)
        let id = "8a6f3c1e-0000-4000-8000-00000000010b"
        let root = try project(home, name: "Plain", id: id, kind: "tweak")
        let git = service(home)
        _ = try git.initialize(GitInitRequest(projectID: id))
        let exclude = try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        for pattern in ProjectExcludes.apelinFiles {
            XCTAssertTrue(exclude.contains(pattern + "\n"), pattern)
        }
        try writeApelinFiles(in: root)
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: id)).entries.map(\.path), ["apelin-project.json"])
    }

    /// A repository made before Apelin wrote its excludes takes them on its
    /// next git call, once the project has an attachment, and not before.
    func testAnOlderRepositoryKeepsApelinsOwnFilesOutOnceItHasAttachments() throws {
        let home = try TemporaryHome(self)
        let id = "8a6f3c1e-0000-4000-8000-00000000010c"
        let root = try project(home, name: "Plain", id: id, kind: "tweak")
        _ = try GitRepository.create(at: root)
        let exclude = root.appendingPathComponent(".git/info/exclude")
        let git = service(home)
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: id)).entries.map(\.path), ["apelin-project.json"])
        XCTAssertFalse(((try? String(contentsOf: exclude, encoding: .utf8)) ?? "").contains("/Attachments/"), "nothing to keep out yet")

        try writeApelinFiles(in: root)
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: id)).entries.map(\.path), ["apelin-project.json"])
        let text = try String(contentsOf: exclude, encoding: .utf8)
        for pattern in ProjectExcludes.apelinFiles {
            XCTAssertEqual(text.components(separatedBy: "\n").count(where: { $0 == pattern }), 1, pattern)
        }
        _ = try git.status(GitStatusRequest(projectID: id))
        XCTAssertEqual(try String(contentsOf: exclude, encoding: .utf8), text, "written once")
    }

    /// An attachment the agent saved, and a temporary file its file tools
    /// left beside a file they replace.
    private func writeApelinFiles(in root: URL) throws {
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: attachments.appendingPathComponent("4b0c0f5e-0000-4000-8000-000000000001"))
        try Data("partial".utf8).write(to: root.appendingPathComponent(".Tweak.m.apelin-1F2E3D4C"))
    }

    func testCommitAllStagesNewChangedAndDeletedFilesButNotIgnoredOnes() throws {
        let home = try TemporaryHome(self)
        let id = "8a6f3c1e-0000-4000-8000-000000000109"
        let root = try project(home, name: "Plain", id: id, kind: "tweak")
        let git = service(home)
        _ = try git.initialize(GitInitRequest(projectID: id))
        try Data("build/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data("o".utf8).write(to: root.appendingPathComponent("build/out.o"))
        try Data("a\n".utf8).write(to: root.appendingPathComponent("a.m"))
        try Data("b\n".utf8).write(to: root.appendingPathComponent("b.m"))
        let commit = { (message: String) in
            try git.commit(GitCommitRequest(
                projectID: id, message: message, authorName: "A", authorEmail: "a@apelin.invalid", all: true,
            ))
        }
        _ = try commit("First")
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: id)).entries, [], "everything but build/ went in")
        try Data("a2\n".utf8).write(to: root.appendingPathComponent("a.m"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.m"))
        try Data("c\n".utf8).write(to: root.appendingPathComponent("c.m"))
        _ = try commit("Second")
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: id)).entries, [], "the change, the removal and the new file")
        XCTAssertThrowsError(try commit("Nothing")) { XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest, "\($0)") }
        // without all, only what was staged
        try Data("a3\n".utf8).write(to: root.appendingPathComponent("a.m"))
        XCTAssertThrowsError(try git.commit(GitCommitRequest(
            projectID: id, message: "Staged only", authorName: "A", authorEmail: "a@apelin.invalid",
        )))
    }

    func testCloneIntoThatClashesLeavesTheWorkspace() throws {
        let home = try TemporaryHome(self)
        let (url, _) = try bareRemote(home)
        let id = "8a6f3c1e-0000-4000-8000-000000000104"
        let root = try project(home, name: "Space", id: id, kind: "workspace")
        try Data("mine\n".utf8).write(to: root.appendingPathComponent("README"))
        let git = service(home)
        let request = GitCloneIntoRequest(projectID: id, url: url)
        XCTAssertThrowsError(try git.cloneInto(request, into: git.checkCloneInto(request), reporter: .silent)) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict, "\($0)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["README", "apelin-project.json"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("README"), encoding: .utf8), "mine\n")
    }

    func testTheWorkerRefusesABadImportAsItsReply() async throws {
        let home = try TemporaryHome(self)
        let id = "8a6f3c1e-0000-4000-8000-000000000105"
        try project(home, name: "Tweak", id: id, kind: "tweak")
        let log = EventLog()
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) {
            _, kind, payload in log.append(kind, payload)
        }
        let request = GitCloneIntoRequest(projectID: id, url: "https://example.com/a.git")
        let (reply, _) = try await worker.handle(ChannelRequest(request: WireRequest(request), descriptors: [], taskID: TaskID("import")))
        XCTAssertThrowsError(try reply.result.get()) { XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest) }
        XCTAssertEqual(log.kinds, [], "no task ran")
    }

    // MARK: Fetch, pull and push

    func testFetchPullAndPushThroughTheService() throws {
        let home = try TemporaryHome(self)
        let (url, seed) = try bareRemote(home)
        let id = "8a6f3c1e-0000-4000-8000-000000000106"
        let root = try project(home, name: "Space", id: id, kind: "workspace")
        let git = service(home)
        let clone = GitCloneIntoRequest(projectID: id, url: url)
        _ = try git.cloneInto(clone, into: git.checkCloneInto(clone), reporter: .silent)
        let first = try XCTUnwrap(seed.head().commit)

        // Up to date.
        let pullLog = EventLog()
        let upToDate = try git.pull(git.preparePull(GitPullRequest(projectID: id)), reporter: pullLog.reporter)
        XCTAssertEqual(upToDate, .object([
            "branch": .string("main"), "from": .string(first), "to": .string(first), "upToDate": .bool(true),
        ]))

        // The seed moves on; fetch sees it, pull takes it.
        try Data("two\n".utf8).write(to: seed.workdir.appendingPathComponent("README"))
        try seed.stage(["README"])
        let second = try seed.commit(message: "Second", author: author)
        _ = try seed.push()
        let fetched = try git.fetch(git.prepareFetch(GitFetchRequest(projectID: id)), reporter: .silent)
        XCTAssertEqual(fetched, .object([
            "remote": .string("origin"),
            "updated": .array([.object([
                "ref": .string("refs/remotes/origin/main"), "from": .string(first), "to": .string(second),
            ])]),
        ]))
        let pulled = try git.pull(git.preparePull(GitPullRequest(projectID: id)), reporter: .silent)
        XCTAssertEqual(pulled["upToDate"], .bool(false))
        XCTAssertEqual(pulled["to"], .string(second))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("README"), encoding: .utf8), "two\n")

        // A commit here goes back.
        try Data("int x;\n".utf8).write(to: root.appendingPathComponent("main.c"))
        _ = try git.stage(GitStageRequest(projectID: id, paths: ["main.c"]))
        let third = try git.commit(GitCommitRequest(projectID: id, message: "Third", authorName: "A", authorEmail: "a@apelin.invalid"))
        let pushLog = EventLog()
        let pushed = try git.push(git.preparePush(GitPushRequest(projectID: id)), reporter: pushLog.reporter)
        XCTAssertEqual(pushed, .object([
            "remote": .string("origin"), "branch": .string("main"), "commit": .string(third.commitID), "from": .string(second),
        ]))
        XCTAssertEqual(pushLog.events.first?.1?["stage"]?.stringValue, "pushing")
        for (kind, payload) in pushLog.events where kind == "progress" {
            XCTAssertEqual(payload?["stage"]?.stringValue, "pushing")
        }

        // The seed has not pulled: its push is refused, and so is its pull
        // once it has a commit of its own.
        try Data("three\n".utf8).write(to: seed.workdir.appendingPathComponent("README"))
        try seed.stage(["README"])
        try seed.commit(message: "Diverge", author: author)
        XCTAssertThrowsError(try seed.push()) { error in
            XCTAssertEqual(GitService.apelinError(error).code, .conflict)
            XCTAssertEqual(GitService.apelinError(error).reason?.rawValue, "rejected")
        }
        XCTAssertThrowsError(try seed.pull()) { error in
            XCTAssertEqual(GitService.apelinError(error).code, .conflict)
            XCTAssertEqual(GitService.apelinError(error).reason?.rawValue, "notFastForward")
        }
    }

    func testRemoteOperationsTakeOnlyHTTPS() throws {
        let home = try TemporaryHome(self)
        let (url, _) = try bareRemote(home)
        let id = "8a6f3c1e-0000-4000-8000-000000000107"
        try project(home, name: "Space", id: id, kind: "workspace")
        let clone = GitCloneIntoRequest(projectID: id, url: url)
        let local = service(home)
        _ = try local.cloneInto(clone, into: local.checkCloneInto(clone), reporter: .silent)

        let git = GitService(layout: home.layout)
        XCTAssertThrowsError(try git.prepareFetch(GitFetchRequest(projectID: id))) { XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest) }
        XCTAssertThrowsError(try git.preparePull(GitPullRequest(projectID: id))) { XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest) }
        XCTAssertThrowsError(try git.preparePush(GitPushRequest(projectID: id))) { XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest) }
        XCTAssertThrowsError(try git.prepareFetch(GitFetchRequest(projectID: id, remote: "upstream"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .notFound)
        }
        XCTAssertThrowsError(try local.preparePush(GitPushRequest(projectID: id, branch: "a..b"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
        }

        // A push goes to the remote's pushurl, which must pass too.
        XCTAssertNoThrow(try local.preparePush(GitPushRequest(projectID: id)))
        let root = home.layout.data.projects.appendingPathComponent("Space", isDirectory: true)
        try GitRepository(at: root).setLocalConfigValue("http://example.com/a.git", for: "remote.origin.pushurl")
        XCTAssertThrowsError(try local.preparePush(GitPushRequest(projectID: id))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
        }
    }

    /// A project made here has no remote: a push with a URL adds it, then
    /// pushes as to any remote, and records it as the branch's upstream.
    func testAPushWithAURLAddsTheRemoteTheProjectDoesNotHave() throws {
        let home = try TemporaryHome(self)
        let bare = home.home.appendingPathComponent("empty.git", isDirectory: true)
        try GitRepository.createBare(at: bare)
        let created = try ProjectStore(dataFolder: home.layout.data).createEmpty(name: "Fresh")
        let id = created.projectID
        let git = service(home)
        let commit = try git.commit(GitCommitRequest(
            projectID: id, message: "First", authorName: "A", authorEmail: "a@apelin.invalid", all: true,
        )).commitID

        XCTAssertThrowsError(try git.preparePush(GitPushRequest(projectID: id))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .notFound)
            XCTAssertEqual(($0 as? ApelinError)?.reason, .noSuchRemote, "the agent is told to ask for an address")
        }
        let pushed = try git.push(git.preparePush(GitPushRequest(projectID: id, url: bare.path)), reporter: .silent)
        XCTAssertEqual(pushed, .object(["remote": .string("origin"), "branch": .string("main"), "commit": .string(commit)]))
        let repository = try GitRepository(at: URL(fileURLWithPath: created.path, isDirectory: true))
        XCTAssertEqual(repository.remoteURL(), bare.path)
        XCTAssertEqual(repository.localConfigValue("branch.main.remote"), "origin")
        let check = try GitRepository.create(at: home.home.appendingPathComponent("check", isDirectory: true))
        try check.addRemote("origin", url: bare.path)
        XCTAssertEqual(try check.fetch().updated.first { $0.ref == "refs/remotes/origin/main" }?.to, commit, "the remote has the commit")

        // The same URL again is the same remote; fetch and pull read it too.
        XCTAssertNoThrow(try git.preparePush(GitPushRequest(projectID: id, url: bare.path)))
        XCTAssertNoThrow(try git.fetch(git.prepareFetch(GitFetchRequest(projectID: id)), reporter: .silent))
        // Another URL never moves it.
        XCTAssertThrowsError(try git.preparePush(GitPushRequest(projectID: id, url: "/elsewhere.git"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict)
            XCTAssertEqual(($0 as? ApelinError)?.reason, .remoteURLDiffers)
        }
        XCTAssertEqual(repository.remoteURL(), bare.path)
    }

    func testAPushURLIsHTTPSAndARefusedOneAddsNothing() throws {
        let home = try TemporaryHome(self)
        let created = try ProjectStore(dataFolder: home.layout.data).createEmpty(name: "Fresh")
        let root = URL(fileURLWithPath: created.path, isDirectory: true)
        let git = GitService(layout: home.layout)
        for url in ["http://example.com/a.git", "ssh://example.com/a.git", "/tmp/a.git", "https://u:p@example.com/a.git"] {
            XCTAssertThrowsError(try git.preparePush(GitPushRequest(projectID: created.projectID, url: url)), url) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
            }
        }
        XCTAssertNil(try GitRepository(at: root).remoteURL())

        // An HTTPS URL a rewrite sends elsewhere is refused as a remote that
        // has it would be, and the remote it added is taken away again.
        try GitRepository(at: root).setLocalConfigValue("https://example.com/a.git", for: "url.http://example.com/a.git.pushInsteadOf")
        XCTAssertThrowsError(try git.preparePush(GitPushRequest(projectID: created.projectID, url: "https://example.com/a.git"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
        }
        XCTAssertNil(try GitRepository(at: root).remoteURL())
        XCTAssertNoThrow(try git.preparePush(GitPushRequest(projectID: created.projectID, url: "https://example.com/b.git")))
        XCTAssertEqual(try GitRepository(at: root).remoteURL(), "https://example.com/b.git")
    }

    /// A push goes where libgit2 sends it, through `pushInsteadOf` too.
    func testAPushInsteadOfRewriteMustPassToo() throws {
        let home = try TemporaryHome(self)
        let (url, _) = try bareRemote(home)
        let id = "8a6f3c1e-0000-4000-8000-00000000010a"
        let root = try project(home, name: "Space", id: id, kind: "workspace")
        let local = service(home)
        let clone = GitCloneIntoRequest(projectID: id, url: url)
        _ = try local.cloneInto(clone, into: local.checkCloneInto(clone), reporter: .silent)
        XCTAssertNoThrow(try local.preparePush(GitPushRequest(projectID: id)))

        try GitRepository(at: root).setLocalConfigValue(url, for: "url.http://example.com/a.git.pushInsteadOf")
        XCTAssertNil(try GitRepository(at: root).localConfigValue("remote.origin.pushurl"))
        XCTAssertThrowsError(try local.preparePush(GitPushRequest(projectID: id))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
        }
    }

    func testACancelledFetchEndsCancelled() throws {
        let home = try TemporaryHome(self)
        let (url, seed) = try bareRemote(home)
        let id = "8a6f3c1e-0000-4000-8000-000000000108"
        try project(home, name: "Space", id: id, kind: "workspace")
        let git = service(home)
        let clone = GitCloneIntoRequest(projectID: id, url: url)
        _ = try git.cloneInto(clone, into: git.checkCloneInto(clone), reporter: .silent)
        try Data(count: 256 * 1024).write(to: seed.workdir.appendingPathComponent("blob"))
        try seed.stage(["blob"])
        try seed.commit(message: "Blob", author: author)
        _ = try seed.push()

        let flag = CancellationFlag()
        flag.cancel()
        let reporter = TaskReporter(cancellation: flag) { _, _ in }
        XCTAssertThrowsError(try git.fetch(git.prepareFetch(GitFetchRequest(projectID: id)), reporter: reporter)) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .cancelled, "\($0)")
        }
    }

    func testErrorsCarryTheirReason() {
        let auth = GitService.apelinError(GitError(.authenticationFailed, "fetch origin: authentication failed"))
        XCTAssertEqual(auth.code, .denied)
        XCTAssertEqual(auth.reason?.rawValue, "authenticationRequired")
        XCTAssertNil(GitService.apelinError(GitError(.conflict, "checkout")).reason, "an overwrite is not a refusal")
    }

    func testAFailedTaskCarriesTheReasonInItsState() async throws {
        let home = try TemporaryHome(self)
        let (url, seed) = try bareRemote(home)
        let id = "8a6f3c1e-0000-4000-8000-000000000109"
        let root = try project(home, name: "Space", id: id, kind: "workspace")
        let log = EventLog()
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) {
            _, kind, payload in log.append(kind, payload)
        }
        worker.git.acceptsLocalRemotes = true
        let clone = GitCloneIntoRequest(projectID: id, url: url)
        _ = try worker.git.cloneInto(clone, into: worker.git.checkCloneInto(clone), reporter: .silent)

        // Both sides commit: the workspace's pull cannot fast-forward.
        try Data("theirs\n".utf8).write(to: seed.workdir.appendingPathComponent("README"))
        try seed.stage(["README"])
        try seed.commit(message: "Theirs", author: author)
        _ = try seed.push()
        let work = try GitRepository(at: root)
        try Data("mine\n".utf8).write(to: root.appendingPathComponent("mine.txt"))
        try work.stage(["mine.txt"])
        try work.commit(message: "Mine", author: author)

        let request = try ChannelRequest(request: WireRequest(GitPullRequest(projectID: id)), descriptors: [], taskID: TaskID("pull"))
        let (reply, _) = await worker.handle(request)
        XCTAssertNoThrow(try reply.result.get())
        for _ in 0 ..< 200 where !(log.last(TaskEvent.stateKind)?["state"]?.stringValue.map { TaskState(rawValue: $0)?.isTerminal == true } ?? false) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let state = try XCTUnwrap(log.last(TaskEvent.stateKind))
        XCTAssertEqual(state["state"]?.stringValue, TaskState.failed.rawValue, "\(log.kinds)")
        XCTAssertEqual(state["reason"]?.stringValue, "notFastForward")
        XCTAssertNotNil(state["message"]?.stringValue)
    }

    // MARK: Settings and credentials

    func testAuthorSettings() throws {
        let home = try TemporaryHome(self)
        let git = service(home)
        XCTAssertEqual(try git.settings(), GitSettingsResponse())
        _ = try git.setAuthor(GitAuthorSetRequest(authorName: "  Ada  ", authorEmail: "ada@apelin.invalid"))
        XCTAssertEqual(try git.settings(), GitSettingsResponse(authorName: "Ada", authorEmail: "ada@apelin.invalid"))
        _ = try git.setAuthor(GitAuthorSetRequest(authorName: "Ada", authorEmail: ""))
        XCTAssertEqual(try git.settings(), GitSettingsResponse(authorName: "Ada"))
        let text = try String(contentsOf: home.layout.gitSettings, encoding: .utf8)
        XCTAssertFalse(text.contains("authorEmail"), text)
        _ = try git.setAuthor(GitAuthorSetRequest(authorName: nil, authorEmail: nil))
        XCTAssertEqual(try git.settings(), GitSettingsResponse())
        for name in ["Two\nLines", "<ada>", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try git.setAuthor(GitAuthorSetRequest(authorName: name, authorEmail: nil))) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
            }
        }
    }

    func testCredentialsAreListedWithoutTheirTokens() throws {
        let home = try TemporaryHome(self)
        let store = MemoryGitCredentialStore()
        let git = service(home, store: store)
        _ = try git.setCredential(GitCredentialSetRequest(host: "GitHub.com", username: "ada", token: "secret-one"))
        _ = try git.setCredential(GitCredentialSetRequest(host: "git.example.com:08443", username: "bob", token: "secret-two"))
        _ = try git.setCredential(GitCredentialSetRequest(host: "github.com", username: "ada2", token: "secret-three"))
        let settings = try git.settings()
        XCTAssertEqual(settings.credentials, [
            GitCredentialSummary(host: "git.example.com:8443", username: "bob"),
            GitCredentialSummary(host: "github.com", username: "ada2"),
        ])
        XCTAssertFalse(try String(decoding: JSONCoding.encode(settings), as: UTF8.self).contains("secret"))
        XCTAssertEqual(try store.credential(forHost: "github.com"), GitCredential(username: "ada2", token: "secret-three"))

        // Offered by exact host and port only.
        let lookup = git.credentialLookup
        XCTAssertEqual(lookup("https://github.com/a/b.git")?.username, "ada2")
        XCTAssertEqual(lookup("https://GITHUB.com/a/b.git")?.username, "ada2")
        XCTAssertNil(lookup("https://www.github.com/a/b.git"))
        XCTAssertNil(lookup("https://github.com:443/a/b.git"))
        XCTAssertNil(lookup("http://github.com/a/b.git"))
        XCTAssertEqual(lookup("https://git.example.com:8443/x.git")?.username, "bob")
        XCTAssertNil(lookup("https://git.example.com/x.git"))

        _ = try git.removeCredential(GitCredentialRemoveRequest(host: "GITHUB.COM"))
        _ = try git.removeCredential(GitCredentialRemoveRequest(host: "never.example.com"))
        XCTAssertEqual(try git.settings().credentials, [GitCredentialSummary(host: "git.example.com:8443", username: "bob")])
    }

    func testCredentialRequestsAreChecked() throws {
        let home = try TemporaryHome(self)
        let git = service(home)
        XCTAssertEqual(try GitService.credentialHost("GitHub.com"), "github.com")
        XCTAssertEqual(try GitService.credentialHost("host:0080"), "host:80")
        for host in ["", "https://github.com", "github.com/a", "ada@github.com", "git hub.com", "github.com\n", "a\0b",
                     ":443", "host:", "host:http", "host:0", "host:65536", "host:1:2"]
        {
            XCTAssertThrowsError(try GitService.credentialHost(host), host.debugDescription) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
            }
        }
        let refused = [
            GitCredentialSetRequest(host: "github.com", username: "", token: "t"),
            GitCredentialSetRequest(host: "github.com", username: "  ", token: "t"),
            GitCredentialSetRequest(host: "github.com", username: "a:b", token: "t"),
            GitCredentialSetRequest(host: "github.com", username: "a", token: ""),
            GitCredentialSetRequest(host: "github.com", username: "a", token: "one\ntwo"),
            GitCredentialSetRequest(host: "github.com", username: "a", token: "one\rtwo"),
            GitCredentialSetRequest(host: "github.com", username: "a", token: String(repeating: "t", count: 4097)),
        ]
        for request in refused {
            XCTAssertThrowsError(try git.setCredential(request)) { error in
                XCTAssertEqual((error as? ApelinError)?.code, .badRequest)
                XCTAssertFalse("\(error)".contains("one"), "no message quotes the token")
            }
        }
        XCTAssertNoThrow(try git.setCredential(GitCredentialSetRequest(
            host: "github.com",
            username: "a",
            token: String(repeating: "t", count: 4096),
        )))
        XCTAssertThrowsError(try git.removeCredential(GitCredentialRemoveRequest(host: "a/b")))
    }

    func testTheWorkerServesSettings() async throws {
        let home = try TemporaryHome(self)
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) { _, _, _ in }
        let set = GitCredentialSetRequest(host: "github.com", username: "ada", token: "secret")
        let (saved, _) = try await worker.handle(ChannelRequest(request: WireRequest(set), descriptors: [], taskID: nil))
        XCTAssertNoThrow(try saved.result.get())
        let (reply, _) = try await worker.handle(ChannelRequest(request: WireRequest(GitSettingsRequest()), descriptors: [], taskID: nil))
        let settings = try JSONCoding.decode(GitSettingsResponse.self, from: reply.result.get())
        XCTAssertEqual(settings.credentials, [GitCredentialSummary(host: "github.com", username: "ada")])
    }
}
