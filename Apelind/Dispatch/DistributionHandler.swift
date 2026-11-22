import ApelinProtocol

/// The user's package repository, served by apelin-environment, which holds
/// the github.com sign-in. The app's alone (CallerPolicy), but for a publish,
/// which an agent may start as AgentPublishRules allows, checked here before
/// the task is made. Its tasks are not resumed: each talks to GitHub, and the
/// one cut off is answered by running it again, which a link does safely.
///
/// A project's release builds published as a GitHub Release
/// (`distributionRelease`) go the same way: the app's, and an agent's as
/// AgentReleaseRules allows; not resumed, since running it again fills in
/// the draft one cut off left.
///
/// Feedback (`feedbackSend`) is one request to GitHub with the same sign-in,
/// on Apelin's own repository; an agent may send it, and edit an issue the
/// account opened there (`feedbackEdit`), as AgentFeedbackRules allows,
/// checked here before it is forwarded, and read one (`feedbackRead`).
/// Reading and giving that repository a star (`feedbackStarState`,
/// `feedbackStar`) stay the app's.
enum DistributionHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .distributionRepositoryList, .distributionRepositoryUnlink:
            await host.forward(request, to: .environment)
        case .distributionRepositoryCreate, .distributionRepositoryLink:
            await host.startTask(request, kind: .environment, role: .environment, resumable: false)
        case .distributionPublish:
            await publish(request, host: host)
        case .distributionRelease:
            await release(request, host: host)
        case .feedbackSend:
            await sendFeedback(request, host: host)
        case .feedbackEdit:
            await editFeedback(request, host: host)
        case .feedbackRead, .feedbackStarState, .feedbackStar:
            await host.forward(request, to: .environment)
        default:
            request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a distribution operation"))
        }
    }

    private static func publish(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if case let .worker(.agent, instance) = request.caller {
            let publish: DistributionPublishRequest
            do {
                publish = try request.decode(DistributionPublishRequest.self)
            } catch {
                return request.fail(error)
            }
            if let refusal = await AgentPublishRules.authorize(
                publish,
                session: instance,
                registry: host.registry,
                artifacts: host.artifacts,
            ) {
                return request.fail(refusal)
            }
        }
        return await host.startTask(request, kind: .environment, role: .environment, resumable: false)
    }

    private static func release(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if case let .worker(.agent, instance) = request.caller {
            let release: DistributionReleaseRequest
            do {
                release = try request.decode(DistributionReleaseRequest.self)
            } catch {
                return request.fail(error)
            }
            if let refusal = await AgentReleaseRules.authorize(
                release,
                session: instance,
                registry: host.registry,
                artifacts: host.artifacts,
            ) {
                return request.fail(refusal)
            }
        }
        return await host.startTask(request, kind: .environment, role: .environment, resumable: false)
    }

    private static func sendFeedback(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if case let .worker(.agent, instance) = request.caller {
            let feedback: FeedbackSendRequest
            do {
                feedback = try request.decode(FeedbackSendRequest.self)
            } catch {
                return request.fail(error)
            }
            if let refusal = await AgentFeedbackRules.authorize(feedback, session: instance, registry: host.registry) {
                return request.fail(refusal)
            }
        }
        return await host.forward(request, to: .environment)
    }

    private static func editFeedback(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if case let .worker(.agent, instance) = request.caller {
            let edit: FeedbackEditRequest
            do {
                edit = try request.decode(FeedbackEditRequest.self)
            } catch {
                return request.fail(error)
            }
            if let refusal = await AgentFeedbackRules.authorize(edit, session: instance, registry: host.registry) {
                return request.fail(refusal)
            }
        }
        return await host.forward(request, to: .environment)
    }
}
