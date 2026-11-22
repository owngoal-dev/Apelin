import ApelinCore
import ApelinProtocol
import Foundation

// Stopping a load check (Apelind/Session/Agent/LoadCheckCancelRules.swift,
// issue #76): `confirmLoadedCancel` stops a load check and no other kind of
// task, and an agent stops only a check its own session started — the one
// apelin_package_confirm_loaded waited on when the user stopped the call.

func loadCheckCancelChecks(scratch: URL, scratchPath: String) async {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("load-check-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    let project = ResolvedProject(id: "p-load-check", name: "Hello", path: scratchPath)
    for id in ["load-check-a", "load-check-b"] {
        await sessions.add(AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: project,
            mode: .confirm,
            createdAt: Date(),
        ))
    }
    let own = await registry.create(kind: .confirmLoaded, owner: .diagnostics)
    await sessions.recordStarted(own.taskID, session: "load-check-a")
    let build = await registry.create(kind: .build, owner: .build)
    await sessions.recordStarted(build.taskID, session: "load-check-a")
    let theApps = await registry.create(kind: .confirmLoaded, owner: .diagnostics)

    func refusal(_ taskID: TaskID, _ caller: Caller) async -> ApelinError? {
        await LoadCheckCancelRules.refusal(ConfirmLoadedCancelRequest(taskID: taskID), caller: caller, registry: registry)
    }
    let agent = Caller.worker(.agent, instance: "load-check-a")
    let again = await refusal(own.taskID, agent)
    check(again == nil, "an agent stops the load check its session started")
    let another = await refusal(own.taskID, .worker(.agent, instance: "load-check-b"))
    check(another?.code == .denied, "another session's agent does not")
    let unnamed = await refusal(own.taskID, .worker(.agent, instance: nil))
    check(unnamed?.code == .denied, "nor an agent worker with no session")
    let notStarted = await refusal(theApps.taskID, agent)
    check(notStarted?.code == .denied, "nor a check the app started")
    let notACheck = await refusal(build.taskID, agent)
    check(notACheck?.code == .badRequest, "a build it started is not stopped as a load check")
    let appsOwn = await refusal(theApps.taskID, .app)
    check(appsOwn == nil, "the app stops any load check")
    let appBuild = await refusal(build.taskID, .app)
    check(appBuild?.code == .badRequest, "and no other kind of task through it")
    let missing = await refusal(TaskID("no-such-task"), .app)
    check(missing?.code == .notFound, "a task that does not exist is not found")
}
