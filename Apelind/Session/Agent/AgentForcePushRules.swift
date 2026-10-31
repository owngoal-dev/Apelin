import ApelinCore
import ApelinProtocol
import Foundation

/// An agent's forced push (git_push with force_with_lease, owner,
/// 2026-10-31, issue #29): it overwrites the remote's branch, and the
/// commits it takes off are gone from the branch for everyone who pulls it,
/// so it runs only on an approval the user gave for exactly it, in every
/// mode — Strict, Relaxed and Full alike; Full lifts root commands, not
/// this. Each one spends an approval the app gave this session whose own
/// `approvalRequested` names exactly that push (`detail.forcePush`
/// {projectID, remote, url?, branch, expectedCommit, localCommit,
/// overwritten, overwrittenCount}): the remote, the branch, and the lease's
/// commits, which go to apelin-environment as the card named them, since a
/// request that differs in any of them is refused. Once, never for the
/// session. An ordinary push is untouched, and so are the app's own calls.
enum AgentForcePushRules {
    static let detailKey = "forcePush"

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this forced push of
    /// this project.
    static func covers(_ push: GitPushRequest, lease: GitPushLease, project: String, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.gitPush.rawValue,
              let detail = asked["detail"]?[detailKey],
              let branch = push.branch
        else { return false }
        return detail["projectID"]?.stringValue == project
            && detail["remote"]?.stringValue == (push.remote ?? "origin")
            && detail["branch"]?.stringValue == branch
            && detail["url"]?.stringValue == push.url
            && detail["expectedCommit"]?.stringValue == lease.expectedCommit
            && detail["localCommit"]?.stringValue == lease.localCommit
    }

    /// Nil when the session may push it, after spending the approval that
    /// covers it; else why not. A push without a lease passes: it is never
    /// forced.
    static func authorize(_ push: GitPushRequest, session: String?, registry: TaskRegistry) async -> ApelinError? {
        guard let lease = push.forceWithLease else { return nil }
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard push.branch != nil, lease.localCommit != nil else {
            return ApelinError(.badRequest, "an agent's forced push names its branch and the local commit it sends")
        }
        let covered = await AgentApprovals.spend(entry: entry, registry: registry) { asked in
            covers(push, lease: lease, project: entry.project.id, asked: asked)
        }
        guard covered else {
            let remote = push.remote ?? "origin"
            return ApelinError(
                .denied,
                "approval required, in every mode: the user has not approved overwriting \(remote)'s \(push.branch ?? "") at \(lease.expectedCommit) with \(lease.localCommit ?? "")",
            )
        }
        return nil
    }
}
