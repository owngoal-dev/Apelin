import ApelinCore
import ApelinProtocol
import Foundation

/// A transcript read in batches, and shown again at other times, is the one
/// built from every event at once: `ChatTranscript.append` and the cache
/// that uses it, over random logs split at random, at times either side of
/// the quiet deadline.
func checkTranscriptFold() {
    checkPayloadReaders()
    var seen = FoldCoverage()
    for seed in UInt64(1) ... 64 {
        checkFold(seed: seed, seen: &seen)
    }
    for seed in UInt64(1) ... 32 {
        checkCache(seed: seed, seen: &seen)
    }
    seen.expectEverything()
    print("ok: a transcript read in batches, its cache too, is the one built from every event at once "
        + "(\(seen.states) states)")
}

/// What the states compared showed, so the logs are known to reach every
/// part of the transcript the batches could get wrong.
private struct FoldCoverage {
    var states = 0
    var waitingForQuiet = 0
    var standingInForQuiet = 0
    var counting = 0
    var settling = 0
    var compacting = 0
    var compacted = 0
    var queued = 0
    var onTheirWay = 0
    var decided = 0
    var senders = 0
    var attached = 0
    var bannered = 0
    var reconnecting = 0

    /// `transcript`, built at once with `sending`, at a time `wentQuiet`
    /// says is past its quiet deadline or not.
    mutating func note(_ transcript: ChatTranscript, sending: [ComposerDraft], wentQuiet: Bool) {
        let rows = transcript.messages
        states += 1
        waitingForQuiet += transcript.quietDeadline == nil ? 0 : 1
        standingInForQuiet += wentQuiet ? 1 : 0
        counting += rows.contains { $0.receivedTokens != nil } ? 1 : 0
        settling += rows.contains(where: \.receivedSettles) ? 1 : 0
        compacting += transcript.isCompacting ? 1 : 0
        compacted += rows.contains { $0.role == .compaction && !$0.text.isEmpty } ? 1 : 0
        queued += rows.contains { row in row.isQueued && !sending.contains { $0.id == row.id } } ? 1 : 0
        onTheirWay += sending.contains { draft in rows.contains { $0.id == draft.id && $0.text == draft.text } } ? 1 : 0
        decided += rows.contains { row in
            row.trace.contains { $0.role == .approval(.approve) || $0.role == .approval(.deny) }
        } ? 1 : 0
        senders += rows.contains { $0.sender != nil } ? 1 : 0
        attached += rows.contains { !$0.attachments.isEmpty } ? 1 : 0
        // a running summary's line: its newest call, with a file tool's counts
        bannered += rows.contains { $0.role.isThinking && $0.banner?.change != nil } ? 1 : 0
        reconnecting += rows.contains { $0.recovery == .reconnecting } ? 1 : 0
    }

    func expectEverything() {
        let counts = [
            waitingForQuiet, standingInForQuiet, counting, settling, compacting, compacted, queued, onTheirWay, decided, senders,
            attached, bannered, reconnecting,
        ]
        precondition(!counts.contains(0), "the random logs reach every part of a transcript: \(self)")
    }
}

/// The payload readers read what decoding reads, malformed lists included.
private func checkPayloadReaders() {
    let attachment: JSONValue = .object([
        "path": .string("A/1.png"), "name": .string("1.png"), "mimeType": .string("image/png"),
    ])
    let id = JSONValue.string(UUID().uuidString)
    let values: [JSONValue?] = [
        nil, .null, .string("x"), .number(1), .array([]), .object([:]),
        .array([attachment]), .array([attachment, attachment]),
        .array([attachment, .object(["path": .string("p"), "name": .string("n")])]),
        .array([.object(["path": .number(1), "name": .string("n"), "mimeType": .string("m")])]),
        .array([.object(["path": .string("p"), "name": .string("n"), "mimeType": .string("m"), "extra": .null])]),
        .array([attachment, .null]), .array([id]), .array([id, id]), .array([id, .string("not an id")]),
        .array([.number(3)]),
    ]
    for value in values {
        let decodedFiles = value.flatMap { try? $0.decode([AgentAttachment].self) } ?? []
        precondition(ChatTranscript.attachments(in: value) == decodedFiles, "attachments as decoded: \(value as Any)")
        let decodedIDs = Set(value.flatMap { try? $0.decode([UUID].self) } ?? [])
        precondition(ChatTranscript.identifiers(in: value) == decodedIDs, "ids as decoded: \(value as Any)")
    }
}

