import ApelinCore
import ApelinGit
import ApelinProject
import ApelinProtocol
import Foundation

/// The git operations on the wire, each on one project and nothing else,
/// and the settings behind them: the commit author and one HTTPS credential
/// per host, offered only to a remote whose host is exactly that one.
public struct GitService: Sendable {
    public let layout: EnvironmentLayout
    let projects: ProjectLocator
    let credentials: any GitCredentialStore
    /// Lets fetch, pull, push and clone-into talk to a remote that is a
    /// local path, for tests against a bare repository on disk. Never set
    /// in the worker: the remotes it accepts are HTTPS ones only.
    var acceptsLocalRemotes = false

    public init(layout: EnvironmentLayout, credentials: any GitCredentialStore = MemoryGitCredentialStore()) {
        self.layout = layout
        self.credentials = credentials
        projects = ProjectLocator(layout: layout)
    }

    public func status(_ request: GitStatusRequest) throws -> GitStatusResponse {
        let repository = try open(request.projectID).repository
        let head = repository.head()
        let entries = try mapped { try repository.status() }
        return GitStatusResponse(
            branch: head.branch,
            head: head.commit,
            entries: entries.map { GitStatusEntry(path: $0.path, index: $0.index, worktree: $0.worktree) },
        )
    }

    public func diff(_ request: GitDiffRequest) throws -> GitDiffResponse {
        let (project, repository) = try open(request.projectID)
        let path = try request.path.map { try projects.checkRelative($0, in: project) }
        return try GitDiffResponse(diff: mapped { try repository.diff(path: path, staged: request.staged) })
    }

    public func stage(_ request: GitStageRequest) throws -> Acknowledged {
        let (project, repository) = try open(request.projectID)
        let paths = try checkedPaths(request.paths, in: project)
        try mapped { try repository.stage(paths) }
        return Acknowledged()
    }

    public func unstage(_ request: GitUnstageRequest) throws -> Acknowledged {
        let (project, repository) = try open(request.projectID)
        let paths = try checkedPaths(request.paths, in: project)
        try mapped { try repository.unstage(paths) }
        return Acknowledged()
    }

    public func commit(_ request: GitCommitRequest) throws -> GitCommitResponse {
        let repository = try open(request.projectID).repository
        let author = try author(name: request.authorName, email: request.authorEmail, repository: repository)
        return try GitCommitResponse(commitID: mapped {
            if request.all == true {
                try repository.stageAll()
            }
            return try repository.commit(message: request.message, author: author)
        })
    }

    /// A repository for a project that has none, on `main`, keeping
    /// Apelin's own files out as a new project's does.
    public func initialize(_ request: GitInitRequest) throws -> GitInitResponse {
        let project = try projects.locate(request.projectID)
        var metadata = stat()
        guard lstat(project.root.appendingPathComponent(".git").path, &metadata) != 0 else {
            throw ApelinError(.conflict, "\(project.name) already has a repository")
        }
        let repository = try mapped {
            let repository = try GitRepository.create(at: project.root, initialBranch: Self.initialBranch)
            try repository.addExcludes(ProjectExcludes.apelinFiles)
            return repository
        }
        return GitInitResponse(branch: repository.head().branch ?? Self.initialBranch)
    }

    /// The branch a repository Apelin makes starts on.
    static let initialBranch = "main"

    /// Validates a clone request before the task is accepted.
    public func checkClone(_ request: GitCloneRequest) throws -> URL {
        try Self.checkRemote(url: request.url, branch: request.branch)
        return try projects.newProjectRoot(named: request.projectName)
    }

    /// The remote and branch every clone takes: an HTTPS URL and a branch.
    static func checkRemote(url: String, branch: String) throws {
        guard GitClone.isAcceptedRemote(url) else {
            throw ApelinError(.badRequest, "Enter an HTTPS link to the repository.")
        }
        guard !branch.isEmpty else { throw ApelinError(.badRequest, "no branch") }
    }

