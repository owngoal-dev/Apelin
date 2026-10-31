import ApelinCore
import ApelinProtocol
import CryptoKit
import Foundation

/// Rebuilds visible rows from ordered host events. Rebuilding from the same
/// events gives the same row IDs.
///
/// A fold: the events are read once, in order, into rows that `append`
/// carries on from, and the rows shown are made from those afresh each
/// time. Events read in batches and shown at a `now` give what a transcript
/// built from all of them at once, at that `now`, would.
struct ChatTranscript {
    var messages: [ChatMessage] = []
    var isWorking = false
    /// Compacting between runs, as the app asked (`agentCompact`).
    var isCompacting = false
    var approvalIDs: [UUID: String] = [:]
    /// While the turn runs and its last row is a reply with nothing after
    /// it: when, with no event before then, a running summary stands in
    /// under the reply. Nil once it does, and whenever nothing would.
    private(set) var quietDeadline: Date?
    /// How many events it has read.
    private(set) var eventCount = 0
    /// How long a running turn goes without an event before a summary
    /// stands in under its reply: the model may be writing a call it has
    /// not announced yet, or the provider has stalled.
    static let quietInterval: TimeInterval = 1.5
    /// The rows the events have made, before the thoughts, calls and
    /// approvals between two replies are folded into their summary.
    private var rows: [ChatMessage] = []
    /// Where each id's first row is among `rows`, so a message or a decision
    /// finds its row without reading every row before it.
    private var firstRows: [UUID: Int] = [:]
    /// Sent during a run and not taken by it yet: shown after everything
    /// else until the run takes them, then in place like any message.
    private var queued: [ChatMessage] = []
    private var lastEventTime: Date?
    private var thinking: Int?
    private var thinkingStarted: Date?
    private var assistant: Int?
    private var toolRows: [String: Int] = [:]
    /// The reason the agent gave each call (`ToolReason`), by call ID: what
    /// an approval card says first.
    private var callReasons: [String: String] = [:]
    /// The row the turn has shown nothing after yet: its prompt, or images a
    /// tool returned. A running summary stands in under it, under the id the
    /// next thought takes, so the one becomes the other with no gap.
    private var unanswered: UUID?
    /// The run's output so far, from its latest `received`.
    private var receivedTokens: Int?
    /// Where the message streaming now began among `rows`, and the row it
    /// answered then, from its `messageStarted` until anything but its
    /// stream comes: a `messageDiscarded` (kwwk asks for it again) takes
    /// back what it showed, so the reply that follows is not drawn twice.
    private var attempt: (rows: Int, unanswered: UUID?)?
    /// A model request failed and is being made again, and nothing has
    /// come of it yet (`reconnecting`): the running summary says so.
    private var reconnecting = false
    /// What ends `attempt`: anything but its stream, or news that may come
    /// meanwhile (a title, a message queued, the count).
    private static let endsAttempt: Set<String> = [
        "prompt", "steer", "message", "toolCall", "toolResult", "approvalRequested", "approvalResolved",
        "error", "finished", "compactionStarted", "compactionFinished", TaskEvent.stateKind,
    ]
    /// What ends `reconnecting`: the request answered, or the run moved on.
    private static let endsReconnecting = endsAttempt.union(["messageStarted", "thinking", "toolCallPreparing", "text"])

    /// `conversationTitle` names another conversation of the project by its
    /// session ID, for a message its agent sent. `sending` are messages sent
    /// and not echoed yet: each shows last, under its draft's id, until the
    /// host's `prompt` or `queued` event with that id takes its place.
    /// `now` judges whether a running turn has been quiet for
    /// `quietInterval`; without it no summary stands in for the quiet.
    init(
        events: [TaskEvent],
        sending: [ComposerDraft] = [],
        conversationTitle: (String) -> String? = { _ in nil },
        now: Date? = nil,
        attachment: (AgentAttachment) -> ComposerAttachment?,
    ) {
        append(events, sending: sending, conversationTitle: conversationTitle, now: now, attachment: attachment)
    }