/// One log read in random batches, each compared with the transcript of
/// the same events built at once.
private func checkFold(seed: UInt64, seen: inout FoldCoverage) {
    var random = FoldRandom(seed: seed)
    let log = FoldLog.make(count: 240, random: &random)
    var files = FoldFiles()
    let title = FoldLog.title
    var folded = ChatTranscript(events: []) { files.file($0) }
    var read = 0
    while read < log.events.count {
        // none at times: the rows shown again, later, with nothing new
        let next = min(log.events.count, read + random.int(in: 0 ... 7))
        let sending = log.sending(random: &random)
        let now = log.now(after: next, random: &random)
        folded.append(log.events[read ..< next], sending: sending, conversationTitle: title, now: now) {
            files.file($0)
        }
        read = next
        let events = Array(log.events[..<read])
        let built = ChatTranscript(events: events, sending: sending, conversationTitle: title, now: now) {
            files.file($0)
        }
        expectSame(folded, built, "seed \(seed), \(read) events")
        seen.note(built, sending: sending, wentQuiet: wentQuiet(built, events: events, now: now))
    }
}

/// Whether `built`, made at `now`, shows the summary that stands in once its
/// turn has gone quiet: without a time, the same events still wait for it.
private func wentQuiet(_ built: ChatTranscript, events: [TaskEvent], now: Date?) -> Bool {
    guard now != nil, built.isWorking, built.quietDeadline == nil else { return false }
    return ChatTranscript(events: events) { _ in nil }.quietDeadline != nil
}

/// One record whose events grow, whose messages on their way change, whose
/// senders are renamed, asked for at times either side of the quiet
/// deadline: the cache's transcript is always the one built at once. Its
/// time only goes forward, as the clock's does: a summary that stood in
/// once a turn went quiet stays until the next event.
private func checkCache(seed: UInt64, seen: inout FoldCoverage) {
    var random = FoldRandom(seed: seed &* 31)
    let log = FoldLog.make(count: 240, random: &random)
    var files = FoldFiles()
    var cache = ChatTranscriptCache()
    var record = ChatRecord(summary: ChatSummary(title: "Fold", lastInteraction: Date()))
    var renamed = false
    var clock = Date.distantPast
    while record.events.count < log.events.count {
        switch random.int(in: 0 ... 9) {
        case 0: renamed.toggle()
        case 1: break
        default:
            let next = min(log.events.count, record.events.count + random.int(in: 1 ... 6))
            record.events += log.events[record.events.count ..< next]
        }
        let drafts = log.sending(random: &random)
        record.sending = drafts.isEmpty ? nil : drafts
        clock = max(clock, log.now(after: record.events.count, random: &random) ?? clock)
        let now = clock
        let title: (String) -> String? = { session in
            renamed ? FoldLog.title(session).map { $0 + " (renamed)" } : FoldLog.title(session)
        }
        let cached = cache.transcript(of: record, now: now, isFollowed: { _ in true }, conversationTitle: title) {
            files.file($0)
        }
        let built = ChatTranscript(events: record.events, sending: drafts, conversationTitle: title, now: now) {
            files.file($0)
        }
        expectSame(cached, built, "cache seed \(seed), \(record.events.count) events")
        seen.note(built, sending: drafts, wentQuiet: wentQuiet(built, events: record.events, now: now))
    }
}

/// The two show the same rows, state, approvals, deadline and token figure,
/// having read as many events; else the first row they differ in is said.
private func expectSame(_ folded: ChatTranscript, _ built: ChatTranscript, _ context: String) {
    if folded.messages == built.messages, folded.isWorking == built.isWorking,
       folded.isCompacting == built.isCompacting, folded.approvalIDs == built.approvalIDs,
       folded.quietDeadline == built.quietDeadline, folded.eventCount == built.eventCount,
       folded.messages.map(\.receivedTokens) == built.messages.map(\.receivedTokens)
    {
        return
    }
    var report = "a transcript read in batches must be the one built at once: \(context)"
    report += "\n  rows \(folded.messages.count) vs \(built.messages.count)"
    if let (fold, whole) = zip(folded.messages, built.messages).first(where: { $0 != $1 }) {
        report += "\n  read in batches: \(fold)\n  built at once:   \(whole)"
    }
    report += "\n  working \(folded.isWorking)/\(built.isWorking)"
    report += ", compacting \(folded.isCompacting)/\(built.isCompacting)"
    report += "\n  deadline \(String(describing: folded.quietDeadline))/\(String(describing: built.quietDeadline))"
    preconditionFailure(report)
}