    /// What a resumed clone answers when the clone it repeats had already
    /// ended — its marker cleared — before the host heard the task's final
    /// `state`: the project folder is there, a repository of the request's
    /// URL with its branch checked out, whose `apelin.cloneTask` is this
    /// task's ID. Nil otherwise, and the clone runs as a new one. Only a
    /// resumed task asks, after the worker's start swept every folder a
    /// cut-off clone left, so a repository still there is a complete one;
    /// the task ID tells it from a folder another clone of the same name
    /// and URL made.
    public func finishedClone(_ request: GitCloneRequest, taskID: TaskID) -> JSONValue? {
        guard let root = existingProjectFolder(named: request.projectName),
              let repository = try? GitRepository(at: root),
              repository.localConfigValue(Self.cloneTaskKey) == taskID.rawValue,
              repository.remoteURL() == request.url else { return nil }
        let head = repository.head()
        guard head.branch == request.branch, let commit = head.commit else { return nil }
        return Self.cloneResult(request, commit: commit)
    }

    /// The clone itself, run as a task. With a task ID, the folder it makes
    /// is named in `Environment/clones/<taskID>` until the clone ends, so a
    /// worker that starts after one was cut off knows the folder is its own;
    /// one that ended keeps the task ID as `apelin.cloneTask` in its
    /// `.git/config` and is answered by `finishedClone` if the host resumes
    /// it.
    public func clone(
        _ request: GitCloneRequest,
        into root: URL,
        taskID: TaskID? = nil,
        reporter: TaskReporter,
    ) throws -> JSONValue {
        let marker = try taskID.map { try markClone(root, taskID: $0) }
        defer { marker.map { try? FileManager.default.removeItem(at: $0) } }
        reporter.stage("fetching")
        do {
            let result = try GitClone.shallow(
                url: request.url,
                branch: request.branch,
                into: root,
                credentials: credentialLookup,
                progress: Self.fetchProgress(reporter),
            )
            // Written while the marker is still there: a clone stopped
            // before this is swept, never taken for a finished one.
            if let taskID {
                try GitRepository(at: root).setLocalConfigValue(taskID.rawValue, for: Self.cloneTaskKey)
            }
            return Self.cloneResult(request, commit: result.commit)
        } catch {
            // A failed or stopped clone leaves nothing behind in Projects/.
            try? FileManager.default.removeItem(at: root)
            throw Self.apelinError(error)
        }
    }