    /// Reads `events`, the ones that follow those read so far, and shows the
    /// rows again with `sending` and at `now`, as `init` describes them; an
    /// empty `events` only shows them again.
    mutating func append(
        _ events: some Collection<TaskEvent>,
        sending: [ComposerDraft] = [],
        conversationTitle: (String) -> String? = { _ in nil },
        now: Date? = nil,
        attachment: (AgentAttachment) -> ComposerAttachment?,
    ) {
        // By position: a reopened session's events go on after the earlier
        // task's under a numbering that starts again (`ChatRecord.reopen`).
        for (index, event) in zip(eventCount..., events) {
            let payload = event.payload
            let text = payload?["text"]?.stringValue ?? ""
            let id = Self.rowID("event:\(index)")
            lastEventTime = event.time
            if Self.endsAttempt.contains(event.kind) {
                attempt = nil
            }
            if Self.endsReconnecting.contains(event.kind) {
                reconnecting = false
            }
            switch event.kind {
            case "prompt", "steer":
                finishThinking(at: event.time)
                assistant = nil
                let messageID = Self.userMessageID(of: event) ?? id
                let files = Self.attachments(in: payload?["attachments"])
                queued.removeAll { $0.id == messageID }
                if firstRows[messageID] == nil {
                    var message = ChatMessage(
                        id: messageID,
                        role: .user,
                        text: text,
                        attachments: files.compactMap(attachment),
                    )
                    message.sender = payload?["from"]?.stringValue.map { Self.senderLine(conversationTitle($0)) }
                    add(message)
                }
                unanswered = messageID
                isWorking = true
            case "queued":
                guard let messageID = Self.userMessageID(of: event),
                      firstRows[messageID] == nil, !queued.contains(where: { $0.id == messageID })
                else { break }
                let files = Self.attachments(in: payload?["attachments"])
                var message = ChatMessage(
                    id: messageID,
                    role: .user,
                    text: text,
                    attachments: files.compactMap(attachment),
                )
                message.isQueued = true
                queued.append(message)
            case "queueDropped":
                let ids = Self.identifiers(in: payload?["ids"])
                queued.removeAll { ids.contains($0.id) }
            case "messageStarted":
                assistant = nil
                finishThinking(at: event.time)
                attempt = (rows.count, unanswered)
                startThinking(id: id, at: event.time)
                isWorking = true
            case "messageDiscarded":
                // The rows it made go, and what it answered is unanswered
                // again: the stand-in its thought replaced comes back, and
                // the next attempt's thought takes its id once more.
                guard let attempt else { break }
                rows.removeSubrange(attempt.rows...)
                firstRows = firstRows.filter { $0.value < attempt.rows }
                thinking = nil
                thinkingStarted = nil
                assistant = nil
                unanswered = attempt.unanswered
                self.attempt = nil
            case "reconnecting":
                reconnecting = true
            case "thinking":
                if thinking == nil {
                    startThinking(id: id, at: event.time)
                }
                if let thinking {
                    rows[thinking].text += text
                }
            case "toolCallPreparing":
                // The call shows only once its arguments are whole, so the
                // summary runs meanwhile. The message keeps its one text
                // row: its full text still comes in `message`.
                if thinking == nil {
                    startThinking(id: id, at: event.time)
                }
            case "text", "message":
                finishThinking(at: event.time)
                guard !text.isEmpty else { break }
                unanswered = nil
                if assistant == nil {
                    assistant = rows.count
                    add(ChatMessage(id: id, role: .assistant, text: ""))
                }
                if let assistant {
                    if event.kind == "message" {
                        rows[assistant].text = text
                    } else {
                        rows[assistant].text += text
                    }
                }
            case "toolCall":
                // A call no thought announced heads its summary from where
                // a summary standing in under the last row was.
                if thinking == nil, standInAnchor != nil {
                    startThinking(id: id, at: event.time)
                }
                finishThinking(at: event.time)
                assistant = nil
                unanswered = nil
                if let toolID = payload?["id"]?.stringValue {
                    toolRows[toolID] = rows.count
                    let name = payload?["tool"]?.stringValue ?? ""
                    let arguments = payload?["arguments"]?.stringValue
                    var row = ChatMessage(id: id, role: .tool, text: Self.toolTitle(name, arguments: arguments))
                    row.detail = arguments ?? ""
                    row.banner = ToolCallBanner(tool: name, arguments: arguments, title: row.text)
                    row.awaitsResult = true
                    if let reason = Self.reason(arguments) {
                        callReasons[toolID] = reason
                    }
                    add(row)
                }
            case "toolResult":
                if let toolID = payload?["id"]?.stringValue, let index = toolRows[toolID] {
                    let output = payload?["output"]?.stringValue ?? ""
                    rows[index].detail += "\n\n" + output
                    rows[index].awaitsResult = false
                    if rows[index].banner?.file != nil, payload?["isError"]?.boolValue != true {
                        rows[index].banner?.change = ToolCallBanner.lineChange(in: output)
                    }
                }
                let files = Self.attachments(in: payload?["attachments"])
                if !files.isEmpty {
                    add(ChatMessage(
                        id: id,
                        role: .assistant,
                        text: "",
                        attachments: files.compactMap(attachment),
                    ))
                    unanswered = id
                }
            case "approvalRequested":
                if let approvalID = payload?["approvalID"]?.stringValue {
                    let rowID = Self.rowID(approvalID)
                    approvalIDs[rowID] = approvalID
                    let title = ApprovalCardText.title(payload) ?? Self.toolTitle(
                        payload?["tool"]?.stringValue ?? "",
                        arguments: payload?["arguments"]?.stringValue,
                    )
                    let detail = ApprovalCardText.detail(
                        payload,
                        title: title,
                        callReason: payload?["toolCallID"]?.stringValue.flatMap { callReasons[$0] },
                    )
                    var request = ChatMessage(id: rowID, role: .approval(nil), text: title + "\n\n" + detail)
                    request.runsAsRoot = ApprovalCardText.isRoot(payload)
                    request.approvalSections = ApprovalCardText.sections(
                        payload, title: title,
                        callReason: payload?["toolCallID"]?.stringValue.flatMap { callReasons[$0] },
                    )
                    add(request)
                }
            case "approvalResolved":
                if let approvalID = payload?["approvalID"]?.stringValue,
                   let index = firstRows[Self.rowID(approvalID)]
                {
                    rows[index].role = .approval(payload?["decision"]?.stringValue == "approve" ? .approve : .deny)
                }
            case "error":
                // Also the sessions that recorded a whole NSError before the agent cut it.
                let message = payload?["message"]?.stringValue.map(ErrorDescription.localized)
                add(ChatMessage(id: id, role: .assistant, text: message ?? ""))
            case "received":
                receivedTokens = payload?["tokens"]?.doubleValue.map { Int($0) }
            case "finished":
                finishThinking(at: event.time)
                assistant = nil
                isWorking = false
                receivedTokens = nil
            case "compactionStarted":
                isCompacting = true
            case "compactionFinished":
                isCompacting = false
                if payload?["outcome"]?.stringValue == AgentCompactionResult.Outcome.compacted.rawValue {
                    // text after it is a reply of its own, under it
                    assistant = nil
                    add(ChatMessage(id: id, role: .compaction, text: payload?["summary"]?.stringValue ?? ""))
                }
            case TaskEvent.stateKind:
                if Self.endsTask(event) {
                    finishThinking(at: event.time)
                    isWorking = false
                    isCompacting = false
                    receivedTokens = nil
                }
            default: break
            }
        }
        eventCount += events.count
        show(sending: sending, now: now)
    }

