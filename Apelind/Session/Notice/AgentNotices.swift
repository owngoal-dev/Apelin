import ApelinCore
import ApelinProtocol
import Foundation

/// A banner the session host posts as the app (`NoticePoster`): a turn of an
/// agent session ended, the session waits for the reader's decision, or its
/// agent asked to tell the reader something (`apelin_notification_send`).
struct AgentNotice: Equatable, Sendable {
    /// The same for the same event however often the session's events are
    /// relayed again, so posting it twice replaces it instead of doubling it.
    var identifier: String
    /// The banners' thread, and the conversation a tap opens.
    var sessionID: String
    var title: Text
    var subtitle: Text?
    var body: Text?

    /// What a tap hands to the app's own URL handling.
    var link: String {
        "apelin://conversation/" + sessionID
    }

    enum Text: Equatable, Sendable {
        /// The agent's or the reader's own words.
        case verbatim(String)
        /// A key of the app's catalogue, which the system resolves when it
        /// shows the banner, in the app's language. The app spells each one
        /// too, so none is an orphan: "New Chat" (ChatRuntime), "Approval
        /// Required" and "Root Approval Required" (ChatApprovalRow), "Done"
        /// and "Failed" (EnvironmentTaskController).
        case key(String)
    }
}

/// How many turns ended, approvals were asked and notices the agent sent in
/// a session, in the order its event log holds them.
struct AgentNoticeMarks: Codable, Equatable, Sendable {
    var turns = 0
    var approvals = 0
    var notices = 0

    func union(_ other: AgentNoticeMarks) -> AgentNoticeMarks {
        AgentNoticeMarks(
            turns: max(turns, other.turns),
            approvals: max(approvals, other.approvals),
            notices: max(notices, other.notices),
        )
    }
}

extension AgentNoticeMarks {
    /// A count `notices.json` does not hold is none: marks written before
    /// agents could send notices keep their turns and approvals.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        turns = try values.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        approvals = try values.decodeIfPresent(Int.self, forKey: .approvals) ?? 0
        notices = try values.decodeIfPresent(Int.self, forKey: .notices) ?? 0
    }
}

/// What one agent task has relayed, as far as its banners go. A session that
/// opens again — after its worker or the host restarted — relays its whole
/// event log into a new task before anything new, so the events are counted
/// from the start of each task, and one at or below the session's marks
/// (what an earlier task already decided) is a replay and posts nothing.
struct AgentNoticeTrack: Sendable {
    let sessionID: String
    /// Opened with `closeWhenFinished`: a console run or a test, which posts
    /// nothing.
    var headless: Bool
    private(set) var marks = AgentNoticeMarks()
    private var firstPrompt: String?
    private var lastMessage: String?
    private var lastError: String?
    /// Each call's `reason`, by tool call ID, until its turn ends.
    private var reasons: [String: String] = [:]
    /// The agent's notices since the last prompt or turn end. Every run
    /// starts with a prompt, so this never counts more than the agent's own
    /// count for its run (`UserNotices`): what the agent was told went, goes.
    private var turnNotices = 0

    init(sessionID: String, headless: Bool = false) {
        self.sessionID = sessionID
        self.headless = headless
    }

    /// The event kinds a track reads; the host skips the rest unread.
    static let kinds: Set<String> = [
        "prompt", "message", "error", "toolCall", "approvalRequested", "finished", AgentNoticeRules.eventKind,
    ]

