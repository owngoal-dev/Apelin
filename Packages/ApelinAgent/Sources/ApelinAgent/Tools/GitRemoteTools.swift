import enum ApelinProtocol.AgentToolName
import enum ApelinProtocol.GitRemoteName
import enum ApelinProtocol.GitRemoteURL
import Foundation
import KWWKAI

/// The remote names and addresses the git tools take (issue #32), checked
/// before anyone is asked or the host is called: a remote is a name, and an
/// address given where one goes is answered with how to add it, never with
/// "no such remote".
enum GitRemoteTools {
    /// The tools whose `remote` argument names a remote.
    static let namingRemote: Set<AgentToolName> = [.gitFetch, .gitPull, .gitPush]

    /// Refuses a remote's name that is an address, a path or an option;
    /// any other a remote the project has may carry. Nil, the tool's
    /// default, passes.
    static func checkName(_ name: String?) throws {
        guard let name else { return }
        if GitRemoteName.looksLikeAddress(name) {
            throw ToolArgumentError("“\(name)” is an address, not a remote's name: a remote is a name such as origin. To use that repository, add it with git_remote_set (a name and this url), or point an existing remote there, then name the remote here.")
        }
        if let problem = GitRemoteName.existingProblem(name) {
            throw ToolArgumentError(problem)
        }
    }

    /// git_remote_set's name and address, as the host will take them.
    static func checkSet(_ arguments: JSONValue) throws {
        let name = try arguments.requireString("name")
        try checkName(name)
        if let problem = GitRemoteName.problem(name) {
            throw ToolArgumentError(problem)
        }
        if let problem = try GitRemoteURL.problem(arguments.requireString("url")) {
            throw ToolArgumentError("Nothing was changed: \(problem)")
        }
    }
}
