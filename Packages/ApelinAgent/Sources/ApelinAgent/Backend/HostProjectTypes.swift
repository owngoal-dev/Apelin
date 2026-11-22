import enum ApelinProtocol.ApelinLink
import Foundation

// MARK: - Projects

/// A template parameter's value: the kinds a template declares are strings
/// (identifiers and choices among them), booleans, integers and lists of
/// strings (bundleIDList and executableList, such as the tweak's
/// filterBundles).
public enum TemplateValue: Sendable, Hashable, Codable {
    case string(String)
    case boolean(Bool)
    case integer(Int)
    case list([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode([String].self) {
            self = .list(value)
        } else {
            self = try .string(container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .list(value): try container.encode(value)
        }
    }
}

public struct ProjectTemplate: Sendable, Hashable, Codable {
    public struct Parameter: Sendable, Hashable, Codable {
        public var name: String
        /// The manifest's type: projectName, identifier, bundleID,
        /// packageID, version, deploymentTarget, string, enum, bool, or a
        /// list of strings: bundleIDList or executableList.
        public var kind: String
        public var summary: String?
        public var defaultValue: TemplateValue?
        public init(name: String, kind: String, summary: String? = nil, defaultValue: TemplateValue? = nil) {
            self.name = name
            self.kind = kind
            self.summary = summary
            self.defaultValue = defaultValue
        }
    }

    /// `<extension-id>/<template-id>`, what apelin_project_create takes.
    public var id: String
    public var name: String
    /// The extension's kind: workspace, app, tweak, commandLineTool or
    /// preferenceBundle.
    public var kind: String
    public var summary: String?
    public var parameters: [Parameter]
    public init(id: String, name: String, kind: String, summary: String? = nil, parameters: [Parameter] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.summary = summary
        self.parameters = parameters
    }
}

public struct ProjectTemplateListResponse: Sendable, Hashable, Codable {
    public var templates: [ProjectTemplate]
    public init(templates: [ProjectTemplate]) {
        self.templates = templates
    }
}

public struct ProjectCreateToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var templateID: String
    /// The folder under `Projects/`, which never changes.
    public var name: String
    /// Parameters the template asks for; Apelin fills the rest.
    public var values: [String: TemplateValue]
    public init(context: HostCallContext, templateID: String, name: String, values: [String: TemplateValue] = [:]) {
        self.context = context
        self.templateID = templateID
        self.name = name
        self.values = values
    }
}

public struct ProjectCreateToolResponse: Sendable, Hashable, Codable {
    public var projectID: String
    public var name: String
    /// `apelin://project/<projectID>`, which opens it in the app.
    public var link: String
    /// The identifiers Apelin made up for it, to ask the user about
    /// (`PlaceholderIdentifiers`); the agent adds it, the host never does.
    public var identifierHint: String?
    /// How its first conversation is opened: with `project` set to it,
    /// since apelin_conversation_create without one opens in the caller's
    /// project (issue #79).
    public var next: String
    public init(projectID: String, name: String, identifierHint: String? = nil) {
        self.projectID = projectID
        self.name = name
        link = ApelinLink.project(projectID)
        self.identifierHint = identifierHint
        next = "Open its first conversation with apelin_conversation_create and project \"\(projectID)\"; without project, a conversation never opens in the new project."
    }
}

/// apelin_project_list: the projects under `Projects/`, by the folder name
/// and projectID the conversation tools take.
public struct ProjectListToolResponse: Sendable, Hashable, Codable {
    public var projects: [ListedProject]
    /// More projects than the list holds.
    public var truncated: Bool

    public init(projects: [ListedProject], truncated: Bool) {
        self.projects = projects
        self.truncated = truncated
    }
}

public struct ListedProject: Sendable, Hashable, Codable {
    public var folder: String
    public var projectID: String
    /// The name the sidebar shows (`displayName`, else the folder).
    public var displayName: String
    /// `apelin` (a build description) or `external` (a workspace's own build).
    public var buildSystem: String
    /// The project this conversation works in.
    public var isThisProject: Bool
    /// `apelin://project/<projectID>`, which opens it in the app.
    public var link: String

    public init(folder: String, projectID: String, displayName: String, buildSystem: String, isThisProject: Bool) {
        self.folder = folder
        self.projectID = projectID
        self.displayName = displayName
        self.buildSystem = buildSystem
        self.isThisProject = isThisProject
        link = ApelinLink.project(projectID)
    }
}

/// apelin_project_rename: a project's displayName, by `projectRename`.
public struct ProjectRenameToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var projectID: String
    public var folder: String
    public var displayName: String
    /// Only replace the name Apelin generated (`onlyIfAutomatic`).
    public var automatic: Bool
    public init(context: HostCallContext, projectID: String, folder: String, displayName: String, automatic: Bool) {
        self.context = context
        self.projectID = projectID
        self.folder = folder
        self.displayName = displayName
        self.automatic = automatic
    }
}

/// apelin_project_delete: another project, for good, by `projectDelete`.
public struct ProjectDeleteToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var projectID: String
    /// The folder the card named; the host deletes the project only there.
    public var folder: String
    public init(context: HostCallContext, projectID: String, folder: String) {
        self.context = context
        self.projectID = projectID
        self.folder = folder
    }
}

public struct ProjectDeleteToolResponse: Sendable, Hashable, Codable {
    public var projectID: String
    public var folder: String
    /// What went with it, for the reply to the user.
    public var deleted: String
    public init(projectID: String, folder: String) {
        self.projectID = projectID
        self.folder = folder
        deleted = "The project's folder with every file in it, and its conversations, which were closed first; Apelin no longer lists them."
    }
}

public struct ProjectRenameToolResponse: Sendable, Hashable, Codable {
    public var projectID: String
    public var folder: String
    /// The name the sidebar shows now: the new one, or the one an
    /// automatic rename left in place.
    public var displayName: String
    public var changed: Bool
    /// `apelin://project/<projectID>`, which opens it in the app.
    public var link: String
    /// After an automatic rename, the identifiers Apelin made up for the
    /// project (`PlaceholderIdentifiers`); the agent adds it.
    public var identifierHint: String?
    public init(projectID: String, folder: String, displayName: String, changed: Bool) {
        self.projectID = projectID
        self.folder = folder
        self.displayName = displayName
        self.changed = changed
        link = ApelinLink.project(projectID)
    }
}
