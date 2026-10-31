import ApelinCore
@testable import ApelinGit
import Foundation
import XCTest

/// A squash (owner, 2026-10-31): the commits after a base on the checked-out
/// branch become one, whose tree is HEAD's, the old head kept in the
/// reflog; refused, with nothing changed, unless HEAD is where the caller
/// saw it, the base is an ancestor, there are two or more commits, and
/// nothing tracked is uncommitted.
final class GitSquashTests: XCTestCase {
    private let author = GitSignature(name: "Apelin Test", email: "test@apelin.invalid")

    private func scratch() -> URL {
        let base = URL(fileURLWithPath: CanonicalPath.resolve(NSTemporaryDirectory())!, isDirectory: true)
        let url = base.appendingPathComponent("apelin-squash-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func commit(_ text: String, _ path: String, in repository: GitRepository, message: String) throws -> String {
        let url = repository.workdir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try repository.stage([path])
        return try repository.commit(message: message, author: author)
    }

    private func read(_ path: String, in repository: GitRepository) -> String? {
        FileManager.default.contents(atPath: repository.workdir.appendingPathComponent(path).path)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// `main` with five commits: First, then Two to Five.
    private func repository() throws -> (GitRepository, [String]) {
        let repository = try GitRepository.create(at: scratch())
        var commits = try [commit("one\n", "README", in: repository, message: "First")]
        for (index, name) in ["Two", "Three", "Four", "Five"].enumerated() {
            try commits.append(commit("\(index)\n", "File\(index).txt", in: repository, message: name))
        }
        return (repository, commits)
    }

    func testThreeCommitsBecomeOneWithTheSameFiles() throws {
        let (repository, commits) = try repository()
        let plan = try repository.squashPlan(.count(3))
        XCTAssertEqual(plan.branch, "main")
        XCTAssertEqual(plan.head, commits[4])
        XCTAssertEqual(plan.base, commits[1])
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan.commits.map(\.subject), ["Five", "Four", "Three"], "newest first")
        XCTAssertNil(plan.upstream)
        XCTAssertEqual(plan.published, 0)
        XCTAssertEqual(try repository.squashPlan(.commit(String(commits[1].prefix(7)))), plan, "a base by seven digits")
        XCTAssertEqual(repository.head().commit, commits[4], "a plan changes nothing")

        let result = try repository.squash(base: commits[1], expectedHead: commits[4], message: "Add three files", author: author)
        XCTAssertEqual(result.plan, plan)
        XCTAssertEqual(repository.head(), GitHead(branch: "main", commit: result.commit))
        XCTAssertEqual(try repository.status(), [], "the index and the work tree are HEAD's tree still")
        XCTAssertEqual(read("File3.txt", in: repository), "3\n")
        let squashed = try repository.squashPlan(.count(2))
        XCTAssertEqual(squashed.commits.map(\.subject), ["Add three files", "Two"])
        XCTAssertEqual(squashed.base, commits[0])

        let reflog = try XCTUnwrap(read(".git/logs/refs/heads/main", in: repository))
        XCTAssertTrue(reflog.contains("\(commits[4]) \(result.commit)"), "the old head stays reachable: \(reflog)")
        XCTAssertTrue(reflog.contains("squash: 3 commits after \(commits[1].prefix(7)) into one"), reflog)
    }

    func testASquashIsRefusedAndChangesNothing() throws {
        let (repository, commits) = try repository()
        func refused(_ kind: GitError.Kind, _ words: String, _ body: () throws -> Void) {
            XCTAssertThrowsError(try body()) { error in
                XCTAssertEqual((error as? GitError)?.kind, kind, "\(error)")
                XCTAssertTrue("\(error)".contains(words), "\(error)")
            }
            XCTAssertEqual(repository.head().commit, commits[4])
        }
        refused(.headChanged, "is at \(commits[4]) now") {
            _ = try repository.squash(base: commits[1], expectedHead: commits[3], message: "x", author: author)
        }
        refused(.conflict, "one commit after") {
            _ = try repository.squash(base: commits[3], expectedHead: commits[4], message: "x", author: author)
        }
        refused(.conflict, "no commit after") {
            _ = try repository.squashPlan(.commit(commits[4]))
        }
        refused(.conflict, "two or more") { _ = try repository.squashPlan(.count(1)) }
        refused(.conflict, "no commit 5 back") { _ = try repository.squashPlan(.count(5)) }
        refused(.invalid, "full commit IDs") {
            _ = try repository.squash(base: String(commits[1].prefix(7)), expectedHead: commits[4], message: "x", author: author)
        }
        refused(.invalid, "message is empty") {
            _ = try repository.squash(base: commits[1], expectedHead: commits[4], message: " \n", author: author)
        }

        refused(.notFound, "no commit") { _ = try repository.squashPlan(.commit("1234567")) }
        refused(.invalid, "not a commit ID") { _ = try repository.squashPlan(.commit("HEAD~2")) }

        // A tracked change waits for a commit; an untracked file does not.
        try Data("changed\n".utf8).write(to: repository.workdir.appendingPathComponent("README"))
        refused(.conflict, "changes not committed (README)") { _ = try repository.squashPlan(.count(2)) }
        try Data("one\n".utf8).write(to: repository.workdir.appendingPathComponent("README"))
        try Data("scratch\n".utf8).write(to: repository.workdir.appendingPathComponent("notes.txt"))
        XCTAssertEqual(try repository.squashPlan(.count(2)).count, 2, "an untracked file is left alone")
    }

    /// A commit of another history, fetched into this repository, is there
    /// but no ancestor of HEAD.
    func testABaseThatIsNotAnAncestorIsRefused() throws {
        let (repository, commits) = try repository()
        let other = try GitRepository.create(at: scratch())
        let foreign = try commit("other\n", "Other.txt", in: other, message: "Elsewhere")
        try repository.addRemote("other", url: other.workdir.path)
        _ = try repository.fetch(remote: "other")
        XCTAssertThrowsError(try repository.squash(base: foreign, expectedHead: commits[4], message: "x", author: author)) {
            XCTAssertEqual(($0 as? GitError)?.kind, .conflict, "\($0)")
            XCTAssertTrue("\($0)".contains("is not an ancestor"), "\($0)")
        }
        XCTAssertEqual(repository.head().commit, commits[4])
    }

    func testAPlanSaysHowManyCommitsTheUpstreamHas() throws {
        let (repository, commits) = try repository()
        let bare = repository.workdir.deletingLastPathComponent().appendingPathComponent("remote-\(UUID().uuidString).git")
        addTeardownBlock { try? FileManager.default.removeItem(at: bare) }
        try GitRepository.createBare(at: bare)
        try repository.addRemote("origin", url: bare.path)
        // The remote has Four and everything before it.
        try repository.createBranch("published", at: commits[3])
        _ = try repository.push(branch: "published")
        try repository.setLocalConfigValue("origin", for: "branch.main.remote")
        try repository.setLocalConfigValue("refs/heads/published", for: "branch.main.merge")
        _ = try repository.fetch()
        let plan = try repository.squashPlan(.count(3))
        XCTAssertEqual(plan.upstream, "origin/published")
        XCTAssertEqual(plan.published, 2, "Three and Four are on the remote; Five is not")
    }
}