    /// Takes the task's next event and answers the banner it makes: an
    /// `approvalRequested`, a `finished` turn that completed or failed, or
    /// the agent's `notice`. None for a turn the reader stopped, for a
    /// notice past `AgentNoticeRules.maximumPerTurn` or with no text, for a
    /// headless session, or for an event `posted` already counts. `title`:
    /// the session's own, from its latest `title` event.
    mutating func take(
        _ kind: String,
        payload: JSONValue?,
        title: String?,
        posted: AgentNoticeMarks,
    ) -> AgentNotice? {
        switch kind {
        case "prompt":
            turnNotices = 0
            if firstPrompt == nil {
                firstPrompt = AgentConversationRules.title(payload?["text"]?.stringValue)
            }
        case "message":
            if let text = payload?["text"]?.stringValue, AgentNoticeText.excerpt(text) != nil {
                lastMessage = text
            }
        case "error":
            if let message = payload?["message"]?.stringValue, !message.isEmpty {
                lastError = message
            }
        case "toolCall":
            if let id = payload?["id"]?.stringValue,
               let reason = AgentNoticeText.reason(arguments: payload?["arguments"]?.stringValue)
            {
                reasons[id] = reason
            }
        case "approvalRequested":
            marks.approvals += 1
            guard !headless, marks.approvals > posted.approvals else { return nil }
            // The agent's words for the call, else why the gate asked.
            let reason = payload?["toolCallID"]?.stringValue.flatMap { reasons[$0] }
                ?? payload?["reason"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return AgentNotice(
                identifier: "\(sessionID).approval.\(marks.approvals)",
                sessionID: sessionID,
                title: conversation(title),
                subtitle: .key(AgentApprovals.isRootRequest(payload) ? "Root Approval Required" : "Approval Required"),
                body: reason.map(AgentNotice.Text.verbatim),
            )
        case "finished":
            marks.turns += 1
            defer {
                lastMessage = nil
                lastError = nil
                reasons = [:]
                turnNotices = 0
            }
            guard !headless, marks.turns > posted.turns else { return nil }
            let excerpt = lastMessage.flatMap { AgentNoticeText.excerpt($0) }
            let identifier = "\(sessionID).turn.\(marks.turns)"
            switch payload?["reason"]?.stringValue {
            case "completed":
                return AgentNotice(
                    identifier: identifier,
                    sessionID: sessionID,
                    title: conversation(title),
                    body: excerpt.map(AgentNotice.Text.verbatim) ?? .key("Done"),
                )
            case "failed":
                return AgentNotice(
                    identifier: identifier,
                    sessionID: sessionID,
                    title: conversation(title),
                    subtitle: .key("Failed"),
                    body: (lastError ?? excerpt).map(AgentNotice.Text.verbatim),
                )
            default:
                // `aborted`: the reader stopped it, and knows.
                return nil
            }
        case AgentNoticeRules.eventKind:
            marks.notices += 1
            turnNotices += 1
            // Plain and bounded again here: the event is the worker's, and
            // its text the model's.
            guard !headless, marks.notices > posted.notices, turnNotices <= AgentNoticeRules.maximumPerTurn,
                  let body = AgentNoticeRules.bounded(
                      payload?["body"]?.stringValue,
                      limit: AgentNoticeRules.maximumBodyLength,
                  )
            else { return nil }
            let headline = AgentNoticeRules.bounded(
                payload?["title"]?.stringValue,
                limit: AgentNoticeRules.maximumTitleLength,
            )
            return AgentNotice(
                identifier: "\(sessionID).notice.\(marks.notices)",
                sessionID: sessionID,
                title: conversation(title),
                subtitle: headline.map(AgentNotice.Text.verbatim),
                body: .verbatim(body),
            )
        default:
            break
        }
        return nil
    }

    /// The session's title, else its first message's opening — what the
    /// app's sidebar names a conversation the agent has not titled yet.
    private func conversation(_ title: String?) -> AgentNotice.Text {
        (AgentConversationRules.title(title) ?? firstPrompt).map(AgentNotice.Text.verbatim) ?? .key("New Chat")
    }
}

enum AgentNoticeText {
    /// About two lines of a banner.
    static let excerptLength = 180

