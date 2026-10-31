import ApelinCore
import ApelinProtocol
import Foundation

func event(_ seq: UInt64, _ kind: String, _ values: [String: JSONValue] = [:]) -> TaskEvent {
    TaskEvent(seq: EventSeq(seq), kind: kind, time: Date(timeIntervalSince1970: Double(seq)), payload: .object(values))
}

let userID = UUID()
let events = [
    event(1, "prompt", ["id": .string(userID.uuidString), "text": .string("Make a change")]),
    event(2, "messageStarted"), event(3, "thinking", ["text": .string("A supplied reasoning summary")]),
    event(4, "toolCall", ["id": .string("t1"), "tool": .string("file_read"), "arguments": .string("{\"path\":\"README.md\"}")]),
    event(5, "toolResult", ["id": .string("t1"), "output": .string("file content")]),
    event(6, "approvalRequested", ["approvalID": .string("a1"), "tool": .string("shell_run"), "arguments": .string("{}")]),
    event(7, "approvalResolved", ["approvalID": .string("a1"), "decision": .string("deny")]),
    event(8, "messageStarted"), event(9, "text", ["text": .string("Partial")]),
    event(10, "message", ["text": .string("Final text")]), event(11, "finished"),
]
let transcript = ChatTranscript(events: events) { _ in nil }
precondition(!transcript.isWorking)
precondition(transcript.messages.first?.id == userID)
precondition(transcript.messages.filter { $0.role == .assistant }.map(\.text) == ["Final text"])
precondition(!transcript.messages.contains { $0.role == .tool })
precondition(!transcript.messages.contains { $0.role.isApproval })
precondition(transcript.messages.flatMap(\.trace).first { $0.role.isApproval }?.role == .approval(.deny))
precondition(transcript.messages.contains { $0.role == .thinking(seconds: 3, tools: 1) })
precondition(transcript.messages.map(\.id) == ChatTranscript(events: events) { _ in nil }.messages.map(\.id))
precondition(ChatTranscript(events: Array(events.prefix(6))) { _ in nil }.messages.contains { $0.role.needsApproval })
precondition(ChatTranscript(events: Array(events.prefix(9))) { _ in nil }.isWorking)
let toolLoop = [
    event(1, "messageStarted"), event(2, "thinking", ["text": .string("First thought")]),
    event(3, "toolCall", ["id": .string("t1"), "tool": .string("file_list")]),
    event(4, "toolResult", ["id": .string("t1")]), event(4, "message", ["text": .string("")]),
    event(5, "messageStarted"), event(6, "thinking", ["text": .string("Second thought")]),
    event(7, "toolCall", ["id": .string("t2"), "tool": .string("file_read")]),
    event(8, "messageStarted"), event(9, "message", ["text": .string("Answer")]), event(10, "finished"),
]
let combined = ChatTranscript(events: toolLoop) { _ in nil }.messages
precondition(combined.count == 2)
precondition(combined[0].role == .thinking(seconds: 5, tools: 2))
precondition(combined[0].text == "First thought\n\nSecond thought")
precondition(combined[0].trace.filter { $0.role == .tool }.count == 2)
precondition(combined[0].trace.first { $0.role == .tool }?.detail != nil)
precondition(combined[1].role == .assistant && combined[1].text == "Answer")
print("ok: chat replay, streaming replacement, hidden tools, alternating thought summaries, approval decisions and stable identities")

let noThought = ChatTranscript(events: [event(1, "messageStarted"), event(2, "message", ["text": .string("Answer")]), event(3, "finished")]) { _ in nil }
precondition(noThought.messages.count == 1 && noThought.messages[0].role == .assistant, "An empty model start is not a completed thought")
let fastThought = ChatTranscript(events: [
    TaskEvent(seq: EventSeq(1), kind: "messageStarted", time: Date(timeIntervalSince1970: 1)),
    TaskEvent(seq: EventSeq(2), kind: "thinking", time: Date(timeIntervalSince1970: 1.1), payload: .object(["text": .string("Reasoning")])),
    TaskEvent(seq: EventSeq(3), kind: "message", time: Date(timeIntervalSince1970: 1.2), payload: .object(["text": .string("Answer")])),
    event(4, "finished"),
]) { _ in nil }
precondition(fastThought.messages.count == 1 && fastThought.messages[0].role == .assistant, "Zero-second, zero-tool summaries are hidden")
precondition(!fastThought.isWorking)
let orphanTool = ChatTranscript(events: [event(1, "toolCall", ["id": .string("tool"), "tool": .string("file_list")]), event(2, "finished")]) { _ in nil }
precondition(orphanTool.messages[0].role == .thinking(seconds: 0, tools: 1), "A tool without supplied thinking still counts once")
let notified = ChatTranscript(events: [
    event(1, "toolCall", ["id": .string("n1"), "tool": .string("apelin_notification_send"), "arguments": .string("{\"body\":\"Built.\"}")]),
    event(2, "notice", ["body": .string("Built.")]),
    event(3, "toolResult", ["id": .string("n1"), "output": .string("Sent to Apelin as a notification.")]),
    event(4, "finished"),
]) { _ in nil }.messages
precondition(notified.count == 1 && notified[0].trace.map(\.text) == ["Send a notification"],
             "a notice shows only as its call, named in the trace: \(notified.flatMap(\.trace).map(\.text))")
/// A file the agent shows is an assistant row of its result's attachments,
/// shown as any attachment is: a PDF as a document card.
let shownFiles = ChatTranscript(events: [
    event(1, "prompt", ["text": .string("Let me see the notes")]),
    event(2, "toolCall", ["id": .string("s1"), "tool": .string("file_show"), "arguments": .string("{\"paths\":[\"Docs/notes.pdf\"]}")]),
    event(3, "toolResult", ["id": .string("s1"), "output": .string("Shown to the user in this conversation: Docs/notes.pdf."), "attachments": .array([
        .object(["path": .string("Attachments/0f1e"), "name": .string("notes.pdf"), "mimeType": .string("application/pdf")]),
    ])]),
    event(4, "toolCall", ["id": .string("s2"), "tool": .string("file_show"), "arguments": .string("{\"paths\":[\"a.png\",\"b.log\"]}")]),
    event(5, "toolCall", ["id": .string("s3"), "tool": .string("file_show"), "arguments": .string("{}")]),
    event(6, "message", ["text": .string("There they are.")]),
    event(7, "finished"),
]) { item in
    ComposerAttachment(name: item.name, data: Data(item.path.utf8), isImage: item.mimeType.hasPrefix("image/"))
}.messages
precondition(shownFiles.contains { $0.role == .assistant && $0.attachments.map(\.name) == ["notes.pdf"] && !$0.attachments[0].isImage },
             "a shown PDF is a document attachment of the reply: \(shownFiles.map(\.attachments))")
precondition(shownFiles.flatMap(\.trace).filter { $0.role == .tool }.map(\.text) == ["Show Docs/notes.pdf", "Show 2 files", "Show a file"],
             "\(shownFiles.flatMap(\.trace).map(\.text))")
print("ok: empty thoughts, subsecond reasoning, standalone tools, shown files and ended turns")

/// The approval card shows what the decision is bound to: why the gate
/// asked, a changed description's diff, then the arguments read by name
/// (through `ToolCallDetail`, as the trace sheet reads them).
let installApproval = ChatTranscript(events: [
    event(1, "prompt", ["text": .string("Install it")]),
    event(2, "approvalRequested", [
        "approvalID": .string("a2"), "tool": .string("apelin_package_install"), "arguments": .string("{\"artifact_id\":\"x\"}"),
        "reason": .string("the packaging description changed since the template or the last approval"),
        "detail": .object(["descriptionChanged": .object([
            "kind": .string("packaging"), "digest": .string("d"), "diff": .string("+postinst"),
        ])]),
    ]),
]) { _ in nil }.messages.first { $0.role.needsApproval }
precondition(installApproval?.approvalTitle == "Install the package")
let approvalDetail = installApproval?.approvalDetail ?? ""
let detailPositions = ["the packaging description changed", "+postinst", "artifact_id"]
    .compactMap { approvalDetail.range(of: $0)?.lowerBound }
precondition(
    detailPositions.count == 3 && detailPositions == detailPositions.sorted()
        && !approvalDetail.contains("{\"artifact_id\""),
    "the card names the reason, the diff, then the arguments by name, not as raw JSON: \(approvalDetail)",
)
print("ok: an approval card carries the reason and the description diff before the arguments")

/// A publication's card shows what it is bound to, the repository and each
/// package with its digest, rather than the build IDs the call named.
let publishApproval = ChatTranscript(events: [
    event(1, "prompt", ["text": .string("Publish both")]),
    event(2, "approvalRequested", [
        "approvalID": .string("p1"), "tool": .string("apelin_package_publish"),
        "arguments": .string("{\"build_ids\":[\"b-hide\",\"b-less\"]}"),
        "reason": .string("Publishes these 2 packages to your package repository someone/packages on GitHub."),
        "detail": .object(["packagePublish": .object([
            "repository": .string("someone/packages"),
            "packages": .array([
                .object(["packageID": .string("com.example.clock"), "version": .string("1.0"),
                         "architecture": .string("iphoneos-arm64e"), "digest": .string("sha256:aa")]),
                .object(["packageID": .string("com.example.clock"), "version": .string("1.0"),
                         "architecture": .string("iphoneos-arm64"), "digest": .string("sha256:bb")]),
            ]),
        ])]),
    ]),
]) { _ in nil }.messages.first { $0.role.needsApproval }
precondition(publishApproval?.approvalTitle == "Publish to the package repository")
let publishDetail = publishApproval?.approvalDetail ?? ""
precondition(
    publishDetail.contains("repository\nsomeone/packages")
        && publishDetail.contains("com.example.clock 1.0 (iphoneos-arm64e)\nsha256:aa")
        && publishDetail.contains("com.example.clock 1.0 (iphoneos-arm64)\nsha256:bb")
        && !publishDetail.contains("b-hide"),
    "the card names the repository and each package's digest, not the build IDs: \(publishDetail)",
)
print("ok: a publication's card names the repository and every package's digest")

