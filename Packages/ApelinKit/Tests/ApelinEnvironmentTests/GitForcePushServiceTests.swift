import ApelinCore
@testable import ApelinEnvironment
@testable import ApelinGit
@testable import ApelinProtocol
import Foundation
import XCTest

/// A forced push through the git service (issue #29): the fetch that sets a
/// branch beside the remote's, the lease checked before the task and when it
/// pushes, the `lease` event, and the reasons a refusal carries. Against a
/// bare repository on disk (`acceptsLocalRemotes`).
final class GitForcePushServiceTests: XCTestCase {
    private let author = GitSignature(name: "Apelin Test", email: "test@apelin.invalid")
    private let id = "8a6f3c1e-0000-4000-8000-000000000201"

    /// A workspace cloned from a bare remote, both sides with a commit of
    /// their own since: the remote's main has `theirs`, the workspace's
    /// `mine`.
    private struct Diverged {
        let git: GitService
        let url: String
        let seed: GitRepository
        let work: GitRepository
        let theirs: String
        let mine: String
    }

    @discardableResult
    private func commit(_ text: String, _ path: String, in repository: GitRepository, message: String) throws -> String {
        try Data(text.utf8).write(to: repository.workdir.appendingPathComponent(path))
        try repository.stage([path])
        return try repository.commit(message: message, author: author)
    }

