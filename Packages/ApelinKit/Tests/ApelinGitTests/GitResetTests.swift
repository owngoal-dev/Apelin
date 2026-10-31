import ApelinCore
@testable import ApelinGit
import Foundation
import XCTest

/// "Remote wins" (issue #32): a branch and its work tree made exactly a
/// remote's branch, after what is lost is saved on a branch of its own,
/// against a bare repository on disk.
final class GitResetTests: XCTestCase {
    private let author = GitSignature(name: "Apelin Test", email: "test@apelin.invalid")
    private let stamp = Date(timeIntervalSince1970: 1_793_448_000)

    private func scratch() -> URL {
        let base = URL(fileURLWithPath: CanonicalPath.resolve(NSTemporaryDirectory())!, isDirectory: true)
        let url = base.appendingPathComponent("apelin-reset-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in root: URL) -> String? {
        FileManager.default.contents(atPath: root.appendingPathComponent(path).path).map { String(decoding: $0, as: UTF8.self) }
    }

    @discardableResult
    private func commit(_ files: [String: String], in repository: GitRepository, message: String) throws -> String {
        for (path, text) in files {
            try write(text, path, in: repository.workdir)
        }
        try repository.stageAll()
        return try repository.commit(message: message, author: author)
    }

    /// A bare remote whose main the seed pushed, and the seed.
    private func remote(_ base: URL) throws -> (url: String, seed: GitRepository) {
        let bare = base.appendingPathComponent("remote.git", isDirectory: true)
        try GitRepository.createBare(at: bare)
        let seed = try GitRepository.create(at: base.appendingPathComponent("seed", isDirectory: true))
        try commit(["README": "theirs\n", "Sources/Tweak.m": "// theirs\n"], in: seed, message: "Their first")
        try commit(["notes.txt": "theirs\n"], in: seed, message: "Their notes")
        try seed.addRemote("origin", url: bare.path)
        _ = try seed.push()
        return (bare.path, seed)
    }

    /// A project of its own with history, as Pineora's was: no remote.
    private func project(_ base: URL) throws -> GitRepository {
        let project = try GitRepository.create(at: base.appendingPathComponent("project", isDirectory: true))
        try commit(["README": "mine\n", "Mine.m": "// mine\n"], in: project, message: "My first")
        try commit(["Mine.m": "// mine, again\n"], in: project, message: "My second")
        return project
    }

    func testUnrelatedHistoriesAreReplacedAndEverythingLostIsSaved() throws {
        let base = scratch()
        let (url, seed) = try remote(base)
        let project = try project(base)
        let mine = try XCTUnwrap(project.head().commit)
        try project.addRemote("origin", url: url)
        // Uncommitted: a tracked change, a staged new file, an untracked file
        // the remote has, and an untracked and an ignored file it has not.
        try write("// mine, unsaved\n", "Mine.m", in: project.workdir)
        try write("staged\n", "Staged.m", in: project.workdir)
        try project.stage(["Staged.m"])
        try write("my notes\n", "notes.txt", in: project.workdir)
        try write("keep me\n", "Scratch.txt", in: project.workdir)
        try write("build/\n", ".git/info/exclude", in: project.workdir)
        try write("object\n", "build/out.o", in: project.workdir)

        XCTAssertEqual(try project.fetchBranch(remote: "origin", branch: nil), "main", "the remote's HEAD names main")
        let plan = try project.resetPlan(remote: "origin", branch: "main")
        let theirs = try XCTUnwrap(seed.head().commit)
        XCTAssertEqual(plan.remoteCommit, theirs)
        XCTAssertEqual(plan.remoteSubject, "Their notes")
        XCTAssertEqual(plan.head, mine)
        XCTAssertEqual(plan.currentBranch, "main")
        XCTAssertTrue(plan.unrelatedHistories)
        XCTAssertEqual(plan.lostCommitCount, 2)
        XCTAssertEqual(plan.lostCommits.map(\.subject), ["My second", "My first"])
        XCTAssertEqual(Set(plan.changedFiles.map(\.path)), ["Mine.m", "Staged.m"])
        XCTAssertEqual(plan.overwrittenFiles, ["notes.txt"])
        XCTAssertFalse(plan.upToDate)

        let result = try project.reset(
            toRemote: "origin", branch: "main", expectedRemoteCommit: theirs, expectedHead: mine,
            backupAuthor: author, now: stamp,
        )
        XCTAssertEqual(result.commit, theirs)
        XCTAssertEqual(result.previousHead, mine)
        let backup = try XCTUnwrap(result.backupBranch)
        XCTAssertTrue(backup.hasPrefix("apelin-backup/"), backup)

        // The project is exactly the remote's.
        XCTAssertEqual(project.head(), GitHead(branch: "main", commit: theirs))
        XCTAssertEqual(read("README", in: project.workdir), "theirs\n")
        XCTAssertEqual(read("notes.txt", in: project.workdir), "theirs\n")
        XCTAssertEqual(read("Sources/Tweak.m", in: project.workdir), "// theirs\n")
        XCTAssertNil(read("Mine.m", in: project.workdir), "a file only the old history had is gone from the work tree")
        XCTAssertEqual(read("Scratch.txt", in: project.workdir), "keep me\n", "an untracked file the remote lacks stays")
        XCTAssertEqual(read("build/out.o", in: project.workdir), "object\n", "and an ignored one")
        let left = try project.status()
        XCTAssertTrue(left.contains(GitStatusItem(path: "Scratch.txt", index: "?", worktree: "?")), "\(left)")
        XCTAssertTrue(left.allSatisfy { $0.index == "?" }, "nothing tracked differs from the remote's: \(left)")
        XCTAssertEqual(project.localConfigValue("branch.main.remote"), "origin")

        // The backup holds every bit of it: on top of the old HEAD, the
        // unsaved change, the staged file and the notes the remote replaced.
        let (saved, branches) = try branches(of: project, in: base)
        let savedFiles = try XCTUnwrap(branches[backup])
        XCTAssertEqual(try saved.fileContents("Mine.m", inCommit: savedFiles).map { String(decoding: $0, as: UTF8.self) }, "// mine, unsaved\n")
        XCTAssertEqual(try saved.fileContents("Staged.m", inCommit: savedFiles).map { String(decoding: $0, as: UTF8.self) }, "staged\n")
        XCTAssertEqual(try saved.fileContents("notes.txt", inCommit: savedFiles).map { String(decoding: $0, as: UTF8.self) }, "my notes\n")
        XCTAssertEqual(try saved.fileContents("README", inCommit: savedFiles).map { String(decoding: $0, as: UTF8.self) }, "mine\n")
        XCTAssertNil(try saved.fileContents("Scratch.txt", inCommit: savedFiles), "nothing the reset left alone")
        XCTAssertNotEqual(savedFiles, mine, "a commit of its own, on top of the old HEAD")
    }

    func testADivergedBranchLosesOnlyItsOwnCommitsAndACleanOneNeedsNoBackupCommit() throws {
        let base = scratch()
        let (url, seed) = try remote(base)
        let project = try GitRepository.create(at: base.appendingPathComponent("project", isDirectory: true))
        try project.addRemote("origin", url: url)
        _ = try project.pull()
        try commit(["Mine.m": "// mine\n"], in: project, message: "Mine")
        let mine = try XCTUnwrap(project.head().commit)
        try commit(["README": "theirs, later\n"], in: seed, message: "Their third")
        _ = try seed.push()

        _ = try project.fetchBranch(remote: "origin", branch: "main")
        let plan = try project.resetPlan(remote: "origin", branch: "main")
        XCTAssertFalse(plan.unrelatedHistories)
        XCTAssertEqual(plan.lostCommits.map(\.subject), ["Mine"])
        XCTAssertEqual(plan.changedFiles, [])
        let result = try project.reset(
            toRemote: "origin", branch: "main", expectedRemoteCommit: plan.remoteCommit, expectedHead: mine,
            backupAuthor: author, now: stamp,
        )
        XCTAssertEqual(result.backupBranch, "apelin-backup/" + Self.formatted(stamp))
        let saved = try branches(of: project, in: base).1[XCTUnwrap(result.backupBranch)]
        XCTAssertEqual(saved, mine, "nothing uncommitted: the backup is the old HEAD itself")
        XCTAssertEqual(read("README", in: project.workdir), "theirs, later\n")

        // A second reset in the same second takes the next name, and one
        // already the remote's is up to date.
        XCTAssertTrue(try project.resetPlan(remote: "origin", branch: "main").upToDate)
        let again = try project.reset(
            toRemote: "origin", branch: "main", expectedRemoteCommit: plan.remoteCommit, expectedHead: plan.remoteCommit,
            backupAuthor: author, now: stamp,
        )
        XCTAssertEqual(again.backupBranch, "apelin-backup/" + Self.formatted(stamp) + "-2")
    }

    func testAMovedRemoteOrHEADChangesNothing() throws {
        let base = scratch()
        let (url, seed) = try remote(base)
        let project = try project(base)
        let mine = try XCTUnwrap(project.head().commit)
        try project.addRemote("origin", url: url)
        try write("// unsaved\n", "Mine.m", in: project.workdir)
        _ = try project.fetchBranch(remote: "origin", branch: "main")
        let shown = try project.resetPlan(remote: "origin", branch: "main")

        // The remote moves after the user was shown it.
        try commit(["README": "moved\n"], in: seed, message: "Moved")
        _ = try seed.push()
        _ = try project.fetchBranch(remote: "origin", branch: "main")
        XCTAssertThrowsError(try project.reset(
            toRemote: "origin", branch: "main", expectedRemoteCommit: shown.remoteCommit, expectedHead: mine, backupAuthor: author,
        )) { XCTAssertEqual(($0 as? GitError)?.kind, .conflict, "\($0)") }
        // HEAD moves.
        let moved = try project.resetPlan(remote: "origin", branch: "main")
        XCTAssertThrowsError(try project.reset(
            toRemote: "origin", branch: "main", expectedRemoteCommit: moved.remoteCommit, expectedHead: nil, backupAuthor: author,
        )) { XCTAssertEqual(($0 as? GitError)?.kind, .conflict) }
        XCTAssertEqual(project.head().commit, mine)
        XCTAssertEqual(read("Mine.m", in: project.workdir), "// unsaved\n", "nothing changed")
        XCTAssertEqual(try branches(of: project, in: base).1.keys.filter { $0.hasPrefix("apelin-backup/") }, [], "and nothing was saved")
    }

    func testAnotherBranchCheckedOutStaysAndAnUntouchedRepositoryNeedsNoBackup() throws {
        let base = scratch()
        let (url, seed) = try remote(base)
        let theirs = try XCTUnwrap(seed.head().commit)

        // A new project's repository: no commit, nothing to keep.
        let fresh = try GitRepository.create(at: base.appendingPathComponent("fresh", isDirectory: true))
        try fresh.addRemote("origin", url: url)
        _ = try fresh.fetchBranch(remote: "origin", branch: "main")
        let plan = try fresh.resetPlan(remote: "origin", branch: "main")
        XCTAssertNil(plan.head)
        XCTAssertEqual(plan.lostCommitCount, 0)
        let result = try fresh.reset(toRemote: "origin", branch: "main", expectedRemoteCommit: theirs, expectedHead: nil, backupAuthor: author)
        XCTAssertNil(result.backupBranch)
        XCTAssertEqual(fresh.head(), GitHead(branch: "main", commit: theirs))

        // Checked out on another branch: it stays, HEAD moves to main.
        let other = try GitRepository.create(at: base.appendingPathComponent("other", isDirectory: true), initialBranch: "work")
        try commit(["Work.m": "// work\n"], in: other, message: "Work")
        let work = try XCTUnwrap(other.head().commit)
        try other.addRemote("origin", url: url)
        _ = try other.fetchBranch(remote: "origin", branch: "main")
        let switching = try other.resetPlan(remote: "origin", branch: "main")
        XCTAssertEqual(switching.currentBranch, "work")
        XCTAssertEqual(switching.lostCommitCount, 0, "the branch work keeps its commits")
        _ = try other.reset(toRemote: "origin", branch: "main", expectedRemoteCommit: theirs, expectedHead: work, backupAuthor: author)
        XCTAssertEqual(other.head(), GitHead(branch: "main", commit: theirs))
        XCTAssertEqual(try branches(of: other, in: base).1["work"], work)
    }

    func testANameThatIsNoBranchOrRemoteIsRefused() throws {
        let base = scratch()
        let (url, _) = try remote(base)
        let project = try project(base)
        try project.addRemote("origin", url: url)
        XCTAssertThrowsError(try project.fetchBranch(remote: "origin", branch: "-x"))
        XCTAssertThrowsError(try project.fetchBranch(remote: "../x", branch: "main"))
        XCTAssertThrowsError(try project.resetPlan(remote: "origin", branch: "missing")) {
            XCTAssertEqual(($0 as? GitError)?.kind, .notFound)
        }
    }

    /// Every branch of `repository` by name, as a fetch into another
    /// repository sees them, and that repository, which holds their commits.
    private func branches(of repository: GitRepository, in base: URL) throws -> (GitRepository, [String: String]) {
        let check = try GitRepository.create(at: base.appendingPathComponent("check-\(UUID().uuidString)", isDirectory: true))
        try check.addRemote("project", url: repository.workdir.path)
        let fetched = try check.fetch(remote: "project")
        var branches: [String: String] = [:]
        for update in fetched.updated where update.ref.hasPrefix("refs/remotes/project/") {
            branches[String(update.ref.dropFirst("refs/remotes/project/".count))] = update.to
        }
        return (check, branches)
    }

    private static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
