import ApelinCore
import Foundation

// Settings ▸ Skills ▸ From GitHub, against a GitHub that answers from a
// script: which links it takes, how a ref with slashes is told from the path
// after it, what a scan finds and leaves behind, what it refuses to import
// and why, GitHub's refusals in its own words, and an import that lands in
// the skills folder through SkillFolder, every byte the commit's.

func require(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        FileHandle.standardError.write(Data("error: line \(line): \(message)\n".utf8))
        exit(1)
    }
}

func expect(_ expected: GitHubSkillFailure, line: Int = #line, _ body: () async throws -> Void) async {
    do {
        try await body()
        require(false, "expected \(expected)", line: line)
    } catch let failure as GitHubSkillFailure {
        require(failure == expected, "expected \(expected), got \(failure)", line: line)
    } catch {
        require(false, "expected \(expected), got \(error)", line: line)
    }
}

/// GitHub, answering each URL it knows and failing on any other.
final class FakeGitHub: @unchecked Sendable {
    struct Answer {
        var status = 200
        var body: Data
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var answers: [String: Answer] = [:]
    private(set) var asked: [String] = []

    func answer(_ url: String, status: Int = 200, json: Any, headers: [String: String] = [:]) {
        let body = try! JSONSerialization.data(withJSONObject: json)
        lock.withLock { answers[url] = Answer(status: status, body: body, headers: headers) }
    }

    func answer(_ url: String, status: Int = 200, text: String, headers: [String: String] = [:]) {
        lock.withLock { answers[url] = Answer(status: status, body: Data(text.utf8), headers: headers) }
    }

    var api: [String] {
        lock.withLock { asked.filter { $0.hasPrefix("https://api.github.com/") } }
    }