/// A feedback edit's card shows what it is bound to: the repository, the
/// issue and the new text in full, not the revision the call named, and
/// no title when only the body changes.
let feedbackEditApproval = ChatTranscript(events: [
    event(1, "prompt", ["text": .string("Broaden #12")]),
    event(2, "approvalRequested", [
        "approvalID": .string("e1"), "tool": .string("apelin_feedback_edit"),
        "arguments": .string("{\"body\":\"It ends early on both bootstraps.\",\"number\":12,\"revision\":\"0123abcd\"}"),
        "reason": .string("Replaces the body of issue #12 on owngoal-dev/Apelin."),
        "detail": .object(["feedbackEdit": .object([
            "repository": .string("owngoal-dev/Apelin"), "number": .number(12),
            "url": .string("https://github.com/owngoal-dev/Apelin/issues/12"),
            "body": .string("It ends early on both bootstraps."),
            "currentTitle": .string("The build log stops early"), "currentBody": .string("It ends early."),
        ])]),
    ]),
]) { _ in nil }.messages.first { $0.role.needsApproval }
precondition(feedbackEditApproval?.approvalTitle == "Edit a feedback issue")
let feedbackEditDetail = feedbackEditApproval?.approvalDetail ?? ""
precondition(
    feedbackEditDetail.contains("repository\nowngoal-dev/Apelin") && feedbackEditDetail.contains("issue\n#12")
        && feedbackEditDetail.contains("body\nIt ends early on both bootstraps.")
        && !feedbackEditDetail.contains("0123abcd") && !feedbackEditDetail.contains("title\n")
        && !feedbackEditDetail.contains("It ends early."),
    "the card names the issue and the new body, not the revision or what it replaces: \(feedbackEditDetail)",
)
print("ok: a feedback edit's card names the issue and the whole new text")

/// A command that runs as root marks its card (`runsAsRoot`). The card says
/// the root sentence once (the red line; the gate's own sentence is left
/// out), why the agent made the call first, then the command as the line the
/// reader would type, with no `root` row: what they read before Face ID.
let rootGateReason = "Runs as root, with full control of this device. Each command that runs as root needs your approval."
let rootApproval = ChatTranscript(events: [
    event(1, "prompt", ["text": .string("Install the dependency")]),
    event(2, "toolCall", ["id": .string("c1"), "tool": .string("shell_run"),
                          "arguments": .string("{\"argv\":[\"id\",\"-u\"],\"reason\":\"以 root 身份运行 id -u 查看 uid\",\"root\":true}")]),
    event(3, "approvalRequested", [
        "approvalID": .string("r1"), "toolCallID": .string("c1"), "tool": .string("shell_run"),
        "arguments": .string("{\"argv\":[\"id\",\"-u\"],\"root\":true}"),
        "reason": .string(rootGateReason),
        "detail": .object(["rootCommand": .object([
            "argv": .object(["_0": .array([.string("id"), .string("-u")])]),
        ])]),
    ]),
]) { _ in nil }.messages.first { $0.role.needsApproval }
let rootDetail = rootApproval?.approvalDetail ?? ""
precondition(rootApproval?.runsAsRoot == true, "a root command's card is marked")
precondition(!rootDetail.contains("Runs as root"), "the root sentence is said once, by the red line: \(rootDetail)")
precondition(rootDetail.hasPrefix("以 root 身份运行 id -u 查看 uid"), "the agent's reason comes first: \(rootDetail)")
precondition(rootDetail.contains("argv\nid -u"), "the command reads as its command line: \(rootDetail)")
precondition(!rootDetail.contains("[\"id\""), "not as a JSON array: \(rootDetail)")
precondition(!rootDetail.contains("root\ntrue"), "and no root row, the red line says it: \(rootDetail)")

/// An ordinary command's card keeps the gate's sentence, and gets the
/// agent's reason and the command line too.
let shellGateReason = "This command is not in your approved presets. Review it before running."
let plainShell = ChatTranscript(events: [
    event(1, "prompt", ["text": .string("x")]),
    event(2, "toolCall", ["id": .string("c2"), "tool": .string("shell_run"),
                          "arguments": .string("{\"argv\":[\"make\",\"-C\",\"My Tweak\"],\"reason\":\"Build the tweak\"}")]),
    event(3, "approvalRequested", [
        "approvalID": .string("s1"), "toolCallID": .string("c2"), "tool": .string("shell_run"),
        "arguments": .string("{\"argv\":[\"make\",\"-C\",\"My Tweak\"]}"),
        "reason": .string(shellGateReason),
        "detail": .object(["command": .object(["argv": .object(["_0": .array([
            .string("make"), .string("-C"), .string("My Tweak"),
        ])])])]),
    ]),
]) { _ in nil }.messages.first { $0.role.needsApproval }
let shellDetail = plainShell?.approvalDetail ?? ""
precondition(plainShell?.runsAsRoot == false, "an ordinary command's card is not marked as root")
let shellPositions = ["Build the tweak", shellGateReason, "make -C 'My Tweak'"].compactMap { shellDetail.range(of: $0)?.lowerBound }
precondition(
    shellPositions.count == 3 && shellPositions == shellPositions.sorted(),
    "the agent's reason, the gate's, then the command line: \(shellDetail)",
)

/// The card shows the command and directory the approval is bound to, the
/// request's `detail.rootCommand` and `workingDirectory`, even where the
/// call's arguments say otherwise.
let mismatched = ChatTranscript(events: [
    event(1, "prompt", ["text": .string("x")]),
    event(2, "approvalRequested", [
        "approvalID": .string("m1"), "tool": .string("shell_run"), "workingDirectory": .string("Sources"),
        "arguments": .string("{\"argv\":[\"id\",\"-u\"],\"cwd\":\".\",\"root\":true}"),
        "detail": .object(["rootCommand": .object(["argv": .object(["_0": .array([
            .string("rm"), .string("-rf"), .string("/var/mobile"),
        ])])])]),
    ]),
]) { _ in nil }.messages.first { $0.role.needsApproval }
let mismatchedDetail = mismatched?.approvalDetail ?? ""
precondition(
    mismatchedDetail.contains("argv\nrm -rf /var/mobile") && !mismatchedDetail.contains("id -u"),
    "the bound command is shown, not the arguments' own: \(mismatchedDetail)",
)
precondition(mismatchedDetail.contains("cwd\nSources"), "in the bound directory: \(mismatchedDetail)")

/// The command line is display only and never ambiguous: each distinct argv
/// reads differently, whatever its words hold.
let argvs: [[String]] = [
    ["id", "-u"], ["id -u"], ["id", "", "-u"], ["id", " -u"], ["a'b"], ["a\\'b"], ["*"], ["\\*"],
    ["a\tb"], ["a b"], ["a\nb"], ["a\u{200B}b"], ["ab"], ["a\u{00A0}b"], ["~"], ["$HOME"], ["'$HOME'"],
    [""], ["", ""], ["x=1", "id"], ["x=1 id"],
]
let lines = argvs.map(CommandLineText.quoted)
precondition(Set(lines).count == argvs.count, "two argvs read the same: \(lines)")
precondition(CommandLineText.quoted(["id", "-u"]) == "id -u")
precondition(CommandLineText.quoted(["make", "-C", "My Tweak"]) == "make -C 'My Tweak'")
precondition(CommandLineText.quoted([""]) == "''", "an empty word is shown")
precondition(CommandLineText.quoted(["it's"]) == #"'it'\''s'"#)
precondition(CommandLineText.quoted(["*.m"]) == "'*.m'", "a glob is quoted")
precondition(CommandLineText.quoted(["a\u{200B}b"]) == "$'a\\u200Bb'", "a character that does not show is escaped")
precondition(CommandLineText.quoted(["a\nb"]) == #"$'a\nb'"#)
print("ok: a root command's card is marked and shows the command")

let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-chat-store-\(UUID())")
try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: storageURL) }
let storage = ChatStore(folder: DataFolder(root: storageURL))
let record = ChatRecord(summary: ChatSummary(title: "Deletion regression", lastInteraction: Date()))
try await storage.save(record, revision: 1)
let savedRecords = try await storage.load()
precondition(savedRecords.count == 1, "A chat saved through the temporary-directory alias must load")
try await storage.remove(record.summary.id)
try await storage.save(record, revision: 2)
let deletedRecords = try await storage.load()
precondition(deletedRecords.isEmpty, "A queued save must not resurrect a deleted chat")
let unsaved = ChatRecord(summary: ChatSummary(title: "Unsaved", lastInteraction: Date()))
try await storage.remove(unsaved.summary.id)
try await storage.save(unsaved, revision: 3)
let unsavedRecords = try await storage.load()
precondition(unsavedRecords.isEmpty, "Deleting before the first save must also prevent resurrection")
let retryURL = storageURL.appendingPathComponent("retry")
try FileManager.default.createDirectory(at: retryURL, withIntermediateDirectories: false)
let obstruction = retryURL.appendingPathComponent("Chats")
try Data().write(to: obstruction)
let retryStore = ChatStore(folder: DataFolder(root: retryURL))
do {
    try await retryStore.save(record, revision: 1)
    preconditionFailure("Saving through a file must fail")
} catch {}
try FileManager.default.removeItem(at: obstruction)
try await retryStore.save(record, revision: 1)
let retriedRecords = try await retryStore.load()
precondition(retriedRecords.count == 1, "A failed save must allow retrying the same revision")
print("ok: chat deletion before/after saving, queued-save suppression and failed-save retry")

