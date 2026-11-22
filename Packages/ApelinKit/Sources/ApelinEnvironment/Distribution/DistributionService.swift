import ApelinCore
import ApelinGit
import ApelinProject
import ApelinProtocol
import Darwin
import Foundation

/// The user's package repository (Operations/Distribution.swift): a GitHub
/// repository of theirs, cloned as a workspace project, which GitHub Actions
/// indexes and GitHub Pages serves. GitHub's API is called with the
/// github.com credential the user signed in with; the clone fetches and
/// pushes with it as any remote does. The link is
/// `Settings/distribution.json`. A project's release builds published as a
/// GitHub Release of a repository the caller names go through here too
/// (`DistributionService+Release.swift`), with the same sign-in.
public struct DistributionService: Sendable {
    let layout: EnvironmentLayout
    let git: GitService
    let credentials: any GitCredentialStore
    /// GitHub's API, a release's uploads and the files read back from one;
    /// a test answers for all three.
    var exchange: GitHubAPI.Exchange = GitHubAPI.live
    var upload: GitHubAPI.Upload = GitHubAPI.liveUpload
    var download: GitHubAPI.Download = GitHubAPI.liveDownload
    /// Where `owner/name` is cloned from and pushed to; a test points it at a
    /// bare repository on disk.
    var remoteURL: @Sendable (String) -> String = { "https://github.com/\($0).git" }

    /// GitHub refuses a file over 100 MB in a push.
    static let maximumPackageBytes = 100 << 20

    public init(layout: EnvironmentLayout, git: GitService, credentials: any GitCredentialStore) {
        self.layout = layout
        self.git = git
        self.credentials = credentials
    }

    var linkFile: URL {
        layout.settings.appendingPathComponent("distribution.json")
    }

    // MARK: The link

    public func list(_ request: DistributionRepositoryListRequest) async throws -> DistributionRepositoryListResponse {
        let account = try? credentials.credential(forHost: GitHubHost.name)
        var response = DistributionRepositoryListResponse(account: account?.username, linked: linked())
        guard request.repositories, let account else { return response }
        let api = try api()
        // one the account can only read could never be published to
        let repositories = try await api.repositories().filter { $0.permissions?.push != false }
        response.repositories = repositories.map {
            DistributionRepositoryCandidate(
                fullName: $0.fullName,
                isPrivate: $0.isPrivate,
                description: $0.description,
                hasPages: $0.hasPages ?? false,
            )
        }
        let listed = await (try? api.organizations()) ?? []
        let owners = repositories.map(\.owner.login)
        var seen = Set([account.username.lowercased()])
        response.organizations = (listed + owners)
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return response
    }

    /// The link while the project holding its clone is still there.
    func linked() -> DistributionRepository? {
        guard let record = (try? JSONFile.read(DistributionRepository.self, at: linkFile)) ?? nil,
              let project = try? git.projects.locate(record.projectID)
        else { return nil }
        var linked = record
        linked.projectName = project.name
        return linked
    }

    public func unlink() throws -> Acknowledged {
        do {
            try FileManager.default.removeItem(at: linkFile)
        } catch CocoaError.fileNoSuchFile {}
        return Acknowledged()
    }

    private func record(_ repository: DistributionRepository) throws {
        try layout.make(layout.settings)
        try JSONFile.write(repository, to: linkFile)
    }

    // MARK: Creating

    /// Checked before the task is accepted: a name GitHub takes that is also
    /// a free project name, and a github.com credential to make it with.
    public func prepareCreate(_ request: DistributionRepositoryCreateRequest) throws -> String {
        let name = request.name.trimmingCharacters(in: .whitespaces)
        guard GitHubName.isRepository(name) else {
            throw ApelinError(
                .badRequest,
                "Use letters, digits, hyphens, underscores and periods for the repository's name, at most 100.",
            )
        }
        if let owner = request.owner, !GitHubName.isLogin(owner) {
            throw ApelinError(.badRequest, "Name the organization by its GitHub login.")
        }
        _ = try git.projects.newProjectRoot(named: name)
        _ = try api()
        return name
    }