    var scanner: GitHubSkillScanner {
        GitHubSkillScanner { request in
            let url = request.url!.absoluteString
            let answer = self.lock.withLock {
                self.asked.append(url)
                return self.answers[url]
            }
            guard let answer else {
                FileHandle.standardError.write(Data("error: asked what the script does not answer: \(url)\n".utf8))
                exit(1)
            }
            if url.hasPrefix("https://api.github.com/") {
                require(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json", "the API's media type")
                require(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10", "the API version")
            }
            require(request.value(forHTTPHeaderField: "Authorization") == nil, "nothing is signed in")
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: answer.headers)!
            return (answer.body, response)
        }
    }
}

// MARK: - Links

func link(_ text: String) -> GitHubSkillLink? {
    GitHubSkillLink.parse(text)
}

do {
    let repository = link("https://github.com/mattpocock/skills")
    require(repository == GitHubSkillLink(owner: "mattpocock", repository: "skills", target: .repository, words: [], namespace: nil), "a repository")
    require(link("  https://github.com/mattpocock/skills/\n") == repository, "a trailing slash and white space around it")
    require(link("https://github.com/mattpocock/skills.git") == repository, "a clone address")
    require(link("https://www.github.com/mattpocock/skills") == repository, "www.github.com")
    require(link("HTTPS://GitHub.com/mattpocock/skills") == repository, "the scheme and host in any case")
    require(link("https://github.com/mattpocock/skills?tab=readme-ov-file#readme") == repository, "a query and fragment are not read")

    let folder = link("https://github.com/mattpocock/skills/tree/matt/commands-and-skills/skills")
    require(folder?.target == .folder && folder?.words == ["matt", "commands-and-skills", "skills"], "a folder keeps the ref and path together")
    require(link("https://github.com/o/r/tree/main")?.words == ["main"], "a ref alone is the whole tree")
    require(link("https://github.com/o/r/tree/f%C3%A9ature/docs")?.words == ["féature", "docs"], "words are decoded")

    let file = link("https://github.com/o/r/blob/main/skills/tdd/SKILL.md?plain=1#L4")
    require(file?.target == .skillFile && file?.words == ["main", "skills", "tdd", "SKILL.md"], "a SKILL.md")
    let raw = link("https://raw.githubusercontent.com/o/r/refs/heads/feature/x/tdd/SKILL.md")
    require(raw?.target == .skillFile && raw?.namespace == .heads && raw?.words == ["feature", "x", "tdd", "SKILL.md"], "raw with refs/heads/")
    require(link("https://raw.githubusercontent.com/o/r/v1.2/SKILL.md")?.namespace == nil, "raw with a ref")

    for refused in [
        "http://github.com/o/r", "https://gist.github.com/o/r", "https://github.com/o", "https://github.com",
        "https://github.com/o/r/issues", "https://github.com/o/r/tree", "https://github.com/o/r/blob/main/README.md",
        "https://github.com/o/r/blob/SKILL.md", "https://user@github.com/o/r", "https://github.com:8443/o/r",
        "https://github.com/-o/r", "https://github.com/o/..", "https://github.com/o//r", "https://github.com/o/r/tree/a%2Fb",
        "https://raw.githubusercontent.com/o/r/main/README.md", "https://raw.githubusercontent.com/o/r/SKILL.md",
        "https://github.com/o/r/tree/main/a b", "github.com/o/r", "ftp://github.com/o/r", "",
        "https://github.com/o/r/tree/main/%2E%2E/x", "https://example.com/o/r",
    ] {
        require(link(refused) == nil, "refused: \(refused)")
    }
}

// MARK: - A repository of several skills

let commit = String(repeating: "a", count: 40)
let rootTree = String(repeating: "b", count: 40)
let skillsTree = String(repeating: "c", count: 40)
var repositoryFiles: [String: String] = [:]

/// A tree entry for a file whose text is served by raw.githubusercontent.com.
func file(_ path: String, _ text: String, mode: String = "100644") -> [String: Any] {
    repositoryFiles[path] = text
    let data = Data(text.utf8)
    return ["path": path, "mode": mode, "type": "blob", "sha": GitHubSkillScanner.blobID(of: data), "size": data.count]
}

func folder(_ path: String) -> [String: Any] {
    ["path": path, "mode": "040000", "type": "tree", "sha": String(repeating: "d", count: 40)]
}

func skill(_ name: String, _ description: String, extra: String = "") -> String {
    "---\nname: \(name)\ndescription: \(description)\n\(extra)---\n\n# \(name)\n\nThe instructions.\n"
}

let github = FakeGitHub()
let api = "https://api.github.com/repos/mattpocock/skills"
let rawBase = "https://raw.githubusercontent.com/mattpocock/skills/\(commit)/"
let tree: [[String: Any]] = [
    folder("skills"),
    file("skills/README.md", "# Skills"),
    folder("skills/tdd"),
    file("skills/tdd/SKILL.md", skill("tdd", "Test-driven development.")),
    file("skills/tdd/mocking.md", "# Mocking"),
    folder("skills/tdd/agents"),
    file("skills/tdd/agents/openai.yaml", "name: tdd"),
    folder("skills/tdd/scripts"),
    file("skills/tdd/scripts/run.sh", "#!/bin/sh\necho never\n", mode: "100755"),
    file("skills/tdd/.DS_Store", "junk"),
    folder("skills/tdd/.github"),
    file("skills/tdd/.github/workflow.yml", "on: push"),
    ["path": "skills/tdd/latest.md", "mode": "120000", "type": "blob", "sha": String(repeating: "e", count: 40), "size": 9],
    ["path": "skills/tdd/vendor", "mode": "160000", "type": "commit", "sha": String(repeating: "f", count: 40)],
    folder("skills/ask"),
    file("skills/ask/SKILL.md", skill("ask-matt", "A router.", extra: "disable-model-invocation: true\n")),
    folder("skills/Bad_Name"),
    file("skills/Bad_Name/SKILL.md", "---\ndescription: Named for its folder.\n---\nBody"),
    folder("skills/folded"),
    file("skills/folded/SKILL.md", "---\nname: folded\ndescription: >\n  Written over\n  several lines.\n---\nBody"),
    folder("skills/icli"),
    file("skills/icli/SKILL.md", skill("apelin-icli", "Shadows a built-in.")),
    folder("skills/empty"),
    file("skills/empty/SKILL.md", "---\n---\nNo frontmatter at all."),
    folder("skills/long"),
    file("skills/long/SKILL.md", skill("long", String(repeating: "x", count: 1025))),
    folder("skills/tdd-copy"),
    file("skills/tdd-copy/SKILL.md", skill("tdd", "The same name, elsewhere.")),
    folder("skills/.claude"),
    folder("skills/.claude/skills"),
    folder("skills/.claude/skills/hidden-one"),
    file("skills/.claude/skills/hidden-one/SKILL.md", skill("hidden-one", "Found under a hidden folder.")),
    folder("skills/linked"),
    ["path": "skills/linked/SKILL.md", "mode": "120000", "type": "blob", "sha": String(repeating: "e", count: 40), "size": 12],
]
let skillsListing: [[String: Any]] = tree.filter { ($0["path"] as! String).hasPrefix("skills/") }.map { entry in
    var entry = entry
    entry["path"] = String((entry["path"] as! String).dropFirst("skills/".count))
    return entry
}

github.answer("\(api)/git/matching-refs/heads/main", json: [["ref": "refs/heads/main"], ["ref": "refs/heads/main-old"]])
github.answer("\(api)/commits/heads/main?per_page=1", json: ["sha": commit, "commit": ["tree": ["sha": rootTree]]])
github.answer("\(api)/contents?ref=\(commit)", json: [["name": "skills", "type": "dir", "sha": skillsTree], ["name": "README.md", "type": "file", "sha": commit]])
github.answer("\(api)/git/trees/\(skillsTree)?recursive=1", json: ["sha": skillsTree, "truncated": false, "tree": skillsListing])
for (path, text) in repositoryFiles {
    github.answer(rawBase + path, text: text)
}

let builtIns: Set<String> = ["apelin-icli", "apelin-git-workflow"]
let scan = try await github.scanner.scan(link("https://github.com/mattpocock/skills/tree/main/skills")!, builtInNames: builtIns)
require(scan.place == GitHubSkillPlace(owner: "mattpocock", repository: "skills", ref: "main", commit: commit, path: "skills", single: false), "the place")
require(github.api == [
    "\(api)/git/matching-refs/heads/main",
    "\(api)/commits/heads/main?per_page=1",
    "\(api)/contents?ref=\(commit)",
    "\(api)/git/trees/\(skillsTree)?recursive=1",
], "four API requests: the ref, the commit, the folder and its tree; got \(github.api)")
let byFolder = Dictionary(uniqueKeysWithValues: scan.candidates.map { ($0.folder, $0) })
require(scan.candidates.map(\.folder) == [
    ".claude/skills/hidden-one", "Bad_Name", "ask", "empty", "folded", "icli", "linked", "long", "tdd-copy", "tdd",
], "every folder with a SKILL.md, in path order: \(scan.candidates.map(\.folder))")
require(scan.omitted == 0, "none omitted")

let tdd = byFolder["tdd"]!
require(tdd.problem == nil && tdd.name == "tdd" && tdd.description == "Test-driven development.", "tdd imports")
require(tdd.files.map(\.path) == ["SKILL.md", "agents/openai.yaml", "mocking.md", "scripts/run.sh"], "its files, the script among them: \(tdd.files.map(\.path))")
require(tdd.folders == ["agents", "scripts"], "its folders: \(tdd.folders)")
require(tdd.leftBehind == [".DS_Store", ".github", "latest.md", "vendor"], "hidden entries, a link and a submodule stay: \(tdd.leftBehind)")
require(tdd.instructions.hasPrefix("---\nname: tdd"), "the SKILL.md for the preview")
require(byFolder["ask"]?.problem == .userInvokedOnly && byFolder["ask"]?.name == "ask-matt", "a command-only skill is named and refused")
require(byFolder["Bad_Name"]?.problem == .invalidName && byFolder["Bad_Name"]?.name == "Bad_Name", "a folder's name kwwk refuses")
require(byFolder["folded"]?.problem == .noDescription, "a description written as a YAML block")
require(byFolder["empty"]?.problem == .noDescription, "an empty frontmatter, which kwwk traps on")
require(byFolder["long"]?.problem == .longDescription, "a description over 1,024 characters")
require(byFolder["icli"]?.problem == .builtIn, "a built-in's name")
require(byFolder["linked"]?.problem == .notText, "a SKILL.md that is a link")
require(byFolder["tdd-copy"]?.problem == nil && byFolder["tdd-copy"]?.name == "tdd", "the same name in another folder")
require(byFolder[".claude/skills/hidden-one"]?.problem == nil, "a skill under a hidden folder is found")
require(!github.asked.contains(rawBase + "skills/linked/SKILL.md"), "a link is not read")

/// One name takes one place: ticking one unticks the other.
var selection = GitHubSkillImportPlan.initialSelection(of: scan.candidates)
require(selection.isEmpty, "several importable skills start unticked")
selection = GitHubSkillImportPlan.toggling("tdd", in: selection, candidates: scan.candidates)
selection = GitHubSkillImportPlan.toggling("tdd-copy", in: selection, candidates: scan.candidates)
require(selection == ["tdd-copy"], "a second skill of one name replaces the first in the selection")
require(GitHubSkillImportPlan.toggling("ask", in: selection, candidates: scan.candidates) == selection, "a refused skill is never ticked")
require(GitHubSkillImportPlan.toggling("tdd-copy", in: selection, candidates: scan.candidates).isEmpty, "a tap unticks")
require(GitHubSkillImportPlan.all(of: scan.candidates) == [".claude/skills/hidden-one", "tdd-copy"], "Select All takes the first of each name")

// MARK: - Importing

let manager = FileManager.default
let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("apelin-github-skills-\(UUID().uuidString)", isDirectory: true)
try manager.createDirectory(at: base, withIntermediateDirectories: false)
defer { try? manager.removeItem(at: base) }

let staged = base.appendingPathComponent("staging/tdd", isDirectory: true)
try manager.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: false)
/// The files a download reports, as it reports them.
final class Written: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func add(_ path: String) {
        lock.withLock { paths.append(path) }
    }