func activityTitle(_ seconds: Int?, _ tools: Int) -> String {
    ChatMessage(role: .thinking(seconds: seconds, tools: tools), text: "").activityTitle
}

precondition(activityTitle(0, 0).isEmpty)
precondition(activityTitle(0, 1) == "Called 1 tool")
precondition(activityTitle(0, 3) == "Called 3 tools")
precondition(activityTitle(2, 0) == "Thought for 2 seconds")
precondition(activityTitle(1, 2) == "Thought for 1 second and called 2 tools")
precondition(activityTitle(nil, 0) == "Thinking…")
print("ok: activity summary shows only positive duration and tool counts")

/// While the turn runs, the trailing summary stays unfinished across tool
/// calls and carries the output the run has received, from its latest
/// `received`; a run that has ended, or sent none, has no count.
func received(_ seq: UInt64, _ tokens: Double) -> TaskEvent {
    event(seq, "received", ["tokens": .number(tokens)])
}

let running = [
    event(1, "prompt", ["text": .string("Change the hook")]),
    event(2, "messageStarted"), event(3, "thinking", ["text": .string("Look at the hook")]),
    received(4, 12),
    event(5, "toolCall", ["id": .string("t1"), "tool": .string("file_edit"),
                          "arguments": .string("{\"reason\":\"Turn the hook on\",\"path\":\"Sources/Tweak.x\"}")]),
    received(6, 1234),
]
let calling = ChatTranscript(events: running) { _ in nil }.messages.last
precondition(calling?.role == .thinking(seconds: nil, tools: 1))
precondition(calling?.receivedTokens == 1234, "the latest count")
let patched = running + [event(7, "toolResult", ["id": .string("t1"), "output": .string("Patched Sources/Tweak.x (1 replacement, +3 -1)")])]
precondition(ChatTranscript(events: patched) { _ in nil }.messages.last?.receivedTokens == 1234, "kept across a call's result")
let ended = ChatTranscript(events: patched + [event(8, "finished")]) { _ in nil }.messages.last
precondition(ended?.role.isThinking == false && ended?.receivedTokens == nil)
let nextRun = patched + [event(8, "finished"), event(9, "prompt", ["text": .string("Again")]), event(10, "messageStarted")]
precondition(ChatTranscript(events: nextRun) { _ in nil }.messages.last?.receivedTokens == nil, "a new run counts afresh")
precondition(ChatTranscript(events: nextRun + [received(11, 3)]) { _ in nil }.messages.last?.receivedTokens == 3)
precondition(ChatTranscript(events: Array(running.prefix(3))) { _ in nil }.messages.last?.receivedTokens == nil,
             "an older session sends no count")
precondition(ChatTranscript(events: running) { _ in nil }.messages.map(\.id)
    == ChatTranscript(events: running.filter { $0.kind != "received" }) { _ in nil }.messages.map(\.id),
    "a count adds no row")
print("ok: a running summary stays running across calls and carries the run's received tokens")

/// Once the reply after it has begun, the summary is finished and keeps the
/// run's count, settling, until the run ends; a turn that replies without a
/// summary of its own leaves the last turn's summary without one.
let replying = patched + [
    event(8, "messageStarted"), event(9, "text", ["text": .string("Done: the hook is on.")]),
    received(10, 1400),
]
let settlingRows = ChatTranscript(events: replying) { _ in nil }.messages
precondition(settlingRows.last?.role == .assistant, "the reply is the last row")
let summaryAbove = settlingRows[settlingRows.count - 2]
precondition(!summaryAbove.role.isThinking && summaryAbove.receivedTokens == 1400 && summaryAbove.receivedSettles,
             "the summary above the reply keeps the count, settling")
precondition(!ChatTranscript(events: running) { _ in nil }.messages.contains(where: \.receivedSettles),
             "a running summary does not settle")
let endedReply = ChatTranscript(events: replying + [event(11, "message", ["text": .string("Done: the hook is on.")]),
                                                    event(12, "finished")]) { _ in nil }.messages
precondition(endedReply.allSatisfy { $0.receivedTokens == nil && !$0.receivedSettles }, "an ended run has no count")
let directReply = replying + [
    event(11, "message", ["text": .string("Done: the hook is on.")]), event(12, "finished"),
    event(13, "prompt", ["text": .string("Thanks")]), event(14, "messageStarted"),
    event(15, "text", ["text": .string("You're welcome.")]), received(16, 5),
]
precondition(ChatTranscript(events: directReply) { _ in nil }.messages.allSatisfy { $0.receivedTokens == nil },
             "no count goes above the turn's own message")
print("ok: the count stays, settling, on the summary above the reply the run is writing")

/// The line under a running summary is its newest call: the reason the agent
/// gave, a file edit's name and, once its result is in, the lines it added
/// and removed. Thinking after a call leaves the call there; nothing of the
/// thinking shows.
func call(_ seq: UInt64, _ id: String, _ tool: String, _ arguments: String) -> TaskEvent {
    event(seq, "toolCall", ["id": .string(id), "tool": .string(tool), "arguments": .string(arguments)])
}

func result(_ seq: UInt64, _ id: String, _ output: String, isError: Bool = false) -> TaskEvent {
    event(seq, "toolResult", ["id": .string(id), "output": .string(output), "isError": .bool(isError)])
}

func banner(_ events: [TaskEvent]) -> ToolCallBanner? {
    ChatTranscript(events: events) { _ in nil }.messages.last?.banner
}

let editing = [
    event(1, "prompt", ["text": .string("Change the hook")]),
    event(2, "messageStarted"), event(3, "thinking", ["text": .string("Look at the hook")]),
    call(4, "t1", "file_edit", "{\"reason\":\"Turn the hook on\",\"path\":\"Sources/Tweak.x\"}"),
]
precondition(banner(editing) == ToolCallBanner(reason: "Turn the hook on", file: "Tweak.x"), "the reason and the file, no counts yet")
let editedCall = editing + [result(5, "t1", "Patched Sources/Tweak.x (1 replacement, +3 -1)\n--- a/Sources/Tweak.x")]
precondition(banner(editedCall) == ToolCallBanner(reason: "Turn the hook on", file: "Tweak.x", change: .init(added: 3, removed: 1)))
precondition(banner(editing + [result(5, "t1", "Patched Sources/Tweak.x (1 replacement, +3 -1)", isError: true)])?.change == nil,
             "a failed call has no counts")
let thinkingAfter = editedCall + [event(6, "messageStarted"), event(7, "thinking", ["text": .string("Now build it")])]
precondition(banner(thinkingAfter)?.reason == "Turn the hook on", "thinking leaves the newest call in place")
let written = thinkingAfter + [
    call(8, "t2", "file_write", "{\"reason\":\"Add the preferences\",\"path\":\"Prefs/Root.plist\"}"),
    result(9, "t2", "Created Prefs/Root.plist (812 bytes, +24 -0)"),
]
precondition(banner(written) == ToolCallBanner(reason: "Add the preferences", file: "Root.plist", change: .init(added: 24, removed: 0)),
             "the newest call")
let buildCall = written + [call(10, "t3", "apelin_project_build", "{}")]
precondition(banner(buildCall) == ToolCallBanner(reason: "Build the project"), "a call without a reason shows its title, and no file")
let readWithPath = written + [call(10, "t3", "file_read", "{\"reason\":\"Check the hook\",\"path\":\"Sources/Tweak.x\"}")]
precondition(banner(readWithPath) == ToolCallBanner(reason: "Check the hook"), "only a file tool names its file")
let earlierName = Array(editing.prefix(3)) + [call(4, "t1", "patch_file", "{\"reason\":\"Turn the hook on\",\"path\":\"Sources/Tweak.x\"}")]
precondition(banner(earlierName) == banner(editing), "a call recorded under an earlier name names its file too")
precondition(banner(editedCall + [event(6, "finished")]) == nil, "a finished summary has no line")
precondition(banner(Array(editing.prefix(3))) == nil, "nor a running one before its first call")
precondition(ChatTranscript(events: editedCall) { _ in nil }.messages.count == 2, "the line adds no row")
precondition(ToolCallBanner.lineChange(in: "Replaced Tweak.x (40 bytes, +2 -2)") == .init(added: 2, removed: 2))
precondition(ToolCallBanner.lineChange(in: "Unable to patch Tweak.x") == nil)
precondition(ToolCallBanner.lineChange(in: "Patched Tweak.x (1 replacement)") == nil)
print("ok: a running summary's line is its newest call, with a file edit's name and counts")