    /// The rows as shown, made afresh from the fold's: what it holds and
    /// `sending` and `now` decide them, never what was shown before.
    private mutating func show(sending: [ComposerDraft], now: Date?) {
        messages = Self.presentationRows(rows)
        quietDeadline = nil
        if isWorking {
            if let unanswered, messages.last?.id == unanswered {
                messages.append(Self.standIn(after: unanswered))
            } else if let reply = Self.standInAnchor(after: messages, unanswered: unanswered),
                      let last = lastEventTime
            {
                let deadline = last.addingTimeInterval(Self.quietInterval)
                if let now, now >= deadline {
                    messages.append(Self.standIn(after: reply))
                } else {
                    quietDeadline = deadline
                }
            }
            Self.keepTrailingSummaryRunning(&messages, receivedTokens: receivedTokens, reconnecting: reconnecting)
        }
        messages += queued
        for draft in sending where !messages.contains(where: { $0.id == draft.id }) {
            var message = ChatMessage(id: draft.id, role: .user, text: draft.text, attachments: draft.attachments)
            // A running turn takes it at its next step, as the host will say.
            message.isQueued = isWorking
            messages.append(message)
        }
    }

    /// Adds a row to the fold's, noting where its id's first row is.
    private mutating func add(_ row: ChatMessage) {
        if firstRows[row.id] == nil {
            firstRows[row.id] = rows.count
        }
        rows.append(row)
    }

