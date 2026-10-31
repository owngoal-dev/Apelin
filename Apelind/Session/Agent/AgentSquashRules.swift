import ApelinCore
import ApelinProtocol
import Foundation

/// An agent's `gitSquash` (git_squash, owner, 2026-10-31): it replaces the
/// commits after a base on the project's checked-out branch with one, a
/// history the user may have read or published, so under Confirm it runs
/// only by spending one approval the app gave this session whose own
/// `approvalRequested` names exactly it (`detail.squash` {projectID,
/// branch, base, expectedHead, message, commits, count, upstream?,
/// published}): the request's base, expected head and message must be the
/// card's. Once, never for the session; Relaxed and Full run it as they
/// commit. A preview changes nothing and passes in every mode.
/// apelin-environment refuses a head that moved since (`headChanged`).
enum AgentSquashRules {
    static let detailKey = "squash"

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this squash of this
    /// project.
    static func covers(_ squash: GitSquashRequest, project: String, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.gitSquash.rawValue,
              let detail = asked["detail"]?[detailKey],
              let base = squash.base, let head = squash.expectedHead, let message = squash.message
        else { return false }
        return detail["projectID"]?.stringValue == project
            && detail["base"]?.stringValue == base
            && detail["expectedHead"]?.stringValue == head
            && detail["message"]?.stringValue == message
    }

    /// Nil when the session may squash, after spending the approval that
    /// covers it under Confirm; else why not.
    static func authorize(_ squash: GitSquashRequest, session: String?, registry: TaskRegistry) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard squash.preview != true, entry.mode.asks else { return nil }
        let covered = await AgentApprovals.spend(entry: entry, registry: registry) { asked in
            covers(squash, project: entry.project.id, asked: asked)
        }
        guard covered else {
            return ApelinError(
                .denied,
                "approval required: the user has not approved squashing these commits after \(squash.base ?? "the base") into one with this message",
            )
        }
        return nil
    }
}
