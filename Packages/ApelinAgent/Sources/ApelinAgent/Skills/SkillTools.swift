import struct ApelinCore.SkillFolder
import struct ApelinCore.SkillManifest
import Foundation
import KWWKAgent
import KWWKAI

/// apelin_skill_list, apelin_skill_save and apelin_skill_remove: the user's
/// skills folder, written as mobile through the writer Settings ▸ Skills
/// uses (`SkillFolder`). A save is checked as kwwk will read it before it is
/// asked about, and again, staged, before it goes in.
struct SkillTools {
    /// kwwk's bounds on a skill's frontmatter (`Skills.validateName`).
    static let maximumNameLength = SkillManifest.maximumNameLength
    static let maximumDescriptionLength = SkillManifest.maximumDescriptionLength

    let directory: URL

    struct Listing: Encodable {
        struct Skill: Encodable {
            var name: String
            var description: String
            /// `builtIn` or `user`.
            var source: String
            /// A user skill's place in the skills folder.
            var location: String?
            var files: [String]
        }

        struct Problem: Encodable {
            var location: String?
            var message: String
        }

        var skills: [Skill]
        var problems: [Problem]
    }

    struct Saved: Encodable {
        var name: String
        var location: String
        var replaced: Bool
        var note = "Every conversation lists it from its next message; apelin_skill_read reads it."
    }

    struct Removed: Encodable {
        var name: String
        var location: String
    }

    /// What a session is offered, without the instructions apelin_skill_read
    /// answers.
    func list() -> Listing {
        let listing = SkillCatalog.listing(userDirectory: directory)
        return Listing(
            skills: listing.skills.map {
                Listing.Skill(name: $0.name, description: $0.description, source: $0.source.rawValue, location: $0.location, files: $0.files)
            },
            problems: listing.problems.map { Listing.Problem(location: $0.location, message: $0.message) },
        )
    }

    /// What a save would write, checked before the user is asked.
    func change(saving arguments: JSONValue) throws -> SkillChangeApproval {
        let name = try arguments.requireString("name").trimmingCharacters(in: .whitespaces)
        if let problem = Self.nameProblem(name) {
            throw ToolArgumentError("The skill's name \(problem).")
        }
        guard !BuiltInSkills.all.contains(where: { $0.name == name }) else {
            throw ToolArgumentError("\(name) is a built-in skill's name; choose another.")
        }
        let description = try arguments.requireString("description").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, !description.contains(where: \.isNewline), !description.contains("\0"),
              description.count <= Self.maximumDescriptionLength
        else {
            throw ToolArgumentError("The description is one line of 1 to \(Self.maximumDescriptionLength) characters saying when to use the skill.")
        }
        let instructions = try arguments.requireString("instructions").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty, !instructions.contains("\0"), instructions.utf8.count <= SkillReader.maxBodyBytes else {
            throw ToolArgumentError("The instructions are 1 to \(SkillReader.maxBodyBytes) bytes of text.")
        }
        let place = directory.appendingPathComponent(name, isDirectory: true)
        let occupied = Self.exists(place)
        if Self.exists(directory.appendingPathComponent(name + ".md")) {
            throw ToolArgumentError("\(name).md at the top of the skills folder is a skill of that name; remove it with apelin_skill_remove first, or choose another name.")
        }
        if occupied, arguments.argBool("replace") != true {
            throw ToolArgumentError("The skills folder already holds \(name); pass replace: true to replace it, or choose another name.")
        }
        return SkillChangeApproval(
            action: "save",
            name: name,
            location: name,
            replacing: occupied,
            text: "---\nname: \(name)\ndescription: \(description)\n---\n\n\(instructions)\n",
        )
    }

    /// The user's skill a removal takes away, found as a session finds it.
    func change(removing arguments: JSONValue) throws -> SkillChangeApproval {
        let name = try arguments.requireString("name").trimmingCharacters(in: .whitespaces)
        let skills = SkillCatalog.load(userDirectory: directory).skills
        guard let skill = skills.first(where: { $0.name == name }) else {
            throw ToolArgumentError("No skill is named \(name); apelin_skill_list names them.")
        }
        guard skill.isUserSkill, let location = skill.location else {
            throw ToolArgumentError("\(name) is built into Apelin and cannot be removed.")
        }
        return SkillChangeApproval(action: "remove", name: name, location: location, replacing: false, text: nil)
    }

    /// Writes the approved skill. Staged, it must read back as kwwk reads
    /// it — this name and description, no diagnostic — or nothing changes.
    func save(_ change: SkillChangeApproval) throws -> Saved {
        guard change.action == "save", let text = change.text else { throw ToolDeniedError(message: "not a skill to save") }
        do {
            try SkillFolder(root: directory).write(text, named: change.location, replacing: change.replacing) { staged in
                let loaded = Skills.load(directories: [staged.deletingLastPathComponent().path], useIndex: false)
                if let diagnostic = loaded.diagnostics.first {
                    throw ToolArgumentError("The skill would not be offered: \(diagnostic.message).")
                }
                guard loaded.skills.contains(where: { $0.name == change.name }) else {
                    throw ToolArgumentError("The skill would not be offered as \(change.name).")
                }
            }
        } catch SkillFolder.Failure.exists {
            throw ToolArgumentError("The skills folder already holds \(change.name); pass replace: true to replace it.")
        }
        return Saved(name: change.name, location: change.location, replaced: change.replacing)
    }

    func remove(_ change: SkillChangeApproval) throws -> Removed {
        guard change.action == "remove" else { throw ToolDeniedError(message: "not a skill to remove") }
        try SkillFolder(root: directory).remove(change.location)
        return Removed(name: change.name, location: change.location)
    }

    /// Why `name` is no skill name kwwk takes, or nil.
    static func nameProblem(_ name: String) -> String? {
        switch SkillManifest.nameProblem(name) {
        case .length?: "is 1 to \(maximumNameLength) characters"
        case .characters?: "takes lowercase letters, digits and hyphens only"
        case .hyphens?: "neither starts nor ends with a hyphen, nor has two in a row"
        case nil: nil
        }
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