    var all: [String] {
        lock.withLock { paths }
    }
}

let written = Written()
try await github.scanner.download(tdd, from: scan.place, into: staged) { path in
    written.add(path)
}

require(written.all.sorted() == tdd.files.map(\.path), "every file is written once: \(written.all)")
let skillsFolder = SkillFolder(root: base.appendingPathComponent("skills", isDirectory: true))
let location = try skillsFolder.add(staged, replacing: false)
let landed = skillsFolder.root.appendingPathComponent(location)
require(location == "tdd", "the skill lands under its name")
try require(String(contentsOf: landed.appendingPathComponent("scripts/run.sh"), encoding: .utf8) == "#!/bin/sh\necho never\n", "a script comes as text")
let mode = try manager.attributesOfItem(atPath: landed.appendingPathComponent("scripts/run.sh").path)[.posixPermissions] as! NSNumber
require(mode.intValue & 0o111 == 0, "nothing is made executable")
try require(String(contentsOf: landed.appendingPathComponent("agents/openai.yaml"), encoding: .utf8) == "name: tdd", "a reference file comes with it")
require(!manager.fileExists(atPath: landed.appendingPathComponent(".DS_Store").path), "hidden files stay behind")

// A file whose bytes are not the commit's is refused, and the folder made for it is the caller's to remove.
github.answer(rawBase + "skills/tdd/mocking.md", text: "# Mocking, changed")
await expect(.changed("skills/tdd/mocking.md")) {
    try await github.scanner.download(tdd, from: scan.place, into: base.appendingPathComponent("again", isDirectory: true))
}

