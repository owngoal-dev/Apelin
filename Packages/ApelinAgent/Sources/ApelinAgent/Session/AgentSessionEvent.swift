import ApelinProtocol
import Foundation

/// What a session tells the app. Each one is written to the session's event
/// log with a sequence number before it is delivered, so an app that was
/// killed, resprung or suspended reattaches with `afterSeq` and misses
/// nothing.
public enum AgentSessionEvent: Sendable, Hashable, Codable {
    /// A prompt entered the session (also queued follow-ups). `from`: the
    /// conversation of this project whose agent sent it, not the user.
    case promptSubmitted(text: String, from: String? = nil)
    case userMessage(id: UUID, text: String, attachments: [AgentAttachment])
    /// A message sent while a run was going: queued for the run's next
    /// step, and a `userMessage` of the same id once the run takes it.
    case userMessageQueued(id: UUID, text: String, attachments: [AgentAttachment])
    /// Queued messages the run never took, because it was stopped first.
    case queuedMessagesDropped(ids: [UUID])
    case titleUpdated(String)
    case projectNameSuggested(String)
    /// A steering message was queued for the running turn.
    case steered(text: String)
    /// A model turn started streaming.
    case messageStarted
    /// The message streaming since the last `messageStarted` was given up
    /// and is asked for again: its text and thinking are not the reply.
    case messageDiscarded
    /// A model request failed and is being made again: kwwk's retry, or a
    /// failed handshake asked again (`NetworkRecovery`).
    case reconnecting
    /// A model request failed with no route to the network, and waits for
    /// one before it is made again (`NetworkRecovery`).
    case waitingForNetwork
    /// Streamed assistant text.
    case textDelta(String)
    /// Streamed reasoning text.
    case thinkingDelta(String)
    /// The model began writing a tool call; the call itself follows once its
    /// arguments are whole, which for a long file can take a while.
    case toolCallPreparing
    /// The assistant message is complete; `text` is all of its text.
    case messageFinished(text: String)
    /// The output tokens the run has received so far (`OutputTally`):
    /// recorded a few times a second while a message streams, and when it
    /// ends, at the provider's count where it gave one.
    case received(tokens: Int)
    case toolCallStarted(ToolCallRecord)
    case toolCallFinished(ToolResultRecord)
    /// The session is waiting: nothing runs until `approve` answers, and an
    /// app that is not connected leaves it waiting.
    case approvalRequested(ApprovalRequest)
    case approvalResolved(requestID: String, decision: ApprovalDecision)
    /// The agent asked Apelin to tell the user something while they are
    /// away (`apelin_notification_send`): plain text within `AgentNoticeRules`' lengths,
    /// which the session host posts as a banner by its own rules.
    case notice(title: String?, body: String)
    /// `reason`: why a model request failed, where the agent can tell
    /// (`FailureReason`); the message stays the provider's own words.
    case error(message: String, reason: ApelinError.Reason? = nil)
    /// A run ended.
    case finished(reason: FinishReason)
    /// The app asked to compact the conversation, between runs.
    case compactionStarted
    /// The compaction ended; a message sent meanwhile starts its run now.
    case compactionFinished(AgentCompactionResult)
}

public enum FinishReason: String, Sendable, Hashable, Codable {
    case completed
    case aborted
    case failed
}

public struct ToolCallRecord: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    /// The arguments as JSON text.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResultRecord: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    /// The text the model saw, bounded. Images are recorded as attachment
    /// ids, never inline.
    public var output: String
    public var isError: Bool
    public var attachments: [AgentAttachment]?

    public init(id: String, name: String, output: String, isError: Bool, attachments: [AgentAttachment]? = nil) {
        self.id = id
        self.name = name
        self.output = output
        self.isError = isError
        self.attachments = attachments
    }
}

/// One line of `events.jsonl`.
public struct SessionEventRecord: Sendable, Hashable, Codable {
    public var seq: UInt64
    public var date: Date
    public var event: AgentSessionEvent

    public init(seq: UInt64, date: Date, event: AgentSessionEvent) {
        self.seq = seq
        self.date = date
        self.event = event
    }
}
