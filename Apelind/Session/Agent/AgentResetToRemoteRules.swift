import ApelinCore
import ApelinProtocol
import Foundation

/// An agent's `gitResetToRemote` (git_reset_to_remote, issue #32): the
/// project made exactly a remote's branch, which discards local work, so it
/// asks in every mode, Strict, Relaxed and Full alike, the way a root
/// command asks outside Full. Each one spends an approval the app gave this
/// session whose own `approvalRequested` names exactly that reset
/// (`detail.resetToRemote` {projectID, remote, url, branch, remoteCommit,
/// head?, …}), once, never for the session: the request must carry the
/// remote's commit, HEAD and address the card showed, which apelin-
/// environment holds the project to again before it changes anything.
enum AgentResetToRemoteRules {
    static let detailKey = "resetToRemote"

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this reset of the
    /// session's project.
    static func covers(_ reset: GitResetToRemoteRequest, project: String, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.gitResetToRemote.rawValue,
              let detail = asked["detail"]?[detailKey], let url = detail["url"]?.stringValue
        else { return false }
        return detail["projectID"]?.stringValue == project
            && detail["remote"]?.stringValue == reset.remote
            && detail["branch"]?.stringValue == reset.branch
            && url == reset.expectedURL
            && detail["remoteCommit"]?.stringValue == reset.expectedRemoteCommit
            && detail["head"]?.stringValue == reset.expectedHead
    }

    /// Nil once the approval that covers it is spent, else why not. In
    /// every mode.
    static func authorize(_ reset: GitResetToRemoteRequest, session: String?, registry: TaskRegistry) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard reset.expectedURL != nil,
              await AgentApprovals.spend(entry: entry, registry: registry, covers: {
                  covers(reset, project: entry.project.id, asked: $0)
              })
        else {
            return ApelinError(
                .denied,
                "approval required: the user has not approved making this project exactly \(reset.remote)/\(reset.branch) at \(reset.expectedRemoteCommit.prefix(7)); a reset discards local work and asks in every mode",
            )
        }
        return nil
    }
}
