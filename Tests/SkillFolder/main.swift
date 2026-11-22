import Foundation

// Settings ▸ Skills copies a skill into the skills folder and removes one
// by its place there: a folder with a SKILL.md or one Markdown file comes
// in whole or not at all, links and hidden entries stay behind, what is
// there is replaced only when asked, and nothing outside the folder goes.

func require(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}

func fails(_ expected: SkillFolder.Failure, _ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch let failure as SkillFolder.Failure {
        return failure == expected
    } catch {
        return false
    }
}

let manager = FileManager.default
let base = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("apelin-skill-folder-\(UUID().uuidString)", isDirectory: true)
try manager.createDirectory(at: base, withIntermediateDirectories: false)
defer { try? manager.removeItem(at: base) }

func write(_ relative: String, _ text: String) throws {
    let url = base.appendingPathComponent(relative)
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func read(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

func visible(_ url: URL) -> [String] {
    ((try? manager.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

let folder = SkillFolder(root: base.appendingPathComponent("skills", isDirectory: true))
try write("secret.txt", "outside")

// A folder: its files and subfolders, never its links or hidden entries.
try write("in/release-notes/SKILL.md", "---\nname: release-notes\ndescription: Notes.\n---\nSymptom first.")
try write("in/release-notes/templates/short.md", "# Short")
try write("in/release-notes/.git/config", "[core]")
try manager.createSymbolicLink(
    at: base.appendingPathComponent("in/release-notes/leak.txt"),
    withDestinationURL: base.appendingPathComponent("secret.txt"),
)
let notes = try folder.add(base.appendingPathComponent("in/release-notes"), replacing: false)
let copied = folder.root.appendingPathComponent(notes)
require(notes == "release-notes", "a folder keeps its name")
require(visible(copied) == ["SKILL.md", "templates"], "files and folders are copied, links are not")
require(!manager.fileExists(atPath: copied.appendingPathComponent(".git").path), "hidden entries stay behind")
require(read(copied.appendingPathComponent("templates/short.md")) == "# Short", "subfolders come along")
require(visible(folder.root) == ["release-notes"], "nothing is left staged")

// What is there is replaced only when asked.
try write("in/release-notes/SKILL.md", "---\nname: release-notes\ndescription: Notes.\n---\nSymptom second.")
require(fails(.exists("release-notes")) {
    try folder.add(base.appendingPathComponent("in/release-notes"), replacing: false)
}, "an existing skill is not replaced unasked")
require(read(copied.appendingPathComponent("SKILL.md"))?.contains("first") == true, "and is left as it was")
try folder.add(base.appendingPathComponent("in/release-notes"), replacing: true)
require(read(copied.appendingPathComponent("SKILL.md"))?.contains("second") == true, "replacing takes the new copy")
require(visible(folder.root) == ["release-notes"], "and leaves nothing of the old one behind")

// One Markdown file becomes a folder named for it.
try write("in/lint.md", "---\nname: lint\ndescription: Lint.\n---\nRun it.")
try require(folder.add(base.appendingPathComponent("in/lint.md"), replacing: false) == "lint", "a file names its folder")
require(read(folder.root.appendingPathComponent("lint/SKILL.md"))?.contains("Run it.") == true, "as its SKILL.md")

// Not a skill: a folder without SKILL.md, another kind of file, a bare SKILL.md.
try write("in/empty/readme.txt", "no skill here")
try write("in/notes.txt", "plain text")
try write("in/bare/SKILL.md", "---\nname: bare\ndescription: Bare.\n---\nx")
require(fails(.notASkill) { try folder.add(base.appendingPathComponent("in/empty"), replacing: false) },
        "a folder needs a SKILL.md at its top")
require(fails(.notASkill) { try folder.add(base.appendingPathComponent("in/notes.txt"), replacing: false) },
        "a file must be Markdown")
require(fails(.notASkill) { try folder.add(base.appendingPathComponent("in/bare/SKILL.md"), replacing: false) },
        "a file named SKILL.md names no folder")

// An empty frontmatter, which stops kwwk's loader and every worker that
// lists the folder: refused whole, as a folder or as one file, whatever
// its line ends.
try write("in/hollow/SKILL.md", "---\n---\nNothing above.")
try write("in/hollow/notes.md", "# Notes")
try write("in/hollow.md", "---\r\n---\r\n")
try write("in/fenced.md", "----\n---\nfour dashes, then a fence: kwwk reads it")
require(fails(.emptyFrontmatter) { try folder.add(base.appendingPathComponent("in/hollow"), replacing: false) },
        "a folder whose SKILL.md opens with an empty frontmatter is refused")
require(fails(.emptyFrontmatter) { try folder.add(base.appendingPathComponent("in/hollow.md"), replacing: false) },
        "and so is such a Markdown file, CRLF and all")
require(visible(folder.root) == ["lint", "release-notes"], "and nothing of either stays")
require(!SkillManifest.stopsKwwkLoader("----\n---\nx") && !SkillManifest.stopsKwwkLoader("---\n\n---\nx"),
        "a fence kwwk reads is no empty frontmatter")
require(SkillManifest.stopsKwwkLoader("\u{FEFF}---\r---"), "a byte-order mark and a lone CR are read past")
try require(folder.add(base.appendingPathComponent("in/fenced.md"), replacing: false) == "fenced", "kwwk reads four dashes")
try folder.remove("fenced")

// Too large: nothing is left behind.
try write("in/huge/SKILL.md", "---\nname: huge\ndescription: Huge.\n---\nx")
try Data(count: SkillFolder.maximumBytes + 1).write(to: base.appendingPathComponent("in/huge/blob.bin"))
require(fails(.tooLarge) { try folder.add(base.appendingPathComponent("in/huge"), replacing: false) },
        "a skill over the size bound is refused")
require(visible(folder.root) == ["lint", "release-notes"], "and nothing of it stays")

// Removal: by place, inside the folder only, a link itself and not what it names.
try manager.createSymbolicLink(at: folder.root.appendingPathComponent("outside"), withDestinationURL: base)
require(fails(.invalidLocation) { try folder.remove("outside/secret.txt") }, "a way out through a link is refused")
require(fails(.invalidLocation) { try folder.remove("../secret.txt") }, "a way up is refused")
require(fails(.invalidLocation) { try folder.remove("missing") }, "a place with nothing there is refused")
try folder.remove("outside")
require(manager.fileExists(atPath: base.appendingPathComponent("secret.txt").path), "a link goes, not what it names")
try folder.remove("lint")
require(visible(folder.root) == ["release-notes"], "a skill goes by its place")

// Written text (the agent's apelin_skill_save): a folder named for the
// skill, checked while staged, in whole or not at all.
var checked: [String] = []
let written = try folder.write("---\nname: triage\ndescription: Crashes.\n---\n\nRead the report.\n", named: "triage", replacing: false) {
    checked.append($0.lastPathComponent)
    require(read($0.appendingPathComponent("SKILL.md"))?.hasSuffix("Read the report.\n") == true, "check sees the staged file")
}

require(written == "triage" && checked == ["triage"], "the staged folder carries the skill's name")
require(read(folder.root.appendingPathComponent("triage/SKILL.md"))?.contains("name: triage") == true, "and lands as its SKILL.md")
require(fails(.exists("triage")) { try folder.write("x", named: "triage", replacing: false) }, "a skill there stays unless replaced")
struct Refused: Error {}
do {
    try folder.write("bad", named: "triage", replacing: true) { _ in throw Refused() }
    require(false, "a failed check writes nothing")
} catch is Refused {}
require(read(folder.root.appendingPathComponent("triage/SKILL.md"))?.contains("Read the report.") == true, "and keeps the skill there")
try folder.write("---\nname: triage\ndescription: Crashes.\n---\n\nSymbolicate first.\n", named: "triage", replacing: true)
require(read(folder.root.appendingPathComponent("triage/SKILL.md"))?.contains("Symbolicate first.") == true, "a replacement replaces")
require(fails(.invalidLocation) { try folder.write("x", named: "../escape", replacing: false) }, "a name is one place in the folder")
require(fails(.invalidLocation) { try folder.write("x", named: ".hidden", replacing: false) }, "and not a hidden one")
require(visible(folder.root) == ["release-notes", "triage"], "nothing staged is left")
require(((try? manager.contentsOfDirectory(atPath: folder.root.path)) ?? []).filter { $0.hasPrefix(".") }.isEmpty, "no hidden leftovers")

print("ok: skills come into the folder whole or not at all, and go only from inside it")
