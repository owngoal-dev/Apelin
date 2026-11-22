import ApelinCore
import Foundation

/// Where a link points once its ref is one commit: every file of a scan and
/// of its import comes from that commit.
struct GitHubSkillPlace: Equatable, Sendable {
    let owner: String
    let repository: String
    /// The branch, tag or commit the link named, or the default branch.
    let ref: String
    /// The commit's full SHA.
    let commit: String
    /// The folder in the repository, `/`-separated, empty for its top.
    let path: String
    /// A link to one `SKILL.md`: only the skill of that folder is read.
    let single: Bool

    var fullName: String {
        owner + "/" + repository
    }

    /// The link named the commit itself, by its ID or the start of it.
    var refIsCommit: Bool {
        ref.count >= 7 && ref.allSatisfy(\.isHexDigit) && commit.hasPrefix(ref.lowercased())
    }

    /// The name of the folder at `path`: its last word, or the repository's
    /// at the top, as a clone would name it.
    var folderName: String {
        path.split(separator: "/").last.map(String.init) ?? repository
    }
}

/// One entry of a Git tree as GitHub's API lists it (`GET …/git/trees`), its
/// path relative to the folder the tree was read at.
struct GitHubTreeEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file
        /// A symbolic link (mode `120000`), whose target is its text.
        case link
        case folder
        /// A submodule (a `commit` entry): another repository.
        case submodule
    }

    let path: String
    let kind: Kind
    /// The object's SHA-1, a file's Git blob ID.
    let sha: String
    let size: Int
}

/// A folder of the repository with a `SKILL.md`, and what importing it
/// would copy. What `SkillFolder` leaves behind is left here too, so the
/// staged copy is what it would take: hidden entries, links and submodules.
struct GitHubSkillCandidate: Equatable, Sendable {
    struct File: Equatable, Sendable {
        /// Relative to the skill's folder.
        let path: String
        let sha: String
        let size: Int
    }

    /// Why it cannot be imported: each would leave it out of every chat,
    /// silently or as one of Settings ▸ Skills' problems.
    enum Problem: Equatable, Sendable {
        /// The `SKILL.md` is a link, or not UTF-8 text.
        case notText
        /// Over `SkillFolder`'s limits, or a `SKILL.md` over 1 MB.
        case tooLarge
        /// No name kwwk takes.
        case invalidName
        /// No description, or one written as a YAML block kwwk does not read.
        case noDescription
        /// A description over kwwk's 1,024 characters.
        case longDescription
        /// `disable-model-invocation: true`: for typing as a command, which
        /// Apelin's chats do not take, so its catalogue leaves it out.
        case userInvokedOnly
        /// A skill built into Apelin has the name.
        case builtIn
    }

    static let maximumInstructionsBytes = 1 << 20

    /// The folder in the repository, `/`-separated, empty for its top.
    let folder: String
    /// The name it would be offered under: the frontmatter's, else the
    /// folder's. The skills folder keeps it under this name, so kwwk finds
    /// the folder named for the skill.
    let name: String
    let description: String
    /// The `SKILL.md` as it is, for the preview; empty when it does not read.
    let instructions: String
    let files: [File]
    /// Folders below the skill's own, relative to it, every one made.
    let folders: [String]
    /// Hidden entries, links and submodules, relative to the skill's folder.
    let leftBehind: [String]
    let problem: Problem?

    /// What `SkillFolder` counts against its 2,000.
    var entries: Int {
        files.count + folders.count
    }

    var bytes: Int {
        files.reduce(0) { $0 + $1.size }
    }
}

/// A folder's skills before their `SKILL.md`s are read: what each would
/// copy and leave behind.
struct GitHubSkillLayout: Equatable, Sendable {
    let folder: String
    let folderName: String
    /// The `SKILL.md`'s entry; a link when it is one.
    let instructions: GitHubTreeEntry
    let files: [GitHubSkillCandidate.File]
    let folders: [String]
    let leftBehind: [String]

    /// The most a scan reads; the rest are counted, not listed.
    static let maximumCandidates = 200

    /// Every folder at or below the tree's top that holds a `SKILL.md`, in
    /// path order — only the top one for a `single` link. A skill's files
    /// are everything below its folder, other skills' folders included,
    /// as `SkillFolder` copies a folder; one under a hidden folder is still
    /// found (`.claude/skills/…`), its own hidden entries still stay.
    static func layouts(
        of entries: [GitHubTreeEntry],
        topName: String,
        single: Bool,
    ) -> (layouts: [GitHubSkillLayout], omitted: Int) {
        let sorted = entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        let found = sorted.filter { entry in
            guard entry.kind == .file || entry.kind == .link else { return false }
            return single
                ? entry.path == GitHubSkillLink.skillFileName
                : entry.path.split(separator: "/").last.map(String.init) == GitHubSkillLink.skillFileName
        }
        let layouts = found.prefix(maximumCandidates).map { instructions in
            let folder = String(instructions.path.dropLast(GitHubSkillLink.skillFileName.count + 1))
            return layout(of: folder, instructions: instructions, in: sorted, topName: topName)
        }
        return (Array(layouts), found.count - layouts.count)
    }

