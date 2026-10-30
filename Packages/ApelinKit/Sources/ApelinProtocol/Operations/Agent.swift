import Foundation

// Agent: one apelin-agent process per session (KWWKAgent), spawned by the
// session host as mobile; the session is a task of kind `agent` whose events
// are the agent's structured output (`message`, `toolCall`, `toolResult`,
// `approvalRequested` {approvalID, tool, arguments}, `state`). The full list
// is in AGENTS.md ▸ Decisions ▸ Agent sessions.
// Served by apelin-agent (Workers/Agent; Packages/ApelinAgent) through the host.

public enum ApprovalMode: String, Codable, Sendable {
    /// Everything runs, except a shell_run as root, which asks every time.
    case relaxed
    /// Project edits and the preset list run; anything else is confirmed.
    case confirm
    /// Everything Relaxed runs, and shell_run as root too, without asking.
    case full

    /// Whether the session asks before the risky steps Relaxed and Full
    /// let through: only Strict (`confirm`) does.
    public var asks: Bool {
        self == .confirm
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case approve
    case deny
}

/// How far an approval reaches.
public enum ApprovalScope: String, Codable, Sendable {
    /// The call that asked, once.
    case once
    /// Identical calls for the rest of the session, where the request
    /// offered it (`allowsSessionScope`); for shell_run the host records a
    /// grant for that command in that working directory.
    case session
}

public struct AgentSessionSummary: Codable, Sendable, Equatable {
    public var sessionID: String
    public var task: TaskHandle
    public var projectID: String?
    /// The project's folder under `Projects/`; nil for a temporary chat.
    public var projectName: String?
    public var title: String?
    public var state: TaskState
    public var updatedAt: Date
    /// The session whose agent opened this one (`agentOpen` from an agent);
    /// nil for one the app opened.
    public var parentSessionID: String?

    public init(
        sessionID: String,
        task: TaskHandle,
        projectID: String? = nil,
        projectName: String? = nil,
        title: String? = nil,
        state: TaskState,
        updatedAt: Date,
        parentSessionID: String? = nil,
    ) {
        self.sessionID = sessionID
        self.task = task
        self.projectID = projectID
        self.projectName = projectName
        self.title = title
        self.state = state
        self.updatedAt = updatedAt
        self.parentSessionID = parentSessionID
    }
}

/// Conversations an agent opens and talks to (2026-10-22).
///
/// An agent may call `agentOpen`, `agentPrompt`, `agentList` and
/// `agentAttach`, and `agentAbort` and `agentClose` for the sessions it
/// opened. The host decides what it may not: a new session is in the
/// caller's own project, or in another one the request names (never a
/// temporary one), under the caller's current approval mode, with a first
/// prompt; a prompt goes to another session as the user's message marked
/// `fromSessionID`, with no approval mode, provider, model or attachment of
/// the caller's; a list names one project's sessions and an attach reads
/// only a session's of a project the caller may reach. Under Confirm,
/// reaching another project takes the user's approval: an open or a prompt
/// one the app gave for exactly it, a list or an attach one the app gave
/// this session for that project. `agentApprove`, `agentSteer` and
/// `agentCompact` stay the app's. At most `maximumOpenChildren` sessions an
/// agent opened run in a project at once, and a chain of openings is at
/// most `maximumDepth` deep.
public enum AgentConversations {
    public static let maximumOpenChildren = 6
    /// A conversation the app opened is depth 0; one it opens is 1.
    public static let maximumDepth = 2
    /// The event the host appends to the opener's task when an agent opens
    /// a session: {sessionID, task: {taskID, kind}, title?, prompt,
    /// projectID, projectName}. The app adopts it as a conversation of that
    /// project, which may be another than the opener's.
    public static let openedEventKind = "conversationOpened"
}

/// Links the app opens (`apelin://`), which an agent hands the user beside
/// a conversation or project it opened or points to.
public enum ApelinLink {
    public static let scheme = "apelin"

    /// `apelin://conversation/<session ID>`: that conversation, its project selected.
    public static func conversation(_ sessionID: String) -> String {
        "\(scheme)://conversation/\(sessionID)"
    }

    /// `apelin://project/<projectID>`: that project.
    public static func project(_ projectID: String) -> String {
        "\(scheme)://project/\(projectID)"
    }
}

/// Which provider a session talks to, and what Settings ▸ Model Providers
/// signs in to: every login kwwk offers, each kept under one kwwk store id
/// (in brackets). Credentials are never part of a request: the agent reads
/// them from the keychain by that id. The first four are the original
/// names; a case is never renamed on the wire.
public enum AgentProvider: String, Codable, Sendable {
    /// GitHub Copilot (kwwk's `github-copilot` credential).
    case githubCopilot
    /// Anthropic's Messages API with an API key (`anthropic-api-key`).
    case anthropic
    /// Anthropic with an OAuth sign-in (`anthropic`).
    case anthropicOAuth
    /// An OpenAI-compatible endpoint (`openai-compatible`; the base URL is
    /// stored with the key).
    case openAICompatible

