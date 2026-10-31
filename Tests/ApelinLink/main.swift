import Foundation

func require(_ condition: Bool, _ message: String, line: Int = #line) {
    guard condition else { fatalError("Line \(line): \(message)") }
}

func link(_ text: String) -> ApelinLink? {
    URL(string: text).flatMap(ApelinLink.init(url:))
}

// MARK: - Parsing

let session = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
require(link("apelin://conversation/\(session)") == .conversation(session), "A conversation by its session ID")
require(link("APELIN://Conversation/\(session)/") == .conversation(session), "Scheme and kind ignore case; a trailing slash is fine")
require(link("apelin:conversation/\(session)") == .conversation(session), "The kind may be the first path component")
require(link("apelin://conversation/\(session)?from=widget#top") == .conversation(session), "Query and fragment are ignored")
require(link("apelin://project/I3%20Chain%20Tweak") == .project("I3 Chain Tweak"), "A folder name is percent-decoded")
require(link("apelin://project/\(session)") == .project(session), "A project by its projectID")
require(link("apelin://chat?prompt=Hello%20there") == .chat(prompt: "Hello there"), "A prompt for a new General Chat")
require(link("apelin://Chat/?prompt=a%26b%3Dc%2B%0Anext") == .chat(prompt: "a&b=c+\nnext"), "Escaped text, a line break")
require(link("apelin://chat?prompt=%E7%9B%B8%E6%9C%BA&other=1") == .chat(prompt: "相机"), "Other query items are ignored")
require(link("apelin://chat") == .chat(prompt: ""), "No prompt: an empty composer")
require(link("apelin://") == .app, "The bare scheme opens the app")
require(link("apelin:") == .app, "So does the scheme alone")
for unknown in [
    "apelin://conversation", "apelin://conversation/", "apelin://project",
    "apelin://conversation/a/b", "apelin://settings/x", "apelin://chat/\(session)",
    "apelin://conversation/..", "apelin://project/.", "apelin://conversation/a%00b",
    "apelin://conversation/a%2Fb", "apelin://project/" + String(repeating: "x", count: 256),
    "apelin://chat?prompt=a%00b", "apelin://chat?prompt=a%1Bb", "apelin://chat/x?prompt=a",
    "apelin://chat?prompt=" + String(repeating: "x", count: ApelinLink.maximumPromptLength + 1),
] {
    require(link(unknown) == .unknown, "Unknown or malformed: \(unknown)")
}

for other in ["https://example.com/conversation/x", "file:///tmp/a.apeproj", "ighostvt://new"] {
    require(link(other) == nil, "Not an apelin link: \(other)")
}

// MARK: - Building, and reading back what was built

require(ApelinLink.conversation(session).url.absoluteString == "apelin://conversation/\(session)", "The documented form")
require(ApelinLink.project("I3 Chain Tweak").url.absoluteString == "apelin://project/I3%20Chain%20Tweak", "Spaces escaped")
require(ApelinLink.app.url.absoluteString == "apelin://", "The app")
require(ApelinLink.chat(prompt: "Fix the build").url.absoluteString == "apelin://chat?prompt=Fix%20the%20build", "A prompt")
require(ApelinLink.chat(prompt: "").url.absoluteString == "apelin://chat", "No prompt")
for prompt in ["a&b=c+d", "line one\nline two\ttab", "100% 相机 #tag ?q", ""] {
    require(ApelinLink(url: ApelinLink.chat(prompt: prompt).url) == .chat(prompt: prompt), "Round trip: \(prompt)")
}

for name in ["I3 Chain Tweak", "相机翻译", "a?b#c;d", "100% done", session] {
    for built in [ApelinLink.conversation(name), .project(name)] {
        require(ApelinLink(url: built.url) == built, "Round trip: \(name)")
    }
}

// MARK: - Open in Apelin for a repository

let repository = "https://github.com/owner/repo"
let escapedRepository = "https%3A%2F%2Fgithub.com%2Fowner%2Frepo"
require(link("apelin://import?url=\(escapedRepository)") == .importRepository(url: repository, branch: nil),
        "An escaped address, the default branch")
