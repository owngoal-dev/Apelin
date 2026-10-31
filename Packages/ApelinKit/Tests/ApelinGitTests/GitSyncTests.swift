import ApelinCore
@testable import ApelinGit
import Foundation
import XCTest

/// Fetch, pull, push and the clone into a folder, against a bare repository
/// on disk through libgit2's local transport: no network.
final class GitSyncTests: XCTestCase {
    private let author = GitSignature(name: "Apelin Test", email: "test@apelin.invalid")

    /// A bare remote and a seed repository that has pushed one commit to it.
    private struct Remote {
        let base: URL
        let bare: URL
        let seed: GitRepository

        var url: String {
            bare.path
        }
    }

    private func scratch() -> URL {
        let base = URL(fileURLWithPath: CanonicalPath.resolve(NSTemporaryDirectory())!, isDirectory: true)
        let url = base.appendingPathComponent("apelin-sync-\(UUID().uuidString)", isDirectory: true)
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
    private func commit(_ text: String, _ path: String, in repository: GitRepository, message: String) throws -> String {
        try write(text, path, in: repository.workdir)
        try repository.stage([path])
        return try repository.commit(message: message, author: author)
    }

    private func remote() throws -> Remote {
        let base = scratch()
        let bare = base.appendingPathComponent("remote.git", isDirectory: true)
        try GitRepository.createBare(at: bare)
        let seed = try GitRepository.create(at: base.appendingPathComponent("seed", isDirectory: true))
        try commit("one\n", "README", in: seed, message: "First")
        try write("int main(void) { return 0; }\n", "Sources/main.c", in: seed.workdir)
        try seed.stage(["Sources/main.c"])
        try seed.commit(message: "Sources", author: author)
        try seed.addRemote("origin", url: bare.path)
        _ = try seed.push()
        return Remote(base: base, bare: bare, seed: seed)
    }

    /// A clone of `remote` made the way a workspace takes one.
    private func workspace(_ remote: Remote, name: String = "work") throws -> GitRepository {
        let folder = remote.base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try GitClone.into(folder, url: remote.url)
        return try GitRepository(at: folder)
    }

    // MARK: Push

    func testPushRecordsTheUpstream() throws {
        let remote = try remote()
        XCTAssertEqual(remote.seed.localConfigValue("branch.main.remote"), "origin")
        XCTAssertEqual(remote.seed.localConfigValue("branch.main.merge"), "refs/heads/main")
        let previous = remote.seed.head().commit
        let tip = try commit("two\n", "README", in: remote.seed, message: "Second")
        let result = try remote.seed.push()
        XCTAssertEqual(result, GitPushResult(remote: "origin", branch: "main", commit: tip, from: previous))
        let other = try workspace(remote)
        XCTAssertEqual(other.head().commit, tip)
    }

    func testPushThatIsNotAFastForwardIsRefused() throws {
        let remote = try remote()
        let other = try workspace(remote)
        let theirs = try commit("theirs\n", "README", in: other, message: "Theirs")
        _ = try other.push()
        try commit("mine\n", "README", in: remote.seed, message: "Mine")
        XCTAssertThrowsError(try remote.seed.push()) { XCTAssertEqual(($0 as? GitError)?.kind, .rejected, "\($0)") }
        XCTAssertEqual(try workspace(remote, name: "check").head().commit, theirs, "the remote kept its branch")
        XCTAssertThrowsError(try remote.seed.push(branch: "no-such-branch")) { XCTAssertEqual(($0 as? GitError)?.kind, .notFound) }
        XCTAssertThrowsError(try remote.seed.push(branch: "-x")) { XCTAssertEqual(($0 as? GitError)?.kind, .invalid) }
        XCTAssertThrowsError(try remote.seed.push(remote: "elsewhere")) { XCTAssertEqual(($0 as? GitError)?.kind, .notFound) }
    }

    // MARK: Fetch and pull

    func testFetchMovesOnlyTheRemoteTrackingBranch() throws {
        let remote = try remote()
        let work = try workspace(remote)
        let old = try XCTUnwrap(work.head().commit)
        let tip = try commit("two\n", "README", in: remote.seed, message: "Second")
        _ = try remote.seed.push()

        let result = try work.fetch()
        XCTAssertEqual(result.remote, "origin")
        XCTAssertEqual(result.updated, [GitRefUpdate(ref: "refs/remotes/origin/main", from: old, to: tip)])
        XCTAssertEqual(work.head().commit, old, "a fetch moves no branch")
        XCTAssertEqual(read("README", in: work.workdir), "one\n")
        XCTAssertEqual(try work.fetch().updated, [], "nothing new the second time")
    }

    func testPullFastForwardsAndThenIsUpToDate() throws {
        let remote = try remote()
        let work = try workspace(remote)
        let old = try XCTUnwrap(work.head().commit)
        try write("scratch\n", "notes.txt", in: work.workdir)
        let tip = try commit("two\n", "README", in: remote.seed, message: "Second")
        _ = try remote.seed.push()

        let pulled = try work.pull()
        XCTAssertEqual(pulled, GitPullResult(branch: "main", from: old, to: tip, upToDate: false))
        XCTAssertEqual(work.head(), GitHead(branch: "main", commit: tip))
        XCTAssertEqual(read("README", in: work.workdir), "two\n")
        XCTAssertEqual(read("notes.txt", in: work.workdir), "scratch\n", "an untracked file out of the way stays")
        XCTAssertEqual(try work.status(), [GitStatusItem(path: "notes.txt", index: "?", worktree: "?")])

        XCTAssertEqual(try work.pull(), GitPullResult(branch: "main", from: tip, to: tip, upToDate: true))
    }

    func testPullOfADivergedBranchChangesNothing() throws {
        let remote = try remote()
        let work = try workspace(remote)
        let mine = try commit("mine\n", "Sources/main.c", in: work, message: "Mine")
        try commit("theirs\n", "README", in: remote.seed, message: "Theirs")
        _ = try remote.seed.push()

        XCTAssertThrowsError(try work.pull()) { XCTAssertEqual(($0 as? GitError)?.kind, .notFastForward, "\($0)") }
        XCTAssertEqual(work.head().commit, mine)
        XCTAssertEqual(read("README", in: work.workdir), "one\n")
        XCTAssertEqual(try work.status(), [])
    }

    func testPullThatWouldOverwriteAChangeChangesNothing() throws {
        let remote = try remote()
        let work = try workspace(remote)
        let old = work.head().commit
        try write("edited here\n", "README", in: work.workdir)
        try commit("theirs\n", "README", in: remote.seed, message: "Theirs")
        // A file the new commit adds is there already, untracked.
        try commit("new\n", "Added.txt", in: remote.seed, message: "Add")
        _ = try remote.seed.push()

        XCTAssertThrowsError(try work.pull()) { error in
            XCTAssertEqual((error as? GitError)?.kind, .conflict, "\(error)")
            XCTAssertTrue("\(error)".contains("README"), "\(error)")
        }
        XCTAssertEqual(work.head().commit, old)
        XCTAssertEqual(read("README", in: work.workdir), "edited here\n")
        XCTAssertNil(read("Added.txt", in: work.workdir))

        try FileManager.default.removeItem(at: work.workdir.appendingPathComponent("README"))
        try write("one\n", "README", in: work.workdir)
        try write("mine\n", "Added.txt", in: work.workdir)
        XCTAssertThrowsError(try work.pull()) { XCTAssertEqual(($0 as? GitError)?.kind, .conflict, "\($0)") }
        XCTAssertEqual(read("Added.txt", in: work.workdir), "mine\n")
        XCTAssertEqual(work.head().commit, old)
    }

    func testPullNamesOnlyARemoteThatIsThere() throws {
        let remote = try remote()
        let work = try workspace(remote)
        XCTAssertThrowsError(try work.pull(remote: "upstream")) { XCTAssertEqual(($0 as? GitError)?.kind, .notFound) }
        XCTAssertThrowsError(try work.pull(remote: "bad name")) { XCTAssertEqual(($0 as? GitError)?.kind, .invalid) }
    }

    // MARK: Clone into a folder

    func testCloneIntoAFolderKeepsWhatIsThere() throws {
        let remote = try remote()
        let folder = remote.base.appendingPathComponent("workspace", isDirectory: true)
        try write(#"{"kind": "workspace"}"#, "apelin-project.json", in: folder)
        try write("attachment\n", "Attachments/a", in: folder)

        let result = try GitClone.into(folder, url: remote.url, excluding: ["/apelin-project.json", "/Attachments/"])
        let repository = try GitRepository(at: folder)
        XCTAssertEqual(result, try GitCloneIntoResult(branch: "main", commit: XCTUnwrap(remote.seed.head().commit)))
        XCTAssertEqual(repository.head(), GitHead(branch: "main", commit: result.commit))
        XCTAssertEqual(try repository.status(), [], "the description is excluded")
        XCTAssertEqual(read("README", in: folder), "one\n")
        XCTAssertEqual(read("apelin-project.json", in: folder), #"{"kind": "workspace"}"#)
        XCTAssertEqual(repository.remoteURL(), remote.url)
        XCTAssertEqual(repository.localConfigValue("branch.main.remote"), "origin")
        XCTAssertEqual(repository.localConfigValue("branch.main.merge"), "refs/heads/main")
        let exclude = try XCTUnwrap(read(".git/info/exclude", in: folder))
        XCTAssertTrue(exclude.hasSuffix("/apelin-project.json\n/Attachments/\n"), exclude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git/shallow").path), "a full clone")
    }

    func testCloneIntoANamedBranch() throws {
        let remote = try remote()
        let folder = remote.base.appendingPathComponent("named", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try GitClone.into(folder, url: remote.url, branch: "missing")) {
            XCTAssertEqual(($0 as? GitError)?.kind, .notFound)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path))
        XCTAssertEqual(try GitClone.into(folder, url: remote.url, branch: "main").branch, "main")
    }

    func testCloneIntoAFolderWithAClashingFileLeavesItAsItWas() throws {
        let remote = try remote()
        let folder = remote.base.appendingPathComponent("clash", isDirectory: true)
        try write("mine\n", "Sources/main.c", in: folder)
        try write("keep\n", "keep.txt", in: folder)

        XCTAssertThrowsError(try GitClone.into(folder, url: remote.url)) { error in
            XCTAssertEqual((error as? GitError)?.kind, .conflict, "\(error)")
            XCTAssertTrue("\(error)".contains("Sources/main.c"), "\(error)")
        }
        let entries = try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(entries, ["Sources", "Sources/main.c", "keep.txt"])
        XCTAssertEqual(read("Sources/main.c", in: folder), "mine\n")
    }

    func testCloneIntoRefusesAFolderWithARepository() throws {
        let remote = try remote()
        let folder = remote.base.appendingPathComponent("taken", isDirectory: true)
        let repository = try GitRepository.create(at: folder)
        try write("mine\n", "mine.txt", in: folder)
        try repository.stage(["mine.txt"])
        try repository.commit(message: "Mine", author: author)
        XCTAssertThrowsError(try GitClone.into(folder, url: remote.url)) { XCTAssertEqual(($0 as? GitError)?.kind, .conflict) }
        XCTAssertThrowsError(try GitClone.into(remote.base.appendingPathComponent("absent"), url: remote.url)) {
            XCTAssertEqual(($0 as? GitError)?.kind, .notFound)
        }
    }

    /// The untouched repository a new project starts with is replaced, and
    /// put back on its branch when the import fails.
    func testCloneIntoTakesTheUntouchedRepositoryOfANewProject() throws {
        let remote = try remote()
        let folder = remote.base.appendingPathComponent("fresh", isDirectory: true)
        _ = try GitRepository.create(at: folder, initialBranch: "main")
        _ = try GitClone.into(folder, url: remote.url)
        XCTAssertEqual(try GitRepository(at: folder).remoteURL(), remote.url)

        let stopped = remote.base.appendingPathComponent("fresh-stopped", isDirectory: true)
        _ = try GitRepository.create(at: stopped, initialBranch: "trunk")
        XCTAssertThrowsError(try GitClone.into(stopped, url: remote.url, progress: { _ in false }))
        let back = try GitRepository(at: stopped)
        XCTAssertTrue(back.isUntouched)
        XCTAssertEqual(back.head().branch, "trunk")
    }

    func testStoppedCloneIntoRemovesItsRepository() throws {
        let remote = try remote()
        let folder = remote.base.appendingPathComponent("stopped", isDirectory: true)
        try write("keep\n", "keep.txt", in: folder)
        XCTAssertThrowsError(try GitClone.into(folder, url: remote.url, progress: { _ in false })) {
            XCTAssertEqual(($0 as? GitError)?.kind, .cancelled, "\($0)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["keep.txt"])
    }

    func testExcludesAreAddedOnce() throws {
        let remote = try remote()
        try remote.seed.addExcludes(["/a", "/b"])
        try remote.seed.addExcludes(["/b", "/c"])
        let text = try XCTUnwrap(read(".git/info/exclude", in: remote.seed.workdir))
        XCTAssertEqual(text.split(separator: "\n").filter { !$0.hasPrefix("#") }, ["/a", "/b", "/c"])
        XCTAssertThrowsError(try remote.seed.addExcludes(["two\nlines"]))
    }

    // MARK: Credentials

    func testCredentialHostIsTheURLsHostExactly() {
        XCTAssertEqual(GitCredentialHost.key(of: "https://GitHub.com/a/b.git"), "github.com")
        XCTAssertEqual(GitCredentialHost.key(of: "https://git.example.com:8443/a.git"), "git.example.com:8443")
        XCTAssertEqual(GitCredentialHost.key(of: "https://example.com:443/a.git"), "example.com:443")
        for url in ["http://github.com/a/b", "ssh://github.com/a/b", "git@github.com:a/b.git", "/tmp/x", "file:///tmp/x",
                    "https://user@github.com/a/b", "https://user:pw@github.com/a/b", "https:///a/b"]
        {
            XCTAssertNil(GitCredentialHost.key(of: url), url)
        }
    }

    func testBranchNames() {
        XCTAssertTrue(GitRepository.isValidBranchName("main"))
        XCTAssertTrue(GitRepository.isValidBranchName("feature/one"))
        for name in ["", "-x", "a..b", "a b", "a\0b", "HEAD", "x.lock", "a~1"] {
            XCTAssertFalse(GitRepository.isValidBranchName(name), name.debugDescription)
        }
    }
}