github.answer(rawBase + "skills/tdd/mocking.md", text: "# Mocking")

/// The skills folder's own: a name taken here or elsewhere is asked about.
let existing = [
    GitHubSkillImportPlan.Existing(name: "tdd", location: "tdd.md"),
    GitHubSkillImportPlan.Existing(name: "grill", location: "grill"),
    GitHubSkillImportPlan.Existing(name: "other", location: "other-folder"),
]
let plan = GitHubSkillImportPlan.replacements(of: ["tdd", "grill", "fresh", "taken"], existing: existing) { $0 == "taken" }
require(plan == [
    "tdd": .init(elsewhere: ["tdd.md"], atPlace: false),
    "grill": .init(elsewhere: [], atPlace: true),
    "taken": .init(elsewhere: [], atPlace: true),
], "what each import clears: \(plan)")

// MARK: - Refs with slashes, tags, commits and one SKILL.md

let slashed = FakeGitHub()
let other = "https://api.github.com/repos/o/r"
let otherRaw = "https://raw.githubusercontent.com/o/r/\(commit)/"
let docsTree = String(repeating: "1", count: 40)
let skillText = skill("release-notes", "Notes.")
let skillData = Data(skillText.utf8)
let nested = Data(skill("nested", "Below it.").utf8)
slashed.answer("\(other)/git/matching-refs/heads/feature", json: [
    ["ref": "refs/heads/feature-x"], ["ref": "refs/heads/feature/docs"], ["ref": "refs/heads/feature"],
])
slashed.answer("\(other)/commits/heads/feature/docs?per_page=1", json: ["sha": commit, "commit": ["tree": ["sha": rootTree]]])
slashed.answer("\(other)/contents/skills?ref=\(commit)", json: [["name": "release-notes", "type": "dir", "sha": docsTree]])
slashed.answer("\(other)/git/trees/\(docsTree)?recursive=1", json: ["truncated": false, "tree": [
    ["path": "SKILL.md", "mode": "100644", "type": "blob", "sha": GitHubSkillScanner.blobID(of: skillData), "size": skillData.count],
    ["path": "deeper", "mode": "040000", "type": "tree", "sha": docsTree],
    ["path": "deeper/SKILL.md", "mode": "100644", "type": "blob", "sha": GitHubSkillScanner.blobID(of: nested), "size": nested.count],
]])
slashed.answer(otherRaw + "skills/release-notes/SKILL.md", text: skillText)
let single = try await slashed.scanner.scan(
    link("https://github.com/o/r/blob/feature/docs/skills/release-notes/SKILL.md")!,
    builtInNames: [],
)
require(single.place.ref == "feature/docs" && single.place.path == "skills/release-notes" && single.place.single, "the longest branch the path begins with: \(single.place)")
require(single.candidates.map(\.name) == ["release-notes"], "one SKILL.md is one skill, not those below it")
require(single.candidates[0].files.map(\.path) == ["SKILL.md", "deeper/SKILL.md"], "what is below it comes as its files")
require(GitHubSkillImportPlan.initialSelection(of: single.candidates) == [""], "a lone skill starts ticked")
require(!slashed.asked.contains(otherRaw + "skills/release-notes/deeper/SKILL.md"), "a single link reads one SKILL.md")