/// kwwk gives up a reply the connection dropped halfway and asks for it
/// again: what it showed goes, the running summary says it is reconnecting
/// under the id it had, and the reply that follows is drawn once.
let askedID = UUID()
let cutOff = [
    event(1, "prompt", ["id": .string(askedID.uuidString), "text": .string("Explain the hook")]),
    event(2, "messageStarted"), event(3, "thinking", ["text": .string("It chains")]),
    event(4, "text", ["text": .string("The hook ch")]),
    event(5, "messageDiscarded"), event(6, "reconnecting"),
]
let answeringRows = ChatTranscript(events: Array(cutOff.prefix(2))) { _ in nil }.messages
let cutOffRows = ChatTranscript(events: cutOff) { _ in nil }.messages
precondition(cutOffRows.map(\.role) == [.user, .thinking(seconds: nil, tools: 0)], "the partial reply goes: \(cutOffRows)")
precondition(cutOffRows.last?.id == answeringRows.last?.id, "the summary keeps its id")
precondition(cutOffRows.last?.text.isEmpty == true, "and the given-up thought goes with it")
precondition(cutOffRows.last?.isReconnecting == true && cutOffRows.last?.activityTitle == "Reconnecting…")
let cutOffRetried = cutOff + [
    event(7, "messageStarted"), event(8, "text", ["text": .string("The hook chains to the original.")]),
    event(9, "message", ["text": .string("The hook chains to the original.")]), event(10, "finished"),
]
let retriedRunning = ChatTranscript(events: Array(cutOffRetried.prefix(7))) { _ in nil }.messages.last
precondition(retriedRunning?.id == answeringRows.last?.id && retriedRunning?.activityTitle == "Thinking…", "a new attempt ends it")
let retriedReplies = ChatTranscript(events: cutOffRetried) { _ in nil }.messages.filter { $0.role == .assistant }
precondition(retriedReplies.map(\.text) == ["The hook chains to the original."], "the reply is drawn once: \(retriedReplies.map(\.text))")
let callThenRetry = [
    event(1, "prompt", ["text": .string("Build it")]), event(2, "messageStarted"),
    event(3, "toolCall", ["id": .string("t1"), "tool": .string("apelin_project_build"), "arguments": .string("{}")]),
    event(4, "toolResult", ["id": .string("t1"), "output": .string("Built")]),
    event(5, "reconnecting"),
]
precondition(ChatTranscript(events: callThenRetry) { _ in nil }.messages.last?.activityTitle == "Reconnecting…")
precondition(ChatTranscript(events: callThenRetry + [event(6, "finished")]) { _ in nil }.messages.allSatisfy { !$0.isReconnecting },
             "nor once the run ends")
let beforeDiscard = ChatTranscript(events: Array(callThenRetry.prefix(4))) { _ in nil }.messages
let notStreaming = Array(callThenRetry.prefix(4)) + [event(5, "messageDiscarded")]
precondition(ChatTranscript(events: notStreaming) { _ in nil }.messages == beforeDiscard,
             "a discard takes back only a message still streaming")
print("ok: a reply given up halfway is taken back, and a request made again reads Reconnecting…")

/// A running turn that has shown a reply and then gone quiet for
/// `quietInterval` gets a running summary under the reply, under the id its
/// next thought takes, so that thought takes its place with no gap.
let replied = [
    event(1, "prompt", ["text": .string("Write the tweak")]),
    event(2, "messageStarted"), event(3, "text", ["text": .string("I'll write Tweak.x now.")]),
]
let replyAt = Date(timeIntervalSince1970: 3)
let stillStreaming = ChatTranscript(events: replied, now: replyAt.addingTimeInterval(1)) { _ in nil }
precondition(stillStreaming.messages.last?.role == .assistant, "not quiet yet")
precondition(stillStreaming.quietDeadline == replyAt.addingTimeInterval(ChatTranscript.quietInterval))
let quiet = ChatTranscript(events: replied, now: replyAt.addingTimeInterval(2)) { _ in nil }
let standIn = quiet.messages.last
precondition(standIn?.role == .thinking(seconds: nil, tools: 0) && standIn?.activityTitle == "Thinking…")
precondition(quiet.quietDeadline == nil, "nothing to wake for once it stands in")
precondition(ChatTranscript(events: replied) { _ in nil }.messages.last?.role == .assistant, "without a time, never")
for next in [
    [event(6, "toolCallPreparing")],
    [event(6, "messageStarted")],
    [event(6, "thinking", ["text": .string("Hooks first")])],
    [event(6, "toolCall", ["id": .string("t1"), "tool": .string("file_write"), "arguments": .string("{\"path\":\"Tweak.x\"}")])],
] {
    let resumed = ChatTranscript(events: replied + next, now: Date(timeIntervalSince1970: 6.5)) { _ in nil }.messages
    precondition(resumed.last?.id == standIn?.id && resumed.last?.role.isThinking == true,
                 "\(next[0].kind) takes the stand-in's place: \(resumed.map(\.role))")
    precondition(resumed.count == quiet.messages.count)
}

let moreText = replied + [event(6, "text", ["text": .string(" Hooking SpringBoard.")])]
let growing = ChatTranscript(events: moreText, now: Date(timeIntervalSince1970: 6.5)) { _ in nil }
precondition(growing.messages.last?.text == "I'll write Tweak.x now. Hooking SpringBoard.", "more of the reply ends it")
precondition(growing.quietDeadline == Date(timeIntervalSince1970: 6 + ChatTranscript.quietInterval))
let finishedReply = ChatTranscript(events: replied + [event(4, "finished")], now: Date(timeIntervalSince1970: 60)) { _ in nil }
precondition(finishedReply.messages.last?.role == .assistant && finishedReply.quietDeadline == nil, "an ended turn is not quiet")
let summaryShown = ChatTranscript(events: Array(running.prefix(3)), now: Date(timeIntervalSince1970: 60)) { _ in nil }
precondition(summaryShown.messages.count == 2 && summaryShown.quietDeadline == nil, "a running summary is sign enough")
let asking = [
    event(1, "prompt", ["text": .string("Install it")]), event(2, "messageStarted"),
    event(3, "message", ["text": .string("Installing.")]),
    event(4, "toolCall", ["id": .string("t1"), "tool": .string("apelin_package_install"), "arguments": .string("{}")]),
    event(5, "approvalRequested", ["approvalID": .string("a1"), "tool": .string("apelin_package_install"), "arguments": .string("{}")]),
]
let waitingForUser = ChatTranscript(events: asking, now: Date(timeIntervalSince1970: 60)) { _ in nil }
precondition(waitingForUser.messages.last?.role.needsApproval == true && waitingForUser.quietDeadline == nil,
             "a turn waiting for an approval waits for the reader")
let sentWhileQuiet = ChatTranscript(events: replied, sending: [ComposerDraft(text: "And a preference bundle")],
                                    now: Date(timeIntervalSince1970: 60)) { _ in nil }.messages
precondition(sentWhileQuiet.suffix(2).map(\.role) == [.thinking(seconds: nil, tools: 0), .user], "it stands in before a message on its way")
precondition(ChatTranscript(events: replied, now: Date(timeIntervalSince1970: 60)) { _ in nil }.messages.map(\.id)
    == quiet.messages.map(\.id), "rebuilt, it keeps its id")
print("ok: a quiet running turn shows a running summary under its reply, which its next step takes over")

/// Whether every summary, and every step in its trace, counts only the calls
/// in its own trace.
func countsOwnCalls(_ rows: [ChatMessage]) -> Bool {
    rows.allSatisfy { row in
        guard case let .thinking(_, tools) = row.role else { return true }
        return tools == row.trace.count(where: { $0.role == .tool }) && countsOwnCalls(row.trace)
    }
}

/// One model message's text is one row. The relay flushes the streamed text
/// before the call it starts writing, and the full text follows at the
/// message's end; the summary the call starts holds that call.
let textBeforeCall = [
    event(1, "prompt", ["text": .string("Build it")]),
    event(2, "messageStarted"), event(3, "text", ["text": .string("I'll build the release")]),
    event(4, "toolCallPreparing"),
    event(5, "message", ["text": .string("I'll build the release, install it and open it.")]),
    event(6, "toolCall", ["id": .string("t1"), "tool": .string("apelin_project_build"), "arguments": .string("{}")]),
]
let building = ChatTranscript(events: textBeforeCall) { _ in nil }.messages
precondition(building.filter { $0.role == .assistant }.map(\.text) == ["I'll build the release, install it and open it."], "One message's text is one row")
precondition(building.count == 3, "The prompt, the reply and the running call")
precondition(building.last?.role == .thinking(seconds: nil, tools: 1) && building.last?.runningTools == 1)
precondition(countsOwnCalls(building), "No summary counts a call outside its trace")
let built = ChatTranscript(events: textBeforeCall + [
    event(7, "toolResult", ["id": .string("t1"), "output": .string("Built")]),
    event(8, "messageStarted"), event(9, "message", ["text": .string("Done.")]), event(10, "finished"),
]) { _ in nil }.messages
precondition(built.filter { $0.role == .assistant }.map(\.text) == ["I'll build the release, install it and open it.", "Done."])
precondition(built.map(\.role) == [.user, .assistant, .thinking(seconds: 2, tools: 1), .assistant])
precondition(countsOwnCalls(built))
print("ok: a message's text before its call is one row, and the call is in the summary after it")

