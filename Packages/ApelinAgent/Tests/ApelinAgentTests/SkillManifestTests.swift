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