/// A tag, when no branch begins the path; at the top of the repository a
/// skill takes the repository's name.
let tagged = FakeGitHub()
tagged.answer("\(other)/git/matching-refs/heads/v1.0", json: [] as [Any])
tagged.answer("\(other)/git/matching-refs/tags/v1.0", json: [["ref": "refs/tags/v1.0"]])
tagged.answer("\(other)/commits/tags/v1.0?per_page=1", json: ["sha": commit, "commit": ["tree": ["sha": rootTree]]])
let topless = Data("---\ndescription: At the top.\n---\n".utf8)
tagged.answer("\(other)/git/trees/\(rootTree)?recursive=1", json: ["truncated": false, "tree": [
    ["path": "SKILL.md", "mode": "100644", "type": "blob", "sha": GitHubSkillScanner.blobID(of: topless), "size": topless.count],
]])
tagged.answer(otherRaw + "SKILL.md", text: String(decoding: topless, as: UTF8.self))
let top = try await tagged.scanner.scan(link("https://raw.githubusercontent.com/o/r/v1.0/SKILL.md")!, builtInNames: [])
require(top.place.ref == "v1.0" && top.place.path.isEmpty, "a tag")
require(top.candidates.first?.name == "r" && top.candidates.first?.problem == nil, "named for the repository at its top")

/// The footer says a commit once when the link named it.
func place(ref: String) -> GitHubSkillPlace {
    GitHubSkillPlace(owner: "o", repository: "r", ref: ref, commit: "abeeaf95660ba9e8b7c753eb38f441ca707a8823", path: "", single: false)
}

