import ApelinCore
@testable import ApelinEnvironment
import ApelinGit
@testable import ApelinProject
@testable import ApelinProtocol
import Foundation
import XCTest

final class GitServiceTests: XCTestCase {
    private func project(_ home: TemporaryHome, name: String = "Hello", projectID: String? = nil) throws -> URL {
        let root = home.layout.data.projects.appendingPathComponent(name, isDirectory: true)
        _ = try GitRepository.create(at: root)
        if let projectID {
            try Data(#"{"projectID": "\#(projectID)"}"#.utf8).write(to: root.appendingPathComponent("apelin-project.json"))
        }
        return root
    }

    func testOperationsOnAProjectByIDAndByName() throws {
        let home = try TemporaryHome(self)
        let id = "8a6f3c1e-0000-4000-8000-000000000002"
        let root = try project(home, projectID: id)
        try Data("int x;\n".utf8).write(to: root.appendingPathComponent("main.c"))
        let git = GitService(layout: home.layout)

        let status = try git.status(GitStatusRequest(projectID: id))
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(Set(status.entries.map(\.path)), ["apelin-project.json", "main.c"])
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: "Hello")), status)

        _ = try git.stage(GitStageRequest(projectID: id, paths: ["main.c", "apelin-project.json"]))
        XCTAssertTrue(try git.diff(GitDiffRequest(projectID: id, staged: true)).diff.contains("+int x;"))
        _ = try git.unstage(GitUnstageRequest(projectID: id, paths: ["apelin-project.json"]))
        let commit = try git.commit(GitCommitRequest(projectID: id, message: "Start", authorName: "A", authorEmail: "a@apelin.invalid"))
        XCTAssertEqual(commit.commitID.count, 40)
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: id)).head, commit.commitID)
    }

    func testAuthorFromSettings() throws {
        let home = try TemporaryHome(self)
        let root = try project(home)
        try Data("x\n".utf8).write(to: root.appendingPathComponent("x"))
        let git = GitService(layout: home.layout)
        _ = try git.stage(GitStageRequest(projectID: "Hello", paths: ["x"]))
        try home.layout.make(home.layout.settings)
        try Data(#"{"authorName": "Settings Person", "authorEmail": "settings@apelin.invalid"}"#.utf8).write(to: home.layout.gitSettings)
        let commit = try git.commit(GitCommitRequest(projectID: "Hello", message: "From settings"))
        XCTAssertEqual(commit.commitID.count, 40)
    }

    /// The apelin-github-actions skill tells the agent that a script the
    /// file tools wrote (0644) runs on a runner only once `chmod +x` and
    /// `git_commit` have recorded its executable bit (issue #79): in a new
    /// project's repository, `all` stages a mode change as git does.
    func testCommitAllRecordsTheExecutableBit() throws {
        let home = try TemporaryHome(self)
        let root = home.layout.data.projects.appendingPathComponent("Hello", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try EmptyRepository.make(in: root)
        let script = root.appendingPathComponent("Scripts/release.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho release\n".utf8).write(to: script)
        XCTAssertEqual(chmod(script.path, 0o644), 0)
        let git = GitService(layout: home.layout)
        let request = GitCommitRequest(projectID: "Hello", message: "Add the release script", authorName: "A", authorEmail: "a@apelin.invalid", all: true)
        _ = try git.commit(request)
        XCTAssertEqual(try committedMode("Scripts/release.sh", in: root), "100644")

        XCTAssertEqual(chmod(script.path, 0o755), 0)
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: "Hello")).entries.map(\.path), ["Scripts/release.sh"], "a mode change is a change")
        _ = try git.commit(GitCommitRequest(projectID: "Hello", message: "Make it executable", authorName: "A", authorEmail: "a@apelin.invalid", all: true))
        XCTAssertEqual(try committedMode("Scripts/release.sh", in: root), "100755")
    }

    /// The mode HEAD's tree records for `path`, as git itself reads it.
    private func committedMode(_ path: String, in root: URL) throws -> String {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "ls-tree", "HEAD", "--", path]
        let output = Pipe()
        git.standardOutput = output
        git.standardError = FileHandle.nullDevice
        try git.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
    }

    func testPathsAndProjectsStayInside() throws {
        let home = try TemporaryHome(self)
        let root = try project(home)
        let git = GitService(layout: home.layout)
        let outside = home.home.appendingPathComponent("outside")
        try Data("secret\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: home.home.path)

        for path in ["../outside", "/etc/passwd", "link/outside", ""] {
            XCTAssertThrowsError(try git.stage(GitStageRequest(projectID: "Hello", paths: [path])), path) { error in
                XCTAssertTrue([.badRequest, .denied].contains((error as? ApelinError)?.code), "\(path): \(error)")
            }
        }
        XCTAssertThrowsError(try git.diff(GitDiffRequest(projectID: "Hello", path: "../outside")))
        for projectID in ["..", "../Projects", "Nope", "Hello/..", "/"] {
            XCTAssertThrowsError(try git.status(GitStatusRequest(projectID: projectID)), projectID)
        }

        // A project folder that is a link out of Projects/ is not a project.
        try FileManager.default.createSymbolicLink(atPath: home.layout.data.projects.appendingPathComponent("Away").path, withDestinationPath: home.home.path)
        XCTAssertThrowsError(try git.status(GitStatusRequest(projectID: "Away"))) { XCTAssertEqual(($0 as? ApelinError)?.code, .notFound) }
    }

    func testCloneChecks() throws {
        let home = try TemporaryHome(self)
        _ = try project(home)
        let git = GitService(layout: home.layout)
        XCTAssertThrowsError(try git.checkClone(GitCloneRequest(url: "https://github.com/a/b.git", branch: "main", projectName: "Hello"))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict)
        }
        XCTAssertThrowsError(try git.checkClone(GitCloneRequest(url: "https://github.com/a/b.git", branch: "main", projectName: "../x")))
        XCTAssertThrowsError(try git.checkClone(GitCloneRequest(url: "ssh://github.com/a/b.git", branch: "main", projectName: "New")))
        XCTAssertNoThrow(try git.checkClone(GitCloneRequest(url: "https://github.com/a/b.git", branch: "main", projectName: "New")))
    }

    func testCloneIntoAProjectOverTheNetwork() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["APELIN_SKIP_NETWORK_TESTS"] != nil, "APELIN_SKIP_NETWORK_TESTS is set")
        let home = try TemporaryHome(self)
        let git = GitService(layout: home.layout)
        let request = GitCloneRequest(url: "https://github.com/libgit2/TestGitRepository.git", branch: "first-merge", projectName: "Cloned")
        let root = try git.checkClone(request)
        let log = EventLog()
        let result = try git.clone(request, into: root, reporter: log.reporter)
        XCTAssertEqual(result["commit"]?.stringValue, "0966a434eb1a025db6b71485ab63a3bfbea520b6")
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: "Cloned")).branch, "first-merge")
    }
}