/// Summaries separated by a reply count their own calls, not the turn's.
let twoSummaries = [
    event(1, "prompt", ["text": .string("Turn the hook on and build")]),
    event(2, "messageStarted"), event(3, "thinking", ["text": .string("Read the hook first")]),
    event(4, "toolCall", ["id": .string("t1"), "tool": .string("file_read"), "arguments": .string("{\"path\":\"Tweak.x\"}")]),
    event(5, "toolResult", ["id": .string("t1"), "output": .string("%hook")]),
    event(6, "messageStarted"), event(7, "text", ["text": .string("The hook is off.")]), event(8, "toolCallPreparing"),
    event(9, "message", ["text": .string("The hook is off. Turning it on.")]),
    event(10, "toolCall", ["id": .string("t2"), "tool": .string("file_edit"), "arguments": .string("{\"path\":\"Tweak.x\"}")]),
    event(11, "toolResult", ["id": .string("t2"), "output": .string("Patched Tweak.x (1 replacement, +1 -1)")]),
    event(12, "messageStarted"), event(13, "toolCallPreparing"), event(14, "message", ["text": .string("")]),
    event(15, "toolCall", ["id": .string("t3"), "tool": .string("apelin_project_build"), "arguments": .string("{}")]),
    event(16, "toolResult", ["id": .string("t3"), "output": .string("Built")]),
    event(17, "messageStarted"), event(18, "message", ["text": .string("Built.")]), event(19, "finished"),
]
let summaries = ChatTranscript(events: twoSummaries) { _ in nil }.messages
precondition(summaries.map(\.role) == [.user, .thinking(seconds: 3, tools: 1), .assistant, .thinking(seconds: 4, tools: 2), .assistant], "Each summary counts its own calls")
precondition(summaries[2].text == "The hook is off. Turning it on.")
precondition(countsOwnCalls(summaries))
let stillBuilding = ChatTranscript(events: Array(twoSummaries.prefix(15))) { _ in nil }.messages.last
precondition(stillBuilding?.role == .thinking(seconds: nil, tools: 2) && stillBuilding?.runningTools == 1)
precondition(stillBuilding?.activityTitle == "Executing tool…")
print("ok: each summary counts only the calls in its own trace")

/// A message another conversation's agent sent names that conversation over
/// its bubble; the user's own has no such line.
let fromEvents = [
    event(1, "prompt", ["text": .string("Review Tweak.x"), "from": .string("opener-session")]),
    event(2, "prompt", ["text": .string("My own words")]),
    event(3, "prompt", ["text": .string("Unknown sender"), "from": .string("gone-session")]),
]
let fromTranscript = ChatTranscript(events: fromEvents, conversationTitle: { $0 == "opener-session" ? "Plan the tweak" : nil }) { _ in nil }
let users = fromTranscript.messages.filter { $0.role == .user }
precondition(users.map(\.sender) == ["From Plan the tweak", nil, "From another chat"])
precondition(ChatTranscript(events: fromEvents) { _ in nil }.messages.first?.sender == "From another chat")
print("ok: messages from other conversations name their sender")

// conversationOpened on an opener's task adopts the conversation into the
// opener's project, once; agentList adopts what the app missed.
let openerSession = UUID().uuidString.lowercased()
let childSession = UUID().uuidString.lowercased()
let opener = ChatRecord(summary: ChatSummary(title: "Plan", lastInteraction: Date(), projectName: "Clock"), sessionID: openerSession, task: TaskHandle(taskID: TaskID("opener-task"), kind: .agent))
let opened: JSONValue = .object([
    "sessionID": .string(childSession),
    "task": .object(["taskID": .string("child-task"), "kind": .string("agent")]),
    "title": .string("Docs"),
    "prompt": .string("Write the README\nand the changelog"),
])
let adopted = ChatAdoption.record(opened: opened, parent: opener, records: [opener], now: Date(timeIntervalSince1970: 7))
precondition(adopted?.sessionID == childSession && adopted?.task == TaskHandle(taskID: TaskID("child-task"), kind: .agent))
precondition(adopted?.summary.projectName == "Clock" && adopted?.summary.title == "Docs" && adopted?.summary.isWorking == true)
precondition(adopted?.summary.lastInteraction == Date(timeIntervalSince1970: 7) && adopted?.events.isEmpty == true)
precondition(ChatAdoption.record(opened: opened, parent: opener, records: [opener, adopted!]) == nil, "a conversation is adopted once")
var untitled = opened
if case var .object(fields) = untitled {
    fields["title"] = nil
    untitled = .object(fields)
}

precondition(ChatAdoption.record(opened: untitled, parent: opener, records: [opener])?.summary.title == "Write the README")
precondition(ChatAdoption.record(opened: .object(["sessionID": .string("not-a-uuid")]), parent: opener, records: [opener]) == nil)
let general = ChatRecord(summary: ChatSummary(title: "General", lastInteraction: Date(), projectName: nil), sessionID: openerSession)
precondition(ChatAdoption.record(opened: opened, parent: general, records: [general]) == nil, "a conversation naming no project is not adopted from General Chat")
/// One opened in another project, General Chat's or a project's, goes there.
var elsewhere = opened
if case var .object(fields) = elsewhere {
    fields["projectID"] = .string("6f1c5b0e-0000-4000-8000-00000000f00d")
    fields["projectName"] = .string("Far")
    elsewhere = .object(fields)
}

precondition(ChatAdoption.record(opened: elsewhere, parent: general, records: [general])?.summary.projectName == "Far", "General Chat's opens in a project are adopted there")
precondition(ChatAdoption.record(opened: elsewhere, parent: opener, records: [opener])?.summary.projectName == "Far", "and a project's opens in another one too")
precondition(ChatAdoption.title(" ", prompt: nil).isEmpty, "with neither a title nor a prompt it is untitled")

func listed(_ state: TaskState, parent: String?) -> AgentSessionSummary {
    AgentSessionSummary(sessionID: childSession, task: TaskHandle(taskID: TaskID("child-task"), kind: .agent), title: "Docs", state: state, updatedAt: Date(timeIntervalSince1970: 9), parentSessionID: parent)
}

let missed = ChatAdoption.record(session: listed(.running, parent: openerSession), records: [opener])
precondition(missed?.summary.projectName == "Clock" && missed?.summary.title == "Docs" && missed?.sessionID == childSession)
precondition(ChatAdoption.record(session: listed(.running, parent: openerSession), records: [opener, missed!]) == nil)
precondition(ChatAdoption.record(session: listed(.succeeded, parent: openerSession), records: [opener]) == nil, "an ended one is not adopted")
precondition(ChatAdoption.record(session: listed(.running, parent: nil), records: [opener]) == nil, "the app's own are not adopted")
precondition(ChatAdoption.record(session: listed(.running, parent: "unknown"), records: [opener]) == nil, "nor one whose opener has no record")
var listedElsewhere = listed(.running, parent: openerSession)
listedElsewhere.projectName = "Far"
precondition(ChatAdoption.record(session: listedElsewhere, records: [general])?.summary.projectName == "Far", "one General Chat opened is adopted into the project the host lists it in")
print("ok: conversations agents open are adopted once, into the project they were opened in")

// A sent message shows at once under its draft's id; the host's `prompt` or
// `queued` event with that id takes its place, one row each time.
let file = ComposerAttachment(name: "notes.md", data: Data("notes".utf8), text: "notes")
let sent = ComposerDraft(text: "Build it", attachments: [file])
let local = ChatTranscript(events: [], sending: [sent]) { _ in nil }
precondition(local.messages.map(\.id) == [sent.id] && local.messages[0].role == .user)
precondition(local.messages[0].text == "Build it" && local.messages[0].attachments == [file])
precondition(!local.messages[0].isQueued && !local.isWorking, "a local row does not start a turn")
let echoed = ChatTranscript(events: [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])], sending: [sent]) { _ in nil }
precondition(echoed.messages.filter { $0.id == sent.id }.count == 1 && echoed.messages[0].id == sent.id)
precondition(echoed.isWorking && echoed.messages.last?.role == .thinking(seconds: nil, tools: 0))
let busy = [event(1, "prompt", ["text": .string("Earlier")]), event(2, "messageStarted")]
let waiting = ChatTranscript(events: busy, sending: [sent]) { _ in nil }
precondition(waiting.messages.last?.id == sent.id && waiting.messages.last?.isQueued == true, "a running turn will queue it")
let queuedEcho = busy + [event(3, "queued", ["id": .string(sent.id.uuidString), "text": .string("Build it")])]
let hostQueued = ChatTranscript(events: queuedEcho, sending: [sent]) { _ in nil }
precondition(hostQueued.messages.filter { $0.id == sent.id }.count == 1)
precondition(hostQueued.messages.last?.id == sent.id && hostQueued.messages.last?.isQueued == true)
print("ok: a sent message shows at once and its prompt or queued echo replaces it")

var sendingRecord = ChatRecord(summary: ChatSummary(title: "Send", lastInteraction: Date()))
let second = ComposerDraft(text: "And test it")
sendingRecord.sending = [sent, second]
let taken = sendingRecord.takeEchoed(by: [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])])
precondition(taken.map(\.draft.id) == [sent.id] && sendingRecord.sending?.map(\.id) == [second.id])
_ = sendingRecord.takeEchoed(by: [event(2, "queued", ["id": .string(second.id.uuidString), "text": .string("And test it")])])
precondition(sendingRecord.sending == nil)

