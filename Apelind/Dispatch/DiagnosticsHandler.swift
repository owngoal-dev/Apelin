import ApelinProtocol

/// Load confirmation and UI verification, served by apelin-diagnostics.
/// A load check is a task the host owns, so the respring it may trigger —
/// which takes the app down, not the host — cannot lose its answer. The
/// device passcode's three operations are the app's alone (CallerPolicy
/// lets no worker call them), and go to apelin-diagnostics, which alone
/// keeps the passcode; the host reads none of it.
enum DiagnosticsHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .confirmLoaded:
            await host.startTask(request, kind: .confirmLoaded, role: .diagnostics)
        case .confirmLoadedAttach:
            await host.attach(request, ConfirmLoadedAttachRequest.self)
        case .captureScreen:
            await host.forward(request, to: .diagnostics)
        case .readUITree:
            await forwardTreeRead(request, host: host)
        case .uiAction:
            await forwardAction(request, host: host)
        case .devicePasscodeState, .devicePasscodeSave, .devicePasscodeRemove:
            await host.forward(request, to: .diagnostics)
        default:
            request.fail(ApelinError(
                .badRequest,
                "\(request.operation.rawValue) is not a diagnostics operation",
            ))
        }
    }

    /// An agent reads the UI tree only as its session's Ask Before Using the
    /// Screen lets it (AgentScreenRules).
    private static func forwardTreeRead(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if let refusal = await AgentScreenRules.authorize(request.request, caller: request.caller, registry: host.registry) {
            return request.fail(refusal)
        }
        return await host.forward(request, to: .diagnostics)
    }

    /// An agent acts only as its session's Ask Before Using the Screen lets
    /// it (AgentScreenRules), and never on Apelin itself (AgentUIActionRules).
    private static func forwardAction(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if let refusal = await AgentScreenRules.authorize(request.request, caller: request.caller, registry: host.registry) {
            return request.fail(refusal)
        }
        var scoped = request
        do {
            scoped.request = try AgentUIActionRules.scoped(request.request, caller: request.caller)
        } catch {
            return request.fail(error)
        }
        return await host.forward(scoped, to: .diagnostics)
    }
}
