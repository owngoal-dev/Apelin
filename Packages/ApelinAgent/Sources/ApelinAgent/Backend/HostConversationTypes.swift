import enum ApelinProtocol.ApelinLink
import Foundation

// MARK: - conversations

/// Every conversation call reaches the session's own project, or another
/// project it names (`target`), only through the host: it opens, lists and
/// reads that project's conversations and stops the ones the caller opened,
/// and under Strict reaches another project only as the user approved.
public struct ConversationCreateToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// The first message, read by the other agent as the user's.
    public var prompt: String
    public var title: String?
    /// Another project to open it in; nil for the session's own.
    public var target: ProjectIdentity?
    public init(context: HostCallContext, prompt: String, title: String? = nil, target: ProjectIdentity? = nil) {
        self.context = context
        self.prompt = prompt
        self.title = title
        self.target = target
    }
}

/// Names the project the conversation opened in every time, and says so
/// when that is the caller's own: a call that leaves `project` out opens
/// there, which a model following "create a workspace, then open its
/// conversation" read as the new workspace (issue #79).
public struct ConversationCreateToolResponse: Sendable, Hashable, Codable {
    public var sessionID: String
    public var taskID: String
    /// `apelin://conversation/<session id>`, which opens it in the app.
    public var link: String
    /// The project it opened in, by folder, its projectID and its link.
    public var project: String
    public var projectID: String
    public var projectLink: String
    /// It opened in the caller's own project.
    public var isThisProject: Bool
    /// What that means, when it did: set only then.
    public var note: String?
    public init(sessionID: String, taskID: String, project: ProjectIdentity, isThisProject: Bool) {
        self.sessionID = sessionID
        self.taskID = taskID
        link = ApelinLink.conversation(sessionID)
        self.project = project.name.rawValue
        projectID = project.id
        projectLink = ApelinLink.project(project.id)
        self.isThisProject = isThisProject
        note = isThisProject
            ? "It opened in this conversation's own project, \(project.name.rawValue). For another project, such as a workspace apelin_project_create just made, pass project (its folder name or projectID)."
            : nil
    }
}

public struct ConversationSendToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var sessionID: String
    public var text: String
    /// The project the conversation is in, when not the session's own.
    public var target: ProjectIdentity?
    public init(context: HostCallContext, sessionID: String, text: String, target: ProjectIdentity? = nil) {
        self.context = context
        self.sessionID = sessionID
        self.text = text
        self.target = target
    }
}

public struct ConversationListToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// Another project whose conversations to list; nil for the session's own.
    public var target: ProjectIdentity?
    public init(context: HostCallContext, target: ProjectIdentity? = nil) {
        self.context = context
        self.target = target
    }
}

public struct ConversationStopToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var sessionID: String
    /// Also end the conversation, not only its turn.
    public var close: Bool
    public init(context: HostCallContext, sessionID: String, close: Bool = false) {
        self.context = context
        self.sessionID = sessionID
        self.close = close
    }
}

/// What a send or a stop did.
public struct ConversationActionToolResponse: Sendable, Hashable, Codable {
    public var sessionID: String
    /// `sent`, `stopped` or `closed`.
    public var done: String
    public init(sessionID: String, done: String) {
        self.sessionID = sessionID
        self.done = done
    }
}

public struct ConversationSummary: Sendable, Hashable, Codable {
    public var sessionID: String
    /// `apelin://conversation/<session id>`.
    public var link: String
    public var title: String?
    /// The project's folder, when not the session's own.
    public var project: String?
    /// `open` (running a turn or idle), `waitingForApproval` or `ended`.
    public var state: String
    /// The conversation whose agent opened it; nil for the user's.
    public var openedBy: String?
    public var updatedAt: Date
    public var isThisConversation: Bool
    public init(
        sessionID: String,
        title: String? = nil,
        project: String? = nil,
        state: String,
        openedBy: String? = nil,
        updatedAt: Date,
        isThisConversation: Bool = false,
    ) {
        self.sessionID = sessionID
        link = ApelinLink.conversation(sessionID)
        self.title = title
        self.project = project
        self.state = state
        self.openedBy = openedBy
        self.updatedAt = updatedAt
        self.isThisConversation = isThisConversation
    }
}

