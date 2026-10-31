import ApelinCore
import ApelinProtocol

/// The git service on a project, served by apelin-environment (libgit2),
/// and an empty repository made on GitHub, or an issue opened on one the
/// user chose, with the github.com sign-in.
enum GitHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if case let .worker(.agent, instance) = request.caller, !unscoped.contains(request.operation),
           let refusal = await agentScopeRefusal(request, sessionID: instance)
        {
            return request.fail(refusal)
        }
        switch request.operation {
        case .gitStatus, .gitDiff, .gitStage, .gitUnstage, .gitCommit, .gitInit,
             .gitSettings, .gitAuthorSet, .gitCredentialSet, .gitCredentialRemove:
            return await host.forward(request, to: .environment)
        case .gitRepositoryCreate:
            return await createRepository(request, host: host)
        case .gitIssueCreate:
            return await createIssue(request, host: host)
        case .gitClone:
            return await host.startTask(request, kind: .environment, role: .environment, resumable: true)
        case .gitPush:
            return await push(request, host: host)
        case .gitCloneInto, .gitFetch, .gitPull:
            // Not resumed: a push or pull cut off is answered by running it
            // again, which the caller decides.
            return await host.startTask(request, kind: .environment, role: .environment, resumable: false)
        default:
            return request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a git operation"))
        }
    }

    /// What names no project: the device's author and credentials, which an
    /// agent changes only through the user's approval of each call, a
    /// repository made on GitHub, which AgentRepositoryCreateRules decides,
    /// and an issue opened on one, which AgentIssueCreateRules decides.
    private static let unscoped: Set<AppOperation> = [
        .gitSettings, .gitAuthorSet, .gitCredentialSet, .gitCredentialRemove, .gitRepositoryCreate, .gitIssueCreate,
    ]

    /// An agent's git call acts on its own session's project and no other:
    /// a push carries the user's credential for the remote's host.
    private static func agentScopeRefusal(_ request: HostRequest, sessionID: String?) async -> ApelinError? {
        struct Scoped: Decodable { var projectID: String }
        guard let sessionID, let entry = await AgentSessionTable.shared.entry(sessionID) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard let scoped = try? JSONCoding.decode(Scoped.self, from: request.request.payload) else {
            return ApelinError(.badRequest, "\(request.operation.rawValue) names no project")
        }
        guard scoped.projectID == entry.project.id || scoped.projectID == entry.project.name else {
            return ApelinError(.denied, "an agent's git call acts only on its own project")
        }
        return nil
    }

    /// An agent's forced push goes only on the user's approval of exactly
    /// it, in every mode (AgentForcePushRules). Not resumed, as a fetch or a
    /// pull is not.
    private static func push(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if case let .worker(.agent, instance) = request.caller {
            let push: GitPushRequest
            do {
                push = try request.decode(GitPushRequest.self)
            } catch {
                return request.fail(error)
            }
            if let refusal = await AgentForcePushRules.authorize(push, session: instance, registry: host.registry) {
                return request.fail(refusal)
            }
        }
        return await host.startTask(request, kind: .environment, role: .environment, resumable: false)
    }

    /// An agent's is checked here before it is forwarded.
    private static func createRepository(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if case let .worker(.agent, instance) = request.caller {
            let create: GitRepositoryCreateRequest
            do {
                create = try request.decode(GitRepositoryCreateRequest.self)
            } catch {
                return request.fail(error)
            }
            if let refusal = await AgentRepositoryCreateRules.authorize(create, session: instance, registry: host.registry) {
                return request.fail(refusal)
            }
        }
        return await host.forward(request, to: .environment)
    }

    /// An agent's is checked here before it is forwarded.
    private static func createIssue(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if case let .worker(.agent, instance) = request.caller {
            let issue: GitIssueCreateRequest
            do {
                issue = try request.decode(GitIssueCreateRequest.self)
            } catch {
                return request.fail(error)
            }
            if let refusal = await AgentIssueCreateRules.authorize(issue, session: instance, registry: host.registry) {
                return request.fail(refusal)
            }
        }
        return await host.forward(request, to: .environment)
    }
}
