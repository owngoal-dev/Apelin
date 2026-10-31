import ApelinCore
import ApelinGit
import ApelinProject
import ApelinProtocol
import Darwin
import Foundation

/// A project as a transfer file.
///
/// What travels: the project folder as the user works on it — every file
/// its repository tracks and every untracked one its ignore rules do not
/// leave out (an uncommitted new source file is work, not junk), and the
/// repository's history, so the project goes on where it was. What does not:
/// what the ignore rules name, `.DS_Store`, and in `.git` the hooks, the
/// configuration, submodules, linked worktrees and locks — code and
/// settings that would run on the other device without being seen. A folder
/// with no repository uses the same `.gitignore` rules with an empty index.
/// The required project description always travels. Build outputs live
/// in `Builds/`, outside every project, and never travel.
///
/// On import the project gets a new project ID — the Confirm ledger knows
/// nothing approved under it, and two folders never share one — a `.git`
/// gets a fresh minimal configuration (its HTTPS origin kept), and it is
/// moved into `Projects/<name>/` with `RENAME_EXCL`. Nothing in it runs.
extension TransferService {
    /// `.git` entries that never travel.
    static let repositoryLeftOut: Set<String> = [
        ".git/hooks", ".git/config", ".git/modules", ".git/worktrees", ".git/commondir",
        ".git/gitdir", ".git/fsmonitor--daemon", ".git/fsmonitor--daemon.ipc", ".git/index.lock",
        ".git/HEAD.lock", ".git/config.lock", ".git/shallow.lock",
    ]

    func projectContents(_ project: ProjectLocator.Project, staging: URL, reporter: TaskReporter) throws -> Collected {
        let root = project.root
        let description = try ProjectFiles.read(ProjectStore.projectFileName, in: root)
        let document: JSONDocument
        do {
            document = try StrictJSON.parse(description)
        } catch {
            throw ApelinError(.badRequest, "\(project.name)/\(ProjectStore.projectFileName) does not read: \(error)")
        }
        let digests = (try? ApprovalDigests.compute(document, root: root)).map {
            DescriptionDigests(build: $0.build.digest, packaging: $0.packaging.digest)
        }

        var ignoredCount = 0
        var repository: GitRepository?
        var remote: String?
        var includesRepository = false
        var warnings: [String] = []
        var metadata = stat()
        let gitFolder = root.appendingPathComponent(".git")
        if lstat(gitFolder.path, &metadata) == 0 {
            if metadata.st_mode & S_IFMT == S_IFDIR, let opened = try? GitRepository(at: root) {
                repository = opened
                includesRepository = true
                remote = opened.remoteURL().flatMap { GitClone.isAcceptedRemote($0) ? $0 : nil }
            } else {
                warnings.append("the project's .git is not a repository Apelin can open; it was left out")
            }
        }
        let ignores = try GitIgnoreRules(
            root: root,
            repository: repository,
            scratch: staging.appendingPathComponent("ignore-rules"),
        )
        var nested: [String] = []

        let rules = TransferTree.Rules(
            skip: { path, isDirectory in
                let components = path.split(separator: "/")
                if components.last == ".DS_Store" {
                    return true
                }
                if components.first == ".git" {
                    guard includesRepository else { return true }
                    return Self.repositoryLeftOut.contains(path)
                        || (components.count == 2 && components[1].hasSuffix(".lock"))
                }
                // A repository inside the project is another project's; the
                // import refuses one, so it is not carried.
                if components.dropFirst().contains(where: { $0.lowercased() == ".git" })
                    || (components.count == 1 && path.lowercased() == ".git")
                {
                    nested.append(path)
                    return true
                }
                // Without this file the export could never be imported, even
                // when a new, untracked project ignores all JSON files.
                if path == ProjectStore.projectFileName {
                    return false
                }
                if try ignores.ignores(path, isDirectory: isDirectory) {
                    ignoredCount += 1
                    return true
                }
                return false
            },
            lenient: true,
        )
        let tree = try TransferTree.collect(root, rules: rules, reporter: reporter)
        warnings += nested.map { "left out \($0): a repository inside the project" }
        warnings += tree.leftOut.map { "left out \($0)" }

        let identity = TransferProject(
            projectID: document["projectID"]?.stringValue ?? project.projectID ?? project.name,
            name: project.name,
            templateExtensionID: document["template"]?["extensionID"]?.stringValue,
            templateID: document["template"]?["templateID"]?.stringValue,
            templateVersion: document["template"]?["version"]?.stringValue,
            descriptionDigests: digests,
            toolchainID: project.toolchainID,
            sdkID: project.sdkID,
            includesRepository: includesRepository,
            remoteURL: remote,
            ignoredCount: ignoredCount == 0 ? nil : ignoredCount,
        )
        return Collected(
            manifest: TransferManifest(
                kind: .project,
                id: identity.projectID,
                name: project.name,
                createdBy: "",
                project: identity,
            ),
            tree: tree,
            fileStem: project.name,
            warnings: warnings,
        )
    }