var failed = ChatRecord(summary: ChatSummary(title: "Failed", lastInteraction: Date()))
failed.sending = [sent]
precondition(failed.takeBack(sent) && failed.sending == nil, "a failed send leaves no row")
precondition(failed.draft.id == sent.id && failed.draft.text == "Build it" && failed.draft.attachments == [file])
precondition(ChatTranscript(events: failed.events, sending: failed.sending ?? []) { _ in nil }.messages.isEmpty)
var typedSince = ChatRecord(summary: ChatSummary(title: "Typed", lastInteraction: Date()))
typedSince.sending = [sent]
typedSince.draft = ComposerDraft(text: "Next")
precondition(!typedSince.takeBack(sent) && typedSince.draft.text == "Next" && typedSince.sending == nil, "what was typed since stays")
var recordedFirst = ChatRecord(summary: ChatSummary(title: "Recorded", lastInteraction: Date()))
recordedFirst.sending = [sent]
recordedFirst.events = [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])]
precondition(!recordedFirst.takeBack(sent) && recordedFirst.draft.text.isEmpty, "a message the host recorded is not put back")
print("ok: an echo settles its message and a failed send takes it back into an empty draft")

var killed = ChatRecord(summary: ChatSummary(title: "Killed", lastInteraction: Date()))
killed.sending = [sent]
killed.reclaimUnsent()
precondition(killed.sending == nil && killed.draft.id == sent.id && killed.draft.attachments == [file], "an unechoed message returns to the draft")
precondition(killed.takeEchoed(by: [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])]).isEmpty)
precondition(killed.draft.text.isEmpty, "a returned draft the host did take empties on its echo")
var edited = ChatRecord(summary: ChatSummary(title: "Edited", lastInteraction: Date()))
edited.sending = [sent]
edited.reclaimUnsent()
edited.draft.text = "Build it twice"
_ = edited.takeEchoed(by: [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])])
precondition(edited.draft.text == "Build it twice", "an edited draft stays")
var merged = ChatRecord(summary: ChatSummary(title: "Merged", lastInteraction: Date()))
merged.sending = [sent]
merged.draft = ComposerDraft(text: "Typed after")
merged.reclaimUnsent()
precondition(merged.draft.text == "Build it\n\nTyped after" && merged.draft.attachments == [file])
var settled = ChatRecord(summary: ChatSummary(title: "Settled", lastInteraction: Date()))
settled.sending = [sent]
settled.events = [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])]
settled.reclaimUnsent()
precondition(settled.sending == nil && settled.draft.text.isEmpty, "an echoed message is not put back")
let stored = try JSONEncoder().encode(killed)
precondition(!String(decoding: stored, as: UTF8.self).contains("\"sending\""))
let reread = try JSONDecoder().decode(ChatRecord.self, from: stored)
precondition(reread.sending == nil && reread.draft.text.isEmpty, "a file without `sending` reads")
var pendingRecord = killed
pendingRecord.sending = [sent]
let pendingCopy = try JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(pendingRecord))
precondition(pendingCopy.sending?.first?.attachments == [file], "a message being sent keeps its attachment bytes on disk")
print("ok: a relaunch puts unechoed messages back in the draft, and older files still read")

// A turn starts with a user message a run has taken, or one just sent to an
// idle conversation; a message waiting for a running turn starts none yet.
precondition(TurnFollowing.turnMessage(in: local.messages) == sent.id, "a message sent to an idle conversation starts a turn")
precondition(TurnFollowing.turnMessage(in: waiting.messages) != sent.id, "one a running turn will take starts none yet")
precondition(TurnFollowing.turnMessage(in: hostQueued.messages) == waiting.messages.first?.id)
precondition(TurnFollowing.turnMessage(in: fromTranscript.messages) == fromTranscript.messages.last { $0.role == .user }?.id,
             "a message from another conversation starts a turn")
precondition(TurnFollowing.turnMessage(in: []) == nil)

// A reply's pace is its estimated tokens a second since its first text: about
// four ASCII characters to a token, a token to each other character.
precondition(TokenEstimate.tokens(in: "abcdefgh") == 2)
precondition(TokenEstimate.tokens(in: "你好世界") == 4)
precondition(TokenEstimate.tokens(in: "ok 好") == 1.75)
let turnRows = ChatTranscript(events: [
    event(1, "prompt", ["id": .string(userID.uuidString), "text": .string("Write a long story")]),
    event(2, "messageStarted"), event(3, "thinking", ["text": .string("Planning the story out")]),
    event(4, "text", ["text": .string("Once upon a time")]),
]) { _ in nil }.messages
precondition(TurnFollowing.replyTokens(in: turnRows, after: userID) == 4, "only the reply counts, not the prompt or thinking")

/// A reply that streamed `tokens` more every quarter second for `seconds`.
func pace(tokensPerQuarter tokens: Double, seconds: Double) -> TurnFollowing.Pace {
    var pace = TurnFollowing.Pace()
    var time = 10.0
    var total = 0.0
    while time <= 10 + seconds {
        total += tokens
        pace.observe(tokens: total, at: time)
        time += 0.25
    }
    return pace
}

let slow = pace(tokensPerQuarter: 5, seconds: 8) // 20 tokens a second
let fast = pace(tokensPerQuarter: 30, seconds: 8) // 120 tokens a second
precondition(abs((slow.tokensPerSecond ?? 0) - 20) < 0.01 && !slow.isFast)
precondition(abs((fast.tokensPerSecond ?? 0) - 120) < 0.01 && fast.isFast)
precondition(!pace(tokensPerQuarter: 30, seconds: 0.5).isFast, "one burst is not taken for the pace")
precondition(TurnFollowing.Pace().tokensPerSecond == nil, "a turn with no text yet has no pace")
var backlog = TurnFollowing.Pace()
backlog.observe(tokens: 4000, at: 0)
backlog.observe(tokens: 4040, at: 2)
precondition(!backlog.isFast, "what arrived at once marks the start and does not count")
var atThreshold = TurnFollowing.Pace()
atThreshold.observe(tokens: 1, at: 0)
atThreshold.observe(tokens: 101, at: 2)
precondition(!atThreshold.isFast, "50 tokens a second is still followed")
atThreshold.observe(tokens: 103, at: 2)
precondition(atThreshold.isFast, "faster is not")

/// Where following takes the list, with a 100 pt bar over the visible area.
func follow(_ pace: TurnFollowing.Pace, _ offset: CGFloat, latest: CGFloat, top: CGFloat) -> TurnFollowing.Move {
    TurnFollowing.move(pace: pace, offset: offset, latest: latest, messageTop: top, topInset: 100)
}

precondition(follow(slow, 300, latest: 2000, top: 500) == .latest, "a reply a reader keeps up with is followed past a page")
precondition(follow(slow, 1900, latest: 2600, top: 500) == .latest, "to its end")
precondition(follow(fast, 0, latest: 300, top: 500) == .latest, "a fast one within a page shows the newest content")
precondition(follow(fast, 300, latest: 2000, top: 500) == .stop(400), "past a page it stops with the message at the top")
precondition(follow(fast, 300, latest: 400, top: 500) == .stop(400), "exactly a page is the last step")
precondition(follow(fast, 1900, latest: 2600, top: 500) == .stop(1900), "followed past the page while slow, it stops where it is")
print("ok: a turn is followed to its end unless it streams faster than 50 tokens a second, then for a page")

// A reopened session comes back as a new task that first replays the whole
// history, under its own numbering and times. The conversation keeps the
// events it has, reads past the replay, and takes what follows it.
let firstID = UUID()
let history = [
    event(1, "prompt", ["id": .string(firstID.uuidString), "text": .string("Tell me a story")]),
    event(2, "messageStarted"), event(3, "thinking", ["text": .string("A short one")]),
    event(4, "text", ["text": .string("Once")]), event(5, "text", ["text": .string(" upon")]),
    event(6, "text", ["text": .string(" a")]), event(7, "text", ["text": .string(" time")]),
    event(8, "finished"),
    event(9, "steer", ["text": .string("From another chat")]),
    event(10, "messageStarted"), event(11, "message", ["text": .string("Noted.")]), event(12, "finished"),
]
var reopened = ChatRecord(summary: ChatSummary(title: "Story", lastInteraction: Date()))
reopened.task = TaskHandle(taskID: .make(), kind: .agent)
reopened.events = history
let before = ChatTranscript(events: reopened.events, sending: [sent]) { _ in nil }.messages
reopened.reopen(as: TaskHandle(taskID: .make(), kind: .agent))
precondition(reopened.events == history && reopened.cursor == .start, "the history stays while the new task is read from its start")
// the replay, in two batches, coalesced and numbered its own way
precondition(reopened.take([
    event(1, "prompt", ["id": .string(firstID.uuidString), "text": .string("Tell me a story")]),
    event(2, "messageStarted"), event(3, "thinking", ["text": .string("A short one")]),
]).isEmpty)
precondition(reopened.events == history && reopened.cursor == EventSeq(3))
precondition(ChatTranscript(events: reopened.events, sending: [sent]) { _ in nil }.messages == before,
             "while the replay comes in, the conversation shows what it showed")
let restOfReplay = [
    event(4, "text", ["text": .string("Once upon a time")]), event(5, "finished"),
    event(6, "steer", ["text": .string("From another chat")]),
    event(7, "messageStarted"), event(8, "message", ["text": .string("Noted.")]), event(9, "finished"),
    event(10, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")]),
    event(11, "text", ["text": .string("Done")]),
]
var relaunched = try JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(reopened))
precondition(relaunched.cursor == EventSeq(3), "a replay half read is saved with the record")
precondition(relaunched.take(restOfReplay).map(\.seq) == [EventSeq(10), EventSeq(11)], "and goes on after a relaunch")
precondition(reopened.take(restOfReplay).map(\.seq) == [EventSeq(10), EventSeq(11)], "what follows the replay is taken")
precondition(reopened.events.count == history.count + 2 && reopened.cursor == EventSeq(11))
let after = ChatTranscript(events: reopened.events) { _ in nil }.messages
precondition(Array(after.prefix(before.count - 1)) == Array(before.prefix(before.count - 1)), "the rows already shown keep their ids")
precondition(Set(after.map(\.id)).count == after.count, "and no id repeats, though the numbering started again")
precondition(after.last { $0.role == .user }?.id == sent.id && after.last?.text == "Done")
precondition(reopened.take([event(12, "text", ["text": .string(" now")])]).count == 1, "after the replay, everything is taken")
var unknownHistory = ChatRecord(summary: ChatSummary(title: "Lost", lastInteraction: Date()))
unknownHistory.events = history
unknownHistory.reopen(as: TaskHandle(taskID: .make(), kind: .agent))
precondition(unknownHistory.take([event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])]).count == 1,
             "a task that replays nothing starts with the new message")
