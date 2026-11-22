import ApelinAgent
import ApelinCore
import Foundation
import KWWKAgent
import Testing

/// ApelinCore's `SkillManifest`, which the app's From GitHub judges a skill
/// with before importing it, reads a `SKILL.md` as kwwk's own loader does:
/// the same name, description, body and command-only flag, and a skill
/// kwwk leaves out has no description here either.
@Suite("Skill manifest")
struct SkillManifestTests {
    /// Each `SKILL.md`, in a folder named `folder`.
    private static let cases: [(folder: String, text: String)] = [
        ("plain", "---\nname: plain\ndescription: Use when testing.\n---\n\n# Plain\nBody.\n"),
        ("quoted", "---\nname: 'quoted'\ndescription: \"Quoted: with a colon\"\n---\nBody"),
        ("crlf", "---\r\nname: crlf\r\ndescription: Windows lines.\r\n---\r\nBody\r\n"),
        ("unnamed", "---\ndescription: Named for its folder.\n---\nBody"),
        ("empty-name", "---\nname:\ndescription: An empty name.\n---\nBody"),
        ("commented", "---\n# a comment\nname: commented\n\ndescription: After a blank line.\n---\nBody"),
        ("spaced", "---\n  name  :   spaced  \ndescription:   Padded.   \n---\nBody"),
        ("none", "# No frontmatter\nJust text."),
        ("unclosed", "---\nname: unclosed\ndescription: Never closed.\n"),
        ("dashes", "----\nname: dashes\ndescription: Four dashes.\n---\nBody"),
        ("folded", "---\nname: folded\ndescription: >\n  Over lines.\n---\nBody"),
        ("command", "---\nname: command\ndescription: Typed.\ndisable-model-invocation: TRUE\n---\nBody"),
        ("Upper", "---\ndescription: An upper-case folder.\n---\nBody"),
        ("long", "---\nname: long\ndescription: \(String(repeating: "x", count: 1030))\n---\nBody"),
        ("repeated", "---\nname: repeated\ndescription: First.\ndescription: Second.\n---\nBody"),
        ("bom", "\u{FEFF}---\nname: bom\ndescription: After a byte-order mark.\n---\nBody"),
        ("bad--name", "---\ndescription: Two hyphens.\n---\nBody"),
        ("blank-description", "---\nname: blank-description\ndescription:   \n---\nBody"),
    ]