/// Attachments as the runtime gives them: one value per path, so a row
/// built twice compares equal, and none for a file that cannot be read.
private struct FoldFiles {
    private var files: [String: ComposerAttachment] = [:]

    mutating func file(_ item: AgentAttachment) -> ComposerAttachment? {
        guard !item.path.contains("missing") else { return nil }
        if let file = files[item.path] {
            return file
        }
        let image = item.mimeType.hasPrefix("image/")
        let file = ComposerAttachment(name: item.name, data: Data(item.path.utf8), isImage: image)
        files[item.path] = file
        return file
    }
}

/// A seeded generator, so a failing seed can be run again.
private struct FoldRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func chance(_ odds: Int) -> Bool {
        int(in: 1 ... odds) == 1
    }

    /// An id from the seed too, so the log is the same each run.
    mutating func id() -> UUID {
        let high = next()
        let low = next()
        return withUnsafeBytes(of: (high, low)) { UUID(uuid: $0.load(as: uuid_t.self)) }
    }
}

/// A random but plausible session log: every kind the transcript reads, and
/// ids reused the way a session reuses them — a queued message taken by a
/// prompt, a call answered by its result, an approval by its decision — with
/// malformed payloads, a numbering that starts again as a reopened task's
/// does, and times that stand still or jump.
private struct FoldLog {
    var events: [TaskEvent] = []
    /// Ids the log's prompts and queued messages carry, which a message on
    /// its way may share.
    var messageIDs: [UUID] = []

    static func title(_ session: String) -> String? {
        session == "session-0" ? nil : "Chat \(session)"
    }