require(link("apelin://import?url=\(repository)") == .importRepository(url: repository, branch: nil),
        "An address left unescaped reads the same")
require(link("apelin://Import/?url=\(escapedRepository)&branch=release%2F1.0") ==
    .importRepository(url: repository, branch: "release/1.0"), "A branch with a slash")
require(link("apelin:import?url=\(escapedRepository)&branch=") == .importRepository(url: repository, branch: nil),
        "An empty branch is the default one")
require(link("apelin://import?prompt=Run%20it&url=\(escapedRepository)&token=x&command=rm") ==
    .importRepository(url: repository, branch: nil), "A prompt, a token or a command beside it is ignored")
for address in [
    "https://gitlab.example.com:8443/group/sub/project.git", "https://GitHub.com/Owner/Repo/",
    "https://github.com/owner/%E7%9B%B8%E6%9C%BA", "https://host.example/@scope/name",
    "https://codeberg.org./owner/repo",
] {
    require(ApelinLink.isRepositoryAddress(address), "An address the host clones: \(address)")
    let built = ApelinLink.importRepository(url: address, branch: "main")
    require(ApelinLink(url: built.url) == built, "Round trip: \(address)")
}

require(ApelinLink.importRepository(url: repository, branch: nil).url.absoluteString ==
    "apelin://import?url=https://github.com/owner/repo", "The documented form")
require(ApelinLink(url: ApelinLink.invalidImport.url) == .invalidImport, "An import that names nothing reads back so")

for refused in [
    "http://github.com/owner/repo", "HTTPS://github.com/owner/repo", "ssh://git@github.com/owner/repo", "git@github.com:owner/repo.git",
    "file:///var/mobile/repo", "https://user@github.com/owner/repo", "https://user:token@github.com/owner/repo",
    "https://:token@github.com/owner/repo", "https://github.com/owner/repo?token=x", "https://github.com/owner/repo?",
    "https://github.com/owner/repo#readme", "https://github.com", "https://github.com/", "https://github.com//",
    "https:///owner/repo", "https:/github.com/owner/repo", "https://github.com/owner/../repo",
    "https://github.com/./repo", "https://github.com/owner/repo%0Aevil", "https://github.com/owner/repo%00",
    "https://github.com/owner/%E2%80%AErepo", "https://github.com/owner/re po", "https://github.com/owner/repo\n",
    "https://github.com/owner/相机", "https://github.com/owner/repo%", "https://github.com/owner/repo%G1",
    "https://github.com/owner\\repo", "https://github.com/\"repo\"", "https://github.com/<repo>",
    "https://github.com/" + String(repeating: "a", count: ApelinLink.maximumAddressLength), "",
    // a web page's link reaches only a public name, spelt as it is shown
    "https://[::1]/repo", "https://[fe80::1%25en0]/repo", "https://127.0.0.1/repo", "https://10.0.0.2/repo",
    "https://169.254.169.254/x", "https://0x7f.1/repo", "https://2130706433/repo", "https://localhost/repo",
    "https://localhost:22/repo", "https://gitea/repo", "https://nas.local/repo", "https://git.lan/repo",
    "https://git.home.arpa/repo", "https://git.internal/repo", "https://%00/x", "https://a%2Fb/x",
    "https://github.com%40evil.com/x", "https://git%68ub.com/owner/repo", "https://github.com:99999/owner/repo",
    "https://github.com:0/owner/repo", "https://github.com:/owner/repo", "https://-github.com/owner/repo",
] {
    require(!ApelinLink.isRepositoryAddress(refused), "Not an address to import: \(refused.debugDescription)")
}

for branch in ["main", "release/1.0", "feature/new-ui", "v2", "用户/分支", "a.b", "x@y", "@x"] {
    require(ApelinLink.isBranchName(branch), "A branch git takes: \(branch)")
}