    // Subscriptions kwwk signs in to (`OAuthSubscriptions.providers`).

    /// ChatGPT Plus or Pro through Codex (`openai-codex`).
    case openAICodex
    /// Cursor (`cursor`).
    case cursor
    /// Devin, Windsurf's and Cognition's (`devin`).
    case devin
    /// Kiro, through AWS Builder ID, Google or GitHub (`kiro`).
    case kiro
    /// Qoder, qoder.com (`qoder`).
    case qoder
    /// Qoder CN, qoder.cn (`qoder-cn`).
    case qoderCN
    /// WorkBuddy, Tencent's CodeBuddy plan, China build (`workbuddy`).
    case workBuddy
    /// WorkBuddy AI, the international build (`workbuddy-ai`).
    case workBuddyAI
    /// Kimi For Coding, Moonshot's coding plan (`kimi-coding`).
    case kimiCoding
    /// xAI Grok, SuperGrok or X Premium (`xai`).
    case xai
    /// Z.ai's GLM Coding Plan (`zai`).
    case zai
    /// BigModel's GLM Coding Plan, bigmodel.cn (`zai-coding-cn`).
    case zaiCodingCN
    /// OpenRouter, by a browser sign-in that mints a key or by a typed key
    /// (`openrouter`).
    case openRouter

    // Keys kwwk keeps in its API-key shape.

    /// OpenAI's API with an API key (`openai-api-key`).
    case openAI
    /// Google AI Studio's Gemini API with an API key (`google-api-key`).
    case google
    /// DeepSeek's API with its own API key (`deepseek-api-key`).
    case deepSeek
    /// OpenCode Go, opencode.ai's coding subscription, by an API key from
    /// its Console (`opencode-go`).
    case openCodeGo
}

extension AgentProvider: CaseIterable {}

public enum AgentReasoningEffort: String, Codable, Sendable, CaseIterable {
    case off, minimal, low, medium, high, xhigh, max
}

/// The processing tiers Apelin offers above the provider's standard one,
/// by kwwk's `ServiceTier` names: `priority` (Codex's Fast) and
/// `ultrafast`. A model is offered only those its provider's catalog lists
/// for it (`AgentAccount.serviceTiers`); absent is the standard tier.
public enum AgentServiceTier: String, Codable, Sendable, CaseIterable {
    case priority, ultrafast
}

public struct AgentOpenRequest: OperationRequest {
    public typealias Response = AgentOpenResponse
    public static let operation = AppOperation.agentOpen
    /// The project's `projectID`; or name it with `projectName`.
    public var projectID: String?
    /// `Projects/<name>`, when the caller knows the name rather than the id.
    public var projectName: String?
    /// A UUID-named workspace under Temporary, when this chat has no project.
    public var temporaryID: String?
    /// Reopen the same persisted conversation after its worker has ended.
    public var sessionID: String?
    /// The provider; nil is GitHub Copilot.
    public var provider: AgentProvider?
    /// A model identifier from the app's model settings; nil is the default.
    public var model: String?
    public var approvalMode: ApprovalMode
    /// Ask Before Using the Screen (`ScreenConsent`): nil is on. An agent's
    /// open takes its opener's, whatever it sends.
    public var asksBeforeScreen: Bool?
    public var reasoningEffort: AgentReasoningEffort?
    public var serviceTier: AgentServiceTier?
    /// A first prompt, submitted as soon as the session is open.
    public var prompt: String?
    /// End the session (its task) when the first run finishes: `succeeded`
    /// when it completed, `failed` or `cancelled` otherwise. For headless
    /// runs that follow the session task until it ends.
    public var closeWhenFinished: Bool?
    /// A name for the conversation, from an agent's apelin_conversation_create;
    /// the host keeps it as the session's title and puts it on
    /// `conversationOpened`.
    public var title: String?
    /// Written by the host, never the caller's (it drops what a caller
    /// sends): the app is continuing a conversation no message has reached
    /// since this session host started, so the device may have rebooted and
    /// roothide may have renamed the bootstrap's root since it last ran. The
    /// worker says so in the next message's `<system-state>` when the
    /// conversation has history.
    public var hostRestarted: Bool?

