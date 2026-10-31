import struct ApelinProtocol.GitBranchComparison
import Foundation

/// The git tools that change a branch's history rather than add to it
/// (issue #29): a forced push, read before anyone is asked.
extension ToolRunner {
    /// What a git_push with force_with_lease does: force the remote's branch,
    /// or, when nothing on it would be lost, push without force, and why.
    enum ForcePushPlan {
        case force(ForcePushApproval)
        case unforced(String)
    }

    /// Fetches the remote, as git_fetch does, to learn what its branch is
    /// at and which of its commits the push would take off it. Refuses
    /// before anyone is asked a push the card could not name exactly: no
    /// branch, a remote the project does not have, a `url` that is not
    /// where the remote pushes.
    func forcePush(_ target: GitPushTarget) async throws -> ForcePushPlan {
        guard let branch = target.branch else {
            throw GitToolFailure(message: "Nothing was pushed: no branch is checked out, so name the branch to force-push.")
        }
        let fetched: GitTaskToolResponse
        do {
            fetched = try await backend.gitFetch(GitRemoteToolRequest(
                context: HostCallContext(sessionID: sessionID, project: project, toolCallID: "", approval: .notRequired),
                remote: target.remote,
                branch: branch,
            ))
        } catch {
            throw GitToolFailure(message: "Nothing was pushed: a forced push first fetches \(target.remote) to show the user what it would overwrite, and that failed. \(error.localizedDescription) A forced push goes to a remote the project already has.")
        }
        guard let comparison = fetched.comparison else {
            throw GitToolFailure(message: "Nothing was pushed: the fetch did not say what \(target.remote) has for \(branch).")
        }
        return try Self.forcePushPlan(comparison, target: target, projectID: project.id)
    }

    static func forcePushPlan(
        _ comparison: GitBranchComparison,
        target: GitPushTarget,
        projectID: String,
    ) throws -> ForcePushPlan {
        let branch = comparison.branch
        if let url = target.url, url != comparison.pushURL {
            let actual = comparison.pushURL ?? "an address Apelin does not push to"
            throw GitToolFailure(message: "Nothing was pushed: \(target.remote) pushes to \(actual), not \(url). A forced push goes to the remote as the project has it: name the remote that points to \(url), or leave url out.")
        }
        guard let expected = comparison.remote else {
            return .unforced("\(target.remote) has no branch \(branch), so nothing there is overwritten: it is pushed without force, as a new branch.")
        }
        guard comparison.remoteOnlyCount > 0 else {
            return .unforced("\(target.remote)'s \(branch), at \(ApprovalPolicy.shortCommit(expected)), is already part of this \(branch), so nothing on it is lost: it is pushed without force.")
        }
        guard let pushURL = comparison.pushURL else {
            throw GitToolFailure(message: "Nothing was pushed: \(target.remote) does not push to an HTTPS address, which is the only kind Apelin pushes to.")
        }
        return .force(ForcePushApproval(
            projectID: projectID,
            remote: target.remote,
            url: pushURL,
            branch: branch,
            expectedCommit: expected,
            localCommit: comparison.local,
            localSubject: comparison.localSubject,
            overwritten: comparison.remoteOnly,
            overwrittenCount: comparison.remoteOnlyCount,
        ))
    }

    /// What the model is told after a forced push went: what the remote's
    /// branch was and is, and what left it, for the reply to the user.
    static func forcedPushNote(_ force: ForcePushApproval) -> String {
        let commits = force.overwrittenCount == 1 ? "1 commit" : "\(force.overwrittenCount) commits"
        return "Forced: \(force.remote)'s \(force.branch) was at \(force.expectedCommit) and is at \(force.localCommit) now; \(commits) that only it had are no longer on the branch. Tell the user, naming both commits."
    }
}
