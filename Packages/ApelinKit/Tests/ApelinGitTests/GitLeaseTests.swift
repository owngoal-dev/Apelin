import ApelinCore
@testable import ApelinGit
import Darwin
import Foundation
import XCTest

/// A forced push with a lease (issue #29): the remote's branch is
/// overwritten only while the remote says it is at the commit the lease
/// names, and the fetch before it says what would leave the branch.
/// Against bare repositories on disk, through libgit2's local transport,
/// and once through `git daemon` on the loopback, whose receive-pack holds
/// an update to the old value the push sends.
final class GitLeaseTests: XCTestCase {
    private let author = GitSignature(name: "Apelin Test", email: "test@apelin.invalid")

    private struct Remote {
        let base: URL
        let bare: URL
        let seed: GitRepository
    }

    /// The seed's `main` and the remote's after another clone pushed to it:
    /// the remote has `theirs`, the seed `mine`, both on `first`.
    private struct Diverged {
        let remote: Remote
        let first: String
        let theirs: String
        let mine: String
    }

    private func scratch() -> URL {
        let base = URL(fileURLWithPath: CanonicalPath.resolve(NSTemporaryDirectory())!, isDirectory: true)
        let url = base.appendingPathComponent("apelin-lease-\(UUID().uuidString)", isDirectory: true)
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

    private func remote() throws -> Remote {
        let base = scratch()
        let bare = base.appendingPathComponent("remote.git", isDirectory: true)
        try GitRepository.createBare(at: bare)
        let seed = try GitRepository.create(at: base.appendingPathComponent("seed", isDirectory: true))
        try commit("one\n", "README", in: seed, message: "First")
        try seed.addRemote("origin", url: bare.path)
        _ = try seed.push()
        return Remote(base: base, bare: bare, seed: seed)
    }

    private func clone(_ remote: Remote, branch: String? = nil) throws -> GitRepository {
        let folder = remote.base.appendingPathComponent("clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try GitClone.into(folder, url: remote.bare.path, branch: branch)
        return try GitRepository(at: folder)
    }

    /// What the remote's `main` is at, read through a fresh clone.
    private func remoteMain(_ remote: Remote) throws -> String? {
        try clone(remote).head().commit
    }

    private func diverged() throws -> Diverged {
        let remote = try remote()
        let first = try XCTUnwrap(remote.seed.head().commit)
        let other = try clone(remote)
        let theirs = try commit("theirs\n", "README", in: other, message: "Theirs")
        _ = try other.push()
        let mine = try commit("mine\n", "Mine.txt", in: remote.seed, message: "Mine")
        return Diverged(remote: remote, first: first, theirs: theirs, mine: mine)
    }

    // MARK: What a forced push would lose

    func testAFetchSetsTheBranchBesideWhatTheRemoteHas() throws {
        let remote = try remote()
        let first = try XCTUnwrap(remote.seed.head().commit)
        XCTAssertEqual(
            try remote.seed.fetch(comparing: "main").comparison,
            GitRemoteComparison(branch: "main", local: first, localSubject: "First", remote: first),
            "the same commit: nothing to lose",
        )

        let ahead = try commit("two\n", "README", in: remote.seed, message: "Second")
        XCTAssertEqual(
            try remote.seed.fetch(comparing: "main").comparison,
            GitRemoteComparison(branch: "main", local: ahead, localSubject: "Second", remote: first),
            "the remote's branch is part of this one: an ordinary push",
        )

        let other = try clone(remote)
        let theirs = try commit("theirs\n", "README", in: other, message: "Theirs")
        let later = try commit("later\n", "Later.txt", in: other, message: "Later\n\nWith a body that is not the subject.")
        _ = try other.push()
        let fetched = try remote.seed.fetch(comparing: "main", listing: 1)
        XCTAssertEqual(fetched.comparison, GitRemoteComparison(
            branch: "main",
            local: ahead,
            localSubject: "Second",
            remote: later,
            remoteOnly: [GitLogEntry(commit: later, subject: "Later")],
            remoteOnlyCount: 2,
        ), "newest first, listed as far as asked, all of them counted")
        XCTAssertTrue(fetched.updated.contains(GitRefUpdate(ref: "refs/remotes/origin/main", from: first, to: later)))
        XCTAssertEqual(
            try remote.seed.fetch(comparing: "main").comparison?.remoteOnly.map(\.commit),
            [later, theirs],
        )

        XCTAssertThrowsError(try remote.seed.fetch(comparing: "feature")) {
            XCTAssertEqual(($0 as? GitError)?.kind, .notFound, "no such local branch")
        }
        XCTAssertThrowsError(try remote.seed.fetch(comparing: "-x")) { XCTAssertEqual(($0 as? GitError)?.kind, .invalid) }
    }

    func testAFetchComparingABranchTheRemoteLacks() throws {
        let remote = try remote()
        let first = try XCTUnwrap(remote.seed.head().commit)
        try remote.seed.createBranch("feature", at: first)
        XCTAssertEqual(
            try remote.seed.fetch(comparing: "feature").comparison,
            GitRemoteComparison(branch: "feature", local: first, localSubject: "First", remote: nil),
        )
    }

    // MARK: The lease

    func testALeaseThatHoldsOverwritesTheBranch() throws {
        let diverged = try diverged()
        let seed = diverged.remote.seed
        var seen: [String?] = []
        let result = try seed.push(
            lease: GitLease(expectedCommit: diverged.theirs, localCommit: diverged.mine),
            remoteCommit: { seen.append($0) },
        )
        XCTAssertEqual(result, GitPushResult(
            remote: "origin",
            branch: "main",
            commit: diverged.mine,
            from: diverged.theirs,
            forced: true,
        ))
        XCTAssertEqual(seen, [diverged.theirs], "told what the remote had before anything was sent")
        XCTAssertEqual(try remoteMain(diverged.remote), diverged.mine, "the remote's main is this one now")
        XCTAssertEqual(seed.localConfigValue("branch.main.merge"), "refs/heads/main")
    }

    func testWithoutALeaseAPushIsNeverForced() throws {
        let diverged = try diverged()
        XCTAssertThrowsError(try diverged.remote.seed.push()) {
            XCTAssertEqual(($0 as? GitError)?.kind, .rejected, "\($0)")
        }
        XCTAssertEqual(try remoteMain(diverged.remote), diverged.theirs)
    }

    func testALeaseOnABranchThatMovedPushesNothing() throws {
        let diverged = try diverged()
        // Someone pushes after the lease was taken.
        let other = try clone(diverged.remote)
        let later = try commit("later\n", "Later.txt", in: other, message: "Later")
        _ = try other.push()

        var seen: [String?] = []
        XCTAssertThrowsError(try diverged.remote.seed.push(
            lease: GitLease(expectedCommit: diverged.theirs),
            remoteCommit: { seen.append($0) },
        )) { error in
            XCTAssertEqual((error as? GitError)?.kind, .remoteChanged, "\(error)")
            XCTAssertTrue("\(error)".contains("is at \(later) now, not \(diverged.theirs)"), "\(error)")
            XCTAssertTrue("\(error)".contains("nothing was pushed"), "\(error)")
        }
        XCTAssertEqual(seen, [later])
        XCTAssertEqual(try remoteMain(diverged.remote), later, "the remote kept its branch")
    }

    func testALeaseOnABranchTheRemoteLacksPushesNothing() throws {
        let diverged = try diverged()
        try diverged.remote.seed.createBranch("feature", at: diverged.mine)
        XCTAssertThrowsError(try diverged.remote.seed.push(
            branch: "feature",
            lease: GitLease(expectedCommit: diverged.theirs),
        )) { error in
            XCTAssertEqual((error as? GitError)?.kind, .remoteChanged, "\(error)")
            XCTAssertTrue("\(error)".contains("is gone"), "\(error)")
        }
        XCTAssertThrowsError(try clone(diverged.remote, branch: "feature")) {
            XCTAssertEqual(($0 as? GitError)?.kind, .notFound, "an ordinary push makes it, a forced one never does")
        }
    }

    func testALeaseOnALocalBranchThatMovedPushesNothing() throws {
        let diverged = try diverged()
        let newer = try commit("newer\n", "Newer.txt", in: diverged.remote.seed, message: "Newer")
        XCTAssertThrowsError(try diverged.remote.seed.push(
            lease: GitLease(expectedCommit: diverged.theirs, localCommit: diverged.mine),
        )) { error in
            XCTAssertEqual((error as? GitError)?.kind, .localChanged, "\(error)")
            XCTAssertTrue("\(error)".contains("is at \(newer) now, not \(diverged.mine)"), "\(error)")
        }
        XCTAssertEqual(try remoteMain(diverged.remote), diverged.theirs)
    }

    func testALeaseNamesFullCommitIDs() throws {
        let diverged = try diverged()
        let upper = diverged.theirs.uppercased()
        for lease in [
            GitLease(expectedCommit: String(diverged.theirs.prefix(12))),
            GitLease(expectedCommit: upper),
            GitLease(expectedCommit: diverged.theirs, localCommit: "HEAD"),
        ] {
            XCTAssertThrowsError(try diverged.remote.seed.push(lease: lease)) {
                XCTAssertEqual(($0 as? GitError)?.kind, .invalid, "\(lease)")
            }
        }
        XCTAssertEqual(try remoteMain(diverged.remote), diverged.theirs)
    }

    /// The check and the update go over one connection, and the update's
    /// old value is the commit the remote said: a branch moved on the
    /// remote between the two is refused by the remote itself. The local
    /// transport writes the branch without that check, so this one goes
    /// through `git daemon`, whose receive-pack is git's own.
    func testTheRemoteRefusesAChangeMadeAfterTheCheck() throws {
        let diverged = try diverged()
        let other = try clone(diverged.remote)
        let sneaked = try commit("sneaked\n", "Sneaked.txt", in: other, message: "Sneaked in")
        try other.createBranch("side", at: sneaked)
        _ = try other.push(branch: "side")

        let daemon = try GitDaemon(serving: diverged.remote.base)
        addTeardownBlock { daemon.stop() }
        try diverged.remote.seed.addRemote("daemon", url: daemon.url(for: "remote.git"))
        var moved = false
        XCTAssertThrowsError(try diverged.remote.seed.push(
            remote: "daemon",
            lease: GitLease(expectedCommit: diverged.theirs),
            remoteCommit: { found in
                // The check passed; the branch moves before the update lands.
                XCTAssertEqual(found, diverged.theirs)
                moved = Self.git(["--git-dir", diverged.remote.bare.path, "update-ref", "refs/heads/main", sneaked])
            },
        )) { error in
            XCTAssertEqual((error as? GitError)?.kind, .rejected, "\(error)")
        }
        XCTAssertTrue(moved, "the branch was moved between the check and the update")
        XCTAssertEqual(try remoteMain(diverged.remote), sneaked, "the remote kept what was put there after the check")
    }

    /// Runs `/usr/bin/git` with `arguments`; true when it exits 0.
    static func git(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// `git daemon` serving a folder on a loopback port, pushes allowed; the
/// test is skipped where it cannot start.
private final class GitDaemon {
    private let process: Process
    private let port: UInt16

    init(serving base: URL) throws {
        for _ in 0 ..< 5 {
            let port = UInt16.random(in: 20000 ... 60000)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = [
                "daemon", "--reuseaddr", "--listen=127.0.0.1", "--port=\(port)", "--export-all",
                "--enable=receive-pack", "--informative-errors", "--base-path=\(base.path)", base.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { break }
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline {
                if Self.accepts(port) {
                    self.process = process
                    self.port = port
                    return
                }
                usleep(50000)
            }
            process.terminate()
            process.waitUntilExit()
        }
        throw XCTSkip("git daemon could not be started here")
    }

    func url(for path: String) -> String {
        "git://127.0.0.1:\(port)/\(path)"
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }

    private static func accepts(_ port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