    /// The attachments an event lists, read off its payload as decoding
    /// them would: every one, or none when any is not an attachment.
    /// Decoding writes the value out as JSON and reads it back.
    static func attachments(in value: JSONValue?) -> [AgentAttachment] {
        guard case let .array(items)? = value else { return [] }
        var files: [AgentAttachment] = []
        for item in items {
            guard let path = item["path"]?.stringValue, let name = item["name"]?.stringValue,
                  let mimeType = item["mimeType"]?.stringValue
            else { return [] }
            files.append(AgentAttachment(path: path, name: name, mimeType: mimeType))
        }
        return files
    }

    /// The ids a `queueDropped` lists, read as `attachments(in:)` reads:
    /// every one, or none when any is not an id.
    static func identifiers(in value: JSONValue?) -> Set<UUID> {
        guard case let .array(items)? = value else { return [] }
        var ids: Set<UUID> = []
        for item in items {
            guard let id = item.stringValue.flatMap(UUID.init(uuidString:)) else { return [] }
            ids.insert(id)
        }
        return ids
    }

    /// The id of the user message an event shows: a `prompt`, `steer` or
    /// `queued` that carries one.
    static func userMessageID(of event: TaskEvent) -> UUID? {
        guard ["prompt", "steer", "queued"].contains(event.kind) else { return nil }
        return event.payload?["id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// Whether an event is the `state` a task ends with, which ends its
    /// turn: the host appends nothing after it.
    static func endsTask(_ event: TaskEvent) -> Bool {
        guard event.kind == TaskEvent.stateKind else { return false }
        return event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:))?.isTerminal == true
    }

    /// While the turn runs, its last summary stays unfinished across tool
    /// calls and approvals. Each thought ends when a tool starts, so without
    /// this the title would flip between "Thought for…" and the running one.
    /// It carries the run's output so far, the newest call in its trace and
    /// whether a failed request is being made again.
    private static func keepTrailingSummaryRunning(
        _ rows: inout [ChatMessage],
        receivedTokens: Int?,
        reconnecting: Bool,
    ) {
        guard let index = rows.lastIndex(where: { !$0.role.needsApproval }) else { return }
        guard case let .thinking(_, tools) = rows[index].role else {
            settleCount(&rows, reply: index, receivedTokens: receivedTokens)
            return
        }
        rows[index].role = .thinking(seconds: nil, tools: tools)
        rows[index].runningTools = rows[index].trace.count(where: \.awaitsResult)
        rows[index].receivedTokens = receivedTokens
        rows[index].banner = rows[index].trace.last { $0.role == .tool }?.banner
        rows[index].isReconnecting = reconnecting
    }

    /// While the run writes a reply, the summary just above it is finished
    /// and keeps the run's count, which settles there; never a summary above
    /// the turn's own message.
    private static func settleCount(_ rows: inout [ChatMessage], reply: Int, receivedTokens: Int?) {
        guard receivedTokens != nil, rows[reply].role == .assistant,
              let summary = rows[..<reply].lastIndex(where: { $0.role != .assistant }),
              case .thinking = rows[summary].role
        else { return }
        rows[summary].receivedTokens = receivedTokens
        rows[summary].receivedSettles = true
    }

    /// The running summary that stands in under `row` until the turn shows
    /// what follows it, under the id the next thought will take.
    private static func standIn(after row: UUID) -> ChatMessage {
        ChatMessage(id: firstThoughtID(after: row), role: .thinking(seconds: nil, tools: 0), text: "")
    }

    /// Folds the thoughts, calls and approvals between two replies into one
    /// summary, which counts only the calls in its own trace.
    static func presentationRows(_ messages: [ChatMessage]) -> [ChatMessage] {
        var combined: [ChatMessage] = []
        var summary: Int?
        for (index, message) in messages.enumerated() {
            switch message.role {
            case let .thinking(seconds, _):
                // A finished thought with no text adds only its time: to the
                // summary it follows, or to a new one for the call after it.
                let isEmpty = seconds != nil && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if let summary, case let .thinking(previousSeconds, tools) = combined[summary].role {
                    let totalSeconds = previousSeconds.flatMap { elapsed in seconds.map { elapsed + $0 } }
                    combined[summary].role = .thinking(seconds: totalSeconds, tools: tools)
                    guard !isEmpty else { break }
                    combined[summary].text = [combined[summary].text, message.text].filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                    combined[summary].trace.append(message)
                } else {
                    guard !isEmpty || Self.callFollows(messages, index) else { break }
                    summary = combined.count
                    var header = message
                    header.role = .thinking(seconds: seconds, tools: 0)
                    header.trace = isEmpty ? [] : [message]
                    combined.append(header)
                }
            case .tool, .approval:
                if summary == nil {
                    summary = combined.count
                    combined.append(ChatMessage(
                        id: Self.rowID("trace:\(message.id)"),
                        role: .thinking(seconds: 0, tools: 0),
                        text: "",
                    ))
                }
                if let summary {
                    combined[summary].trace.append(message)
                    if case let .thinking(seconds, _) = combined[summary].role {
                        let calls = combined[summary].trace.count(where: { $0.role == .tool })
                        combined[summary].role = .thinking(seconds: seconds, tools: calls)
                    }
                }
                if message.role.needsApproval {
                    combined.append(message)
                }
            case .user, .assistant, .compaction:
                summary = nil
                combined.append(message)
            }
        }
        return combined.filter {
            if case let .thinking(seconds?, tools) = $0.role {
                return seconds > 0 || tools > 0
            }
            return true
        }
    }