    /// `sorted` is the tree in the byte order of its paths, where everything
    /// below a folder is one run, found by halving.
    private static func layout(
        of folder: String,
        instructions: GitHubTreeEntry,
        in sorted: [GitHubTreeEntry],
        topName: String,
    ) -> GitHubSkillLayout {
        let prefix = Array((folder.isEmpty ? "" : folder + "/").utf8)
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle].path.utf8.lexicographicallyPrecedes(prefix) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var files: [GitHubSkillCandidate.File] = []
        var folders: [String] = []
        var leftBehind: [String] = []
        var hiddenSeen: Set<String> = []
        for entry in sorted[low...] {
            guard entry.path.utf8.starts(with: prefix) else { break }
            // the prefix ends in "/", so the rest starts on a character
            let relative = String(decoding: entry.path.utf8.dropFirst(prefix.count), as: UTF8.self)
            let words = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if let hidden = words.firstIndex(where: { $0.hasPrefix(".") }) {
                // the hidden entry once, not everything under it
                let place = words[...hidden].joined(separator: "/")
                if hiddenSeen.insert(place).inserted {
                    leftBehind.append(place)
                }
                continue
            }
            switch entry.kind {
            case .file: files.append(.init(path: relative, sha: entry.sha, size: entry.size))
            case .folder: folders.append(relative)
            case .link, .submodule: leftBehind.append(relative)
            }
        }
        let name = folder.split(separator: "/").last.map(String.init) ?? topName
        return GitHubSkillLayout(
            folder: folder,
            folderName: name,
            instructions: instructions,
            files: files,
            folders: folders,
            leftBehind: leftBehind,
        )
    }

    /// The candidate it is once its `SKILL.md` is read (`text`, nil when it
    /// is a link, larger than 1 MB or not UTF-8), judged as kwwk and
    /// `SkillFolder` will judge it.
    func candidate(text: String?, builtInNames: Set<String>) -> GitHubSkillCandidate {
        let manifest = text.map(SkillManifest.init)
        let name = manifest?.name(inFolderNamed: folderName) ?? folderName
        let description = manifest?.description ?? ""
        var problem: GitHubSkillCandidate.Problem?
        if manifest == nil || instructions.kind != .file {
            problem = instructions.size > GitHubSkillCandidate.maximumInstructionsBytes ? .tooLarge : .notText
        } else if files.count + folders.count > SkillFolder.maximumEntries
            || files.reduce(0, { $0 + $1.size }) > SkillFolder.maximumBytes
        {
            problem = .tooLarge
        } else if SkillManifest.nameProblem(name) != nil {
            problem = .invalidName
        } else if manifest?.description == nil || manifest?.describesInBlock == true {
            problem = .noDescription
        } else if description.count > SkillManifest.maximumDescriptionLength {
            problem = .longDescription
        } else if manifest?.disablesModelInvocation == true {
            problem = .userInvokedOnly
        } else if builtInNames.contains(name) {
            problem = .builtIn
        }
        return GitHubSkillCandidate(
            folder: folder,
            name: name,
            description: description,
            instructions: text ?? "",
            files: files,
            folders: folders,
            leftBehind: leftBehind,
            problem: problem,
        )
    }
}

/// What an import does with what the skills folder already holds.
enum GitHubSkillImportPlan {
    /// A skill of the folder, as Settings ▸ Skills lists it: its name, and
    /// its place in the folder.
    struct Existing: Equatable, Sendable {
        let name: String
        let location: String
    }

    /// What one imported name clears first.
    struct Replacement: Equatable, Sendable {
        /// Other places in the folder that hold a skill of the name: kwwk
        /// keeps the first of two skills of one name and drops the other
        /// unsaid, so they go.
        let elsewhere: [String]
        /// Something sits at the name's own place, which `SkillFolder`
        /// replaces.
        let atPlace: Bool
    }

    /// For each name in `names` that the skills folder already has — a
    /// listed skill of that name wherever it sits, or anything at the place
    /// the import would take (`occupied`) — what goes to make room for it.
    static func replacements(
        of names: [String],
        existing: [Existing],
        occupied: (String) -> Bool,
    ) -> [String: Replacement] {
        var plan: [String: Replacement] = [:]
        for name in names {
            let elsewhere = Set(existing.filter { $0.name == name && $0.location != name }.map(\.location)).sorted()
            let atPlace = occupied(name) || existing.contains { $0.location == name }
            if atPlace || !elsewhere.isEmpty {
                plan[name] = Replacement(elsewhere: elsewhere, atPlace: atPlace)
            }
        }
        return plan
    }

    /// The ticked folders after a tap on `folder`: ticked, it is unticked;
    /// unticked, it is ticked and any other of the same name unticked, since
    /// one name takes one place. A candidate that cannot be imported is never
    /// ticked.
    static func toggling(
        _ folder: String,
        in selection: Set<String>,
        candidates: [GitHubSkillCandidate],
    ) -> Set<String> {
        guard let candidate = candidates.first(where: { $0.folder == folder }), candidate.problem == nil else {
            return selection
        }
        var selection = selection
        if selection.remove(folder) == nil {
            for other in candidates where other.name == candidate.name {
                selection.remove(other.folder)
            }
            selection.insert(folder)
        }
        return selection
    }

    /// Ticked when a scan comes back: the one importable skill, when there
    /// is only one; nothing otherwise, so a repository of many skills is
    /// chosen from rather than taken whole.
    static func initialSelection(of candidates: [GitHubSkillCandidate]) -> Set<String> {
        let importable = candidates.filter { $0.problem == nil }
        return importable.count == 1 ? [importable[0].folder] : []
    }

    /// Every importable candidate, the first of each name.
    static func all(of candidates: [GitHubSkillCandidate]) -> Set<String> {
        var names: Set<String> = []
        var selection: Set<String> = []
        for candidate in candidates where candidate.problem == nil && names.insert(candidate.name).inserted {
            selection.insert(candidate.folder)
        }
        return selection
    }
}