var firstTask = ChatRecord(summary: ChatSummary(title: "New", lastInteraction: Date()))
firstTask.reopen(as: TaskHandle(taskID: .make(), kind: .agent))
precondition(firstTask.take([event(1, "error", ["message": .string("Sign in first")])]).count == 1,
             "a conversation with no history reads its first task from the start, an early error included")
var sameTask = reopened
sameTask.reopen(as: reopened.task!)
precondition(sameTask.events == reopened.events && sameTask.cursor == EventSeq(12), "the same task again reads on")
// Compact… reopens a stopped session with no message after the replay:
// the compaction it asked for is new, one already in the history is not.
var compacted = ChatRecord(summary: ChatSummary(title: "Long", lastInteraction: Date()))
compacted.task = TaskHandle(taskID: .make(), kind: .agent)
compacted.events = history + [event(13, "compactionStarted"), event(14, "compactionFinished", ["outcome": .string("compacted")])]
compacted.reopen(as: TaskHandle(taskID: .make(), kind: .agent))
let compactionReplay = history + [event(13, "compactionStarted"), event(14, "compactionFinished", ["outcome": .string("compacted")])]
precondition(compacted.take(compactionReplay).isEmpty, "a compaction in the history is part of the replay")
let asked = compacted.take([event(15, "compactionStarted"), event(16, "compactionFinished", ["outcome": .string("tooShort")])])
precondition(asked.map(\.kind) == ["compactionStarted", "compactionFinished"], "the one asked for after a reopen is taken")
print("ok: a reopened session's replay is read past, and the conversation keeps its rows")

checkReplayEnd()

/// A Compact… that compacted leaves a row where it happened, carrying the
/// summary the conversation goes on from; one that did not leaves none.
/// An older session recorded its compaction without the summary: the row
/// is there, with nothing to open.
let compactionSummary = "The user is building a tweak; <the hook> loads & logs."
let compactedLog = history + [
    event(13, "compactionStarted"),
    event(14, "compactionFinished", [
        "outcome": .string("compacted"), "messagesCompacted": .number(6), "summary": .string(compactionSummary),
    ]),
    event(15, "prompt", ["id": .string(UUID().uuidString), "text": .string("Carry on")]),
]
let compactedRows = ChatTranscript(events: compactedLog) { _ in nil }.messages
let compactionIndex = compactedRows.firstIndex { $0.role == .compaction }
precondition(compactedRows.count(where: { $0.role == .compaction }) == 1, "one row for the compaction")
precondition(compactionIndex.map { compactedRows[$0].text } == compactionSummary, "the row keeps the summary as written")
precondition(compactionIndex.map { compactedRows[$0 - 1].text } == "Noted.", "after the reply it followed")
precondition(compactionIndex.map { compactedRows[$0 + 1].role } == .user, "before the message sent after it")
precondition(ChatTranscript(events: compactedLog) { _ in nil }.messages.map(\.id) == compactedRows.map(\.id),
             "the row's id comes from its event, built again or not")
let notCompacted = ChatTranscript(events: history + [
    event(13, "compactionStarted"), event(14, "compactionFinished", ["outcome": .string("tooShort")]),
]) { _ in nil }
precondition(!notCompacted.messages.contains { $0.role == .compaction } && !notCompacted.isCompacting,
             "a compaction that left the chat as it was shows no row")
let olderCompaction = ChatTranscript(events: history + [
    event(13, "compactionStarted"),
    event(14, "compactionFinished", ["outcome": .string("compacted"), "messagesCompacted": .number(6)]),
]) { _ in nil }
precondition(olderCompaction.messages.last?.role == .compaction && olderCompaction.messages.last?.text == "",
             "an older session's compaction has its row, with no summary")
let textAfter = ChatTranscript(events: [
    event(1, "messageStarted"), event(2, "text", ["text": .string("Before")]),
    event(3, "compactionFinished", ["outcome": .string("compacted"), "summary": .string("S")]),
    event(4, "text", ["text": .string("After")]),
]) { _ in nil }.messages
precondition(textAfter.map(\.text) == ["Before", "S", "After"], "text after the row never lands above it")
let olderResult = try JSONValue.object(["outcome": .string("compacted"), "messagesCompacted": .number(6)])
    .decode(AgentCompactionResult.self)
precondition(olderResult == AgentCompactionResult(outcome: .compacted, messagesCompacted: 6),
             "a result recorded before the summary was kept still decodes")
print("ok: a Compact… that compacted is a row where it happened, which opens the summary")

/// A name the reader gives a conversation is kept: the agent's `title`
/// events and the first message's opening no longer replace it, a name of
/// nothing but spaces changes nothing, and the name survives a relaunch.
var renamed = ChatSummary.untitled(lastInteraction: Date(), projectName: nil)
renamed.suggestTitle("Opening words")
precondition(renamed.title == "Opening words" && renamed.isNamedByReader == nil, "an unnamed conversation takes suggestions")
precondition(!renamed.rename(to: " \n\t "), "a name with nothing in it is refused")
precondition(renamed.title == "Opening words" && renamed.isNamedByReader == nil, "and changes nothing")
precondition(renamed.rename(to: "  Release checklist  "))
precondition(renamed.title == "Release checklist" && renamed.isNamedByReader == true, "the typed name, trimmed")
renamed.suggestTitle("Agent title after the rename")
precondition(renamed.title == "Release checklist", "a host title after a rename does not replace it")
let renamedFile = try JSONEncoder().encode(ChatRecord(summary: renamed))
var relaunchedNamed = try JSONDecoder().decode(ChatRecord.self, from: renamedFile).summary
precondition(relaunchedNamed.title == "Release checklist" && relaunchedNamed.isNamedByReader == true, "the name survives a relaunch")
relaunchedNamed.suggestTitle("Title replayed from the start of the task")
precondition(relaunchedNamed.title == "Release checklist", "a replayed title after a relaunch does not replace it either")
precondition(relaunchedNamed.rename(to: "Second name") && relaunchedNamed.title == "Second name", "the reader can rename again")
let olderSummary = try JSONDecoder().decode(ChatSummary.self, from: Data("""
{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","updated":0,"isPinned":false,"isWorking":false}
""".utf8))
precondition(olderSummary.isNamedByReader == nil, "a file from before renaming reads as unnamed")
print("ok: a renamed conversation keeps its name over the agent's titles and across a relaunch")

/// An untitled conversation is kept as no title: shown as New Chat in the
/// language the app runs in now, and named after its first message. One an
/// earlier version saved as the words New Chat, in any of the app's
/// languages, reads as untitled too, unless the reader typed them.
var fresh = ChatSummary.untitled(lastInteraction: Date(), projectName: "Clock")
precondition(fresh.isUntitled && fresh.displayTitle == String(localized: "New Chat"), "a new conversation has only a placeholder")
let freshFile = try JSONEncoder().encode(ChatRecord(summary: fresh))
let freshSaved = try JSONDecoder().decode(ChatRecord.self, from: freshFile).summary
precondition(freshSaved.isUntitled && freshSaved.title.isEmpty, "and is saved with no title")
fresh.nameAfterFirstMessage(text: "Hook the lock screen", attachmentName: "notes.txt")
precondition(!fresh.isUntitled && fresh.title == "Hook the lock screen", "its first message names it")
fresh.nameAfterFirstMessage(text: "Then the home screen", attachmentName: nil)
precondition(fresh.title == "Hook the lock screen", "a later message does not")
fresh.suggestTitle("Lock screen tweak")
precondition(fresh.displayTitle == "Lock screen tweak", "the agent's title replaces the first message's")
var attachedOnly = ChatSummary.untitled(lastInteraction: Date(), projectName: nil)
attachedOnly.nameAfterFirstMessage(text: "", attachmentName: "crash.ips")
precondition(attachedOnly.title == "crash.ips", "a message of attachments alone is named after the first")
var nothingSent = ChatSummary.untitled(lastInteraction: Date(), projectName: nil)
nothingSent.nameAfterFirstMessage(text: "", attachmentName: nil)
precondition(nothingSent.isUntitled, "nothing to name it after leaves it untitled, never the words New Chat")
var longOpening = ChatSummary.untitled(lastInteraction: Date(), projectName: nil)
longOpening.nameAfterFirstMessage(text: String(repeating: "a", count: 200), attachmentName: nil)
precondition(longOpening.title.count == 80, "the opening is its first 80 characters")

func savedSummary(title: String, namedByReader: Bool? = nil) throws -> ChatSummary {
    let named = namedByReader.map { ",\"isNamedByReader\":\($0)" } ?? ""
    let file = "{\"id\":\"6F9619FF-8B86-D011-B42D-00C04FC964FF\",\"title\":\"\(title)\","
        + "\"updated\":0,\"isPinned\":false,\"isWorking\":false\(named)}"
    return try JSONDecoder().decode(ChatSummary.self, from: Data(file.utf8))
}