public struct ConversationListToolResponse: Sendable, Hashable, Codable {
    public var conversations: [ConversationSummary]
    /// What the list left out, and how to list it.
    public var note: String?
    public init(conversations: [ConversationSummary], note: String? = nil) {
        self.conversations = conversations
        self.note = note
    }
}

public struct ConversationReadToolRequest: Sendable, Hashable, Codable {
    /// apelin_conversation_read waits at most three minutes. The provider
    /// keeps a conversation's prompt cached for five minutes from the start
    /// of the request that last used it (Anthropic's default; OpenAI's is
    /// about as short), and a longer wait makes the reader's next request
    /// write its whole conversation into the cache again. Waiting again
    /// costs a read of that cache instead.
    public static let maximumWaitSeconds = 180

    public var context: HostCallContext
    public var sessionID: String
    /// Only what came after this point; nil for the whole conversation.
    public var afterSeq: UInt64?
    /// 0 to `maximumWaitSeconds`.
    public var waitSeconds: Int
    /// The project the conversation is in, when not the session's own.
    public var target: ProjectIdentity?
    public init(
        context: HostCallContext,
        sessionID: String,
        afterSeq: UInt64? = nil,
        waitSeconds: Int = 0,
        target: ProjectIdentity? = nil,
    ) {
        self.context = context
        self.sessionID = sessionID
        self.afterSeq = afterSeq
        self.waitSeconds = waitSeconds
        self.target = target
    }
}

public enum ConversationState: String, Sendable, Hashable, Codable {
    /// A turn is going.
    case running
    /// It asked the user and waits for the answer.
    case waitingForApproval
    /// Its last turn finished; it waits for a message.
    case idle
    /// Closed, failed or stopped with the session host; it takes no more
    /// messages until the user reopens it.
    case ended
}

public struct ConversationMessage: Sendable, Hashable, Codable {
    public var seq: UInt64
    /// `assistant`, or `error` for a failure it reported.
    public var role: String
    public var text: String
    public init(seq: UInt64, role: String, text: String) {
        self.seq = seq
        self.role = role
        self.text = text
    }
}

public struct ConversationApproval: Sendable, Hashable, Codable {
    public var approvalID: String
    public var tool: String
    public var reason: String
    public init(approvalID: String, tool: String, reason: String) {
        self.approvalID = approvalID
        self.tool = tool
        self.reason = reason
    }
}

public struct ConversationReadToolResponse: Sendable, Hashable, Codable {
    public var sessionID: String
    /// `apelin://conversation/<session id>`.
    public var link: String
    public var title: String?
    public var state: ConversationState
    public var messages: [ConversationMessage]
    /// Approvals it waits on, which only the user can give; none once it
    /// has ended.
    public var pendingApprovals: [ConversationApproval]
    /// Pass as after_seq to read on from here.
    public var lastSeq: UInt64
    /// The messages were cut at a bound; read again from `lastSeq` for the rest.
    public var truncated: Bool
    /// The wait ran out before the turn ended.
    public var timedOut: Bool
    public init(
        sessionID: String,
        title: String? = nil,
        state: ConversationState,
        messages: [ConversationMessage] = [],
        pendingApprovals: [ConversationApproval] = [],
        lastSeq: UInt64,
        truncated: Bool = false,
        timedOut: Bool = false,
    ) {
        self.sessionID = sessionID
        link = ApelinLink.conversation(sessionID)
        self.title = title
        self.state = state
        self.messages = messages
        self.pendingApprovals = pendingApprovals
        self.lastSeq = lastSeq
        self.truncated = truncated
        self.timedOut = timedOut
    }
}

/// A conversation call that did not happen, in words the model can act on.
public struct ConversationToolFailure: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var errorDescription: String? {
        message
    }

    public init(message: String) {
        self.message = message
    }
}
