import ApelinCore
@testable import ApelinEnvironment
@testable import ApelinGit
@testable import ApelinProtocol
import Foundation
import XCTest

/// A squash through the git service: a preview that changes nothing, the
/// squash with the author the settings name, and the refusals and reasons
/// a caller acts on.
final class GitSquashServiceTests: XCTestCase {
    private let id = "8a6f3c1e-0000-4000-8000-000000000301"

    /// A project whose repository has First, then Two, Three and Four.
    private func project() throws -> (GitService, GitRepository, [String]) {
        let home = try TemporaryHome(self)
        let root = home.layout.data.projects.appendingPathComponent("Clock", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let description = #"{"schemaVersion": 1, "projectID": "\#(id)", "kind": "workspace", "buildSystem": "external"}"#
        try Data(description.utf8).write(to: root.appendingPathComponent("apelin-project.json"))
        let repository = try GitRepository.create(at: root)
        try repository.addExcludes(["/apelin-project.json"])
        let author = GitSignature(name: "Apelin Test", email: "test@apelin.invalid")
        var commits: [String] = []
        for name in ["First", "Two", "Three", "Four"] {
            try Data(name.utf8).write(to: root.appendingPathComponent("\(name).txt"))
            try repository.stage(["\(name).txt"])
            try commits.append(repository.commit(message: name, author: author))
        }
        let git = GitService(layout: home.layout)
        _ = try git.setAuthor(GitAuthorSetRequest(authorName: "Settings Author", authorEmail: "settings@apelin.invalid"))
        return (git, repository, commits)
    }

    func testAPreviewChangesNothingAndTheSquashTakesWhatItRead() throws {
        let (git, repository, commits) = try project()
        let preview = try git.squash(GitSquashRequest(projectID: id, count: 3, preview: true))
        XCTAssertEqual(preview, GitSquashResponse(
            branch: "main",
            previousHead: commits[3],
            base: commits[0],
            commits: [
                GitCommitSummary(commit: commits[3], subject: "Four"),
                GitCommitSummary(commit: commits[2], subject: "Three"),
                GitCommitSummary(commit: commits[1], subject: "Two"),
            ],
            count: 3,
        ))
        XCTAssertEqual(repository.head().commit, commits[3], "a preview changes nothing")

        let done = try git.squash(GitSquashRequest(
            projectID: id, base: preview.base, message: "Add the files", expectedHead: preview.previousHead,
        ))
        let commit = try XCTUnwrap(done.commit)
        XCTAssertEqual(repository.head().commit, commit)
        XCTAssertEqual(done.previousHead, commits[3])
        XCTAssertEqual(done.count, 3)
        XCTAssertEqual(try repository.status(), [])
        XCTAssertThrowsError(try git.squash(GitSquashRequest(projectID: id, base: commits[0], preview: true))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict, "one commit is left after First: \($0)")
        }
    }

    func testTheRefusalsCarryTheirCodes() throws {
        let (git, repository, commits) = try project()
        func refused(_ request: GitSquashRequest, _ code: ApelinError.Code, _ reason: ApelinError.Reason? = nil) {
            XCTAssertThrowsError(try git.squash(request)) { error in
                XCTAssertEqual((error as? ApelinError)?.code, code, "\(error)")
                if let reason {
                    XCTAssertEqual((error as? ApelinError)?.reason, reason)
                }
            }
            XCTAssertEqual(repository.head().commit, commits[3])
        }
        refused(GitSquashRequest(projectID: id, preview: true), .badRequest)
        refused(GitSquashRequest(projectID: id, base: commits[0], count: 2, preview: true), .badRequest)
        refused(GitSquashRequest(projectID: id, count: 1, preview: true), .conflict)
        refused(GitSquashRequest(projectID: id, base: commits[0], message: "x"), .badRequest)
        refused(GitSquashRequest(projectID: id, base: commits[0], expectedHead: commits[3]), .badRequest)
        refused(GitSquashRequest(projectID: id, base: commits[0], message: "x", expectedHead: commits[2]), .conflict, .headChanged)
        try Data("changed".utf8).write(to: repository.workdir.appendingPathComponent("Two.txt"))
        refused(GitSquashRequest(projectID: id, count: 2, preview: true), .conflict)
    }
}
