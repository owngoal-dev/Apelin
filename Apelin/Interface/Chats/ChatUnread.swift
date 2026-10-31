import ApelinProtocol
import Foundation

/// Which conversations hold a reply the reader has not seen (issue #28):
/// a yellow dot on the sidebar's row, and a count beside each project in
/// the project menu, so the reader finds the project and then the
/// conversation.
///
/// A conversation becomes unread when its task brings a reply while the
/// reader is not looking at it (`ChatRuntime.viewedChat`): an assistant
/// message with text, an error, the end of a turn the reader did not stop,
/// or an approval asked. A reopened session's replay of its history never
/// does, since `ChatRecord.take` reads past it, and neither do the reader's
/// own messages, a title, a queued echo or a count. Looking at it reads it,
/// and so does writing in it. Unread is kept apart from working: the row
/// shows its spinner while it works and the dot only once it is at rest,
/// and the menu counts the conversations that show the dot.
enum ChatUnread {
    /// Whether `event` brings something the reader should come back for.
    static func isReply(_ event: TaskEvent) -> Bool {
        switch event.kind {
        case "message":
            !(event.payload?["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "error", "approvalRequested":
            true
        case "finished":
            // `aborted`: the reader stopped it, and knows, as the
            // notifications say
            event.payload?["reason"]?.stringValue != "aborted"
        default:
            false
        }
    }

    /// A project menu row's title: its name, then how many of its
    /// conversations wait unread, as `Pineora - 3`; the name alone when
    /// none does.
    static func menuTitle(_ name: String, unread: Int) -> String {
        unread > 0 ? String(localized: "\(name) - \(unread)") : name
    }

    /// How many conversations show as unread (`ChatSummary.showsUnread`),
    /// in General Chat and in each project.
    struct Counts: Equatable {
        /// The temporary conversations', General Chat's.
        var general = 0
        /// By project folder name; a project with none is absent.
        var projects: [String: Int] = [:]

        init(_ chats: some Sequence<ChatSummary>) {
            for chat in chats where chat.showsUnread {
                if let name = chat.projectName {
                    projects[name, default: 0] += 1
                } else {
                    general += 1
                }
            }
        }

        /// The projects' together, for a submenu that holds them.
        func total(of names: some Sequence<String>) -> Int {
            names.reduce(0) { $0 + (projects[$1] ?? 0) }
        }
    }
}

extension ChatSummary {
    /// What the sidebar's dot and the project menu's counts show: a reply
    /// waits unread, and the conversation is at rest. While it works, its
    /// spinner shows instead.
    var showsUnread: Bool {
        isUnread && !isWorking
    }

    /// Takes `events`, just read from the conversation's task, and marks it
    /// unread when one is a reply (`ChatUnread.isReply`) and the reader is
    /// not looking at it. Returns whether that changed it.
    @discardableResult
    mutating func noteReplies(in events: some Sequence<TaskEvent>, isViewed: Bool) -> Bool {
        guard !isUnread, !isViewed, events.contains(where: ChatUnread.isReply) else { return false }
        isUnread = true
        return true
    }

    /// The reader looked at it, or wrote in it. Returns whether it was
    /// unread.
    @discardableResult
    mutating func markRead() -> Bool {
        defer { isUnread = false }
        return isUnread
    }
}
