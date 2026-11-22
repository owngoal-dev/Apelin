import ApelinProtocol

/// Who stops which load check (`confirmLoadedCancel`, issue #76): only a
/// load check, since every other kind of task has a cancel of its own, and
/// an agent only one its own session started — apelin_package_confirm_loaded
/// stops the check it waited on when the user stops the call, so a listen of
/// minutes ends with it. The app and the console stop any.
enum LoadCheckCancelRules {
    /// The refusal, or nil to let the cancel through to the worker.
    static func refusal(_ cancel: ConfirmLoadedCancelRequest, caller: Caller, registry: TaskRegistry) async -> ApelinError? {
        if case let .worker(.agent, session) = caller {
            guard let session, await AgentSessionTable.shared.started(cancel.taskID, session: session) else {
                return ApelinError(.denied, "an agent stops only the load checks it started")
            }
        }
        guard let record = await registry.record(cancel.taskID) else {
            return ApelinError(.notFound, "This task could not be found.")
        }
        guard record.kind == .confirmLoaded else {
            return ApelinError(.badRequest, "task \(cancel.taskID) is not a load check")
        }
        return nil
    }
}