    /// Makes the repository on GitHub, then the project with the template,
    /// its first commit and push, then Pages. Once GitHub has the
    /// repository, a failure says that Link finishes the setup: the project
    /// is kept, with the repository as its origin, and a link takes it.
    public func create(
        _ request: DistributionRepositoryCreateRequest,
        name: String,
        reporter: TaskReporter,
    ) async throws -> JSONValue {
        let api = try api()
        reporter.stage("creating")
        let login = try await api.login()
        let organization = request.owner.flatMap { $0.lowercased() == login.lowercased() ? nil : $0 }
        let created = try await api.createRepository(
            name: name,
            description: request.description ?? "Packages for jailbroken iOS, published with Apelin.",
            isPrivate: false,
            organization: organization,
            // Issues for its users; neither a wiki nor a project board.
            features: ["has_issues": true, "has_wiki": false, "has_projects": false],
        )
        do {
            try reporter.checkCancelled()
            reporter.stage("preparing")
            let project = try ProjectStore(dataFolder: layout.data).createEmpty(name: name)
            let root = URL(fileURLWithPath: project.path, isDirectory: true)
            let repository = try GitRepository(at: root)
            try repository.addExcludes(GitService.apelinFiles)
            try repository.addRemote("origin", url: remoteURL(created.fullName))
            let source = Self.sourceURL(owner: created.owner.login, name: created.name)
            let branch = repository.head().branch ?? EmptyRepositoryBranch.name
            _ = try Self.addTemplate(to: root, repository: created.fullName, sourceURL: source, branch: branch)
            try repository.stageAll()
            try repository.commit(message: "Set up the package repository", author: author(repository, login: login))
            try reporter.checkCancelled()
            reporter.stage("pushing")
            _ = try repository.push(remote: "origin", branch: branch, credentials: git.credentialLookup)
            return try await finish(
                api,
                remote: created,
                project: (project.projectID, project.name),
                source: source,
                reporter: reporter,
            )
        } catch {
            var failure = GitService.apelinError(error)
            if failure.code != .cancelled {
                failure.message += " GitHub has the repository \(created.fullName) now: Link Distribution Repository finishes setting it up."
            }
            throw failure
        }
    }

    // MARK: Linking