    public init(
        projectID: String? = nil,
        projectName: String? = nil,
        temporaryID: String? = nil,
        sessionID: String? = nil,
        provider: AgentProvider? = nil,
        model: String? = nil,
        approvalMode: ApprovalMode = .confirm,
        asksBeforeScreen: Bool? = nil,
        reasoningEffort: AgentReasoningEffort? = nil,
        serviceTier: AgentServiceTier? = nil,
        prompt: String? = nil,
        closeWhenFinished: Bool? = nil,
        title: String? = nil,
        hostRestarted: Bool? = nil,
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.temporaryID = temporaryID
        self.sessionID = sessionID
        self.provider = provider
        self.model = model
        self.approvalMode = approvalMode
        self.asksBeforeScreen = asksBeforeScreen
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.prompt = prompt
        self.closeWhenFinished = closeWhenFinished
        self.title = title
        self.hostRestarted = hostRestarted
    }
}

public struct AgentOpenResponse: Codable, Sendable, Equatable {
    public var sessionID: String
    public var task: TaskHandle

    public init(sessionID: String, task: TaskHandle) {
        self.sessionID = sessionID
        self.task = task
    }
}

/// Input files travel as descriptors; names are display metadata, never paths.
public struct AgentInputAttachment: Codable, Sendable, Equatable {
    public var descriptor: DescriptorSlot
    public var name: String
    public var mimeType: String
    public init(descriptor: DescriptorSlot, name: String, mimeType: String) {
        self.descriptor = descriptor
        self.name = name
        self.mimeType = mimeType
    }
}

/// A saved file relative to the session workspace, usable after replay.
public struct AgentAttachment: Codable, Sendable, Hashable {
    public var path: String
    public var name: String
    public var mimeType: String
    public init(path: String, name: String, mimeType: String) {
        self.path = path
        self.name = name
        self.mimeType = mimeType
    }
}

public struct AgentPromptRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentPrompt
    public var sessionID: String
    public var text: String
    public var messageID: UUID?
    public var provider: AgentProvider?
    public var model: String?
    public var reasoningEffort: AgentReasoningEffort?
    public var serviceTier: AgentServiceTier?
    public var attachments: [AgentInputAttachment]?
    public var approvalMode: ApprovalMode?
    /// Ask Before Using the Screen (`ScreenConsent`), as the app has it now;
    /// nil leaves the session's as it is, as a nil `approvalMode` does. The
    /// host drops it from an agent's prompt.
    public var asksBeforeScreen: Bool?
    /// The session whose agent sent this, written by the host for an
    /// agent's prompt and cleared for the app's; the worker records it on
    /// the `prompt` event as `from`.
    public var fromSessionID: String?

    public init(
        sessionID: String,
        text: String,
        messageID: UUID? = nil,
        attachments: [AgentInputAttachment]? = nil,
        provider: AgentProvider? = nil,
        model: String? = nil,
        reasoningEffort: AgentReasoningEffort? = nil,
        serviceTier: AgentServiceTier? = nil,
        approvalMode: ApprovalMode? = nil,
        asksBeforeScreen: Bool? = nil,
        fromSessionID: String? = nil,
    ) {
        self.sessionID = sessionID
        self.text = text
        self.messageID = messageID
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.attachments = attachments
        self.approvalMode = approvalMode
        self.asksBeforeScreen = asksBeforeScreen
        self.fromSessionID = fromSessionID
    }
}

public struct AgentSteerRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentSteer
    public var sessionID: String
    public var text: String

    public init(sessionID: String, text: String) {
        self.sessionID = sessionID
        self.text = text
    }
}

public struct AgentAbortRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentAbort
    public var sessionID: String
    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

/// Compacts the conversation now, as the session does on its own when its
/// context fills: the earlier messages become a summary the model reads,
/// natively where the provider can, and the recent ones stay as they are.
/// The app's alone, between runs: refused `conflict` while a run goes or
/// another compaction does. The answer comes once it has started; the
/// session's task says how it went, `compactionStarted` then
/// `compactionFinished` {outcome, messagesCompacted?, message?, summary?},
/// and `agentAbort` stops it.
public struct AgentCompactRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentCompact
    public var sessionID: String
    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