    func inspectProject(_ manifest: TransferManifest, into inspection: inout TransferInspection) {
        guard let project = manifest.project else { return }
        inspection.suggestedName = freeName(for: project.name)
        if inspection.suggestedName != project.name {
            inspection.notes.append(
                "A project named \(project.name) is already here; this one can be added under another name.",
            )
        }
        inspection.notes.append("It gets a new project ID, and nothing in it counts as approved: in Strict mode, its first build and install ask again.")
        if let toolchain = project.toolchainID,
           !ToolchainRegistry.load(layout).toolchains.contains(where: { $0.id == toolchain })
        {
            inspection.notes.append(
                "It builds with a toolchain that is not set up here; its check will say so until you pick another.",
            )
        }
        if let sdkID = project.sdkID, sdk.store.record(sdkID) == nil {
            inspection.notes.append("It builds against an SDK that is not registered here (\(sdkID)).")
        }
        if project.includesRepository {
            inspection.notes.append("Its Git history comes with it; hooks and repository settings do not.")
        }
    }

    /// `name` when no project has it, else `name 2`, `name 3`, ….
    func freeName(for name: String) -> String {
        let base = ProjectName.validate(name) == nil ? name : "Imported Project"
        if !projects.exists(named: base) {
            return base
        }
        for number in 2 ..< 1000 {
            let candidate = "\(base) \(number)"
            if ProjectName.validate(candidate) == nil, !projects.exists(named: candidate) {
                return candidate
            }
        }
        return base + " " + UUID().uuidString.prefix(8).lowercased()
    }