    /// Whether a call or an approval comes right after the row at `index`:
    /// the thought before a call heads the summary that holds it.
    private static func callFollows(_ rows: [ChatMessage], _ index: Int) -> Bool {
        guard rows.indices.contains(index + 1) else { return false }
        let next = rows[index + 1].role
        return next == .tool || next.isApproval
    }

    /// The last of the fold's rows, when a running summary may stand in
    /// under it (`standInAnchor(after:unanswered:)`).
    private var standInAnchor: UUID? {
        Self.standInAnchor(after: rows, unanswered: unanswered)
    }

    /// The last of `rows`, when a running summary may stand in under it:
    /// the turn's unanswered row, or a reply (or an error) it showed last,
    /// under which one stands in once the turn has gone quiet.
    private static func standInAnchor(after rows: [ChatMessage], unanswered: UUID?) -> UUID? {
        guard let last = rows.last, last.id == unanswered || last.role == .assistant else { return nil }
        return last.id
    }

    /// A thought right after a row a summary may have stood in under takes
    /// the id the stand-in had.
    private mutating func startThinking(id: UUID, at date: Date) {
        let id = standInAnchor.map(Self.firstThoughtID) ?? unanswered.map(Self.firstThoughtID) ?? id
        thinking = rows.count
        thinkingStarted = date
        unanswered = nil
        add(ChatMessage(id: id, role: .thinking(seconds: nil, tools: 0), text: ""))
    }

    private static func firstThoughtID(after row: UUID) -> UUID {
        rowID("answer:\(row)")
    }

    private mutating func finishThinking(at date: Date) {
        guard let thinking else { return }
        let seconds = max(0, Int(date.timeIntervalSince(thinkingStarted ?? date)))
        rows[thinking].role = .thinking(seconds: seconds, tools: 0)
        self.thinking = nil
        thinkingStarted = nil
    }