for branch in [
    "", "a..b", "-x", "--upload-pack=sh", "x.lock", "a/b.lock/c", "@{u}", "a@{1}", "@", "HEAD", "/a", "a/",
    "a//b", "a.", ".hidden", "a/.b", "a b", "a~1", "a^", "a:b", "a?", "a*", "a[b", "a\\b", "a\u{7F}",
    "a\u{0}b", "a\u{202E}b", "a\u{200B}b", "a\u{00A0}b", "a\nb", String(repeating: "b", count: ApelinLink.maximumBranchLength + 1),
    // drawn blank, so the sheet would show no branch at all
    "\u{3164}", "\u{2800}", "\u{115F}", "\u{FFA0}", "a\u{FFFE}", "a\u{2060}b", "a\u{E000}",
] {
    require(!ApelinLink.isBranchName(branch), "Not a branch: \(branch.debugDescription)")
}

for invalid in [
    "apelin://import", "apelin://import?branch=main", "apelin://import?url=",
    "apelin://import?url=http%3A%2F%2Fgithub.com%2Fowner%2Frepo",
    "apelin://import?url=https%3A%2F%2Fuser%3Atoken%40github.com%2Fowner%2Frepo",
    "apelin://import?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo%3Ftoken%3Dx",
    "apelin://import?url=\(escapedRepository)&branch=a..b",
    "apelin://import?url=\(escapedRepository)&branch=-x",
    "apelin://import?url=\(escapedRepository)&branch=x.lock",
    "apelin://import?url=\(escapedRepository)&branch=%40%7B",
    "apelin://import?url=\(escapedRepository)&url=https%3A%2F%2Fevil.example%2Frepo",
    "apelin://import?url=\(escapedRepository)&branch=main&branch=evil",
    "apelin://import?url=\(escapedRepository)%0A",
    // escapes that decode to no text are no value, not the default branch
    "apelin://import?url=\(escapedRepository)&branch=%FF",
    "apelin://import?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo%FF",
] {
    require(link(invalid) == .invalidImport, "An import naming nothing Apelin imports: \(invalid)")
}

require(link("apelin://import/x?url=\(escapedRepository)") == .unknown, "An import has no path of its own")
require(link("apelin://import?URL=\(escapedRepository)") == .invalidImport, "Parameter names keep their case")
require(link("apelin://import?url=javascript%3Aalert(1)") == .invalidImport, "Another scheme, however it is spelt")

// MARK: - The import's own decisions

typealias Plan = RepositoryImportPlan
require(Plan.suggestedName(for: "https://github.com/owner/repo.git", taken: []) == "repo", "The name, without .git")
require(Plan.suggestedName(for: "https://github.com/owner/repo/", taken: []) == "repo", "A trailing slash")
require(Plan.suggestedName(for: "https://github.com/owner/.dotfiles", taken: []) == "dotfiles",
        "No leading dot, which a project name may not start with")
require(Plan.suggestedName(for: "https://example.com/owner/.git", taken: []) == "owner", "Else the component before")
require(Plan.suggestedName(for: "https://github.com/owner/%E7%9B%B8%E6%9C%BA", taken: []) == "相机", "Decoded")
require(Plan.suggestedName(for: repository, taken: ["Repo", "repo 2"]) == "repo 3",
        "A name no project has, ignoring case: an existing one is never overwritten")
let long = Plan.suggestedName(for: "https://host/" + String(repeating: "x", count: 300), taken: [])
require(long.utf8.count == Plan.maximumSuggestionLength, "A long name is cut to fit a folder")

let same = [
    "https://github.com/owner/repo", "https://GitHub.com/Owner/Repo.git", "https://github.com/owner/repo/",
    "https://github.com:443/owner/repo", "https://token@github.com/owner/repo.git", "http://github.com/owner/repo",
]
for spelling in same {
    require(Plan.comparable(spelling) == "github.com/owner/repo", "One repository: \(spelling)")
}

require(Plan.comparable("https://github.com/owner/repo2") != Plan.comparable(repository), "Another repository")
require(Plan.comparable("https://gitlab.com/owner/repo") != Plan.comparable(repository), "Another host")
require(Plan.comparable("https://github.com:8443/owner/repo") != Plan.comparable(repository), "Another port")
require(Plan.comparable("not a url") == nil, "No host, nothing to compare")