var savedUntitled = try savedSummary(title: "New Chat")
precondition(savedUntitled.isUntitled && savedUntitled.displayTitle == String(localized: "New Chat"),
             "an earlier version's New Chat reads as untitled")
savedUntitled.nameAfterFirstMessage(text: "Make a tweak", attachmentName: nil)
precondition(savedUntitled.title == "Make a tweak", "and is still named after its first message")
let typedNewChat = try savedSummary(title: "New Chat", namedByReader: true)
precondition(typedNewChat.title == "New Chat", "a reader who typed New Chat keeps it")
let otherTitle = try savedSummary(title: "Docs")
precondition(otherTitle.title == "Docs", "any other title stays as it was")

/// New Chat in every language a bundle has, read from its tables
let languages = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-languages-" + UUID().uuidString)
for (language, translation) in [("ja", "新規チャット"), ("fr", "Nouvelle discussion"), ("ar", "محادثة جديدة")] {
    let folder = languages.appendingPathComponent(language + ".lproj")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("\"New Chat\" = \"\(translation)\";\n\"Send\" = \"-\";\n".utf8)
        .write(to: folder.appendingPathComponent("Localizable.strings"))
}

let placeholders = ChatSummary.placeholderTitles(in: Bundle(path: languages.path)!)
try FileManager.default.removeItem(at: languages)
precondition(placeholders == ["New Chat", "新規チャット", "Nouvelle discussion", "محادثة جديدة"],
             "every localization's New Chat and the key itself: \(placeholders)")
print("ok: an untitled conversation is a state, shown in today's language and named after its first message")

do {
    /// Whether two row arrays are one storage: a transcript handed back
    /// from the cache rather than built again.
    func sameStorage(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
        lhs.withUnsafeBufferPointer { a in rhs.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress } }
    }
    let senderTurn = [
        event(1, "prompt", ["id": .string(UUID().uuidString), "text": .string("From afar"), "from": .string("s1")]),
        event(2, "messageStarted"), event(3, "thinking", ["text": .string("Looking")]),
        event(4, "toolCall", ["id": .string("t1"), "tool": .string("file_list")]), event(5, "toolResult", ["id": .string("t1")]),
        event(6, "message", ["text": .string("First reply")]), event(7, "finished"),
    ]
    var titles = ["s1": "Docs"]
    var cache = ChatTranscriptCache()
    var chat = ChatRecord(summary: ChatSummary(title: "Cached", lastInteraction: Date()), events: senderTurn)
    // before any of these turns has gone quiet
    let early = Date(timeIntervalSince1970: 0)
    func cached(_ record: ChatRecord, followed: Set<UUID> = [], now: Date = early) -> ChatTranscript {
        cache.transcript(of: record, now: now, isFollowed: { followed.contains($0) }, conversationTitle: { titles[$0] }) {
            _ in nil
        }
    }
    func fresh(_ record: ChatRecord) -> [ChatMessage] {
        ChatTranscript(events: record.events, sending: record.sending ?? [], conversationTitle: { titles[$0] }, now: early) {
            _ in nil
        }
        .messages
    }
    let first = cached(chat)
    precondition(sameStorage(first.messages, cached(chat).messages), "nothing changed: the transcript built before")

    chat.events += [event(8, "prompt", ["text": .string("Again")]), event(9, "messageStarted"),
                    event(10, "text", ["text": .string("Streaming")])]
    let streamed = cached(chat)
    precondition(!sameStorage(first.messages, streamed.messages), "new events build it again")
    precondition(streamed.messages == fresh(chat) && streamed.isWorking, "as a transcript of the same events")
    precondition(streamed.messages[0].text == first.messages[0].text)

    chat.sending = [ComposerDraft(text: "Queued while it runs")]
    let sending = cached(chat)
    precondition(!sameStorage(streamed.messages, sending.messages), "a message on its way builds it again")
    precondition(sending.messages.last?.text == "Queued while it runs" && sending.messages.last?.isQueued == true)
    chat.sending = [ComposerDraft(id: chat.sending![0].id, text: "Typed again and resent")]
    precondition(cached(chat).messages.last?.text == "Typed again and resent", "a draft resent under its id")

    titles["s1"] = "Renamed Docs"
    let renamed = cached(chat)
    precondition(renamed.messages[0].sender == ChatTranscript.senderLine("Renamed Docs"), "a sender renamed shows")
    precondition(sameStorage(renamed.messages, cached(chat).messages))

    // the page's conversation stays while another one is built; followed
    // ones stay whatever is built
    let other = ChatRecord(summary: ChatSummary(title: "Other", lastInteraction: Date()), events: senderTurn)
    let followed = ChatRecord(summary: ChatSummary(title: "Followed", lastInteraction: Date()), events: senderTurn)
    let keepers: Set = [followed.summary.id]
    let followedFirst = cached(followed, followed: keepers)
    let shown = cached(chat, followed: keepers)
    _ = cached(followed, followed: keepers)
    precondition(sameStorage(shown.messages, cached(chat, followed: keepers).messages), "a followed build keeps the page's")
    _ = cached(other, followed: keepers)
    precondition(!sameStorage(shown.messages, cached(chat, followed: keepers).messages), "another page's drops it")
    precondition(sameStorage(followedFirst.messages, cached(followed, followed: keepers).messages))
    cache.remove(followed.summary.id)
    precondition(!sameStorage(followedFirst.messages, cached(followed, followed: keepers).messages))

    // a rebuilt row equal to the one shown is that very value
    let rows = fresh(chat)
    let rebuilt = fresh(chat)
    let reused = ChatTranscriptCache.reusing(rows, in: rebuilt)
    precondition(reused == rows && rows.contains { !$0.trace.isEmpty })
    precondition(!zip(rebuilt, rows).contains { !$0.trace.isEmpty && sameStorage($0.trace, $1.trace) })
    precondition(zip(reused, rows).allSatisfy { sameStorage($0.trace, $1.trace) }, "unchanged rows share their storage")

    // a turn gone quiet is built again once its deadline has passed, when
    // the page's wake asks, with the running summary standing in
    let quietChat = ChatRecord(summary: ChatSummary(title: "Quiet", lastInteraction: Date()), events: replied)
    let beforeQuiet = cached(quietChat, now: replyAt.addingTimeInterval(1))
    let quietAt = replyAt.addingTimeInterval(ChatTranscript.quietInterval)
    precondition(beforeQuiet.messages.last?.role == .assistant && beforeQuiet.quietDeadline == quietAt)
    precondition(sameStorage(beforeQuiet.messages, cached(quietChat, now: quietAt.addingTimeInterval(-0.1)).messages),
                 "before the deadline, the transcript built before")
    let wentQuiet = cached(quietChat, now: quietAt.addingTimeInterval(0.05))
    precondition(wentQuiet.messages.last?.role == .thinking(seconds: nil, tools: 0) && wentQuiet.quietDeadline == nil,
                 "past it, built again with the stand-in")
    precondition(Array(wentQuiet.messages.dropLast()) == beforeQuiet.messages)
    precondition(sameStorage(wentQuiet.messages, cached(quietChat, now: quietAt.addingTimeInterval(5)).messages),
                 "and then held")
    print("ok: a transcript is built again only when its events, its messages on their way, a sender's title or the turn's quiet change")
}

/// A conversation recorded before the tools were renamed titles its calls as
/// one recorded today does, and every earlier name has a title of its own.
func callTitles(_ tools: [String]) -> [String] {
    let calls = tools.enumerated().map { index, tool in
        event(UInt64(index + 1), "toolCall", [
            "id": .string("c\(index)"), "tool": .string(tool), "arguments": .string("{\"path\":\"a.m\",\"name\":\"Demo\"}"),
        ])
    }
    return ChatTranscript(events: calls + [event(UInt64(tools.count + 1), "finished")]) { _ in nil }
        .messages.flatMap(\.trace).filter { $0.role == .tool }.map(\.text)
}

let earlierNames = AgentToolName.legacyNames.keys.sorted()
let earlierTitles = callTitles(earlierNames)
precondition(earlierTitles.count == earlierNames.count)
precondition(earlierTitles == callTitles(earlierNames.compactMap { AgentToolName.canonical($0)?.rawValue }))
precondition(!earlierTitles.contains { $0.contains("_") }, "an earlier name is titled, not spelled out")
print("ok: calls recorded under the earlier tool names read as today's do")

/// A web fetch is titled by the site it reads.
func webFetchTitle(_ arguments: String) -> String? {
    let call = event(1, "toolCall", [
        "id": .string("w"), "tool": .string(AgentToolName.webFetch.rawValue), "arguments": .string(arguments),
    ])
    return ChatTranscript(events: [call, event(2, "finished")]) { _ in nil }
        .messages.flatMap(\.trace).first { $0.role == .tool }?.text
}

precondition(webFetchTitle(#"{"url":"https://docs.example.com/guide?x=1"}"#) == "Read docs.example.com")
precondition(webFetchTitle("{}") == "Read a webpage")
print("ok: a web fetch is titled by its site")

checkTranscriptFold()

checkToolCallDetail()

checkTraceStep()

checkDroppedMessages()

checkDeletedProjects()

checkCompletedBuilds()

checkStarPromptState()

try checkSidebarOrder()

checkProjectMenuOrder()

checkChatDeletion()

try checkChatUnread()