    /// The first paragraph of an assistant message as plain text, at most
    /// `limit` characters: code blocks, headings, rules and tables passed
    /// over, list and quote markers, emphasis, inline code and link targets
    /// taken off. Nil when nothing is left.
    static func excerpt(_ markdown: String, limit: Int = excerptLength) -> String? {
        var parts: [String] = []
        var inFence = false
        for raw in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isFence = line.hasPrefix("```") || line.hasPrefix("~~~")
            if isFence {
                inFence.toggle()
            }
            if isFence || inFence || line.isEmpty || isStructure(line) {
                // Passed over before the paragraph; after it, its end.
                guard parts.isEmpty else { break }
                continue
            }
            let text = plain(line)
            if !text.isEmpty {
                parts.append(text)
            }
        }
        let joined = parts.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !joined.isEmpty else { return nil }
        guard joined.count > limit else { return joined }
        var cut = String(joined.prefix(limit - 1))
        // Back to the last word boundary, unless that loses most of a line.
        if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) < 30 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// The `reason` an agent gives every tool call (`ToolReason`), from the
    /// call's arguments as the `toolCall` event carries them.
    static func reason(arguments: String?) -> String? {
        guard let arguments,
              let values = try? JSONCoding.decode(JSONValue.self, from: Data(arguments.utf8)),
              let reason = values["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty
        else { return nil }
        return reason
    }

    /// A heading, a rule, a table row or display math: not a sentence.
    private static func isStructure(_ line: String) -> Bool {
        if line.range(of: "^#{1,6}(\\s|$)", options: .regularExpression) != nil {
            return true
        }
        if line.range(of: "^([-*_]\\s*){3,}$", options: .regularExpression) != nil {
            return true
        }
        return line.hasPrefix("|") || line.hasPrefix("$$")
    }

    private static func plain(_ line: String) -> String {
        let rules: [(pattern: String, template: String)] = [
            ("^(>\\s*)+", ""),
            ("^([-*+]|\\d{1,3}[.)])\\s+", ""),
            ("^\\[[ xX]\\]\\s+", ""),
            ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
            ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
            ("(\\*\\*|__|~~|`)", ""),
            ("\\*([^*\\s][^*]*)\\*", "$1"),
        ]
        return rules.reduce(line) { text, rule in
            text.replacingOccurrences(of: rule.pattern, with: rule.template, options: .regularExpression)
        }
        .trimmingCharacters(in: .whitespaces)
    }
}

/// The session host's banners for agent sessions. It reads every agent
/// task's events as the host relays them (`relayed`) and posts what
/// `AgentNoticeTrack` decides; each session's marks are kept in
/// `notices.json` in the host's state directory, so a session the app opens
/// again after a restart does not announce its old turns a second time.
/// Marks of a session whose event log is gone are dropped when it loads.
actor AgentNotices {
    private let file: URL
    private let post: @Sendable (AgentNotice) -> Void
    private var marks: [String: AgentNoticeMarks]
    private var tracks: [TaskID: AgentNoticeTrack] = [:]

    /// `sessions`: where each session's event log lives (`DataFolder.sessions`).
    init(file: URL, sessions: URL, post: @escaping @Sendable (AgentNotice) -> Void) {
        self.file = file
        self.post = post
        // Each session's marks read on their own: one that does not read is
        // that session's alone, and a file that does not read at all is set
        // aside rather than written over with none.
        var saved: [String: AgentNoticeMarks] = [:]
        if let data = try? Data(contentsOf: file) {
            if let entries = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                for (session, value) in entries {
                    saved[session] = try? JSONDecoder().decode(AgentNoticeMarks.self, from: JSONCoding.encode(value))
                }
            } else {
                UnreadableFile.setAside(file)
            }
        }
        marks = saved.filter { session, _ in
            UUID(uuidString: session) != nil
                && FileManager.default.fileExists(atPath: sessions.appendingPathComponent(session).path)
        }
    }

    /// An agent session's task, before its worker hears of it.
    func opened(session: String, task: TaskID, headless: Bool) {
        tracks[task] = AgentNoticeTrack(sessionID: session, headless: headless)
    }

    /// One event the host relayed into a task, in order.
    func relayed(_ record: TaskRegistry.Record, kind: String, payload: JSONValue?) async {
        guard record.kind == .agent, let session = record.ownerKey else { return }
        if kind == TaskEvent.stateKind {
            if let name = payload?["state"]?.stringValue, TaskState(rawValue: name)?.isTerminal == true {
                tracks[record.id] = nil
            }
            return
        }
        guard AgentNoticeTrack.kinds.contains(kind) else { return }
        // Read before the track: nothing suspends between taking the track
        // and putting it back.
        let title = await AgentSessionTable.shared.entry(session)?.title
        var track = tracks[record.id] ?? AgentNoticeTrack(sessionID: session)
        let posted = marks[session] ?? AgentNoticeMarks()
        let notice = track.take(kind, payload: payload, title: title, posted: posted)
        tracks[record.id] = track
        let advanced = posted.union(track.marks)
        if advanced != posted {
            marks[session] = advanced
            save()
        }
        if let notice {
            post(notice)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