let config = """
[core]
\trepositoryformatversion = 0
[remote "upstream"]
\turl = https://github.com/other/repo
[remote "origin"]
\turl = https://github.com/owner/repo.git
\tfetch = +refs/heads/*:refs/remotes/origin/*
[branch "main"]
\tremote = origin
"""
require(Plan.origin(inGitConfig: config) == "https://github.com/owner/repo.git", "Origin's url, not another remote's")
require(Plan.origin(inGitConfig: "[Remote \"origin\"]\n  URL = \"https://x/y\"\n") == "https://x/y",
        "Section and key names ignore case; a quoted value")
require(Plan.origin(inGitConfig: "[remote \"Origin\"]\nurl = https://x/y\n") == nil, "A subsection keeps its case")
require(Plan.origin(inGitConfig: "[remote \"origin\"]\nfetch = x\n[core]\nurl = https://x/y\n") == nil,
        "A url outside origin's section is not origin's")

let request = Plan.Request(address: repository, branch: nil)
require(Plan.arrival(of: request, current: nil) == .start, "Nothing open: show it")
require(Plan.arrival(of: request, current: Plan.Request(address: "https://GitHub.com/owner/repo.git", branch: nil))
    == .showCurrent, "The same repository again: the one open, nothing started twice")
require(Plan.arrival(of: request, current: Plan.Request(address: repository, branch: "dev")) == .busy,
        "Another branch is another import")
require(Plan.arrival(of: request, current: Plan.Request(address: "https://github.com/owner/other", branch: nil))
    == .busy, "Another repository waits for the open one")

// MARK: - The snapshot's order and counts

typealias Chat = ChatWidgetSnapshot.Chat
let now = Date()
func chat(_ id: String, _ status: Chat.Status, _ age: TimeInterval) -> (chat: Chat, updated: Date) {
    (Chat(id: id, title: id, project: nil, status: status, approvalTool: status == .waiting ? "apelin_package_install" : nil),
     now.addingTimeInterval(-age))
}

let snapshot = ChatWidgetSnapshot(chats: [
    chat("old-done", .done, 500),
    chat("working-old", .working, 300),
    chat("failed", .failed, 10),
    chat("waiting", .waiting, 400),
    chat("working-new", .working, 20),
    chat("new-done", .done, 1),
])
require(snapshot.chats.map(\.id) == ["waiting", "working-new", "working-old", "new-done", "failed", "old-done"],
        "Waiting first, then working, then the rest, newest first within each")
require(snapshot.totalCount == 6 && snapshot.workingCount == 2 && snapshot.waitingCount == 1, "Counts cover every chat")
require(snapshot.mostUrgent?.id == "waiting", "The one waiting most needs a look")

let activity = snapshot.inProgress
require(activity.chats.map(\.id) == ["waiting", "working-new", "working-old"], "The activity lists only chats in progress")
require(activity.totalCount == 3, "Its count is of chats in progress")
require(ChatWidgetSnapshot(chats: [chat("a", .done, 1)]).inProgress.totalCount == 0, "Nothing in progress, no activity")
require(ChatWidgetSnapshot(chats: [chat("w", .working, 9), chat("v", .working, 1)]).inProgress.mostUrgent?.id == "v",
        "With nothing waiting, the latest working")

let many = ChatWidgetSnapshot(chats: (0 ..< 20).map { chat("c\($0)", .done, TimeInterval($0)) })
require(many.chats.count == ChatWidgetSnapshot.listLimit && many.totalCount == 20, "The list is capped, the count is not")
let busy = ChatWidgetSnapshot(chats: (0 ..< 9).map { chat("w\($0)", .working, TimeInterval($0)) }).inProgress
require(busy.chats.count == ChatWidgetSnapshot.activityLimit && busy.totalCount == 9, "The activity's payload is capped")
let encoded = try JSONEncoder().encode(busy)
require(encoded.count < 4096, "The activity's payload stays within ActivityKit's 4 KB")
try require(JSONDecoder().decode(ChatWidgetSnapshot.self, from: encoded) == busy, "The snapshot round-trips")

print("ok: ApelinLink, RepositoryImportPlan and ChatWidgetSnapshot")
