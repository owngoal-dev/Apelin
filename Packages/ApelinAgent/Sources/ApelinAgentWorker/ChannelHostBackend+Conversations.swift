import ApelinAgent
import ApelinCore
import ApelinProtocol
import Foundation

public extension ChannelHostBackend {
    // MARK: conversations

    func conversationCreate(
        _ request: ConversationCreateToolRequest,
    ) async throws -> ConversationCreateToolResponse {
        let choice = await modelChoice.current
        let target = request.target ?? project
        // The host opens it in that project, resolved again, under this
        // session's mode; the mode here is a placeholder.
        let opened = try await conversation("apelin_conversation_create") {
            try await service.agentOpen(AgentOpenRequest(
                projectID: target.id,
                projectName: target.name.rawValue,
                provider: choice.provider,
                model: choice.model,
                approvalMode: .confirm,
                reasoningEffort: choice.reasoningEffort,
                serviceTier: choice.serviceTier,
                modelLimits: choice.modelLimits,
                prompt: request.prompt,
                title: request.title,
            ))
        }
        return ConversationCreateToolResponse(
            sessionID: opened.sessionID,
            taskID: opened.task.taskID.rawValue,
            project: request.target,
        )
    }

    func conversationSend(
        _ request: ConversationSendToolRequest,
    ) async throws -> ConversationActionToolResponse {
        try await conversation("apelin_conversation_send") {
            _ = try await service.send(AgentPromptRequest(sessionID: request.sessionID, text: request.text))
        }
        return ConversationActionToolResponse(sessionID: request.sessionID, done: "sent")
    }

    /// General Chat names no project and gets every project's it may reach,
    /// each with its project; the host says how many it left out.
    func conversationList(_ request: ConversationListToolRequest) async throws -> ConversationListToolResponse {
        let listed = try await conversation("apelin_conversation_list") {
            try await service.agentList(projectID: request.target?.id)
        }
        let conversations = listed.sessions.map { summary in
            ConversationSummary(
                sessionID: summary.sessionID,
                title: summary.title,
                project: summary.projectID == project.id ? nil : summary.projectName,
                state: summary.state.isTerminal
                    ? "ended"
                    : summary.state == .waitingForApproval ? "waitingForApproval" : "open",
                openedBy: summary.parentSessionID,
                updatedAt: summary.updatedAt,
                isThisConversation: summary.sessionID == sessionID,
            )
        }
        let note = listed.unreachedProjects.map { count in
            let projects = count == 1 ? "1 more project" : "\(count) more projects"
            return "The conversations of \(projects) are not listed: name one with project to list its conversations; the user is asked each time in Strict mode. apelin_project_list names every project."
        }
        return ConversationListToolResponse(conversations: conversations, note: note)
    }

