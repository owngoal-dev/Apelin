import ApelinCore
import ApelinProtocol
import Foundation

// A reset to a remote (Apelind/Session/Agent/AgentResetToRemoteRules.swift,
// issue #32): an agent's discards local work only on one approval the app
// gave that session for exactly that reset — the project, the remote and
// its address, the branch, the remote's commit and HEAD the card showed —
// in Strict, Relaxed and Full alike; spent once, never held for the
// session; a card for another state, another tool or another session's
// covers nothing, and nothing covers a request without the address.

func resetToRemoteChecks(scratch: URL, scratchPath: String) async {
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .gitResetToRemote), "the agent may reset its project to a remote")
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .gitResetPreview), "and read what that would lose")
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .gitRemoteSet), "and set its remotes")
    check(!CallerPolicy.allows(.worker(.build, instance: nil), .gitResetToRemote), "the build worker may not")
    check(!CallerPolicy.allows(.worker(.environment, instance: nil), .gitResetToRemote), "nor the environment worker")

    let registry = TaskRegistry(directory: scratch.appendingPathComponent("reset-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    let project = ResolvedProject(id: "p-reset", name: "Pineora", path: scratchPath)
    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: project,
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    let remoteCommit = String(repeating: "a", count: 40)
    let head = String(repeating: "b", count: 40)
    let url = "https://github.com/owngoal-dev/Pineora.git"
    let reset = GitResetToRemoteRequest(
        projectID: project.id,
        remote: "origin",
        branch: "main",
        expectedRemoteCommit: remoteCommit,
        expectedHead: head,
        expectedURL: url,
    )
    // What apelin-agent writes into git_reset_to_remote's approvalRequested
    // (ApelinAgentWorker's tests hold that shape).
    func ask(
        _ entry: AgentSessionTable.Entry,
        _ approvalID: String,
        tool: String = "git_reset_to_remote",
        projectID: String = "p-reset",
        remoteCommit card: String? = nil,
        head cardHead: String? = nil,
        url cardURL: String? = nil,
    ) async {
        var detail: [String: JSONValue] = [
            "projectID": .string(projectID), "remote": .string("origin"), "url": .string(cardURL ?? url),
            "branch": .string("main"), "remoteCommit": .string(card ?? remoteCommit),
            "unrelatedHistories": .bool(true), "lostCommitCount": .number(3), "projectFile": .string("repositoryWithProjectID"),
        ]
        detail["head"] = .string(cardHead ?? head)
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string(tool), "allowsSessionScope": .bool(false),
            "detail": .object([AgentResetToRemoteRules.detailKey: .object(detail)]),
        ]))
    }
    func authorized(_ entry: AgentSessionTable.Entry?, _ request: GitResetToRemoteRequest = reset) async -> ApelinError? {
        await AgentResetToRemoteRules.authorize(request, session: entry?.sessionID, registry: registry)
    }

    for mode in [ApprovalMode.confirm, .relaxed, .full] {
        let entry = await session("reset-\(mode.rawValue)", mode: mode)
        let unasked = await authorized(entry)
        check(unasked?.code == .denied, "\(mode.rawValue): a reset is never let through without an approval")
        await ask(entry, "asked-\(mode.rawValue)")
        let asked = await authorized(entry)
        check(asked != nil, "\(mode.rawValue): asking is not approving")
        await sessions.record(entry.sessionID, approvalID: "asked-\(mode.rawValue)", decision: .approve)
        let approved = await authorized(entry)
        check(approved == nil, "\(mode.rawValue): the approved reset runs")
        let again = await authorized(entry)
        check(again != nil, "\(mode.rawValue): once — the next reset asks again")
    }

    // A card for another state covers nothing, and stays unspent.
    let strict = await session("reset-cards", mode: .confirm)
    let cards: [(String, () async -> Void)] = [
        ("moved remote", { await ask(strict, "moved", remoteCommit: String(repeating: "c", count: 40)) }),
        ("moved HEAD", { await ask(strict, "head", head: String(repeating: "d", count: 40)) }),
        ("another address", { await ask(strict, "address", url: "https://github.com/someone/else.git") }),
        ("another project", { await ask(strict, "project", projectID: "p-other") }),
        ("another tool", { await ask(strict, "tool", tool: "git_push") }),
    ]
    for (_, card) in cards {
        await card()
    }
    for approvalID in ["moved", "head", "address", "project", "tool"] {
        await sessions.record(strict.sessionID, approvalID: approvalID, decision: .approve)
    }
    let coveredByNone = await authorized(strict)
    let unspent = await sessions.approvedIDs(strict.sessionID)
    check(coveredByNone != nil && unspent.count == cards.count, "a card for a moved remote, a moved HEAD, another address, project or tool approves nothing")

    // A request that leaves out what the card was bound to is covered by none.
    await ask(strict, "exact")
    await sessions.record(strict.sessionID, approvalID: "exact", decision: .approve)
    var noURL = reset
    noURL.expectedURL = nil
    let withoutURL = await authorized(strict, noURL)
    var noHead = reset
    noHead.expectedHead = nil
    let withoutHead = await authorized(strict, noHead)
    check(withoutURL != nil && withoutHead != nil, "nor does the card cover a request without its address or HEAD")
    let exact = await authorized(strict)
    check(exact == nil, "the exact request spends the exact card")

    // Another session's approval is not this one's.
    let other = await session("reset-other", mode: .full)
    await ask(other, "theirs")
    await sessions.record(other.sessionID, approvalID: "theirs", decision: .approve)
    let elsewhere = await authorized(strict)
    check(elsewhere != nil, "an approval another session was given covers nothing here")
    let noSession = await authorized(nil)
    check(noSession?.code == .denied, "a worker with no session resets nothing")
}