// MARK: - Worker

final class EnvironmentWorkerTests: XCTestCase {
    func testAnImportRunsAsATaskEndingInState() async throws {
        let home = try TemporaryHome(self)
        try SDKFixture.make(at: home.inbox.appendingPathComponent("iPhoneOS99.0.sdk"))
        let log = EventLog()
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) { _, kind, payload in
            log.append(kind, payload)
        }

        let request = try ChannelRequest(request: WireRequest(SDKImportRequest(source: .inbox(path: "iPhoneOS99.0.sdk"))), descriptors: [], taskID: TaskID("task-1"))
        let (reply, _) = await worker.handle(request)
        XCTAssertNoThrow(try reply.result.get())

        for _ in 0 ..< 200 where log.last(TaskEvent.stateKind)?["state"]?.stringValue != TaskState.succeeded.rawValue {
            if log.last(TaskEvent.stateKind)?["state"]?.stringValue == TaskState.failed.rawValue {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(log.last(TaskEvent.stateKind)?["state"]?.stringValue, TaskState.succeeded.rawValue, "\(log.events)")
        XCTAssertEqual(log.last("result")?.value(at: "sdk.canonicalName")?.stringValue, "iphoneos99.0")
        XCTAssertEqual(log.kinds.last, TaskEvent.stateKind)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.layout.staging.appendingPathComponent("task-1").path), "staging removed")

