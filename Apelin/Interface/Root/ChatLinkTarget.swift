import ApelinProtocol
import Foundation
import SPIndicator

/// Where an `apelin://` link leads among the conversations the app has.
@MainActor
enum ChatLinkTarget {
    enum Destination {
        case chat(ChatSummary)
        /// A project with no conversation yet: a new one in it. Or a new
        /// General Chat (no project) with `draft` in its composer.
        case newChat(project: String?, draft: String? = nil)
    }

    /// The conversation or project `link` names, or nil when it names
    /// nothing the app can open. An import is a sheet over the page
    /// (`RepositoryImportFlow`), never a destination.
    static func resolve(_ link: ApelinLink, in runtime: ChatRuntime) async -> Destination? {
        switch link {
        case .app, .unknown, .importRepository, .invalidImport:
            nil
        case let .conversation(id):
            await conversation(id, in: runtime).map(Destination.chat)
        case let .project(id):
            await project(id, in: runtime)
        case let .chat(prompt):
            .newChat(project: nil, draft: prompt)
        }
    }

    /// Says, briefly, that `link` opened nothing; what was shown stays.
    static func reportUnresolved(_ link: ApelinLink) {
        let title = switch link {
        case .conversation: String(localized: "Conversation Not Found")
        case .project: String(localized: "Project Not Found")
        case .app, .chat, .importRepository, .invalidImport, .unknown: String(localized: "Link Not Recognized")
        }
        SPIndicator.present(title: title, preset: .error, haptic: .error)
    }

    /// By its agent session ID, or the app's own chat ID. A session the app
    /// has no row for — an agent opened it while nothing followed its
    /// opener — is taken in first (`ChatAdoption`), in its opener's project
    /// or the one the host names.
    private static func conversation(_ id: String, in runtime: ChatRuntime) async -> ChatSummary? {
        if let summary = summary(for: id, in: runtime) {
            return summary
        }
        guard let sessions = try? await ApelinService.app.agentList().sessions,
              let session = sessions.first(where: { sameID($0.sessionID, id) })
        else { return nil }
        // the launch may have taken it in while the list was read
        if let summary = summary(for: id, in: runtime) {
            return summary
        }
        let records = Array(runtime.records.values)
        var record = ChatAdoption.record(session: session, records: records)
        if record == nil, let projectID = session.projectID {
            let projects = await (try? ProjectSummary.load()) ?? []
            let project = projects.first { $0.projectID.map { sameID($0, projectID) } ?? false }
                ?? projects.first { $0.name == projectID }
            record = project.flatMap {
                ChatAdoption.record(linked: session, projectName: $0.name, records: Array(runtime.records.values))
            }
        }
        return record.flatMap(runtime.adoptLinked)
    }

    /// By its manifest `projectID`, else its folder name: its most recent
    /// conversation, or a new one when it has none.
    private static func project(_ id: String, in runtime: ChatRuntime) async -> Destination? {
        guard let projects = try? await ProjectSummary.load(),
              let project = projects.first(where: { $0.projectID.map { sameID($0, id) } ?? false })
              ?? projects.first(where: { $0.name == id })
        else { return nil }
        let latest = SidebarOrder.newest(
            runtime.records.values.map(\.summary).filter { $0.projectName == project.name },
        )
        return latest.map(Destination.chat) ?? .newChat(project: project.name)
    }

    private static func summary(for id: String, in runtime: ChatRuntime) -> ChatSummary? {
        if let record = runtime.records.values.first(where: { $0.sessionID.map { sameID($0, id) } ?? false }) {
            return record.summary
        }
        return UUID(uuidString: id).flatMap { runtime.records[$0]?.summary }
    }

    /// Identifiers are UUIDs, written in either case.
    private static func sameID(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs {
            return true
        }
        guard let left = UUID(uuidString: lhs), let right = UUID(uuidString: rhs) else { return false }
        return left == right
    }
}