    /// What a message from another conversation says over its bubble.
    static func senderLine(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return String(localized: "From another chat") }
        return String(localized: "From \(title)")
    }

    /// The reason in a call's arguments, trimmed; nil when it gave none.
    private static func reason(_ arguments: String?) -> String? {
        let values = arguments.flatMap { try? JSONCoding.decode(JSONValue.self, from: Data($0.utf8)) }
        let reason = values?["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? nil : reason
    }

    /// A call's title, by the tool it names: today's name or one an earlier
    /// release recorded (`AgentToolName.canonical`), so an old conversation
    /// reads as a new one does. A tool added without a title does not build.
    private static func toolTitle(_ name: String, arguments: String?) -> String {
        guard let tool = AgentToolName.canonical(name) else {
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let values = arguments.flatMap { try? JSONCoding.decode(JSONValue.self, from: Data($0.utf8)) }
        let path = values?["path"]?.stringValue ?? ""
        switch tool {
        case .fileRead: return path.isEmpty ? String(localized: "Read a file") : String(localized: "Read \(path)")
        case .fileWrite, .fileCreate:
            return path.isEmpty ? String(localized: "Write a file") : String(localized: "Write \(path)")
        case .fileEdit: return path.isEmpty ? String(localized: "Edit a file") : String(localized: "Edit \(path)")
        case .fileList: return String(localized: "List files")
        case .fileGrep, .fileFind: return String(localized: "Search files")
        case .fileShow:
            guard case let .array(items)? = values?["paths"] else { return String(localized: "Show a file") }
            let paths = items.compactMap(\.stringValue)
            if paths.count > 1 {
                return String(localized: "Show \(paths.count) files")
            }
            return paths.first.map { String(localized: "Show \($0)") } ?? String(localized: "Show a file")
        case .shellRun: return String(localized: "Run a command")
        case .sdkAnalyzeFramework, .sdkReadHeader: return String(localized: "Read the SDK")
        case .projectBuild: return String(localized: "Build the project")
        case .packageInstall: return String(localized: "Install the package")
        case .packageRemove: return String(localized: "Remove the package")
        case .packageList: return String(localized: "List installed packages")
        case .packagePublish: return String(localized: "Publish to the package repository")
        case .packageConfirmLoaded: return String(localized: "Check the tweak loaded")
        case .screenCapture: return String(localized: "Capture the screen")
        case .screenReadTree: return String(localized: "Inspect the screen")
        case .screenInteract: return String(localized: "Interact with the screen")
        case .logRead: return String(localized: "Read logs")
        case .crashList, .crashRead: return String(localized: "Read crash reports")
        case .crashSymbolicate: return String(localized: "Symbolicate a crash")
        case .deviceRespring: return String(localized: "Restart SpringBoard")
        case .memoryList: return String(localized: "Read memories")
        case .memorySave: return String(localized: "Save a memory")
        case .memoryDelete: return String(localized: "Delete a memory")
        case .skillList: return String(localized: "List skills")
        case .skillRead: return String(localized: "Read a skill")
        case .skillSave: return String(localized: "Save a skill")
        case .skillRemove: return String(localized: "Remove a skill")
        case .projectCheckDistribution: return String(localized: "Check for distribution")
        case .gitStatus: return String(localized: "Check the repository")
        case .gitDiff: return String(localized: "Read the changes")
        case .gitStage: return String(localized: "Stage changes")
        case .gitUnstage: return String(localized: "Unstage changes")
        case .gitCommit: return String(localized: "Commit changes")
        case .gitInit: return String(localized: "Create repository")
        case .gitFetch: return String(localized: "Fetch from the remote")
        case .gitPull: return String(localized: "Pull from the remote")
        case .gitPush: return String(localized: "Push to the remote")
        case .gitClone: return String(localized: "Import the repository")
        case .gitSquash: return String(localized: "Squash commits")
        case .gitRemoteList: return String(localized: "List the remotes")
        case .gitRemoteSet: return String(localized: "Set a remote")
        case .gitRemoteRemove: return String(localized: "Remove a remote")
        case .gitResetToRemote: return String(localized: "Reset to the remote")
        case .gitReadSettings: return String(localized: "Read the Git settings")
        case .gitSetAuthor: return String(localized: "Set the commit author")
        case .gitSaveCredential: return String(localized: "Save a Git credential")
        case .gitRemoveCredential: return String(localized: "Remove a Git credential")
        case .gitCreateRepository: return String(localized: "Create a GitHub repository")
        case .gitCreateIssue: return String(localized: "Create a GitHub issue")
        case .conversationCreate: return String(localized: "Create a chat")
        case .conversationSend: return String(localized: "Send to a chat")
        case .conversationList: return String(localized: "List chats")
        case .conversationRead: return String(localized: "Read a chat")
        case .conversationStop: return String(localized: "Stop a chat")
        case .notificationSend: return String(localized: "Send a notification")
        case .webFetch:
            let host = values?["url"]?.stringValue.flatMap { URLComponents(string: $0)?.host } ?? ""
            return host.isEmpty ? String(localized: "Read a webpage") : String(localized: "Read \(host)")
        case .feedbackSend: return String(localized: "Send feedback")
        case .feedbackRead: return String(localized: "Read a feedback issue")
        case .feedbackEdit: return String(localized: "Edit a feedback issue")
        case .toolchainList: return String(localized: "List toolchains")
        case .sdkList: return String(localized: "List SDKs")
        case .toolchainSetup: return String(localized: "Set up a toolchain")
        case .sdkImport: return String(localized: "Import an SDK")
        case .toolchainSelfTest: return String(localized: "Test the toolchain")
        case .projectSetEnvironment: return String(localized: "Switch the toolchain or SDK")
        case .templateList: return String(localized: "List project templates")
        case .projectList: return String(localized: "List projects")
        case .projectRename: return String(localized: "Rename the project")
        case .projectDelete: return String(localized: "Delete a project")
        case .projectCreate:
            let project = values?["name"]?.stringValue ?? ""
            return project.isEmpty ? String(localized: "Create a project") : String(localized: "Create \(project)")
        }
    }

    private static func rowID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        ))
    }
}