    private func diverged() throws -> Diverged {
        let home = try TemporaryHome(self)
        let bare = home.home.appendingPathComponent("remote.git", isDirectory: true)
        try GitRepository.createBare(at: bare)
        let seed = try GitRepository.create(at: home.home.appendingPathComponent("seed", isDirectory: true))
        try commit("one\n", "README", in: seed, message: "First")
        try seed.addRemote("origin", url: bare.path)
        _ = try seed.push()

        let root = home.layout.data.projects.appendingPathComponent("Space", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let description = #"{"schemaVersion": 1, "projectID": "\#(id)", "kind": "workspace", "buildSystem": "external"}"#
        try Data(description.utf8).write(to: root.appendingPathComponent("apelin-project.json"))
        var git = GitService(layout: home.layout)
        git.acceptsLocalRemotes = true
        let clone = GitCloneIntoRequest(projectID: id, url: bare.path)
        _ = try git.cloneInto(clone, into: git.checkCloneInto(clone), reporter: .silent)

        let theirs = try commit("theirs\n", "README", in: seed, message: "Theirs")
        _ = try seed.push()
        let work = try GitRepository(at: root)
        let mine = try commit("mine\n", "Mine.txt", in: work, message: "Rewrite")
        return Diverged(git: git, url: bare.path, seed: seed, work: work, theirs: theirs, mine: mine)
    }

    func testAFetchNamingABranchSetsItBesideTheRemotes() throws {
        let diverged = try diverged()
        let git = diverged.git
        let fetched = try git.fetch(git.prepareFetch(GitFetchRequest(projectID: id, branch: "main")), reporter: .silent)
        let comparison = try XCTUnwrap(fetched["comparison"]).decode(GitBranchComparison.self)
        XCTAssertEqual(comparison, GitBranchComparison(
            branch: "main",
            local: diverged.mine,
            localSubject: "Rewrite",
            remote: diverged.theirs,
            pushURL: diverged.url,
            remoteOnly: [GitCommitSummary(commit: diverged.theirs, subject: "Theirs")],
            remoteOnlyCount: 1,
        ))
        XCTAssertNil(try git.fetch(git.prepareFetch(GitFetchRequest(projectID: id)), reporter: .silent)["comparison"])

        XCTAssertThrowsError(try git.prepareFetch(GitFetchRequest(projectID: id, branch: "feature"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .notFound, "a branch to compare is a local one")
        }
        XCTAssertThrowsError(try git.prepareFetch(GitFetchRequest(projectID: id, branch: "a..b"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest)
        }
    }

    func testALeaseIsCheckedBeforeTheTask() throws {
        let diverged = try diverged()
        let git = diverged.git
        for expected in ["abc", diverged.theirs.uppercased(), ""] {
            let lease = GitPushLease(expectedCommit: expected, localCommit: diverged.mine)
            XCTAssertThrowsError(try git.preparePush(GitPushRequest(projectID: id, forceWithLease: lease))) {
                XCTAssertEqual(($0 as? ApelinError)?.code, .badRequest, expected)
            }
        }
        let moved = GitPushLease(expectedCommit: diverged.theirs, localCommit: diverged.theirs)
        XCTAssertThrowsError(try git.preparePush(GitPushRequest(projectID: id, forceWithLease: moved))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict)
            XCTAssertEqual(($0 as? ApelinError)?.reason, .localChanged, "the local branch is not at the commit approved")
        }
    }

    func testAForcedPushOverwritesTheBranchAndSaysWhatItReplaced() throws {
        let diverged = try diverged()
        let git = diverged.git
        let ordinary = try git.preparePush(GitPushRequest(projectID: id))
        XCTAssertThrowsError(try git.push(ordinary, reporter: .silent)) {
            XCTAssertEqual(GitService.apelinError($0).reason?.rawValue, "rejected", "never forced without a lease")
        }

        let log = EventLog()
        let lease = GitPushLease(expectedCommit: diverged.theirs, localCommit: diverged.mine)
        let pushed = try git.push(git.preparePush(GitPushRequest(projectID: id, forceWithLease: lease)), reporter: log.reporter)
        XCTAssertEqual(pushed, .object([
            "remote": .string("origin"), "branch": .string("main"), "commit": .string(diverged.mine),
            "from": .string(diverged.theirs), "forced": .bool(true),
        ]))
        XCTAssertEqual(log.last("lease"), .object([
            "branch": .string("main"), "expectedCommit": .string(diverged.theirs), "localCommit": .string(diverged.mine),
            "found": .string(diverged.theirs), "held": .bool(true),
        ]))
        XCTAssertEqual(log.kinds.firstIndex(of: "lease"), 1, "after the stage, before anything is sent")
        XCTAssertEqual(
            try diverged.seed.fetch(comparing: "main").comparison?.remote,
            diverged.mine,
            "the remote's main is the workspace's now",
        )

        // Someone pushes after a new lease was taken: nothing is pushed.
        let again = try commit("again\n", "Again.txt", in: diverged.work, message: "Again")
        let other = diverged.seed.workdir.deletingLastPathComponent().appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try GitClone.into(other, url: diverged.url)
        let otherClone = try GitRepository(at: other)
        let later = try commit("later\n", "Later.txt", in: otherClone, message: "Later")
        _ = try otherClone.push()
        let stale = GitPushLease(expectedCommit: diverged.mine, localCommit: again)
        let refusedLog = EventLog()
        XCTAssertThrowsError(try git.push(git.preparePush(GitPushRequest(projectID: id, forceWithLease: stale)), reporter: refusedLog.reporter)) {
            let error = GitService.apelinError($0)
            XCTAssertEqual(error.code, .conflict)
            XCTAssertEqual(error.reason, .remoteChanged)
            XCTAssertTrue(error.message.contains("nothing was pushed"), error.message)
        }
        XCTAssertEqual(refusedLog.last("lease")?["held"], .bool(false))
        XCTAssertEqual(refusedLog.last("lease")?["found"], .string(later))
        XCTAssertEqual(try otherClone.fetch(comparing: "main").comparison?.remote, later, "the remote kept its branch")
    }

    func testTheLeasesReasonsReachTheTasksState() {
        XCTAssertEqual(GitService.apelinError(GitError(.remoteChanged, "x")).reason, .remoteChanged)
        XCTAssertEqual(GitService.apelinError(GitError(.localChanged, "x")).reason, .localChanged)
        XCTAssertEqual(GitService.apelinError(GitError(.remoteChanged, "x")).code, .conflict)
    }
}