    @Test
    func `reads every SKILL.md as kwwk's loader does`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (folder, text) in Self.cases {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: directory.appendingPathComponent("SKILL.md"))
        }
        let loaded = Skills.load(directories: [root.path], useIndex: false)
        for (folder, _) in Self.cases {
            let file = root.appendingPathComponent(folder).appendingPathComponent("SKILL.md")
            // as the app reads what it downloads
            let read = try #require(String(data: Data(contentsOf: file), encoding: .utf8))
            let manifest = SkillManifest(read)
            let skill = loaded.skills.first { URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent == folder }
            #expect((skill != nil) == (manifest.description != nil), "\(folder): kwwk offers it only with a description")
            if let skill {
                #expect(skill.name == manifest.name(inFolderNamed: folder), "\(folder): the name")
                #expect(skill.description == manifest.description, "\(folder): the description")
                #expect(skill.body == manifest.body, "\(folder): the body")
                #expect(skill.disableModelInvocation == manifest.disablesModelInvocation, "\(folder): command only")
            }
            let name = manifest.name(inFolderNamed: folder)
            let nameDiagnosed = loaded.diagnostics.contains { $0.path.hasSuffix("/\(folder)/SKILL.md") && $0.message.hasPrefix("name ") }
            #expect(nameDiagnosed == (SkillManifest.nameProblem(name) != nil || name != folder), "\(folder): kwwk's name rules")
            let tooLong = loaded.diagnostics.contains { $0.path.hasSuffix("/\(folder)/SKILL.md") && $0.message.hasPrefix("description exceeds") }
            #expect(tooLong == ((manifest.description?.count ?? 0) > SkillManifest.maximumDescriptionLength), "\(folder): kwwk's description bound")
        }
        #expect(try SkillManifest(#require(Self.cases.first { $0.folder == "folded" }?.text)).describesInBlock)
        #expect(try !SkillManifest(#require(Self.cases.first { $0.folder == "plain" }?.text)).describesInBlock)
    }

    @Test
    func `an empty frontmatter, which kwwk's parser traps on, has no description`() {
        let manifest = SkillManifest("---\n---\nNothing above.")
        #expect(manifest.description == nil && manifest.fields.isEmpty)
        #expect(SkillManifest.stopsKwwkLoader("---\n---\nNothing above."))
        #expect(SkillManifest.stopsKwwkLoader("---\r\n---"))
        #expect(!SkillManifest.stopsKwwkLoader("----\n---\nBody"))
        #expect(!SkillManifest.stopsKwwkLoader("---\n\n---\nBody"))
        #expect(!SkillManifest.stopsKwwkLoader("---\nname: x\n---\nBody"))
    }

    /// The trap itself, in kwwk's own loader at the revision Apelin pins:
    /// a skills folder with one such `SKILL.md` stops the process that lists
    /// it. When kwwk no longer traps this fails, and `stopsKwwkLoader`'s
    /// guards can go.
    @Test
    func `kwwk's loader stops the process on a SKILL.md with an empty frontmatter`() async {
        await #expect(processExitsWith: .failure) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-trap-\(UUID().uuidString)")
            let folder = root.appendingPathComponent("hollow", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data("---\n---\nNothing above.\n".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
            _ = Skills.load(directories: [root.path], useIndex: false)
        }
    }

    /// What a session, apelin_skill_read and Settings ▸ Skills list goes
    /// round such files: every other skill is offered as it was, each file
    /// that would stop kwwk is named where it is, as kwwk names a skill
    /// with no description, and nothing of the copy kwwk read is left.
    @Test
    func `the skills listing passes over a file that would stop kwwk and keeps the rest`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-guard-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let files = [
            "plain/SKILL.md": "---\nname: plain\ndescription: Use when testing.\n---\nBody.",
            "plain/reference.md": "---\n---\nNever read: below a SKILL.md.",
            "hollow/SKILL.md": "---\n---\nNothing above.",
            "group/inner/SKILL.md": "---\nname: inner\ndescription: Nested.\n---\nInner.",
            "group/stuck/SKILL.md": "---\r\n---\r\n",
            "loose.md": "---\nname: loose\ndescription: A file at the top.\n---\nLoose.",
            "empty.md": "---\n---\n",
            ".gitignore": "ignored/\n",
            "ignored/SKILL.md": "---\nname: ignored\ndescription: Ignored.\n---\nx",
        ]
        for (place, text) in files {
            let url = root.appendingPathComponent(place)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        #expect(Set(SkillManifest.filesStoppingKwwk(in: root)) == ["hollow/SKILL.md", "group/stuck/SKILL.md", "empty.md"])

        let listed = SkillCatalog.load(userDirectory: root)
        let user = listed.skills.filter(\.isUserSkill)
        #expect(Set(user.map(\.name)) == ["plain", "inner", "loose"])
        #expect(user.first { $0.name == "plain" }?.directory == root.appendingPathComponent("plain").standardizedFileURL.path)
        #expect(user.first { $0.name == "inner" }?.location == "group/inner")
        for place in ["hollow/SKILL.md", "group/stuck/SKILL.md", "empty.md"] {
            #expect(listed.diagnostics.contains { $0.path == root.appendingPathComponent(place).path && $0.message == "description is required" },
                    "\(place) is named as kwwk names a skill with no description")
        }
        #expect(!listed.diagnostics.contains { $0.path.contains("/.check-") }, "no path names the copy")
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".check-") }
        #expect(left.isEmpty, "the copy is removed")
    }

    @Test
    func `the name rules the agent's skill tools quote`() {
        #expect(SkillManifest.nameProblem("release-notes") == nil)
        #expect(SkillManifest.nameProblem("") == .length)
        #expect(SkillManifest.nameProblem(String(repeating: "a", count: 65)) == .length)
        #expect(SkillManifest.nameProblem("Release") == .characters)
        #expect(SkillManifest.nameProblem("notes_v2") == .characters)
        #expect(SkillManifest.nameProblem("-notes") == .hyphens)
        #expect(SkillManifest.nameProblem("release--notes") == .hyphens)
    }
}
