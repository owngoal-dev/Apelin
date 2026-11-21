import ApelinCore
import ApelinProtocol
import Foundation

/// What an agent may do with other conversations (`AgentConversations`),
/// decided from the host's own session table and never from what the agent
/// says. AgentHandler applies these to a request from
/// `Caller.worker(.agent, instance:)`, whose instance is the caller's
/// session; the app's requests pass through unchanged, except that a
/// prompt's `fromSessionID` is the host's to write.
///
/// Another project than the caller's own is reached only as a project under
/// `Projects/`, never a temporary chat, and under Confirm only with the
/// user's approval: an open or a prompt spends an approval the app gave for
/// exactly it (`coversOpen`, `coversSend`); a list or an attach needs the
/// app to have approved, this session, a conversation call naming that
/// project (`AgentSessionTable.mayReach`).
enum AgentConversationRules {
    /// The longest title the host keeps for a conversation.
    static let maximumTitleLength = 80

    /// The key of the approval detail apelin-agent writes for a
    /// conversation call that reaches another project: {action, projectID,
    /// projectName, sessionID?, text?}.
    static let otherProjectDetail = "otherProject"

    /// The open request the host sends for an agent's `agentOpen`: in
    /// `target` — the opener's own project, or another one the request named
    /// — under the opener's current approval mode and Ask Before Using the
    /// Screen, with the prompt, title,
    /// provider, model, effort, tier and model limits it asked for, and nothing else of its own:
    /// no session to reopen, no temporary workspace, no headless close.
    static func childOpen(
        _ open: AgentOpenRequest,
        opener: AgentSessionTable.Entry,
        target: ResolvedProject,
    ) throws -> AgentOpenRequest {
        guard !target.isTemporary else {
            throw ApelinError(.denied, "an agent opens conversations only in a project; name one with its projectID or folder")
        }
        guard opener.depth < AgentConversations.maximumDepth else {
            throw ApelinError(
                .denied,
                "a conversation another agent opened \(opener.depth) deep cannot open more; do the work here",
            )
        }
        guard let prompt = open.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApelinError(.badRequest, "a conversation an agent opens starts with a prompt")
        }
        return AgentOpenRequest(
            projectID: target.id,
            projectName: target.name,
            provider: open.provider,
            model: open.model,
            approvalMode: opener.mode,
            asksBeforeScreen: opener.asksBeforeScreen,
            reasoningEffort: open.reasoningEffort,
            serviceTier: open.serviceTier,
            modelLimits: open.modelLimits,
            prompt: prompt,
            title: title(open.title),
        )
    }

    /// The prompt the host hands the target for an agent's `agentPrompt`:
    /// the text alone, as the user's message marked with the sender, with
    /// none of the sender's mode, model or files.
    static func childPrompt(
        _ prompt: AgentPromptRequest,
        sender: AgentSessionTable.Entry,
        target: AgentSessionTable.Entry?,
        descriptorCount: Int,
    ) throws -> AgentPromptRequest {
        guard descriptorCount == 0, prompt.attachments?.isEmpty ?? true else {
            throw ApelinError(.badRequest, "a message from another conversation carries no files")
        }
        guard let target else {
            throw ApelinError(.notFound, "no conversation \(prompt.sessionID)")
        }
        guard target.sessionID != sender.sessionID else {
            throw ApelinError(.badRequest, "a conversation does not send messages to itself")
        }
        guard !target.project.isTemporary else {
            throw ApelinError(.denied, "conversation \(target.sessionID) is a temporary chat, which takes messages only from the user")
        }
        guard !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApelinError(.badRequest, "the message is empty")
        }
        return AgentPromptRequest(sessionID: target.sessionID, text: prompt.text, fromSessionID: sender.sessionID)
    }

    /// The app's prompt is the user's own: whatever `fromSessionID` it
    /// carries is dropped.
    static func appPrompt(_ prompt: AgentPromptRequest) -> AgentPromptRequest {
        var prompt = prompt
        prompt.fromSessionID = nil
        return prompt
    }

    /// An agent aborts or closes only a conversation it opened.
    static func mayStop(_ target: AgentSessionTable.Entry?, caller: AgentSessionTable.Entry, sessionID: String) throws {
        guard let target else {
            throw ApelinError(.notFound, "no conversation \(sessionID)")
        }
        guard target.parentSessionID == caller.sessionID else {
            throw ApelinError(.denied, "an agent stops only the conversations it opened")
        }
    }

    /// An agent reads the task of a conversation of its own project, or of
    /// another project (never a temporary chat) it may reach: in Relaxed
    /// or Full mode, or once the app approved this session reaching it.
    static func mayRead(
        _ taskID: TaskID,
        target: AgentSessionTable.Entry?,
        caller: AgentSessionTable.Entry,
        reachable: Bool = false,
    ) throws {
        guard let target else {
            throw ApelinError(.denied, "task \(taskID) is not a conversation of this project")
        }
        guard target.project != caller.project else { return }
        try mayReach(target.project, caller: caller, reachable: reachable)
    }

    /// Whether `caller` may list or read `project`'s conversations: its own,
    /// or another project under `Projects/` it may reach.
    static func mayReach(_ project: ResolvedProject, caller: AgentSessionTable.Entry, reachable: Bool) throws {
        guard project != caller.project else { return }
        guard !project.isTemporary else {
            throw ApelinError(.denied, "a temporary chat's conversations are the user's alone")
        }
        guard !caller.mode.asks || reachable else {
            throw ApelinError(
                .denied,
                "approval required: the user has not let this conversation reach the project \(project.name)",
            )
        }
    }

    /// Whether `asked`, one of the opener's own `approvalRequested` events,
    /// approves exactly this open in another project: apelin_conversation_create
    /// naming `target` with this prompt.
    static func coversOpen(_ open: AgentOpenRequest, target: ResolvedProject, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.conversationCreate.rawValue,
              let detail = asked["detail"]?[otherProjectDetail],
              detail["action"]?.stringValue == "create"
        else { return false }
        return detail["projectID"]?.stringValue == target.id && detail["text"]?.stringValue == open.prompt
    }

    /// Whether `asked` approves exactly this message to a conversation of
    /// another project: apelin_conversation_send naming it, its project and this text.
    static func coversSend(_ prompt: AgentPromptRequest, target: AgentSessionTable.Entry, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.conversationSend.rawValue,
              let detail = asked["detail"]?[otherProjectDetail],
              detail["action"]?.stringValue == "send"
        else { return false }
        return detail["projectID"]?.stringValue == target.project.id
            && detail["sessionID"]?.stringValue == target.sessionID
            && detail["text"]?.stringValue == prompt.text
    }

    /// `conversationOpened` on the opener's task: {sessionID, task, title?,
    /// prompt, projectID, projectName}, from which the app adopts the
    /// conversation in that project.
    static func openedEvent(
        sessionID: String,
        task: TaskHandle,
        title: String?,
        prompt: String,
        project: ResolvedProject? = nil,
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "sessionID": .string(sessionID),
            "task": .object(["taskID": .string(task.taskID.rawValue), "kind": .string(task.kind.rawValue)]),
            "prompt": .string(prompt),
        ]
        if let title {
            payload["title"] = .string(title)
        }
        if let project, !project.isTemporary {
            payload["projectID"] = .string(project.id)
            payload["projectName"] = .string(project.name)
        }
        return .object(payload)
    }

    /// One line, trimmed and bounded; nil when nothing is left.
    static func title(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maximumTitleLength))
    }
}
