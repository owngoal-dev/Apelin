import Foundation
import KWWKAI

/// git_reset_to_remote (issue #32): the fetch and the reading of what the
/// reset would discard happen before anyone is asked, so the card shows the
/// state the reset is then held to. Nothing to discard and nothing to
/// change is answered without asking.
extension ToolRunner {
    func resetToAsk(_ arguments: JSONValue) async throws -> ResetToRemoteApproval {
        let remote = arguments.argNonEmptyString("remote") ?? "origin"
        let context = HostCallContext(sessionID: sessionID, project: project, toolCallID: "", approval: .notRequired)
        let preview: GitResetPreviewToolResponse
        do {
            preview = try await backend.gitResetPreview(GitResetPreviewToolRequest(
                context: context,
                remote: remote,
                branch: arguments.argNonEmptyString("branch"),
            ))
        } catch let failure as GitToolFailure {
            throw GitToolFailure(message: "Nothing was changed: " + failure.message)
        }
        let reset = preview.approval
        guard !preview.upToDate else {
            throw ToolArgumentError("Nothing to do: the project already is \(reset.remote)/\(reset.branch) at \(reset.remoteCommit.prefix(7)), with no local change.")
        }
        return reset
    }
}
