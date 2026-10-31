import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("ChannelHostBackend's git tools act on the session's project")
struct GitBackendTests {
    @Test
    func `status, diff, stage, unstage and commit are one request each on the session's project`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitStatus, reply: GitStatusResponse(branch: "main", head: "abc", entries: [
            GitStatusEntry(path: "Sources/Tweak.m", index: " ", worktree: "M"),
        ]))
        fixture.host.on(.gitDiff, reply: GitDiffResponse(diff: "--- a\n+++ b\n"))
        fixture.host.on(.gitStage, reply: Acknowledged())
        fixture.host.on(.gitUnstage, reply: Acknowledged())
        fixture.host.on(.gitCommit, reply: GitCommitResponse(commitID: "def"))

        let status = try await fixture.backend.gitStatus(GitStatusToolRequest(context: fixture.context()))
        let diff = try await fixture.backend.gitDiff(GitDiffToolRequest(context: fixture.context(), path: "Sources/Tweak.m", staged: true))
        let staged = try await fixture.backend.gitStage(GitPathsToolRequest(context: fixture.context(), paths: ["Sources/Tweak.m"]))
        _ = try await fixture.backend.gitUnstage(GitPathsToolRequest(context: fixture.context(), paths: ["README.md"]))
        let commit = try await fixture.backend.gitCommit(GitCommitToolRequest(context: fixture.context(), message: "Hook the clock"))

        #expect(fixture.host.requests.map(\.operation) == [.gitStatus, .gitDiff, .gitStage, .gitUnstage, .gitCommit])
        #expect(fixture.host.requests(GitStatusRequest.self).first?.projectID == fixture.project.id)
        let diffRequest = try #require(fixture.host.requests(GitDiffRequest.self).first)
        #expect(diffRequest.projectID == fixture.project.id)
        #expect(diffRequest.path == "Sources/Tweak.m")
        #expect(diffRequest.staged)
        #expect(fixture.host.requests(GitStageRequest.self).first?.paths == ["Sources/Tweak.m"])
        #expect(fixture.host.requests(GitUnstageRequest.self).first?.paths == ["README.md"])
        let commitRequest = try #require(fixture.host.requests(GitCommitRequest.self).first)
        #expect(commitRequest.projectID == fixture.project.id)
        #expect(commitRequest.message == "Hook the clock")
        #expect(commitRequest.authorName == nil && commitRequest.authorEmail == nil, "the host's settings name the author")

        #expect(status.branch == "main")
        #expect(status.entries == [GitStatusToolEntry(path: "Sources/Tweak.m", index: " ", worktree: "M")])
        #expect(diff.diff == "--- a\n+++ b\n")
        #expect(!diff.truncated)
        #expect(staged.paths == ["Sources/Tweak.m"])
        #expect(commit.commitID == "def")
    }

    @Test
    func `a long diff is cut at a line end and says so`() async throws {
        let fixture = try Fixture()
        let line = String(repeating: "x", count: 99) + "\n"
        fixture.host.on(.gitDiff, reply: GitDiffResponse(diff: String(repeating: line, count: 2000)))
        let diff = try await fixture.backend.gitDiff(GitDiffToolRequest(context: fixture.context()))
        #expect(diff.truncated)
        #expect(diff.diff.utf8.count < ChannelHostBackend.maximumDiffBytes + 200)
        #expect(diff.diff.contains("pass a path"))
        let body = diff.diff.components(separatedBy: "\n…")[0]
        #expect(body.split(separator: "\n").allSatisfy { $0.count == 99 }, "no line is cut in half")
    }

    @Test
    func `push is gitPush on the session's project, read to the end`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitPush, reply: TaskHandle(taskID: TaskID("push-task"), kind: .environment))
        fixture.host.on(.environmentAttach, reply: batch("push-task", [
            ("progress", .object(["stage": .string("pushing"), "completed": .number(1), "total": .number(1)])),
            ("result", .object(["remote": .string("origin"), "branch": .string("main"), "commit": .string("abc")])),
            stateEvent(.succeeded),
        ]))
        let response = try await fixture.backend.gitPush(GitRemoteToolRequest(context: fixture.context(), remote: nil, branch: "main"))
        let sent = try #require(fixture.host.requests(GitPushRequest.self).first)
        #expect(sent.projectID == fixture.project.id)
        #expect(sent.remote == nil)
        #expect(sent.branch == "main")
        #expect(fixture.host.requests.map(\.operation) == [.gitPush, .environmentAttach])
        #expect(response == GitTaskToolResponse(remote: "origin", branch: "main", commit: "abc"))
    }

    @Test
    func `fetch, pull and clone send their own operations and report their results`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitFetch, reply: TaskHandle(taskID: TaskID("fetch-task"), kind: .environment))
        fixture.host.on(.gitPull, reply: TaskHandle(taskID: TaskID("pull-task"), kind: .environment))
        fixture.host.on(.gitCloneInto, reply: TaskHandle(taskID: TaskID("clone-task"), kind: .environment))
        fixture.host.on(.environmentAttach) { request in
            let attach = try request.decode(EnvironmentAttachRequest.self)
            switch attach.taskID.rawValue {
            case "fetch-task":
                return (batch("fetch-task", [
                    ("result", .object(["remote": .string("upstream"), "updated": .array([
                        .object(["ref": .string("refs/remotes/upstream/main"), "from": .string("a"), "to": .string("b")]),
                    ])])),
                    stateEvent(.succeeded),
                ]), [])
            case "pull-task":
                // The result rides on the final state only.
                return (batch("pull-task", [
                    (TaskEvent.stateKind, .object([
                        "state": .string("succeeded"),
                        "result": .object(["branch": .string("main"), "from": .string("a"), "to": .string("b"), "upToDate": .bool(false)]),
                    ])),
                ]), [])
            default:
                return (batch("clone-task", [
                    ("result", .object(["branch": .string("trunk"), "commit": .string("c")])),
                    stateEvent(.succeeded),
                ]), [])
            }
        }

        let fetch = try await fixture.backend.gitFetch(GitRemoteToolRequest(context: fixture.context(), remote: "upstream"))
        let pull = try await fixture.backend.gitPull(GitRemoteToolRequest(context: fixture.context()))
        let clone = try await fixture.backend.gitClone(GitCloneToolRequest(context: fixture.context(), url: "https://example.com/hello.git"))

        #expect(fixture.host.requests(GitFetchRequest.self).first?.remote == "upstream")
        #expect(fixture.host.requests(GitFetchRequest.self).first?.projectID == fixture.project.id)
        #expect(fixture.host.requests(GitPullRequest.self).first?.remote == nil)
        let cloneRequest = try #require(fixture.host.requests(GitCloneIntoRequest.self).first)
        #expect(cloneRequest.projectID == fixture.project.id)
        #expect(cloneRequest.url == "https://example.com/hello.git")
        #expect(cloneRequest.branch == nil)

        #expect(fetch.remote == "upstream")
        #expect(fetch.updated == [GitRefUpdate(ref: "refs/remotes/upstream/main", from: "a", to: "b")])
        #expect(pull == GitTaskToolResponse(branch: "main", from: "a", to: "b", upToDate: false))
        #expect(clone == GitTaskToolResponse(branch: "trunk", commit: "c"))
    }

    @Test
    func `an authentication failure tells the user where to add a token`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitCloneInto, reply: TaskHandle(taskID: TaskID("clone-task"), kind: .environment))
        fixture.host.on(.environmentAttach, reply: batch("clone-task", [
            stateEvent(.failed, "denied: authentication required for https://github.com/owner/private.git"),
        ]))
        do {
            _ = try await fixture.backend.gitClone(GitCloneToolRequest(context: fixture.context(), url: "https://github.com/owner/private.git"))
            Issue.record("the clone should fail")
        } catch let failure as GitToolFailure {
            #expect(failure.message.hasPrefix("git clone failed: authentication required"))
            #expect(failure.message.contains("Settings ▸ Git"))
            #expect(failure.message.contains("for github.com"))
        }
    }

    @Test
    func `a refused start and a rejected push say what happened and what not to do`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitCloneInto) { _ in throw ApelinError(.conflict, "the project already holds a repository") }
        fixture.host.on(.gitPush, reply: TaskHandle(taskID: TaskID("push-task"), kind: .environment))
        fixture.host.on(.environmentAttach, reply: batch("push-task", [
            stateEvent(.failed, "conflict: the remote rejected the update to refs/heads/main"),
        ]))
        fixture.host.on(.gitCommit) { _ in
            throw ApelinError(.badRequest, "no commit author: pass authorName and authorEmail, or set them in Settings/git.json")
        }

        await #expect {
            _ = try await fixture.backend.gitClone(GitCloneToolRequest(context: fixture.context(), url: "https://example.com/x.git"))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.contains("already holds a repository") && message.contains("do not delete their files")
        }
        await #expect {
            _ = try await fixture.backend.gitPush(GitRemoteToolRequest(context: fixture.context()))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.hasPrefix("git push failed: the remote rejected") && message.contains("never a reason to force")
        }
        await #expect {
            _ = try await fixture.backend.gitCommit(GitCommitToolRequest(context: fixture.context(), message: "x"))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.contains("commit author in Settings ▸ Git") && !message.contains("token")
        }
    }

    @Test
    func `a push with a URL sends it, and a sign-in failure there names its host`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitPush, reply: TaskHandle(taskID: TaskID("push-task"), kind: .environment))
        fixture.host.on(.environmentAttach, reply: batch("push-task", [
            stateEvent(.failed, "denied: authentication required for https://github.com/owner/fresh.git"),
        ]))
        await #expect {
            _ = try await fixture.backend.gitPush(GitRemoteToolRequest(
                context: fixture.context(), branch: "main", url: "https://github.com/owner/fresh.git",
            ))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.contains("Sign In with GitHub")
        }
        let sent = try #require(fixture.host.requests(GitPushRequest.self).first)
        #expect(sent.url == "https://github.com/owner/fresh.git")
        #expect(sent.remote == nil)
    }

    @Test
    func `a project without a repository or a remote is told what makes one`() async throws {
        let fixture = try Fixture()
        // A name that reads like a sign-in failure does not make it one.
        fixture.host.on(.gitStatus) { _ in
            throw ApelinError(.notFound, "project Token Clock is not a git repository", reason: .notARepository)
        }
        fixture.host.on(.gitPush) { _ in throw ApelinError(.notFound, "no remote \"origin\"", reason: .noSuchRemote) }
        fixture.host.on(.gitDiff) { _ in throw ApelinError(.notFound, "no path Sources/Gone.m") }

        await #expect {
            _ = try await fixture.backend.gitStatus(GitStatusToolRequest(context: fixture.context()))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.hasPrefix("git status failed: project Token Clock is not a git repository.")
                && message.contains("git_init") && !message.contains("credential")
        }
        await #expect {
            _ = try await fixture.backend.gitPush(GitRemoteToolRequest(context: fixture.context()))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.contains("git_push with url") && message.contains("empty repository")
                && message.contains("apelin_git_create_repository")
        }
        await #expect {
            _ = try await fixture.backend.gitDiff(GitDiffToolRequest(context: fixture.context(), path: "Sources/Gone.m"))
        } throws: { error in
            (error as? GitToolFailure)?.message == "git diff failed: no path Sources/Gone.m."
        }
    }

    @Test
    func `a push URL that is not the remote's says so, not to pull`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitPush) { _ in
            throw ApelinError(
                .conflict,
                "origin already points to https://example.com/a.git. Push to it without a URL, or name another remote.",
                reason: .remoteURLDiffers,
            )
        }
        await #expect {
            _ = try await fixture.backend.gitPush(GitRemoteToolRequest(context: fixture.context(), url: "https://example.com/b.git"))
        } throws: { error in
            let message = (error as? GitToolFailure)?.message ?? ""
            return message.hasPrefix("git push failed: origin already points to") && !message.contains("pull")
        }
    }

    @Test
    func `a push approval carries its remote and branch in the event`() {
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "git_push", arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "Pushing main to origin publishes its commits.",
            detail: .gitPush(remote: "origin", branch: "main"), allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let expected: ApelinCore.JSONValue = .object(["gitPush": .object(["remote": .string("origin"), "branch": .string("main")])])
        #expect(payload["detail"] == expected)
        #expect(payload["allowsSessionScope"] == .bool(false))
    }
}
