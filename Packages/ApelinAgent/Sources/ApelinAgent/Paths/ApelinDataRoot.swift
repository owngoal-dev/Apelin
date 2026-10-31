import Foundation

/// `~/Documents/wiki.qaq.apelin` and the folders the agent uses inside it.
///
/// The home directory is mobile's (the app and `apelin-agent` have no
/// container). Nothing here writes an install prefix: the home comes from the
/// process, and tests pass their own.
public struct ApelinDataRoot: Sendable, Hashable {
    public static let bundleIdentifier = "wiki.qaq.apelin"

    /// `<home>/Documents/wiki.qaq.apelin`.
    public let url: URL

    public init(home: URL) {
        url = home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
    }

    /// The home this folder is in: what `init(home:)` was given.
    public var home: URL {
        url.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The running process's home: mobile's on a device.
    public static var current: ApelinDataRoot {
        ApelinDataRoot(home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    public var projects: URL {
        url.appendingPathComponent("Projects", isDirectory: true)
    }

    public var sessions: URL {
        url.appendingPathComponent("sessions", isDirectory: true)
    }

    public var skills: URL {
        url.appendingPathComponent("skills", isDirectory: true)
    }

    /// `Journal/Agent/`: each conversation's diagnostic journal, beside
    /// the app's own Dog files in `Journal/` (`SessionJournal`).
    public var agentJournals: URL {
        url.appendingPathComponent("Journal", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
    }

    /// Temporary conversations' folders, which belong to no project.
    public var temporary: URL {
        url.appendingPathComponent("Temporary")
    }

    public func project(named name: ProjectName) -> URL {
        projects.appendingPathComponent(name.rawValue, isDirectory: true)
    }

    /// A session's working folder: its temporary folder when it has one,
    /// otherwise its project's.
    public func workspace(for name: ProjectName, temporaryID: String?) -> URL {
        temporaryID.map { temporary.appendingPathComponent($0) } ?? project(named: name)
    }
}

/// A project's name: one path component under `Projects/`.
///
/// Rejects `/`, NUL, `.`, `..`, and names starting with `.` (§2, project
/// location).
public struct ProjectName: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty,
              !rawValue.contains("/"),
              !rawValue.contains("\0"),
              !rawValue.hasPrefix("."),
              rawValue.utf8.count <= 255
        else { throw PathPolicyError.invalidProjectName(rawValue) }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        rawValue
    }
}

/// The project a session is bound to. The id is the one in
/// `apelin-project.json`; the host supplies both.
public struct ProjectIdentity: Sendable, Hashable, Codable {
    /// A temporary conversation's id is this prefix and its folder's UUID.
    static let temporaryIDPrefix = "temporary:"

    public var id: String
    public var name: ProjectName

    public init(id: String, name: ProjectName) {
        self.id = id
        self.name = name
    }

    /// Whether this is General Chat's scratch workspace, which belongs to no project.
    var isTemporary: Bool {
        id.hasPrefix(Self.temporaryIDPrefix)
    }
}
