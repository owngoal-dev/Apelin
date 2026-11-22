import struct ApelinCore.SkillManifest
import Foundation
import KWWKAgent

/// A skill as the session uses it.
public struct SkillDocument: Sendable, Hashable {
    public var name: String
    public var description: String
    public var body: String
    /// True for skills read from the user's folder.
    public var isUserSkill: Bool
    /// The folder a user skill's `SKILL.md` sits in, whose other files
    /// `apelin_skill_read` may read; nil for a built-in or a root-level `.md`.
    public var directory: String?
    /// A built-in skill's files, by name, which `apelin_skill_read` serves as a
    /// user skill's folder is served.
    public var files: [String: String]
    /// A user skill's place in the skills folder, relative to it: what
    /// removing the skill takes away (`SkillCatalog.location`).
    public var location: String?

    public init(
        name: String,
        description: String,
        body: String,
        isUserSkill: Bool = false,
        directory: String? = nil,
        files: [String: String] = [:],
        location: String? = nil,
    ) {
        self.name = name
        self.description = description
        self.body = body
        self.isUserSkill = isUserSkill
        self.directory = directory
        self.files = files
        self.location = location
    }
}

/// Something in the skills folder that is not offered as it stands, or is
/// offered with a warning: kwwk's diagnostic, or a built-in's name taken.
public struct SkillProblem: Sendable, Hashable, CustomStringConvertible {
    public var path: String
    /// What removing it takes away, relative to the skills folder.
    public var location: String?
    public var message: String

    public var description: String {
        "\(path): \(message)"
    }
}

/// The built-in skills plus the user's, from
/// `~/Documents/wiki.qaq.apelin/skills` (kwwk's skill format: a folder per
/// skill with a `SKILL.md`, or a root-level `.md`, with `name` and
/// `description` frontmatter).
///
/// The system prompt lists only each skill's name and description, as pi's
/// `<available_skills>` does; the body is read on demand with `apelin_skill_read`,
/// since the file tools cannot read outside the project.
public enum SkillCatalog {
    public static func load(userDirectory: URL) -> (skills: [SkillDocument], diagnostics: [SkillProblem]) {
        var skills = BuiltInSkills.all
        var names = Set(skills.map(\.name))
        let loaded = loadFolder(userDirectory)
        let userRoot = userDirectory.standardizedFileURL.path
        var diagnostics = loaded.diagnostics.map {
            SkillProblem(path: $0.path, location: location(of: $0.path, in: userRoot), message: $0.message)
        }
        for skill in loaded.skills where !skill.disableModelInvocation {
            // A built-in name is not overridden by a file.
            guard names.insert(skill.name).inserted else {
                diagnostics.append(SkillProblem(
                    path: skill.path,
                    location: location(of: skill.path, in: userRoot),
                    message: "“\(skill.name)” is the name of a built-in skill. Rename this skill to use it.",
                ))
                continue
            }
            let file = URL(fileURLWithPath: skill.path).standardizedFileURL
            let folder = file.deletingLastPathComponent().path
            skills.append(SkillDocument(
                name: skill.name,
                description: skill.description,
                body: skill.body,
                isUserSkill: true,
                directory: file.lastPathComponent == "SKILL.md" && folder != userRoot ? folder : nil,
                location: location(of: skill.path, in: userRoot),
            ))
        }
        return (skills, diagnostics)
    }

    /// kwwk's `Skills.load` of the skills folder `root`, kept from the files
    /// that would stop it (`SkillManifest.filesStoppingKwwk`). With none, it
    /// reads the folder itself. Else it reads a copy of the folder made of
    /// links to everything else and, in place of each such file, an empty
    /// one, which kwwk reads as no frontmatter and so no description, as
    /// `SkillManifest` reads the file itself; the paths it answers are put
    /// back under `root`. The copy is a hidden folder inside `root`, which
    /// kwwk's walk passes over, named for `root` within it, so a top-level
    /// `.md` file is judged by the same folder name.
    static func loadFolder(_ root: URL) -> (skills: [Skill], diagnostics: [SkillDiagnostic]) {
        let stoppers = Set(SkillManifest.filesStoppingKwwk(in: root))
        guard !stoppers.isEmpty else { return Skills.load(directories: [root.path], useIndex: false) }
        let manager = FileManager.default
        let scratch = root.appendingPathComponent(".check-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent(root.lastPathComponent, isDirectory: true)
        var folders: Set<String> = []
        for place in stoppers {
            var parts = place.split(separator: "/").dropLast()
            while !parts.isEmpty {
                folders.insert(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        do {
            try manager.createDirectory(at: copy, withIntermediateDirectories: true)
            try link(root, into: copy, relative: "", emptied: stoppers, made: folders)
        } catch {
            // With no copy to read, the folder's skills wait for the next
            // load, and each file that stops kwwk is named as it reads.
            return ([], stoppers.sorted().map {
                SkillDiagnostic(code: .invalidMetadata, message: "description is required", path: root.appendingPathComponent($0).path)
            })
        }
        let loaded = Skills.load(directories: [copy.path], useIndex: false)
        func own(_ path: String) -> String {
            path.hasPrefix(copy.path + "/") ? root.path + path.dropFirst(copy.path.count) : path
        }
        let skills = loaded.skills.map { skill in
            var skill = skill
            skill.path = own(skill.path)
            return skill
        }
        let diagnostics = loaded.diagnostics.map { diagnostic in
            var diagnostic = diagnostic
            diagnostic.path = own(diagnostic.path)
            return diagnostic
        }
        return (skills, diagnostics)
    }

    /// `source`'s entries into `copy` as links, but each place in `emptied`
    /// as an empty file and each in `made` as a folder of its own, filled the
    /// same way. Another load's hidden copy at the top is left out.
    private static func link(_ source: URL, into copy: URL, relative: String, emptied: Set<String>, made: Set<String>) throws {
        let manager = FileManager.default
        for entry in try manager.contentsOfDirectory(atPath: source.path) {
            if relative.isEmpty, entry.hasPrefix(".check-") {
                continue
            }
            let place = relative + entry
            let target = copy.appendingPathComponent(entry)
            if emptied.contains(place) {
                try Data().write(to: target, options: .withoutOverwriting)
            } else if made.contains(place) {
                try manager.createDirectory(at: target, withIntermediateDirectories: false)
                try link(source.appendingPathComponent(entry), into: target, relative: place + "/", emptied: emptied, made: made)
            } else {
                try manager.createSymbolicLink(at: target, withDestinationURL: source.appendingPathComponent(entry))
            }
        }
    }

    /// A skill file's place in the skills folder `root`, as removing the
    /// skill takes it away: a `SKILL.md`'s folder, else the file itself;
    /// nil outside the folder, or for the folder itself.
    static func location(of path: String, in root: String) -> String? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let removed = file.lastPathComponent == "SKILL.md" ? file.deletingLastPathComponent() : file
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard removed.path.hasPrefix(prefix) else { return nil }
        return String(removed.path.dropFirst(prefix.count))
    }

    static func promptSection(_ skills: [SkillDocument]) -> String {
        guard !skills.isEmpty else { return "" }
        var lines = [
            "# Skills",
            "Skills hold detailed instructions for particular tasks. When a task matches a skill's description, call apelin_skill_read with its name before you start, and follow it.",
            "",
            "<available_skills>",
        ]
        for skill in skills {
            let source = skill.isUserSkill ? " source=\"user\"" : ""
            lines.append("<skill name=\"\(escape(skill.name))\"\(source)>\(escape(skill.description))</skill>")
        }
        lines.append("</available_skills>")
        return lines.joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