        let list = try await worker.handle(ChannelRequest(request: WireRequest(SDKListRequest()), descriptors: [], taskID: nil))
        let response = try JSONCoding.decode(SDKListResponse.self, from: list.0.result.get())
        XCTAssertEqual(response.sdks.map(\.canonicalName), ["iphoneos99.0"])
    }

    /// The host restarted mid-import and sends the same task again: the new
    /// worker starts from clean staging, and an SDK the lost run had already
    /// registered is answered as that record.
    func testAResumedImportStartsOver() async throws {
        let home = try TemporaryHome(self)
        try SDKFixture.make(at: home.inbox.appendingPathComponent("iPhoneOS99.0.sdk"))
        let taskID = TaskID("resumed-import")
        let leftover = home.layout.staging.appendingPathComponent(taskID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: leftover.appendingPathComponent("partial"))

        var records: [String] = []
        for _ in 0 ..< 2 {
            let log = EventLog()
            let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) { _, kind, payload in
                log.append(kind, payload)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.appendingPathComponent("partial").path), "a new worker clears staging")
            let request = try ChannelRequest(request: WireRequest(SDKImportRequest(source: .inbox(path: "iPhoneOS99.0.sdk"))), descriptors: [], taskID: taskID, resumed: true)
            let (reply, _) = await worker.handle(request)
            XCTAssertNoThrow(try reply.result.get())
            for _ in 0 ..< 200 where !(log.last(TaskEvent.stateKind)?["state"]?.stringValue.map { TaskState(rawValue: $0)?.isTerminal == true } ?? false) {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(log.last(TaskEvent.stateKind)?["state"]?.stringValue, TaskState.succeeded.rawValue, "\(log.events)")
            records.append(log.last("result")?.value(at: "sdk.id")?.stringValue ?? "")
        }
        XCTAssertEqual(records[0], records[1], "running it again answers the SDK already registered")
        XCTAssertEqual(SDKStore(layout: home.layout).list().count, 1)
    }

    /// A clone cut off by a stop: the folder it marked as its own goes when
    /// the next worker starts, so the resumed clone can make it again; a
    /// marked folder that is not a repository, and a bad marker, touch
    /// nothing.
    func testACutOffCloneIsSweptAtWorkerStart() throws {
        let home = try TemporaryHome(self)
        let projects = home.layout.data.projects
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("Half/.git/objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("Mine"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: projects.appendingPathComponent("Mine/notes.txt"))
        try FileManager.default.createDirectory(at: home.layout.cloneMarkers, withIntermediateDirectories: true)
        try Data("Half".utf8).write(to: home.layout.cloneMarkers.appendingPathComponent("task-a"))
        try Data("Mine".utf8).write(to: home.layout.cloneMarkers.appendingPathComponent("task-b"))
        try Data("../Mine".utf8).write(to: home.layout.cloneMarkers.appendingPathComponent("task-c"))

        _ = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) { _, _, _ in }

        XCTAssertFalse(FileManager.default.fileExists(atPath: projects.appendingPathComponent("Half").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projects.appendingPathComponent("Mine/notes.txt").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.layout.cloneMarkers.path), [])
        let git = GitService(layout: home.layout)
        XCTAssertNoThrow(try git.checkClone(GitCloneRequest(url: "https://github.com/a/b.git", branch: "main", projectName: "Half")))
    }

    /// The clone finished and cleared its marker, but the host restarted
    /// before the task's final `state` reached it, so it sends the clone
    /// again. The folder is complete — unmarked, it was not cut off — and a
    /// repository of the same URL and branch: the resumed task answers it
    /// rather than failing on a folder that exists. Talks to github.com.
    func testAResumedCloneThatHadFinishedSucceeds() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["APELIN_SKIP_NETWORK_TESTS"] != nil, "APELIN_SKIP_NETWORK_TESTS is set")
        let home = try TemporaryHome(self)
        let request = GitCloneRequest(
            url: "https://github.com/libgit2/TestGitRepository.git",
            branch: "first-merge",
            projectName: "Cloned",
        )
        let taskID = TaskID("clone-task")
        let git = GitService(layout: home.layout)
        _ = try git.clone(request, into: git.checkClone(request), taskID: taskID, reporter: .silent)

        let log = EventLog()
        let worker = EnvironmentWorker(
            layout: home.layout,
            backend: UnavailableToolchainBackend(),
            installer: FakeInstaller(),
        ) { _, kind, payload in
            log.append(kind, payload)
        }
        let resumed = try ChannelRequest(request: WireRequest(request), descriptors: [], taskID: taskID, resumed: true)
        let (reply, _) = await worker.handle(resumed)
        XCTAssertNoThrow(try reply.result.get())
        for _ in 0 ..< 200 where !(log.last(TaskEvent.stateKind)?["state"]?.stringValue.map { TaskState(rawValue: $0)?.isTerminal == true } ?? false) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(log.last(TaskEvent.stateKind)?["state"]?.stringValue, TaskState.succeeded.rawValue, "\(log.events)")
        XCTAssertEqual(log.last("result")?["commit"]?.stringValue, "0966a434eb1a025db6b71485ab63a3bfbea520b6")
        XCTAssertEqual(try git.status(GitStatusRequest(projectID: "Cloned")).branch, "first-merge")

        // Not resumed, or another URL: the folder is in the way, as before.
        let fresh = try ChannelRequest(request: WireRequest(request), descriptors: [], taskID: TaskID("new"))
        let refused = await worker.handle(fresh).0
        XCTAssertThrowsError(try refused.result.get())
        let other = GitCloneRequest(url: "https://github.com/a/b.git", branch: "first-merge", projectName: "Cloned")
        let elsewhere = try ChannelRequest(request: WireRequest(other), descriptors: [], taskID: taskID, resumed: true)
        let refusedElsewhere = await worker.handle(elsewhere).0
        XCTAssertThrowsError(try refusedElsewhere.result.get())
    }

    /// Two clones of the same name and URL: one was cut off before it marked
    /// its folder, the other finished. Resumed, the first does not take the
    /// second's folder for its own; the second, resumed, still does.
    func testAResumedCloneDoesNotAnswerWithAnotherTasksFolder() async throws {
        let home = try TemporaryHome(self)
        let request = GitCloneRequest(url: "https://github.com/a/b.git", branch: "main", projectName: "Cloned")
        let root = home.layout.data.projects.appendingPathComponent("Cloned", isDirectory: true)
        let repository = try GitRepository.create(at: root)
        try Data("int x;\n".utf8).write(to: root.appendingPathComponent("main.c"))
        try repository.stage(["main.c"])
        _ = try repository.commit(message: "Start", author: GitSignature(name: "A", email: "a@apelin.invalid"))
        // What the other task's finished clone leaves: its origin, and its
        // own task ID in the repository's configuration.
        let config = try FileHandle(forWritingTo: root.appendingPathComponent(".git/config"))
        config.seekToEndOfFile()
        config.write(Data("[remote \"origin\"]\n\turl = \(request.url)\n[apelin]\n\tcloneTask = other-task\n".utf8))
        try config.close()

        let worker = EnvironmentWorker(
            layout: home.layout,
            backend: UnavailableToolchainBackend(),
            installer: FakeInstaller(),
        ) { _, _, _ in }
        let mine = try ChannelRequest(
            request: WireRequest(request),
            descriptors: [],
            taskID: TaskID("my-task"),
            resumed: true,
        )
        let refused = await worker.handle(mine).0
        XCTAssertThrowsError(try refused.result.get(), "another task's folder is in the way")
        let theirs = try ChannelRequest(
            request: WireRequest(request),
            descriptors: [],
            taskID: TaskID("other-task"),
            resumed: true,
        )
        let answered = await worker.handle(theirs).0
        XCTAssertNoThrow(try answered.result.get())
    }

    func testABadRequestIsTheReplyNotAFailedTask() async throws {
        let home = try TemporaryHome(self)
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) { _, _, _ in }
        for operation in try [WireRequest(SDKImportRequest(source: .url("http://example.com/x.zip"))), WireRequest(ToolchainSetupRequest())] {
            let (reply, _) = await worker.handle(ChannelRequest(request: operation, descriptors: [], taskID: TaskID.make()))
            XCTAssertThrowsError(try reply.result.get(), "\(operation.operation)")
        }
        XCTAssertEqual(worker.activeTasks, [])
    }

    func testCancelStopsATask() async throws {
        let home = try TemporaryHome(self)
        // A large-ish SDK so the inspection is still running when cancelled.
        let root = try SDKFixture.make(at: home.inbox.appendingPathComponent("iPhoneOS99.0.sdk"))
        for index in 0 ..< 400 {
            try Data(count: 64 * 1024).write(to: root.appendingPathComponent("usr/lib/blob\(index).dat"))
        }
        let log = EventLog()
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) { _, kind, payload in
            log.append(kind, payload)
        }
        let taskID = TaskID("cancel-me")
        _ = try await worker.handle(ChannelRequest(request: WireRequest(SDKImportRequest(source: .inbox(path: "iPhoneOS99.0.sdk"))), descriptors: [], taskID: taskID))
        worker.cancel(taskID)
        for _ in 0 ..< 200 where !(log.last(TaskEvent.stateKind)?["state"]?.stringValue.map { TaskState(rawValue: $0)?.isTerminal == true } ?? false) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(log.last(TaskEvent.stateKind)?["state"]?.stringValue, TaskState.cancelled.rawValue, "\(log.kinds)")
        XCTAssertEqual(SDKStore(layout: home.layout).list(), [])
    }
}