    func conversationRead(_ request: ConversationReadToolRequest) async throws -> ConversationReadToolResponse {
        let sessions = try await conversation("apelin_conversation_read") {
            try await service.agentList(projectID: request.target?.id).sessions
        }
        guard let summary = sessions.first(where: { $0.sessionID == request.sessionID }) else {
            let scope = request.target.map { "the project \($0.name.rawValue)" } ?? "this project"
            throw ConversationToolFailure(message: "apelin_conversation_read failed: \(scope) has no conversation \(request.sessionID). apelin_conversation_list names them; pass project for another project's.")
        }
        var reader = ConversationReader(afterSeq: request.afterSeq ?? 0, byteLimit: Self.maximumConversationBytes)
        // The whole log, a batch at a time: the state and the approvals still
        // waiting depend on what came before `afterSeq` too.
        var cursor = EventSeq.start
        while true {
            let batch = try await conversation("apelin_conversation_read") {
                try await service.agentAttach(AgentAttachRequest(
                    taskID: summary.task.taskID,
                    afterSeq: cursor,
                    waitMilliseconds: 0,
                ))
            }
            reader.take(batch)
            guard batch.lastSeq > cursor, !batch.events.isEmpty, !batch.finished else { break }
            cursor = batch.lastSeq
        }
        let deadline = Date().addingTimeInterval(
            Double(min(ConversationReadToolRequest.maximumWaitSeconds, max(0, request.waitSeconds))),
        )
        var timedOut = false
        while !reader.isSettled {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                timedOut = request.waitSeconds > 0
                break
            }
            let wait = min(Self.conversationPollMilliseconds, max(1, Int(remaining * 1000)))
            let batch = try await conversation("apelin_conversation_read") {
                try await service.agentAttach(AgentAttachRequest(
                    taskID: summary.task.taskID,
                    afterSeq: reader.lastSeq,
                    waitMilliseconds: wait,
                ))
            }
            reader.take(batch)
        }
        return reader.response(sessionID: summary.sessionID, title: summary.title, timedOut: timedOut)
    }

    func conversationStop(
        _ request: ConversationStopToolRequest,
    ) async throws -> ConversationActionToolResponse {
        try await conversation("apelin_conversation_stop") { try await service.agentAbort(sessionID: request.sessionID) }
        guard request.close else {
            return ConversationActionToolResponse(sessionID: request.sessionID, done: "stopped")
        }
        try await conversation("apelin_conversation_stop") { try await service.agentClose(sessionID: request.sessionID) }
        return ConversationActionToolResponse(sessionID: request.sessionID, done: "closed")
    }

    /// One conversation request; a refusal comes back in words the model
    /// can act on.
    private func conversation<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ApelinError {
            var text = "\(operation) failed: \(error.message.isEmpty ? error.code.rawValue : error.message)"
            if !text.hasSuffix(".") {
                text += "."
            }
            switch (operation, error.code) {
            case ("apelin_conversation_create", .conflict):
                text += " Wait for one to finish, or end one you opened with apelin_conversation_stop and close: true."
            case ("apelin_conversation_send", .notFound):
                text += " That conversation is not running any more; the user can reopen it from the sidebar."
            case (_, .denied) where error.message.hasPrefix("approval required"):
                text += " If it is in another project, name that project with project; the user is asked each time."
            default:
                break
            }
            throw ConversationToolFailure(message: text)
        }
    }

    /// A project under `Projects/` by its folder name or its projectID, as
    /// the host resolves `agentOpen`'s: a folder that is a link out of
    /// `Projects/` is not taken. The host resolves it again and decides.
    func resolveProject(_ reference: String) async throws -> ApelinAgent.ProjectIdentity {
        let reference = reference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty, !reference.contains("\0") else {
            throw ConversationToolFailure(message: "name the project by its projectID or folder name")
        }
        let root = projectsURL.resolvingSymlinksInPath()
        if let named = Self.project(named: reference, in: root) {
            return named.identity
        }
        for name in Self.folders(in: root) {
            if let found = Self.project(named: name, in: root), found.identity.id == reference {
                return found.identity
            }
        }
        throw ConversationToolFailure(message: "no project is named or has the id \(reference); apelin_project_list names them, or ask the user")
    }

    /// apelin_project_list: every project `resolveProject` would find, by
    /// folder, at most `maximumListedProjects`.
    func projects() async throws -> ProjectListToolResponse {
        let root = projectsURL.resolvingSymlinksInPath()
        var listed: [ListedProject] = []
        for name in Self.folders(in: root) {
            guard let found = Self.project(named: name, in: root) else { continue }
            guard listed.count < Self.maximumListedProjects else {
                return ProjectListToolResponse(projects: listed, truncated: true)
            }
            let manifest = found.manifest
            let external = manifest["kind"]?.stringValue == "workspace" || manifest["buildSystem"]?.stringValue == "external"
            listed.append(ListedProject(
                folder: name,
                projectID: found.identity.id,
                displayName: manifest["displayName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? name,
                buildSystem: external ? "external" : "apelin",
                isThisProject: found.identity.id == project.id,
            ))
        }
        return ProjectListToolResponse(projects: listed, truncated: false)
    }

    static let maximumListedProjects = 200

    private static func folders(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// One project folder as the host reads it: not a link out of
    /// `Projects/`, its manifest a regular file of at most 1 MB with a
    /// projectID.
    private static func project(
        named name: String,
        in root: URL,
    ) -> (identity: ApelinAgent.ProjectIdentity, manifest: ApelinCore.JSONValue)? {
        guard let folder = try? ApelinAgent.ProjectName(name) else { return nil }
        let url = root.appendingPathComponent(name, isDirectory: true)
        let manifest = url.appendingPathComponent("apelin-project.json")
        guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == root.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: manifest.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1 << 20,
              let data = try? Data(contentsOf: manifest),
              let json = try? JSONCoding.decode(ApelinCore.JSONValue.self, from: data),
              let id = json["projectID"]?.stringValue, !id.isEmpty
        else { return nil }
        return (ApelinAgent.ProjectIdentity(id: id, name: folder), json)
    }
}