    /// Removes what clones cut off by a stop left behind: each marked
    /// folder that is still a repository or empty, then the marker. Run at
    /// worker start, when no clone is running; a clone the host resumes
    /// starts over in a folder that is gone again.
    public func sweepInterruptedClones() {
        let markers = (try? FileManager.default.contentsOfDirectory(
            at: layout.cloneMarkers,
            includingPropertiesForKeys: nil,
        )) ?? []
        for marker in markers {
            defer { try? FileManager.default.removeItem(at: marker) }
            guard let data = FileManager.default.contents(atPath: marker.path),
                  let name = String(data: data, encoding: .utf8),
                  let root = existingProjectFolder(named: name) else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            guard entries.isEmpty || entries.contains(".git") else { continue }
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Clone into a workspace

    /// What Apelin itself keeps in a project folder, none of it the
    /// repository's, so a repository taken into a workspace keeps it out
    /// through `.git/info/exclude`: the description and the icon beside it,
    /// and what every repository Apelin makes keeps out
    /// (`ProjectExcludes.apelinFiles`).
    static let apelinFiles = ["/apelin-project.json", "/apelin-icon.png"] + ProjectExcludes.apelinFiles

    /// Validates a clone-into request before the task is accepted: the
    /// project is an empty workspace's kind, has no repository yet, or only
    /// the untouched one it was made with, and the URL is HTTPS. Answers the
    /// project folder.
    public func checkCloneInto(_ request: GitCloneIntoRequest) throws -> URL {
        let project = try projects.locate(request.projectID)
        guard project.kind == "workspace" else {
            throw ApelinError(
                .badRequest,
                "only a workspace takes a repository, and \(project.name) is \(project.kind.map { "a \($0) project" } ?? "not one")",
            )
        }
        var metadata = stat()
        if lstat(project.root.appendingPathComponent(".git").path, &metadata) == 0 {
            guard let repository = try? GitRepository(at: project.root), repository.isUntouched else {
                throw ApelinError(.conflict, "\(project.name) already has a repository")
            }
        }
        try checkRemoteURL(request.url)
        if let branch = request.branch, !GitRepository.isValidBranchName(branch) {
            throw ApelinError(.badRequest, "\(branch.debugDescription) is not a branch name")
        }
        return project.root
    }

    /// The clone into the workspace, run as a task: `progress` while it
    /// fetches, then `{branch, commit}`. A failure leaves the folder as it
    /// was.
    public func cloneInto(_ request: GitCloneIntoRequest, into root: URL, reporter: TaskReporter) throws -> JSONValue {
        reporter.stage("fetching")
        let result = try mapped {
            try GitClone.into(
                root,
                url: request.url,
                branch: request.branch,
                excluding: Self.apelinFiles,
                credentials: credentialLookup,
                progress: Self.fetchProgress(reporter),
            )
        }
        return .object(["branch": .string(result.branch), "commit": .string(result.commit)])
    }

    // MARK: Fetch, pull and push

    /// A project's repository and the remote a fetch, pull or push talks to,
    /// whose URL was checked when the request was accepted.
    public struct RemoteTarget: Sendable {
        let repository: GitRepository
        let remote: String
        let branch: String?
        /// A forced push's: what it may overwrite, and with what.
        var lease: GitLease?
    }

    /// Validates a fetch before the task is accepted: a branch to compare
    /// must be a local one with a commit.
    public func prepareFetch(_ request: GitFetchRequest) throws -> RemoteTarget {
        let repository = try open(request.projectID).repository
        if let branch = request.branch {
            guard GitRepository.isValidBranchName(branch) else {
                throw ApelinError(.badRequest, "\(branch.debugDescription) is not a branch name")
            }
            guard repository.commit(ofBranch: branch) != nil else {
                throw ApelinError(.notFound, "There is no branch \(branch) with a commit to compare.")
            }
        }
        return try remoteTarget(repository, remote: request.remote ?? "origin", branch: request.branch)
    }

    /// Validates a pull before the task is accepted. With no remote named,
    /// it is the checked-out branch's own (`branch.<name>.remote`), else
    /// `origin`.
    public func preparePull(_ request: GitPullRequest) throws -> RemoteTarget {
        let repository = try open(request.projectID).repository
        guard let branch = repository.head().branch else {
            throw ApelinError(.badRequest, "The repository is not on a branch. Switch to a branch and try again.")
        }
        let remote = request.remote ?? repository.localConfigValue("branch.\(branch).remote") ?? "origin"
        return try remoteTarget(repository, remote: remote, branch: branch)
    }

    /// Validates a push before the task is accepted. With a URL, the remote
    /// is added first when the repository does not have it, and taken away
    /// again when the push does not pass. A lease is checked here as well as
    /// when it pushes: its commits are full IDs, and the local branch is at
    /// the one it names.
    public func preparePush(_ request: GitPushRequest) throws -> RemoteTarget {
        let repository = try open(request.projectID).repository
        guard let branch = request.branch ?? repository.head().branch else {
            throw ApelinError(.badRequest, "The repository is not on a branch. Switch to a branch and try again.")
        }
        guard GitRepository.isValidBranchName(branch) else {
            throw ApelinError(.badRequest, "\(branch.debugDescription) is not a branch name")
        }
        if let lease = request.forceWithLease {
            if let problem = lease.problem {
                throw ApelinError(.badRequest, problem)
            }
            let commit = repository.commit(ofBranch: branch)
            if let approved = lease.localCommit, let commit, approved != commit {
                throw ApelinError(
                    .conflict,
                    "\(branch) is at \(commit) now, not \(approved), the commit this push was to send: nothing was pushed.",
                    reason: .localChanged,
                )
            }
        }
        let remote = request.remote ?? "origin"
        let added = try request.url.map { try addRemote(remote, url: $0, to: repository) } ?? false
        do {
            // A push goes to `pushurl` when the remote has one, and through
            // any `pushInsteadOf`: what libgit2 will push to must pass too.
            if let pushURL = repository.remotePushURL(remote) {
                try checkRemoteURL(pushURL)
            }
            var target = try remoteTarget(repository, remote: remote, branch: branch)
            target.lease = request.forceWithLease.map {
                GitLease(expectedCommit: $0.expectedCommit, localCommit: $0.localCommit)
            }
            return target
        } catch {
            if added {
                try? repository.removeRemote(remote)
            }
            throw error
        }
    }

    /// Adds `remote` fetching from `url` when the repository does not have
    /// it, as `git remote add` does; one it has must have that URL already,
    /// so a push never moves a remote somewhere else. Answers whether it
    /// added it.
    private func addRemote(_ remote: String, url: String, to repository: GitRepository) throws -> Bool {
        try checkRemoteURL(url)
        if let existing = repository.remoteURL(remote) {
            guard existing == url else {
                // Never quoted when it could carry a credential.
                let shown = GitClone.isAcceptedRemote(existing) ? " \(existing)" : " another URL"
                throw ApelinError(
                    .conflict,
                    "\(remote) already points to\(shown). Push to it without a URL, or name another remote.",
                    reason: .remoteURLDiffers,
                )
            }
            return false
        }
        try mapped { try repository.addRemote(remote, url: url) }
        return true
    }

    /// `progress` while it fetches, then `{remote, updated: [{ref, from?,
    /// to}], comparison?}`, the comparison for a fetch that names a branch.
    public func fetch(_ target: RemoteTarget, reporter: TaskReporter) throws -> JSONValue {
        reporter.stage("fetching")
        let result = try mapped {
            try target.repository.fetch(
                remote: target.remote,
                comparing: target.branch,
                credentials: credentialLookup,
                progress: Self.fetchProgress(reporter),
            )
        }
        let updated: [JSONValue] = result.updated.map { update in
            var entry: [String: JSONValue] = ["ref": .string(update.ref), "to": .string(update.to)]
            if let from = update.from {
                entry["from"] = .string(from)
            }
            return .object(entry)
        }
        var payload: [String: JSONValue] = ["remote": .string(result.remote), "updated": .array(updated)]
        if let compared = result.comparison {
            // Shown on an approval card: only an address Apelin pushes to,
            // which carries no credential.
            let pushURL = target.repository.remotePushURL(target.remote).flatMap { url in
                (try? checkRemoteURL(url)) == nil ? nil : url
            }
            let comparison = GitBranchComparison(
                branch: compared.branch,
                local: compared.local,
                localSubject: compared.localSubject,
                remote: compared.remote,
                pushURL: pushURL,
                remoteOnly: compared.remoteOnly.map { GitCommitSummary(commit: $0.commit, subject: $0.subject) },
                remoteOnlyCount: compared.remoteOnlyCount,
            )
            payload["comparison"] = try? JSONValue(encoding: comparison)
        }
        return .object(payload)
    }

    /// `progress` while it fetches, then `{branch, from, to, upToDate}`;
    /// `from` is absent for a branch that had no commit.
    public func pull(_ target: RemoteTarget, reporter: TaskReporter) throws -> JSONValue {
        reporter.stage("fetching")
        let result = try mapped {
            try target.repository.pull(
                remote: target.remote,
                credentials: credentialLookup,
                progress: Self.fetchProgress(reporter),
            )
        }
        var payload: [String: JSONValue] = [
            "branch": .string(result.branch),
            "to": .string(result.to),
            "upToDate": .bool(result.upToDate),
        ]
        if let from = result.from {
            payload["from"] = .string(from)
        }
        return .object(payload)
    }

    /// `progress` {stage: "pushing"} while it uploads, then `{remote, branch,
    /// commit, from?, forced?}`. A forced push first records its lease's
    /// outcome as a `lease` event, held or not, once the remote has said
    /// what its branch is at.
    public func push(_ target: RemoteTarget, reporter: TaskReporter) throws -> JSONValue {
        try reporter.checkCancelled()
        reporter.stage("pushing")
        let throttle = ProgressThrottle()
        let result = try mapped {
            try target.repository.push(
                remote: target.remote,
                branch: target.branch,
                lease: target.lease,
                credentials: credentialLookup,
                remoteCommit: { found in
                    guard let lease = target.lease else { return }
                    reporter.emit("lease", Self.leaseEvent(lease, branch: target.branch, found: found))
                },
            ) { progress in
                if throttle.shouldEmit(force: progress.total > 0 && progress.current == progress.total) {
                    reporter.progress(
                        "pushing",
                        completed: Int64(progress.current),
                        total: Int64(progress.total),
                        detail: "\(progress.bytes) bytes",
                    )
                }
                return !reporter.isCancelled
            }
        }
        var payload: [String: JSONValue] = [
            "remote": .string(result.remote),
            "branch": .string(result.branch),
            "commit": .string(result.commit),
        ]
        payload["from"] = result.from.map { .string($0) }
        if result.forced {
            payload["forced"] = .bool(true)
        }
        return .object(payload)
    }

    /// `lease` {branch, expectedCommit, localCommit?, found?, held}: what a
    /// forced push was to replace, what the remote had, and whether it went
    /// on.
    static func leaseEvent(_ lease: GitLease, branch: String?, found: String?) -> JSONValue {
        var event: [String: JSONValue] = [
            "expectedCommit": .string(lease.expectedCommit),
            "held": .bool(found == lease.expectedCommit),
        ]
        event["branch"] = branch.map { .string($0) }
        event["localCommit"] = lease.localCommit.map { .string($0) }
        event["found"] = found.map { .string($0) }
        return .object(event)
    }

    // MARK: Settings and credentials

    /// What `Settings/git.json` holds; a field left out is not set.
    private struct SettingsFile: Codable {
        var authorName: String?
        var authorEmail: String?
    }

    /// The author from `Settings/git.json` and the saved credentials, host
    /// and user name only.
    public func settings() throws -> GitSettingsResponse {
        let file = (try? JSONFile.read(SettingsFile.self, at: layout.gitSettings)) ?? nil
        let saved = try credentials.summaries().sorted { $0.host < $1.host }
        return GitSettingsResponse(authorName: file?.authorName, authorEmail: file?.authorEmail, credentials: saved)
    }

    /// Writes `Settings/git.json` in one rename; a nil or empty field is
    /// left out.
    public func setAuthor(_ request: GitAuthorSetRequest) throws -> Acknowledged {
        let file = try SettingsFile(
            authorName: Self.authorField(request.authorName, "authorName"),
            authorEmail: Self.authorField(request.authorEmail, "authorEmail"),
        )
        try layout.make(layout.settings)
        do {
            try JSONFile.write(file, to: layout.gitSettings)
        } catch {
            throw ApelinError(.unavailable, "cannot write Settings/git.json: \(error)")
        }
        return Acknowledged()
    }

    /// Saves, or replaces, the credential for one host. No message here
    /// quotes the token.
    public func setCredential(_ request: GitCredentialSetRequest) throws -> Acknowledged {
        let host = try Self.credentialHost(request.host)
        let username = request.username
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty,
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !username.contains(":")
        else {
            // HTTPS basic authentication ends the user name at the first colon.
            throw ApelinError(.badRequest, "Enter a username. It cannot contain a colon or control characters.")
        }
        guard !request.token.isEmpty else { throw ApelinError(.badRequest, "Enter a token.") }
        guard request.token.utf8.count <= 4096 else {
            throw ApelinError(.badRequest, "The token is too long. Check the token and try again.")
        }
        guard !request.token.contains(where: \.isNewline), !request.token.utf8.contains(0) else {
            throw ApelinError(
                .badRequest,
                "The token contains a line break or an invalid character. Paste the token again.",
            )
        }
        try credentials.save(GitCredential(username: username, token: request.token), forHost: host)
        return Acknowledged()
    }

    /// Removes the credential for one host; a host with none is no error.
    public func removeCredential(_ request: GitCredentialRemoveRequest) throws -> Acknowledged {
        try credentials.remove(host: Self.credentialHost(request.host))
        return Acknowledged()
    }

    /// A host as a credential is saved under it, the spelling
    /// `GitCredentialHost.key` gives a remote's URL: a name, lowercased,
    /// optionally `:port` with a port number (written without leading
    /// zeros). No scheme, path, user, whitespace or NUL.
    static func credentialHost(_ raw: String) throws -> String {
        let host = raw.lowercased()
        let refusal = ApelinError(
            .badRequest,
            "\(raw.debugDescription) is not a valid host. Enter a name such as github.com, adding :port if the URL has one.",
        )
        guard !host.isEmpty, !host.contains("/"), !host.contains("@"), !host.utf8.contains(0),
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
        else { throw refusal }
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let name = parts.first, !name.isEmpty else { throw refusal }
        guard parts.count == 2 else { return host }
        guard let digits = parts.last, !digits.isEmpty, digits.allSatisfy({ ("0" ... "9").contains($0) }),
              let port = Int(digits), (1 ... 65535).contains(port)
        else {
            throw ApelinError(
                .badRequest,
                "The port in \(raw.debugDescription) is not valid. Check the port number and try again.",
            )
        }
        return "\(name):\(port)"
    }

    /// One field of the author: trimmed, nil when empty, and refused when it
    /// is something a commit signature cannot hold.
    private static func authorField(_ value: String?, _ name: String) throws -> String? {
        let limit = 256
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.count <= limit, !value.contains("<"), !value.contains(">"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ApelinError(
                .badRequest,
                "\(name) is longer than \(limit) characters or has <, > or a control character",
            )
        }
        return value
    }

    // MARK: Helpers

    /// The credential to offer a remote: the one saved for exactly the host
    /// (and port) of the URL libgit2 connects to, for HTTPS only.
    var credentialLookup: GitCredentialLookup {
        let store = credentials
        return { url in
            guard let host = GitCredentialHost.key(of: url) else { return nil }
            return try? store.credential(forHost: host)
        }
    }

    /// Progress events for a fetch, a few a second and the last one; stops
    /// the fetch once the task is cancelled.
    static func fetchProgress(_ reporter: TaskReporter) -> (GitCloneProgress) -> Bool {
        let throttle = ProgressThrottle()
        return { progress in
            if throttle.shouldEmit(
                force: progress.totalObjects > 0 && progress.indexedObjects == progress.totalObjects,
            ) {
                reporter.progress(
                    "fetching",
                    completed: Int64(progress.indexedObjects),
                    total: Int64(progress.totalObjects),
                    detail: "\(progress.receivedBytes) bytes",
                )
            }
            return !reporter.isCancelled
        }
    }

    /// The URLs a remote operation talks to: HTTPS, and, for tests only, a
    /// local path.
    private func checkRemoteURL(_ url: String) throws {
        if acceptsLocalRemotes, url.hasPrefix("/") {
            return
        }
        guard GitClone.isAcceptedRemote(url) else {
            throw ApelinError(.badRequest, "Apelin supports only HTTPS remotes. Use an HTTPS remote URL.")
        }
    }

    private func remoteTarget(_ repository: GitRepository, remote: String, branch: String?) throws -> RemoteTarget {
        guard let url = repository.remoteURL(remote) else {
            throw ApelinError(.notFound, "no remote \(remote.debugDescription)", reason: .noSuchRemote)
        }
        try checkRemoteURL(url)
        return RemoteTarget(repository: repository, remote: remote, branch: branch)
    }

    /// The configuration key a finished clone keeps its task ID under.
    static let cloneTaskKey = "apelin.cloneTask"

    /// `Projects/<name>` when `name` is a valid project name and that entry
    /// is a real folder, not a link; nil otherwise. What a resumed clone and
    /// the sweep of cut-off ones both act on.
    private func existingProjectFolder(named name: String) -> URL? {
        guard ProjectName.validate(name) == nil, let projects = projects.canonicalProjects() else { return nil }
        let root = URL(fileURLWithPath: projects, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return nil }
        return root
    }

    static func cloneResult(_ request: GitCloneRequest, commit: String) -> JSONValue {
        .object([
            "projectName": .string(request.projectName),
            "branch": .string(request.branch),
            "commit": .string(commit),
        ])
    }

    /// Writes the marker naming the folder a clone makes; a clone that
    /// cannot mark its folder does not start.
    private func markClone(_ root: URL, taskID: TaskID) throws -> URL {
        try layout.make(layout.cloneMarkers)
        guard CanonicalPath.isPlainRelative(taskID.rawValue), !taskID.rawValue.contains("/") else {
            throw ApelinError(.badRequest, "not a task ID")
        }
        let marker = layout.cloneMarkers.appendingPathComponent(taskID.rawValue)
        do {
            try Data(root.lastPathComponent.utf8).write(to: marker, options: .atomic)
        } catch {
            throw ApelinError(.unavailable, "cannot mark the clone: \(error)")
        }
        return marker
    }

    private func open(_ projectID: String) throws -> (project: ProjectLocator.Project, repository: GitRepository) {
        let project = try projects.locate(projectID)
        let repository: GitRepository
        do {
            repository = try GitRepository(at: project.root)
        } catch let error as GitError where error.kind == .notFound {
            throw ApelinError(.notFound, "project \(project.name) is not a git repository", reason: .notARepository)
        } catch {
            throw Self.apelinError(error)
        }
        keepApelinFilesOut(of: repository, in: project)
        return (project, repository)
    }

    /// A repository made before every one Apelin makes kept its own files
    /// out (`ProjectExcludes.apelinFiles`) is given them once the agent has
    /// saved an attachment in the project, before anything reads the work
    /// tree, so the chat's files are never a change to show or commit.
    /// What is tracked stays tracked; a failure leaves it for the next call.
    private func keepApelinFilesOut(of repository: GitRepository, in project: ProjectLocator.Project) {
        var metadata = stat()
        guard lstat(project.root.appendingPathComponent("Attachments").path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else { return }
        try? repository.addExcludes(ProjectExcludes.apelinFiles)
    }

    private func checkedPaths(_ paths: [String], in project: ProjectLocator.Project) throws -> [String] {
        guard !paths.isEmpty else { throw ApelinError(.badRequest, "no paths") }
        return try paths.map { try projects.checkRelative($0, in: project) }
    }

    /// The request's author, else the settings file's, else the repository
    /// configuration's `user.name` / `user.email`.
    func author(name: String?, email: String?, repository: GitRepository) throws -> GitSignature {
        let settings = (try? JSONFile.read(SettingsFile.self, at: layout.gitSettings)) ?? nil
        let configured = repository.configuredSignature()
        let name = [name, settings?.authorName, configured?.name].compactMap(\.self).first { !$0.isEmpty }
        let email = [email, settings?.authorEmail, configured?.email].compactMap(\.self).first { !$0.isEmpty }
        guard let name, let email else {
            throw ApelinError(
                .badRequest,
                "Set an author name and email in Settings ▸ Git, then try again.",
            )
        }
        return GitSignature(name: name, email: email)
    }

    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw Self.apelinError(error)
        }
    }

    /// `body`, its failure as an ApelinError.
    static func mapping<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw apelinError(error)
        }
    }

    static func apelinError(_ error: Error) -> ApelinError {
        if let error = error as? ApelinError {
            return error
        }
        guard let error = error as? GitError else { return ApelinError(.internal, String(describing: error)) }
        switch error.kind {
        case .cancelled: return ApelinError(.cancelled, error.message)
        case .notFound: return ApelinError(.notFound, error.message)
        case .invalid: return ApelinError(.badRequest, error.message)
        case .conflict: return ApelinError(.conflict, error.message)
        case .notFastForward: return ApelinError(.conflict, error.message, reason: .notFastForward)
        case .rejected: return ApelinError(.conflict, error.message, reason: .rejected)
        case .remoteChanged: return ApelinError(.conflict, error.message, reason: .remoteChanged)
        case .localChanged: return ApelinError(.conflict, error.message, reason: .localChanged)
        case .authenticationFailed: return ApelinError(.denied, error.message, reason: .authenticationRequired)
        case .failed: return ApelinError(.internal, error.message)
        }
    }
}

/// What a failed remote operation's error names beyond its code, for a
/// caller that acts on it (the agent asks for a credential, or pulls before
/// it pushes again). A task carries it in its final `state` as `reason`.
/// `authenticationRequired` is ApelinProtocol's, which GitHub's API answers
/// with too.
extension ApelinError.Reason {
    /// `conflict`: the remote refused a push.
    static let rejected = Self(rawValue: "rejected")
    /// `conflict`: a pull cannot fast-forward the branch, which has diverged.
    static let notFastForward = Self(rawValue: "notFastForward")
}