    func importProject(
        _ tree: URL,
        manifest: TransferManifest,
        name: String?,
        reporter: TaskReporter,
    ) throws -> TransferProjectResult {
        reporter.stage("placing")
        guard let project = manifest.project else {
            throw ApelinError(.badRequest, "a project file without its project")
        }

        // Nothing here names a repository but the project's own `.git`.
        let gitFolder = tree.appendingPathComponent(".git")
        var metadata = stat()
        let hasRepository = lstat(gitFolder.path, &metadata) == 0
        if hasRepository, metadata.st_mode & S_IFMT != S_IFDIR {
            throw ApelinError(.badRequest, "the project's .git is not a folder")
        }
        for member in manifest.members {
            let components = member.path.split(separator: "/")
            if components.dropFirst().contains(where: { $0.lowercased() == ".git" })
                || (components.first?.lowercased() == ".git" && components.first != ".git")
            {
                throw ApelinError(.badRequest, "the project carries a repository at \(member.path), inside itself")
            }
        }

        // A new ID, written into the description with nothing else changed,
        // then the description in its written form (ProjectManifestFormat).
        let descriptionURL = tree.appendingPathComponent(ProjectStore.projectFileName)
        guard lstat(descriptionURL.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw ApelinError(.badRequest, "the project has no \(ProjectStore.projectFileName)")
        }
        let original = try Data(contentsOf: descriptionURL)
        let document: JSONDocument
        do {
            document = try StrictJSON.parse(original)
        } catch {
            throw ApelinError(.badRequest, "its \(ProjectStore.projectFileName) does not read: \(error)")
        }
        guard let oldID = document["projectID"]?.stringValue, oldID == project.projectID else {
            throw ApelinError(
                .badRequest,
                "its \(ProjectStore.projectFileName) does not carry the project ID the file names",
            )
        }
        let newID = UUID().uuidString.lowercased()
        guard let replaced = ProjectManifestIdentity.replacing(oldID, with: newID, in: original) else {
            throw ApelinError(
                .badRequest,
                "its project ID appears more than once in \(ProjectStore.projectFileName), so it cannot be given a new one",
            )
        }
        let rewritten = ProjectManifestFormat.formatted(replaced) ?? replaced
        try rewritten.write(to: descriptionURL)
        do {
            _ = try ProjectValidation.load(rewritten)
        } catch {
            reporter.warning("its \(ProjectStore.projectFileName) does not pass the project check: \(error)")
        }

        if hasRepository {
            try settleRepository(at: tree, remote: project.remoteURL, reporter: reporter)
        }
        try reporter.checkCancelled()

        // Into place, never over anything.
        try layout.make(layout.data.projects)
        guard let projectsRoot = projects.canonicalProjects() else {
            throw ApelinError(.unavailable, "no Projects folder")
        }
        chmod(tree.path, 0o755)
        var chosen = name ?? freeName(for: project.name)
        for attempt in 0 ..< 50 {
            if let problem = ProjectName.validate(chosen) {
                throw ApelinError(.badRequest, problem.reason)
            }
            let destination = URL(fileURLWithPath: projectsRoot, isDirectory: true)
                .appendingPathComponent(chosen, isDirectory: true)
            if renamex_np(tree.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                return TransferProjectResult(
                    projectID: newID,
                    name: chosen,
                    path: destination.path,
                    previousProjectID: oldID,
                    includesRepository: hasRepository,
                )
            }
            guard errno == EEXIST, name == nil, attempt < 49 else {
                if errno == EEXIST {
                    throw ApelinError(.conflict, "a project named \(chosen) exists; choose another name")
                }
                throw ArchiveExtractor.posix("move the project into place")
            }
            chosen = freeName(for: project.name)
        }
        throw ApelinError(.conflict, "no free name for \(project.name)")
    }

    /// The repository as git init would leave its configuration, with the
    /// HTTPS origin it came with: nothing the other device configured runs
    /// here. A `.git` that does not open after that is dropped.
    private func settleRepository(at tree: URL, remote: String?, reporter: TaskReporter) throws {
        let git = tree.appendingPathComponent(".git", isDirectory: true)
        for path in Self.repositoryLeftOut {
            try? FileManager.default.removeItem(at: tree.appendingPathComponent(path))
        }
        var config = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n"
        if let remote, GitClone.isAcceptedRemote(remote),
           !remote.contains("\n"), !remote.contains("\""), !remote.contains("\\")
        {
            config += "[remote \"origin\"]\n\turl = \(remote)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
        }
        try Data(config.utf8).write(to: git.appendingPathComponent("config"))
        if (try? GitRepository(at: tree)) == nil {
            try? FileManager.default.removeItem(at: git)
            reporter.warning("its Git history could not be opened here and was left out; the files are all there")
        }
    }
}

extension ProjectLocator {
    /// Whether anything, project or not, is at `Projects/<name>`.
    func exists(named name: String) -> Bool {
        var metadata = stat()
        return lstat(layout.data.projects.appendingPathComponent(name).path, &metadata) == 0
    }
}