    /// Checked before the task is accepted.
    public func prepareLink(_ request: DistributionRepositoryLinkRequest) throws {
        let parts = request.fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ GitHubName.isRepository(String($0)) }) else {
            throw ApelinError(.badRequest, "Name the repository as owner/name.")
        }
        _ = try api()
    }

    /// Takes the project already holding the repository, or clones it into a
    /// new one — an empty repository is set up as a new one would be —, adds
    /// the template's files it lacks without overwriting any, commits and
    /// pushes those, then turns on Pages and links it.
    public func link(_ request: DistributionRepositoryLinkRequest, reporter: TaskReporter) async throws -> JSONValue {
        let api = try api()
        reporter.stage("fetching")
        let remote = try await api.repository(request.fullName)
        guard remote.permissions?.push != false else {
            throw ApelinError(.denied, "The signed-in account cannot push to \(remote.fullName).")
        }
        let login = try await api.login()
        let url = remoteURL(remote.fullName)
        let project: (projectID: String, name: String, root: URL)
        if let existing = existingProject(origin: url) {
            project = existing
            // brought up to date first, so its push is a fast-forward; a
            // clone that has diverged says so when it pushes
            if let target = try? git.preparePull(GitPullRequest(projectID: existing.projectID)) {
                _ = try? git.pull(target, reporter: reporter)
            }
        } else {
            let created = try ProjectStore(dataFolder: layout.data).createEmpty(name: freeProjectName(remote.name))
            let root = URL(fileURLWithPath: created.path, isDirectory: true)
            project = (created.projectID, created.name, root)
            do {
                _ = try GitClone.into(
                    root,
                    url: url,
                    excluding: GitService.apelinFiles,
                    credentials: git.credentialLookup,
                    progress: GitService.fetchProgress(reporter),
                )
            } catch let error as GitError where error.kind == .notFound {
                // An empty repository has no branch to check out: it takes
                // the template as a new one does, under its own origin.
                let repository = try GitRepository(at: root)
                try repository.addExcludes(GitService.apelinFiles)
                try repository.addRemote("origin", url: url)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw GitService.apelinError(error)
            }
        }
        try reporter.checkCancelled()
        reporter.stage("preparing")
        let repository = try GitRepository(at: project.root)
        let source = Self.sourceURL(owner: remote.owner.login, name: remote.name)
        let branch = repository.head().branch ?? remote.defaultBranch ?? EmptyRepositoryBranch.name
        let added = try Self.addTemplate(
            to: project.root,
            repository: remote.fullName,
            sourceURL: source,
            branch: branch,
            overwrite: request.overwrite,
        )
        if !added.isEmpty {
            try repository.stage(added)
            try repository.commit(
                message: request.overwrite
                    ? "Update the package repository from Apelin's template"
                    : "Add the package index and its GitHub Pages workflow",
                author: author(repository, login: login),
            )
        }
        try reporter.checkCancelled()
        reporter.stage("pushing")
        if repository.head().commit != nil {
            _ = try GitService.mapping {
                try repository.push(remote: "origin", branch: branch, credentials: git.credentialLookup)
            }
        }
        return try await finish(
            api,
            remote: remote,
            project: (project.projectID, project.name),
            source: source,
            reporter: reporter,
        )
    }

    /// Pages on, from the workflow, then the link written. A Pages refusal
    /// (a private repository on a plan without Pages) is a warning: the
    /// repository is set up either way.
    private func finish(
        _ api: GitHubAPI,
        remote: GitHubAPI.Repository,
        project: (projectID: String, name: String),
        source: String,
        reporter: TaskReporter,
    ) async throws -> JSONValue {
        try reporter.checkCancelled()
        reporter.stage("publishing")
        var warnings: [String] = []
        var sourceURL = source
        do {
            if let site = try await api.enableWorkflowPages(remote.fullName), let address = site.htmlURL {
                sourceURL = address.hasSuffix("/") ? address : address + "/"
            }
        } catch {
            let message = (error as? ApelinError)?.message ?? String(describing: error)
            warnings.append("GitHub Pages could not be turned on (\(message)). Turn it on in the repository's settings, with GitHub Actions as its source.")
            reporter.warning(warnings[warnings.count - 1])
        }
        let linked = DistributionRepository(
            fullName: remote.fullName,
            url: remote.htmlURL,
            sourceURL: sourceURL,
            projectID: project.projectID,
            projectName: project.name,
        )
        try record(linked)
        return try .object([
            "repository": JSONValue(encoding: linked),
            "warnings": .array(warnings.map(JSONValue.string)),
        ])
    }

    // MARK: Helpers

    func api() throws -> GitHubAPI {
        try GitHubAPI.signedIn(credentials, exchange: exchange, upload: upload, download: download)
    }

    /// The commit author Apelin's settings name, else the repository's, else
    /// the GitHub account's no-reply address.
    func author(_ repository: GitRepository, login: String) -> GitSignature {
        (try? git.author(name: nil, email: nil, repository: repository))
            ?? GitSignature(name: login, email: "\(login)@users.noreply.github.com")
    }

    /// The project whose repository's origin is `url`, however it spells
    /// it: case, a trailing `/` or `.git` aside.
    private func existingProject(origin url: String) -> (projectID: String, name: String, root: URL)? {
        let wanted = Self.comparable(url)
        for project in git.projects.all() {
            guard let projectID = project.projectID,
                  let origin = (try? GitRepository(at: project.root))?.remoteURL(),
                  Self.comparable(origin) == wanted
            else { continue }
            return (projectID, project.name, project.root)
        }
        return nil
    }

    static func comparable(_ url: String) -> String {
        var text = url.lowercased()
        while text.hasSuffix("/") {
            text.removeLast()
        }
        if text.hasSuffix(".git") {
            text.removeLast(4)
        }
        return text
    }

    /// `name`, else `name 2`, `name 3`…, as a project name nothing has yet.
    private func freeProjectName(_ name: String) throws -> String {
        for attempt in 1 ... 50 {
            let candidate = attempt == 1 ? name : "\(name) \(attempt)"
            if (try? git.projects.newProjectRoot(named: candidate)) != nil {
                return candidate
            }
        }
        throw ApelinError(.conflict, "There is no free project name for \(name).")
    }

    /// The template's files the project does not have, written without
    /// following a link and never over a file; answers the paths written.
    /// Writes each template file the repository lacks, and with `overwrite`
    /// replaces a maintained one whose bytes differ, by a rename over it
    /// from beside it, never through a link. Answers the paths it wrote.
    static func addTemplate(
        to root: URL,
        repository: String,
        sourceURL: String,
        branch: String,
        overwrite: Bool = false,
    ) throws -> [String] {
        var written: [String] = []
        for file in DistributionTemplate.files(repository: repository, sourceURL: sourceURL, branch: branch) {
            let parts = file.path.split(separator: "/").map(String.init)
            var folder = root
            for part in parts.dropLast() {
                folder.appendPathComponent(part, isDirectory: true)
                var metadata = stat()
                if lstat(folder.path, &metadata) != 0 {
                    guard mkdir(folder.path, 0o755) == 0 else {
                        throw ApelinError(.internal, "could not make \(part)/: \(String(cString: strerror(errno)))")
                    }
                } else if metadata.st_mode & S_IFMT != S_IFDIR {
                    throw ApelinError(.conflict, "\(part) is in the way of the template's \(file.path).")
                }
            }
            let path = root.appendingPathComponent(file.path).path
            let mode: mode_t = file.executable ? 0o755 : 0o644
            var metadata = stat()
            if lstat(path, &metadata) == 0 {
                guard overwrite, DistributionTemplate.maintained.contains(file.path) else { continue }
                guard metadata.st_mode & S_IFMT == S_IFREG else {
                    throw ApelinError(.conflict, "\(file.path) is not a regular file, so it was not replaced.")
                }
                if FileManager.default.contents(atPath: path) == file.contents {
                    continue
                }
                let temporary = folder.appendingPathComponent(".\(parts.last ?? "file").apelin-\(UUID().uuidString)").path
                try writeNewFile(file.contents, to: temporary, mode: mode, name: file.path)
                guard rename(temporary, path) == 0 else {
                    let reason = String(cString: strerror(errno))
                    Darwin.unlink(temporary)
                    throw ApelinError(.internal, "could not replace \(file.path): \(reason)")
                }
            } else {
                try writeNewFile(file.contents, to: path, mode: mode, name: file.path)
            }
            written.append(file.path)
        }
        return written
    }

    /// A new file at `path`, made exclusively and never through a link.
    private static func writeNewFile(_ contents: Data, to path: String, mode: mode_t, name: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else {
            throw ApelinError(.internal, "could not write \(name): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: contents)
    }

    /// GitHub Pages' address for a repository: the account's own site for
    /// `<owner>.github.io`, else its folder there.
    static func sourceURL(owner: String, name: String) -> String {
        let host = owner.lowercased() + ".github.io"
        return name.lowercased() == host ? "https://\(host)/" : "https://\(host)/\(name)/"
    }

    /// `<Package>_<Version>_<Architecture>.deb`, the epoch's colon spelled
    /// `%3a` as dpkg-name does; refused when a field holds anything a
    /// Debian field of that kind cannot.
    static func packageFileName(package: String, version: String, architecture: String) throws -> String {
        let name = "\(package)_\(version.replacingOccurrences(of: ":", with: "%3a"))_\(architecture).deb"
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.+-~_%")
        guard !package.isEmpty, !version.isEmpty, !architecture.isEmpty,
              !name.hasPrefix("."), name.count <= 255,
              name.dropLast(4).allSatisfy(allowed.contains)
        else { throw ApelinError(.badRequest, "\(package) \(version) cannot be named as a package file.") }
        return name
    }
}

/// The host a GitHub sign-in is saved under.
enum GitHubHost {
    static let name = "github.com"
}

/// The branch a repository Apelin makes starts on.
enum EmptyRepositoryBranch {
    static let name = "main"
}