require(place(ref: "abeeaf95660ba9e8b7c753eb38f441ca707a8823").refIsCommit, "a full commit ID")
require(place(ref: "ABEEAF9").refIsCommit, "the start of one, in any case")
require(!place(ref: "main").refIsCommit && !place(ref: "abeeaf").refIsCommit && !place(ref: "deadbeef").refIsCommit, "a branch")
require(top.place.single && top.place.folderName == "r" && single.place.folderName == "release-notes", "a folder's name")

/// A full commit ID asks for no refs.
let pinned = FakeGitHub()
pinned.answer("\(other)/commits/\(commit)?per_page=1", json: ["sha": commit, "commit": ["tree": ["sha": rootTree]]])
pinned.answer("\(other)/git/trees/\(rootTree)?recursive=1", json: ["truncated": true, "tree": [] as [Any]])
await expect(.tooManyFiles) {
    _ = try await pinned.scanner.scan(link("https://github.com/o/r/tree/\(commit)")!, builtInNames: [])
}

require(pinned.api.count == 2, "a commit and its tree, no refs: \(pinned.api)")

/// No branch, tag or commit begins the path.
let unknown = FakeGitHub()
unknown.answer("\(other)/git/matching-refs/heads/nowhere", json: [["ref": "refs/heads/nowhere-else"]])
unknown.answer("\(other)/git/matching-refs/tags/nowhere", json: [] as [Any])
await expect(.refNotFound("nowhere", words: nil)) {
    _ = try await unknown.scanner.scan(link("https://github.com/o/r/tree/nowhere/skills")!, builtInNames: [])
}

/// A folder the commit does not have.
let pathless = FakeGitHub()
pathless.answer("\(other)/git/matching-refs/heads/main", json: [["ref": "refs/heads/main"]])
pathless.answer("\(other)/commits/heads/main?per_page=1", json: ["sha": commit, "commit": ["tree": ["sha": rootTree]]])
pathless.answer("\(other)/contents/a?ref=\(commit)", status: 404, json: ["message": "Not Found"])
await expect(.pathNotFound("a/b")) {
    _ = try await pathless.scanner.scan(link("https://github.com/o/r/tree/main/a/b")!, builtInNames: [])
}

// MARK: - GitHub's refusals

/// A repository that is not there, or not public, in GitHub's words.
let missing = FakeGitHub()
missing.answer(other, status: 404, json: ["message": "Not Found", "documentation_url": "https://docs.github.com/rest", "status": "404"])
await expect(.repositoryNotFound("o/r", words: "Not Found")) {
    _ = try await missing.scanner.scan(link("https://github.com/o/r")!, builtInNames: [])
}

// The hour's sixty requests spent: when it resets, and GitHub's words.
let limited = FakeGitHub()
let spent = "API rate limit exceeded for 203.0.113.7. (But here's the good news: Authenticated requests get a higher rate limit.)"
limited.answer(other, status: 403, json: ["message": spent], headers: [
    "x-ratelimit-limit": "60", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1795332460",
])
await expect(.rateLimited(resetsAt: Date(timeIntervalSince1970: 1_795_332_460), retryAfter: nil, words: spent)) {
    _ = try await limited.scanner.scan(link("https://github.com/o/r")!, builtInNames: [])
}

/// A secondary limit says how long to wait.
let slowed = FakeGitHub()
slowed.answer(other, status: 429, json: ["message": "You have exceeded a secondary rate limit."], headers: ["retry-after": "60"])
await expect(.rateLimited(resetsAt: nil, retryAfter: 60, words: "You have exceeded a secondary rate limit.")) {
    _ = try await slowed.scanner.scan(link("https://github.com/o/r")!, builtInNames: [])
}

/// raw.githubusercontent.com's own limit.
let rawLimited = FakeGitHub()
rawLimited.answer("\(other)/commits/\(commit)?per_page=1", json: ["sha": commit, "commit": ["tree": ["sha": rootTree]]])
rawLimited.answer("\(other)/git/trees/\(rootTree)?recursive=1", json: ["truncated": false, "tree": [
    ["path": "SKILL.md", "mode": "100644", "type": "blob", "sha": GitHubSkillScanner.blobID(of: skillData), "size": skillData.count],
]])
rawLimited.answer(otherRaw + "SKILL.md", status: 429, text: "429: Too Many Requests")
await expect(.rateLimited(resetsAt: nil, retryAfter: nil, words: "429: Too Many Requests")) {
    _ = try await rawLimited.scanner.scan(link("https://github.com/o/r/blob/\(commit)/SKILL.md")!, builtInNames: [])
}