    static func make(count: Int, random: inout FoldRandom) -> FoldLog {
        var log = FoldLog()
        var seq: UInt64 = 0
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        var openCalls: [String] = []
        var openApprovals: [String] = []
        var queued: [UUID] = []
        var calls = 0
        func add(_ kind: String, _ payload: [String: JSONValue]) {
            seq += 1
            if random.chance(40) {
                // a reopened task numbers its events from the start again
                seq = 1
            }
            switch random.int(in: 0 ... 9) {
            case 0: break
            case 1: time += Double(random.int(in: 2 ... 30))
            default: time += Double(random.int(in: 1 ... 900)) / 1000
            }
            log.events.append(TaskEvent(seq: EventSeq(seq), kind: kind, time: time, payload: .object(payload)))
        }
        func files() -> JSONValue? {
            switch random.int(in: 0 ... 5) {
            case 0:
                .array([.object([
                    "path": .string("Attachments/\(log.events.count).png"), "name": .string("a.png"),
                    "mimeType": .string("image/png"),
                ])])
            case 1:
                .array([.object([
                    "path": .string("Attachments/missing-\(log.events.count).txt"), "name": .string("a.txt"),
                    "mimeType": .string("text/plain"),
                ])])
            case 2: .array([.object(["path": .string("broken")])])
            default: nil
            }
        }
        // Today's names, and now and then one an earlier release recorded.
        let tools = [
            "file_write", "file_read", "shell_run", "file_edit", "apelin_project_build", "apelin_notification_send",
            "apelin_project_create", "patch_file", "build",
        ]
        while log.events.count < count {
            switch random.int(in: 0 ... 29) {
            case 0, 1:
                let id = random.id()
                log.messageIDs.append(id)
                var payload: [String: JSONValue] = [
                    "text": .string("prompt \(log.events.count)"), "id": .string(id.uuidString),
                ]
                payload["attachments"] = files()
                if random.chance(4) {
                    payload["from"] = .string("session-\(random.int(in: 0 ... 2))")
                }
                add("prompt", payload)
            case 2:
                if let id = queued.popLast(), random.chance(2) {
                    add("prompt", ["text": .string("taken"), "id": .string(id.uuidString)])
                } else {
                    add("steer", ["text": .string("steer \(log.events.count)")])
                }
            case 3:
                let id = random.id()
                queued.append(id)
                log.messageIDs.append(id)
                var payload: [String: JSONValue] = ["text": .string("queued"), "id": .string(id.uuidString)]
                payload["attachments"] = files()
                add("queued", payload)
            case 4:
                let ids: [JSONValue] = queued.suffix(random.int(in: 0 ... 2)).map { .string($0.uuidString) }
                add("queueDropped", ["ids": .array(random.chance(5) ? ids + [.string("bad")] : ids)])
            case 5, 6: add("messageStarted", [:])
            case 7, 8, 9: add("thinking", ["text": .string(random.chance(3) ? " \n" : "thought \(log.events.count) ")])
            case 10: add("toolCallPreparing", ["id": .string("call-\(calls + 1)")])
            case 11, 12:
                calls += 1
                let id = "call-\(calls)"
                openCalls.append(id)
                let tool = tools[random.int(in: 0 ... tools.count - 1)]
                let arguments = random.chance(6)
                    ? "{not json"
                    : "{\"path\":\"Sources/F\(calls).swift\",\"name\":\"Proj\",\"reason\":\"because\"}"
                var payload: [String: JSONValue] = ["tool": .string(tool), "arguments": .string(arguments)]
                if !random.chance(10) {
                    payload["id"] = .string(id)
                }
                add("toolCall", payload)
            case 13, 14:
                let id = random.chance(6) ? "call-unknown" : openCalls.popLast() ?? "call-none"
                var payload: [String: JSONValue] = [
                    "id": .string(id), "output": .string("Wrote F (3 lines, +2 -1)\nmore"),
                ]
                payload["attachments"] = files()
                if random.chance(5) {
                    payload["isError"] = .bool(true)
                }
                add("toolResult", payload)
            case 15:
                // now and then an id asked about twice, as a replayed request
                let id = random.chance(8) ? openApprovals.last ?? "approval" : "approval-\(log.events.count)"
                openApprovals.append(id)
                var payload: [String: JSONValue] = [
                    "approvalID": .string(id), "tool": .string("shell_run"),
                    "arguments": .string("{\"command\":\"ls\"}"), "reason": .string("why"),
                ]
                if random.chance(3) {
                    payload["detail"] = .object(["descriptionChanged": .object(["diff": .string("- a\n+ b")])])
                }
                add("approvalRequested", payload)
            case 16:
                let id = random.chance(6) ? "approval-unknown" : openApprovals.popLast() ?? "approval-none"
                let decision = random.chance(2) ? "approve" : "deny"
                add("approvalResolved", ["approvalID": .string(id), "decision": .string(decision)])
            case 17, 18, 19: add("text", ["text": .string(random.chance(4) ? "" : "reply \(log.events.count) ")])
            case 20: add("message", ["text": .string(random.chance(5) ? "" : "whole reply \(log.events.count)")])
            case 21: add("error", ["message": .string("failed \(log.events.count)")])
            case 22: add("received", ["tokens": .number(Double(random.int(in: 0 ... 5000)))])
            case 23: add("finished", ["reason": .string(random.chance(3) ? "failed" : "completed")])
            case 24:
                if random.chance(2) {
                    add("compactionStarted", [:])
                } else {
                    // compacted, with a summary or without (an older session's), or not compacted
                    let outcomes = ["compacted", "compacted", "tooShort", "failed"]
                    var payload: [String: JSONValue] = ["outcome": .string(outcomes[random.int(in: 0 ... 3)])]
                    if random.chance(2) {
                        payload["summary"] = .string("summary \(log.events.count)")
                    }
                    add("compactionFinished", random.chance(6) ? [:] : payload)
                }
            case 25:
                let states = ["running", "succeeded", "failed", "cancelled", "interrupted", "waitingForApproval"]
                add(TaskEvent.stateKind, ["state": .string(states[random.int(in: 0 ... states.count - 1)])])
            // a message given up, kwwk's or the network's request made again
            case 26: add("messageDiscarded", [:])
            case 27: add("reconnecting", [:])
            default:
                add(random.chance(2) ? "title" : "conversationOpened", ["text": .string("t")])
            }
        }
        return log
    }

    /// Messages on their way: none, a new one, or one whose id the log's
    /// own messages carry, so its row may already be there.
    func sending(random: inout FoldRandom) -> [ComposerDraft] {
        switch random.int(in: 0 ... 5) {
        case 0: [ComposerDraft(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, text: "on its way")]
        case 1 where !messageIDs.isEmpty:
            [ComposerDraft(id: messageIDs[random.int(in: 0 ... messageIDs.count - 1)], text: "echoed")]
        default: []
        }
    }

    /// No time at all now and then; else a time either side of the quiet
    /// deadline after the first `count` events, on it exactly too.
    func now(after count: Int, random: inout FoldRandom) -> Date? {
        guard count > 0, !random.chance(6) else { return nil }
        let deadline = events[count - 1].time.addingTimeInterval(ChatTranscript.quietInterval)
        let offsets: [TimeInterval] = [-1, -0.001, 0, 0.001, 1, 30]
        return deadline.addingTimeInterval(offsets[random.int(in: 0 ... offsets.count - 1)])
    }
}