// MARK: - Console scripts

/// The environment's console scripts, and the restart ones, decode as the
/// requests they name.
final class ConsoleScriptTests: XCTestCase {
    func testScriptsDecode() throws {
        let scripts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Documents/Console/scripts")
        let all = try FileManager.default.contentsOfDirectory(atPath: scripts.path)
        let prefixes = ["i2-", "r1-", "t1-", "t2-"]
        let names = all.filter { name in prefixes.contains { name.hasPrefix($0) } && name.hasSuffix(".json") }
        XCTAssertEqual(Set(names), [
            "i2-sdk-import.json", "i2-git.json", "i2-git-commit.json", "i2-git-remote.json",
            "r1-resume-build.json", "r1-resume-sdk-import.json",
            "t1-toolchain-setup.json", "t2-toolchain-remove.json",
        ])
        for name in names {
            let script = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: scripts.appendingPathComponent(name)))
            guard case let .array(steps)? = script["steps"] else { return XCTFail("\(name) has no steps") }
            for step in steps {
                let op = try XCTUnwrap(step["op"]?.stringValue)
                if op == "expect" || op == "wait" {
                    continue
                }
                let operation = try XCTUnwrap(AppOperation(rawValue: op), "\(name): \(op)")
                XCTAssertNoThrow(try decode(operation.requestType, step["request"] ?? .object([:])), "\(name): \(op)")
            }
        }
    }

    private func decode<R: OperationRequest>(_: R.Type, _ value: JSONValue) throws {
        _ = try value.decode(R.self)
    }
}
