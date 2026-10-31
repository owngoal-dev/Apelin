import ApelinProtocol
import Foundation

/// A conversation becomes unread when a reply comes while the reader is
/// not looking at it, never from a reopened session's replay, the reader's
/// own message or news that is no reply; looking at it or writing in it
/// reads it. The sidebar's dot and the project menu's counts show it once
/// the conversation is at rest, and the field survives a save and reads as
/// read in a file written before it (`ChatUnread`).
func checkChatUnread() throws {
    let asked = UUID()
    let prompt = event(1, "prompt", ["id": .string(asked.uuidString), "text": .string("Build it")])
    let turn = [
        prompt,
        event(2, "messageStarted"), event(3, "text", ["text": .string("Building")]),
        event(4, "message", ["text": .string("Built and installed.")]),
        event(5, "finished", ["reason": .string("completed")]),
    ]

    // What counts as a reply.
    precondition(ChatUnread.isReply(event(1, "message", ["text": .string("Done")])), "an assistant message with text")
    precondition(!ChatUnread.isReply(event(1, "message", ["text": .string(" \n")])), "a message with no text, as a call's is")
    precondition(ChatUnread.isReply(event(1, "error", ["message": .string("The provider stopped")])), "an error")
    precondition(ChatUnread.isReply(event(1, "approvalRequested", ["approvalID": .string("a1")])), "an approval asked")
    precondition(ChatUnread.isReply(event(1, "finished", ["reason": .string("failed")])), "a turn that failed")
    precondition(ChatUnread.isReply(event(1, "finished")), "a turn's end")
    precondition(!ChatUnread.isReply(event(1, "finished", ["reason": .string("aborted")])), "a turn the reader stopped")
    let news = [
        "prompt", "steer", "queued", "title", "received", "text", "thinking",
        "toolCall", "toolResult", "messageStarted", TaskEvent.stateKind,
    ]
    for kind in news {
        precondition(!ChatUnread.isReply(event(1, kind, ["text": .string("words")])), "\(kind) is no reply")
    }

    func record() -> ChatRecord {
        var record = ChatRecord(summary: ChatSummary(title: "Build", lastInteraction: Date(), projectName: "Clock"))
        record.task = TaskHandle(taskID: .make(), kind: .agent)
        return record
    }

    // A reply while another conversation is shown marks it; while it is
    // looked at, nothing.
    var away = record()
    let fresh = away.take(turn)
    precondition(away.summary.noteReplies(in: fresh, isViewed: false), "a reply while another is shown")
    precondition(away.summary.isUnread && away.summary.showsUnread, "unread, and at rest it shows")
    precondition(!away.summary.noteReplies(in: fresh, isViewed: false), "already unread: no change")
    var viewed = record()
    precondition(!viewed.summary.noteReplies(in: viewed.take(turn), isViewed: true), "a reply while it is looked at")
    precondition(!viewed.summary.isUnread)
    var asking = record()
    let own = asking.take([prompt, event(2, "title", ["text": .string("Build")])])
    precondition(!asking.summary.noteReplies(in: own, isViewed: false), "the reader's own message and a title")

    // Looking at it reads it; so does writing in it.
    precondition(away.summary.markRead() && !away.summary.isUnread, "looked at: read")
    precondition(!away.summary.markRead(), "read already")
    var written = record()
    written.summary.noteReplies(in: written.take(turn), isViewed: false)
    written.submit(ComposerDraft(text: "And again"))
    precondition(!written.summary.isUnread, "a conversation the reader writes in is read")

    // A reopened session replays the history first: nothing in it marks the
    // conversation, and the reply after it does.
    var reopened = record()
    _ = reopened.take(turn)
    reopened.reopen(as: TaskHandle(taskID: .make(), kind: .agent))
    let replayed = reopened.take(turn)
    precondition(replayed.isEmpty, "the replay is read past")
    precondition(!reopened.summary.noteReplies(in: replayed, isViewed: false), "a replayed reopen marks nothing")
    let again = UUID()
    let next = reopened.take([
        event(6, "prompt", ["id": .string(again.uuidString), "text": .string("Once more")]),
        event(7, "message", ["text": .string("Done again.")]),
    ])
    precondition(next.count == 2 && reopened.summary.noteReplies(in: next, isViewed: false), "what follows the replay counts")

    // Working wins: the dot shows once the run is at rest.
    var running = record()
    running.summary.isWorking = true
    running.summary.noteReplies(in: running.take(Array(turn.prefix(4))), isViewed: false)
    precondition(running.summary.isUnread && !running.summary.showsUnread, "unread while it works shows its spinner")
    running.summary.isWorking = false
    precondition(running.summary.showsUnread, "at rest, the dot")

    // The project menu counts the conversations that show the dot.
    func chat(_ project: String?, unread: Bool, working: Bool = false) -> ChatSummary {
        var summary = ChatSummary(title: "", lastInteraction: Date(), projectName: project)
        summary.isUnread = unread
        summary.isWorking = working
        return summary
    }
    let counts = ChatUnread.Counts([
        chat("Pineora", unread: true), chat("Pineora", unread: true), chat("Pineora", unread: true),
        chat("Pineora", unread: false), chat("Pineora", unread: true, working: true),
        chat("Clock", unread: true), chat("Dock", unread: false),
        chat(nil, unread: true), chat(nil, unread: false),
    ])
    precondition(counts.projects == ["Pineora": 3, "Clock": 1], "conversations, not messages or runs: \(counts.projects)")
    precondition(counts.general == 1, "General Chat's temporary conversations")
    precondition(counts.total(of: ["Clock", "Dock", "Gone"]) == 1, "a submenu sums its projects")
    precondition(ChatUnread.menuTitle("Pineora", unread: 3) == "Pineora - 3", ChatUnread.menuTitle("Pineora", unread: 3))
    precondition(ChatUnread.menuTitle("Pineora", unread: 0) == "Pineora", "none: the name alone, never - 0")

    // Saved with the conversation, and absent from older files.
    var saved = record()
    saved.summary.isUnread = true
    let decoded = try JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(saved))
    precondition(decoded.summary.isUnread, "unread survives a save")
    let readBack = try JSONDecoder().decode(ChatSummary.self, from: JSONEncoder().encode(chat("Clock", unread: false)))
    precondition(!readBack.isUnread, "and read does too")
    let older = Data("""
    {"id":"\(UUID().uuidString)","title":"Alarm","updated":0,"projectName":"Clock","isPinned":false,"isWorking":false}
    """.utf8)
    let olderSummary = try JSONDecoder().decode(ChatSummary.self, from: older)
    precondition(!olderSummary.isUnread, "a file from before reads as read")
    print("ok: a reply the reader has not seen marks its conversation unread, looking or writing reads it, and the menu counts them")
}