/// Any other refusal keeps its status and words.
let blocked = FakeGitHub()
blocked.answer(other, status: 451, json: ["message": "Repository access blocked"])
await expect(.refused(status: 451, words: "Repository access blocked")) {
    _ = try await blocked.scanner.scan(link("https://github.com/o/r")!, builtInNames: [])
}

// MARK: - Limits

/// Entries of a skill at the top with `files` more files of `size` bytes each.
func crowded(files: Int, size: Int) -> [GitHubTreeEntry] {
    [GitHubTreeEntry(path: "SKILL.md", kind: .file, sha: "0", size: 10)]
        + (0 ..< files).map { GitHubTreeEntry(path: "ref/\($0).md", kind: .file, sha: "0", size: size) }
        + [GitHubTreeEntry(path: "ref", kind: .folder, sha: "0", size: 0)]
}

let fine = GitHubSkillLayout.layouts(of: crowded(files: 1998, size: 1), topName: "crowd", single: false).layouts[0]
require(fine.candidate(text: skill("crowd", "Many files."), builtInNames: []).problem == nil, "2,000 entries in all import")
let many = GitHubSkillLayout.layouts(of: crowded(files: 1999, size: 1), topName: "crowd", single: false).layouts[0]
require(many.candidate(text: skill("crowd", "Many files."), builtInNames: []).problem == .tooLarge, "2,001 do not")
let heavy = GitHubSkillLayout.layouts(of: crowded(files: 2, size: 16 << 20), topName: "heavy", single: false).layouts[0]
require(heavy.candidate(text: skill("heavy", "Big files."), builtInNames: []).problem == .tooLarge, "over 32 MB does not")
let bulky = [GitHubTreeEntry(path: "SKILL.md", kind: .file, sha: "0", size: (1 << 20) + 1)]
require(GitHubSkillLayout.layouts(of: bulky, topName: "bulky", single: false).layouts[0].candidate(text: nil, builtInNames: []).problem == .tooLarge, "a SKILL.md over 1 MB")
require(GitHubSkillLayout.layouts(of: [GitHubTreeEntry(path: "SKILL.md", kind: .file, sha: "0", size: 4)], topName: "x", single: false)
    .layouts[0].candidate(text: nil, builtInNames: []).problem == .notText, "a SKILL.md that is not UTF-8")

/// A skill inside another is a skill of its own, and the outer one's files.
let nesting = GitHubSkillLayout.layouts(of: [
    GitHubTreeEntry(path: "sub/x.md", kind: .file, sha: "0", size: 1),
    GitHubTreeEntry(path: "SKILL.md", kind: .file, sha: "0", size: 1),
    GitHubTreeEntry(path: "sub", kind: .folder, sha: "0", size: 0),
    GitHubTreeEntry(path: "sub/SKILL.md", kind: .file, sha: "0", size: 1),
    GitHubTreeEntry(path: "sub-b/y.md", kind: .file, sha: "0", size: 1),
], topName: "outer", single: false).layouts
require(nesting.map(\.folderName) == ["outer", "sub"], "both skills: \(nesting.map(\.folderName))")
require(nesting[0].files.map(\.path) == ["SKILL.md", "sub-b/y.md", "sub/SKILL.md", "sub/x.md"], "the outer one takes everything")
require(nesting[1].files.map(\.path) == ["SKILL.md", "x.md"] && nesting[1].folders.isEmpty, "the inner one its own, not sub-b's")

let flood = (0 ..< 205).map { GitHubTreeEntry(path: "s\($0)/SKILL.md", kind: .file, sha: "0", size: 1) }
let capped = GitHubSkillLayout.layouts(of: flood, topName: "r", single: false)
require(capped.layouts.count == 200 && capped.omitted == 5, "a scan lists 200 and counts the rest")

print("ok: GitHub skills")
