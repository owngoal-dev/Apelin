import ApelinCore
import ApelinProtocol
import Foundation

/// An approval left waiting when the session host stopped can never be
/// answered: its task ended `interrupted`, and the worker that reopens the
/// session resolves it (deny, "the session restarted") before anything new,
/// inside the replay of the history. The conversation takes that one event
/// and reads past the rest of the replay, so the next turn's card is the
/// approval that turn asked for, never the dead one (issue #38). A card
/// that cannot be answered stood in for the composer on every later turn:
/// Approve and Deny answered "This approval request is no longer waiting
/// for a decision.", and nothing more could be typed or sent in it.
func checkAbandonedApproval() {
    let firstID = UUID()
    let deny: [String: JSONValue] = ["approvalID": .string("a1"), "decision": .string("deny")]
    // The turn the app saw: a call that asked, then the host stopped.
    let history = [
        event(1, "prompt", ["id": .string(firstID.uuidString), "text": .string("Run it")]),
        event(2, "messageStarted"),
        event(3, "toolCall", ["id": .string("t1"), "tool": .string("shell_run"), "arguments": .string("{}")]),
        event(4, "approvalRequested", ["approvalID": .string("a1"), "tool": .string("shell_run"), "arguments": .string("{}")]),
        event(5, TaskEvent.stateKind, ["state": .string(TaskState.waitingForApproval.rawValue)]),
        event(6, TaskEvent.stateKind, ["state": .string(TaskState.interrupted.rawValue)]),
    ]
    // The reopened session's task: the log again, numbered as the worker
    // relays it, the resolution it wrote when it opened, then the new turn.
    let replay = [
        event(1, "prompt", ["id": .string(firstID.uuidString), "text": .string("Run it")]),
        event(2, "messageStarted"),
        event(3, "toolCall", ["id": .string("t1"), "tool": .string("shell_run"), "arguments": .string("{}")]),
        event(4, "approvalRequested", ["approvalID": .string("a1"), "tool": .string("shell_run"), "arguments": .string("{}")]),
        event(5, TaskEvent.stateKind, ["state": .string(TaskState.waitingForApproval.rawValue)]),
        event(6, "approvalResolved", deny),
        event(7, TaskEvent.stateKind, ["state": .string(TaskState.running.rawValue)]),
    ]
    let secondID = UUID()
    let next = [
        event(8, "prompt", ["id": .string(secondID.uuidString), "text": .string("Try it again")]),
        event(9, "messageStarted"),
        event(10, "toolCall", ["id": .string("t2"), "tool": .string("shell_run"), "arguments": .string("{}")]),
        event(11, "approvalRequested", ["approvalID": .string("a2"), "tool": .string("shell_run"), "arguments": .string("{}")]),
        event(12, TaskEvent.stateKind, ["state": .string(TaskState.waitingForApproval.rawValue)]),
    ]

    func reopened(_ events: [TaskEvent]) -> ChatRecord {
        var record = ChatRecord(summary: ChatSummary(title: "Run", lastInteraction: Date()))
        record.task = TaskHandle(taskID: .make(), kind: .agent)
        record.events = events
        record.reopen(as: TaskHandle(taskID: .make(), kind: .agent))
        return record
    }

    func pending(_ record: ChatRecord) -> [String] {
        let transcript = ChatTranscript(events: record.events) { _ in nil }
        return transcript.messages.filter(\.role.needsApproval).compactMap { transcript.approvalIDs[$0.id] }
    }

    // Read in one batch, in several, and one event at a time.
    for size in [replay.count + next.count, 3, 1] {
        var record = reopened(history)
        let all = replay + next
        var taken: [TaskEvent] = []
        for start in stride(from: 0, to: all.count, by: size) {
            taken += record.take(Array(all[start ..< min(start + size, all.count)]))
        }
        precondition(taken == [replay[5]] + next, "the dead approval's resolution is taken, the rest of the replay read past")
        precondition(record.events == history + [replay[5]] + next && record.replay == nil)
        precondition(pending(record) == ["a2"], "so the card is the new turn's approval, not the dead one")
        let transcript = ChatTranscript(events: record.events) { _ in nil }
        let dead = transcript.messages.flatMap(\.trace).first { transcript.approvalIDs[$0.id] == "a1" }
        precondition(dead?.role == .approval(.deny), "which shows in the trace as denied")
    }

    // A replay that is all the conversation has seen ends at nothing: the
    // dead approval is resolved before any new message comes.
    var quiet = reopened(history)
    precondition(quiet.take(replay) == [replay[5]] && quiet.replay != nil, "taken while the replay goes on")
    precondition(pending(quiet).isEmpty, "and nothing is left to answer")
    precondition(quiet.take([next[0]]) == [next[0]] && quiet.replay == nil, "the first new message ends the replay")

    // An approval the conversation saw resolved is replayed like the rest:
    // never taken twice.
    let answered = history.prefix(5) + [event(6, "approvalResolved", deny), event(7, TaskEvent.stateKind, [
        "state": .string(TaskState.running.rawValue),
    ])]
    var settled = reopened(Array(answered))
    precondition(settled.take(Array(answered)).isEmpty && settled.events == Array(answered), "its resolution is read past")

    // A conversation the bug left stuck heals on its next reopen: the log
    // holds both resolutions, and the replay brings them again.
    var stuck = reopened(history + next)
    let again = replay + next + [
        event(13, "approvalResolved", ["approvalID": .string("a2"), "decision": .string("deny")]),
        event(14, TaskEvent.stateKind, ["state": .string(TaskState.running.rawValue)]),
    ]
    precondition(stuck.take(again) == [replay[5], again[12]], "both dead approvals are taken")
    precondition(pending(stuck).isEmpty && stuck.replay != nil, "and nothing is left to answer")
    print("ok: an approval the stopped host left waiting is resolved by the reopened session's replay")
}