/// How a compaction ended: the payload of `compactionFinished`.
public struct AgentCompactionResult: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, Sendable, Hashable {
        /// The earlier messages are a summary now.
        case compacted
        /// Everything is still recent enough to be kept as it is.
        case tooShort
        case cancelled
        case failed
    }

    public var outcome: Outcome
    /// How many messages the summary took the place of, when compacted.
    public var messagesCompacted: Int?
    /// Why it failed, in the provider's words where it gave any.
    public var message: String?
    /// When compacted, the summary the conversation now goes on from, as
    /// the reader sees it: kwwk's recap without its markup. Bounded by the
    /// recap's own budget, about 1,800 tokens. Absent from events recorded
    /// before it was kept.
    public var summary: String?

    public init(outcome: Outcome, messagesCompacted: Int? = nil, message: String? = nil, summary: String? = nil) {
        self.outcome = outcome
        self.messagesCompacted = messagesCompacted
        self.message = message
        self.summary = summary
    }
}

public struct AgentApproveRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentApprove
    public var sessionID: String
    public var approvalID: String
    public var decision: ApprovalDecision
    /// Absent is `.once`.
    public var scope: ApprovalScope?
    /// The app checked the device owner for this decision (Face ID, Touch
    /// ID or the passcode, or the device has no passcode). The host takes
    /// an approval of a shell_run as root only with it; the console never
    /// sends it, so a script file cannot approve one.
    public var ownerVerified: Bool?

    public init(
        sessionID: String,
        approvalID: String,
        decision: ApprovalDecision,
        scope: ApprovalScope? = nil,
        ownerVerified: Bool? = nil,
    ) {
        self.sessionID = sessionID
        self.approvalID = approvalID
        self.decision = decision
        self.scope = scope
        self.ownerVerified = ownerVerified
    }
}

public struct AgentAttachRequest: TaskAttachRequest {
    public static let operation = AppOperation.agentAttach
    public var taskID: TaskID
    public var afterSeq: EventSeq
    public var waitMilliseconds: Int

    public init(taskID: TaskID, afterSeq: EventSeq = .start, waitMilliseconds: Int = Self.defaultWaitMilliseconds) {
        self.taskID = taskID
        self.afterSeq = afterSeq
        self.waitMilliseconds = waitMilliseconds
    }
}

public struct AgentListRequest: OperationRequest {
    public typealias Response = AgentListResponse
    public static let operation = AppOperation.agentList
    /// Only this project's sessions, named by its `projectID` or its folder;
    /// absent, every project's for the app, the caller's own for an agent in
    /// a project, and every project's it may reach for one in General Chat.
    public var projectID: String?
    public var projectName: String?

    public init(projectID: String? = nil, projectName: String? = nil) {
        self.projectID = projectID
        self.projectName = projectName
    }
}

public struct AgentListResponse: Codable, Sendable, Equatable {
    /// For an agent, the sessions that have not run since the session host
    /// started too, each by its newest task, which has ended.
    public var sessions: [AgentSessionSummary]
    /// How many projects an agent in General Chat may not list without the
    /// user's approval (Strict), left out of a list that named none; absent
    /// when none was.
    public var unreachedProjects: Int?
    public init(sessions: [AgentSessionSummary] = [], unreachedProjects: Int? = nil) {
        self.sessions = sessions
        self.unreachedProjects = unreachedProjects
    }
}

public struct AgentCloseRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentClose
    public var sessionID: String
    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

public extension ApelinService {
    func agentOpen(_ request: AgentOpenRequest = AgentOpenRequest()) async throws -> AgentOpenResponse {
        try await send(request)
    }

    func agentPrompt(sessionID: String, text: String) async throws {
        _ = try await send(AgentPromptRequest(sessionID: sessionID, text: text))
    }

    func agentSteer(sessionID: String, text: String) async throws {
        _ = try await send(AgentSteerRequest(sessionID: sessionID, text: text))
    }

    func agentAbort(sessionID: String) async throws {
        _ = try await send(AgentAbortRequest(sessionID: sessionID))
    }

    func agentCompact(sessionID: String) async throws {
        _ = try await send(AgentCompactRequest(sessionID: sessionID))
    }

    func agentApprove(
        sessionID: String,
        approvalID: String,
        decision: ApprovalDecision,
        scope: ApprovalScope? = nil,
        ownerVerified: Bool? = nil,
    ) async throws {
        _ = try await send(AgentApproveRequest(
            sessionID: sessionID,
            approvalID: approvalID,
            decision: decision,
            scope: scope,
            ownerVerified: ownerVerified,
        ))
    }

    func agentAttach(_ request: AgentAttachRequest) async throws -> TaskEventBatch {
        try await send(request)
    }

    func agentList(projectID: String? = nil, projectName: String? = nil) async throws -> AgentListResponse {
        try await send(AgentListRequest(projectID: projectID, projectName: projectName))
    }

    func agentClose(sessionID: String) async throws {
        _ = try await send(AgentCloseRequest(sessionID: sessionID))
    }
}
