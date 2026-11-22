// The package repository a user publishes to: an APT source in a GitHub
// repository of theirs, served by GitHub Pages and indexed there by the
// workflow Apelin's template brings (after owngoal-dev/owngoal-packages).
// Served by apelin-environment, which holds the github.com credential the
// user signed in with and calls GitHub's API with it; the app's alone, but
// for the packages an agent publishes to the linked repository
// (`DistributionPublishRequest`) or as a GitHub Release of a project's
// repository (`DistributionReleaseRequest`), and the feedback it files on Apelin's own
// repository (`FeedbackSendRequest`), reads and edits there
// (`FeedbackReadRequest`, `FeedbackEditRequest`). Starring that repository
// is the app's alone (`FeedbackStarRequest`).
//
// The repository's clone is a workspace project like any other, so its
// conversation maintains it with the file and git tools; the link is
// `Settings/distribution.json` in the data folder, naming the repository
// and that project.

/// The linked package repository.
public struct DistributionRepository: Codable, Sendable, Equatable, Hashable {
    /// `owner/name`.
    public var fullName: String
    /// Its page on GitHub, `https://github.com/owner/name`.
    public var url: String
    /// The address a package manager adds: the GitHub Pages site.
    public var sourceURL: String
    /// The workspace project holding its clone.
    public var projectID: String
    public var projectName: String

    public init(fullName: String, url: String, sourceURL: String, projectID: String, projectName: String) {
        self.fullName = fullName
        self.url = url
        self.sourceURL = sourceURL
        self.projectID = projectID
        self.projectName = projectName
    }
}

/// One of the signed-in account's own repositories, offered to link.
public struct DistributionRepositoryCandidate: Codable, Sendable, Equatable, Hashable {
    public var fullName: String
    public var isPrivate: Bool
    public var description: String?
    /// Whether it has a GitHub Pages site already.
    public var hasPages: Bool

    public init(fullName: String, isPrivate: Bool, description: String? = nil, hasPages: Bool = false) {
        self.fullName = fullName
        self.isPrivate = isPrivate
        self.description = description
        self.hasPages = hasPages
    }
}

/// The link, and with `repositories` the account's own repositories, which
/// asks GitHub. Without a github.com credential `account` is nil and the
/// list empty.
public struct DistributionRepositoryListRequest: OperationRequest {
    public typealias Response = DistributionRepositoryListResponse
    public static let operation = AppOperation.distributionRepositoryList
    public var repositories: Bool

    public init(repositories: Bool = true) {
        self.repositories = repositories
    }
}

public struct DistributionRepositoryListResponse: Codable, Sendable, Equatable {
    /// The login of the github.com credential, as saved.
    public var account: String?
    public var linked: DistributionRepository?
    /// The account's own and its organizations', each one it can push to,
    /// most recently updated first.
    public var repositories: [DistributionRepositoryCandidate]
    /// With `repositories`, the organizations a repository can be created
    /// in: those GitHub lists for the account and the owners of the
    /// organization repositories it listed, by name.
    public var organizations: [String]

    public init(
        account: String? = nil,
        linked: DistributionRepository? = nil,
        repositories: [DistributionRepositoryCandidate] = [],
        organizations: [String] = [],
    ) {
        self.account = account
        self.linked = linked
        self.repositories = repositories
        self.organizations = organizations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        linked = try container.decodeIfPresent(DistributionRepository.self, forKey: .linked)
        repositories = try container.decode([DistributionRepositoryCandidate].self, forKey: .repositories)
        organizations = try container.decodeIfPresent([String].self, forKey: .organizations) ?? []
    }
}

/// A task: makes `name` on the signed-in account, or in the organization
/// `owner` names, public, from Apelin's template, as a new workspace project; commits and pushes it, turns on
/// GitHub Pages with the workflow as its source and links it. Stages
/// `creating`, `preparing`, `pushing`, `publishing`; the final `state`
/// carries `result` {repository: DistributionRepository, warnings}.
public struct DistributionRepositoryCreateRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.distributionRepositoryCreate
    public var name: String
    public var description: String?
    /// An organization's login; nil, or the account's own, for the account.
    public var owner: String?

    public init(name: String, description: String? = nil, owner: String? = nil) {
        self.name = name
        self.description = description
        self.owner = owner
    }
}

/// A task: clones one of the account's repositories as a new workspace
/// project (or takes the project already holding it), adds the template's
/// files it lacks without overwriting one, commits and pushes them when it
/// added any, turns on GitHub Pages with the workflow as its source and
/// links it. Stages `fetching`, `preparing`, `pushing`, `publishing`.
/// With `overwrite`, the files the template maintains — the home page,
/// README, icon, workflow and index script — are replaced with the
/// template's as well (Update Repository…); packages, depictions and
/// banners are never touched.
public struct DistributionRepositoryLinkRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.distributionRepositoryLink
    /// `owner/name`.
    public var fullName: String
    public var overwrite: Bool

    public init(fullName: String, overwrite: Bool = false) {
        self.fullName = fullName
        self.overwrite = overwrite
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try container.decode(String.self, forKey: .fullName)
        overwrite = try container.decodeIfPresent(Bool.self, forKey: .overwrite) ?? false
    }
}

/// Forgets the link; the repository and its project stay.
public struct DistributionRepositoryUnlinkRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.distributionRepositoryUnlink

    public init() {}
}

/// A task: brings the linked repository up to date (fast-forward only),
/// copies each package into its `debs/` as
/// `<Package>_<Version>_<Architecture>.deb` — the same bytes already there
/// are skipped, other bytes under that name are `conflict` —, commits
/// "Publish …" and pushes. `files` are `.deb` files under the data folder's
/// `Builds/`, at most 16. Each is copied and hashed, and every name checked,
/// before anything goes into `debs/`, so a refusal publishes none of them.
/// Stages `fetching`, `preparing`, `pushing`; the final `state` carries
/// `result` {published: [file names], skipped: [file names], sourceURL,
/// commit?}.
///
/// The app's, and an agent's as the host allows it (AgentPublishRules),
/// which names both optional fields.
public struct DistributionPublishRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.distributionPublish
    public var files: [String]
    /// `sha256:<64 lowercase hex>` of each file, in `files`' order: the
    /// digests the builds recorded. A file whose bytes are not its digest is
    /// `conflict`; a list of another length, or a digest of another shape,
    /// `badRequest`. Nil publishes the files as they are.
    public var digests: [String]?
    /// `owner/name` of the repository the caller means; another one linked
    /// is `conflict`. Nil publishes to whichever is linked.
    public var repository: String?

    /// GitHub takes a push of this many packages at 100 MB each.
    public static let maximumFiles = 16

    public init(files: [String], digests: [String]? = nil, repository: String? = nil) {
        self.files = files
        self.digests = digests
        self.repository = repository
    }

    /// Whether `digest` is one a build records: `sha256:` and 64 lowercase
    /// hex digits.
    public static func isDigest(_ digest: String) -> Bool {
        let hex = digest.utf8.dropFirst(7)
        return digest.hasPrefix("sha256:") && hex.count == 64
            && hex.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }
}

/// A task (owner, 2026-11-22, issue #77): the release builds of one
/// version, as they were built, published as a GitHub Release of a
/// repository the caller names, for a source that indexes each
/// repository's newest stable Release rather than committed packages
/// (owngoal-dev/owngoal-packages). Served by apelin-environment with the
/// github.com sign-in; nothing is built again, so the packages are the
/// device's own, with the dSYMs their builds kept.
///
/// The tag is `v<version>` of the packages, which are one package ID at
/// one version (the roothide and the rootless build of it), at the
/// project's current commit, which must already be on that repository:
/// its branches are fetched from it, whatever the project's remotes call
/// it, and a commit none of them holds is `conflict` with reason
/// `notPushed`. A tag GitHub has already must name that commit,
/// else `conflict` naming both; a tag is never moved. The release is made
/// as a draft, the packages and a `SHA256SUMS` of every package on it are
/// uploaded, then it is published, never as a pre-release. A release the
/// tag has already, draft or published, is filled in: a file of the same
/// name and bytes is skipped, other bytes under that name are `conflict`,
/// and `SHA256SUMS` is replaced when it changes. Every file is judged
/// before the first upload, so a refusal uploads nothing.
///
/// Stages `fetching`, `checking`, `uploading`, `releasing`; the final
/// `state` carries `result` (`DistributionReleaseResult`). Not resumed: one
/// cut off is answered by running it again, which fills in the draft it
/// left. Without a sign-in, `denied` with reason `authenticationRequired`.
///
/// The app's, and an agent's as the host allows it (AgentReleaseRules),
/// which names `tag` and `commit`.
public struct DistributionReleaseRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.distributionRelease
    /// The project whose commit is tagged: its projectID, or its folder.
    public var projectID: String
    /// `owner/name` on GitHub.
    public var repository: String
    /// `.deb` files under the data folder's `Builds/`, at most
    /// `maximumFiles`.
    public var files: [String]
    /// `sha256:<64 lowercase hex>` of each file, in `files`' order: the
    /// digests the builds recorded. A file whose bytes are not its digest
    /// is `conflict`.
    public var digests: [String]
    /// The tag the caller showed; nil takes the packages' `v<version>`.
    /// Another one is `conflict`.
    public var tag: String?
    /// The commit the caller showed, 40 hex digits; nil takes the
    /// project's HEAD. HEAD elsewhere is `conflict`, reason `headChanged`.
    public var commit: String?
    /// The release's notes, in Markdown; nil for none. Written on the
    /// release this makes, or on one that has none; notes a release has
    /// already are kept.
    public var notes: String?

    public static let maximumFiles = DistributionPublishRequest.maximumFiles
    public static let maximumNotesBytes = 16 * 1024
    /// The checksum file every release carries beside its packages, in
    /// `sha256sum`'s format.
    public static let checksumsName = "SHA256SUMS"

    public init(
        projectID: String,
        repository: String,
        files: [String],
        digests: [String],
        tag: String? = nil,
        commit: String? = nil,
        notes: String? = nil,
    ) {
        self.projectID = projectID
        self.repository = repository
        self.files = files
        self.digests = digests
        self.tag = tag
        self.commit = commit
        self.notes = notes
    }

    /// `v<version>`, nil for a version that cannot be one: a tag and a
    /// release file's name both take only letters, digits, `.`, `-` and
    /// `_` here, since git refuses `:` and `~` in a tag and GitHub renames
    /// a release file whose name has other characters.
    public static func tag(forVersion version: String) -> String? {
        let tag = "v" + version
        guard (2 ... 128).contains(tag.count), isPlainName(tag), !tag.contains(".."),
              !tag.hasSuffix("."), !tag.hasSuffix(".lock")
        else { return nil }
        return tag
    }

    /// Whether GitHub keeps `name` as it is for a release file: letters,
    /// digits, `.`, `-` and `_`, with no period at either end.
    public static func isAssetName(_ name: String) -> Bool {
        (1 ... 255).contains(name.count) && isPlainName(name) && !name.hasPrefix(".") && !name.hasSuffix(".")
    }

    /// 40 lowercase hex digits: a full commit ID.
    public static func isCommit(_ text: String) -> Bool {
        text.utf8.count == 40 && text.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    private static func isPlainName(_ text: String) -> Bool {
        text.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || "._-".utf8.contains($0)
        }
    }

    /// Nil when the request is shaped as one, else why not; what needs the
    /// device or GitHub is checked after.
    public var problem: String? {
        guard GitHubName.isFullName(repository) else {
            return "Name the GitHub repository as owner/name, such as octocat/hello-world."
        }
        guard !files.isEmpty, files.count <= Self.maximumFiles else {
            return "Release between 1 and \(Self.maximumFiles) packages at a time."
        }
        guard digests.count == files.count else {
            return "Name one digest for each package: \(files.count) packages, \(digests.count) digests."
        }
        guard digests.allSatisfy(DistributionPublishRequest.isDigest) else {
            return "A package's digest is sha256: and 64 lowercase hex digits, as its build recorded it."
        }
        if let tag, !tag.hasPrefix("v") || Self.tag(forVersion: String(tag.dropFirst())) != tag {
            return "\(tag) is not a tag Apelin makes: it makes v and the packages' version, such as v1.0.2."
        }
        if let commit, !Self.isCommit(commit) {
            return "Name the commit by its full 40-digit ID."
        }
        if let notes {
            guard notes.utf8.count <= Self.maximumNotesBytes else {
                return "The release notes are at most \(Self.maximumNotesBytes / 1024) KB."
            }
            guard !notes.unicodeScalars.contains("\0") else { return "The release notes hold a NUL character." }
        }
        return nil
    }
}

/// What `distributionRelease` did, in its final `state`'s `result`.
public struct DistributionReleaseResult: Codable, Sendable, Equatable {
    /// `owner/name`.
    public var repository: String
    public var tag: String
    /// The commit the tag names.
    public var commit: String
    /// The release's page on GitHub.
    public var url: String
    /// The package files this task uploaded, as GitHub names them.
    public var uploaded: [String]
    /// Those the release had already, with the same bytes.
    public var skipped: [String]
    /// What became of `SHA256SUMS`: `added`, `replaced` or `unchanged`.
    public var checksums: String
    /// Whether this task made the release.
    public var created: Bool
    /// What did not stop the release but should be told, such as a release
    /// published before as a pre-release, which stays one.
    public var warnings: [String]

    public init(
        repository: String,
        tag: String,
        commit: String,
        url: String,
        uploaded: [String],
        skipped: [String],
        checksums: String,
        created: Bool,
        warnings: [String] = [],
    ) {
        self.repository = repository
        self.tag = tag
        self.commit = commit
        self.url = url
        self.uploaded = uploaded
        self.skipped = skipped
        self.checksums = checksums
        self.created = created
        self.warnings = warnings
    }
}

public extension ApelinError.Reason {
    /// `distributionRelease`, `conflict`: the commit to tag is on no branch
    /// of the GitHub repository, or the project has no commit at all.
    /// Nothing was released; the commit is pushed there first.
    static let notPushed = ApelinError.Reason(rawValue: "notPushed")
}

/// Files feedback as a public issue on Apelin's own repository
/// (`FeedbackRules.repository`, never one the request names) with the
/// github.com sign-in, the title and body checked by `FeedbackRules` first
/// and a footer apelin-environment writes added below the body. Not a task:
/// one request to GitHub. The app's, and an agent's as the host allows it
/// (AgentFeedbackRules). Without a sign-in, `denied` with reason
/// `authenticationRequired`.
public struct FeedbackSendRequest: OperationRequest {
    public typealias Response = FeedbackSendResponse
    public static let operation = AppOperation.feedbackSend
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public struct FeedbackSendResponse: Codable, Sendable, Equatable {
    /// The issue's number in `FeedbackRules.repository`.
    public var number: Int
    /// Its page on GitHub.
    public var url: String

    public init(number: Int, url: String) {
        self.number = number
        self.url = url
    }
}

/// Reads one issue on Apelin's own repository (`FeedbackRules.repository`,
/// never another) with the github.com sign-in: its title, its body without
/// the footer `feedbackSend` wrote and that footer apart, who opened it and
/// whether the signed-in account did, which alone may edit it
/// (`FeedbackEditRequest`). A pull request is no feedback and is refused,
/// `notFound`. Not a task. The app's and an agent's. Without a sign-in,
/// `denied` with reason `authenticationRequired`.
public struct FeedbackReadRequest: OperationRequest {
    public typealias Response = FeedbackReadResponse
    public static let operation = AppOperation.feedbackRead
    /// The issue's number in `FeedbackRules.repository`.
    public var number: Int

    public init(number: Int) {
        self.number = number
    }
}

public struct FeedbackReadResponse: Codable, Sendable, Equatable {
    public var number: Int
    /// Its page on GitHub.
    public var url: String
    public var title: String
    /// The body without the footer.
    public var body: String
    /// The footer's line (`Sent with Apelin … · iOS … · <bootstrap>`), nil
    /// when the body does not end with one.
    public var footer: String?
    /// The login of the account that opened it.
    public var author: String
    /// `open` or `closed`.
    public var state: String
    /// Whether the signed-in account opened it.
    public var isAuthor: Bool

    public init(
        number: Int,
        url: String,
        title: String,
        body: String,
        footer: String?,
        author: String,
        state: String,
        isAuthor: Bool,
    ) {
        self.number = number
        self.url = url
        self.title = title
        self.body = body
        self.footer = footer
        self.author = author
        self.state = state
        self.isAuthor = isAuthor
    }
}

/// Edits the title, the body or both of an issue the signed-in account
/// opened on Apelin's own repository (owner, 2026-10-30): another account's
/// is `denied`. The new text is checked by `FeedbackRules.editProblem`
/// before the sign-in is read; then the issue is read again and nothing is
/// written unless its title and body (without the footer) are still
/// exactly `expectedTitle` and `expectedBody`, as the caller read them, so
/// an edit the user made on GitHub meanwhile is never overwritten
/// (`conflict`). Only the fields that change are sent, and the footer the
/// body had stays below the new one as it was. Not a task. The app's, and
/// an agent's as the host allows it (AgentFeedbackRules). Without a
/// sign-in, `denied` with reason `authenticationRequired`.
public struct FeedbackEditRequest: OperationRequest {
    public typealias Response = FeedbackEditResponse
    public static let operation = AppOperation.feedbackEdit
    public var number: Int
    /// The new title; nil keeps it.
    public var title: String?
    /// The new body, without the footer; nil keeps it.
    public var body: String?
    /// The title and body (without the footer) the edit was made against,
    /// as `FeedbackReadResponse` gave them.
    public var expectedTitle: String
    public var expectedBody: String

    public init(number: Int, title: String?, body: String?, expectedTitle: String, expectedBody: String) {
        self.number = number
        self.title = title
        self.body = body
        self.expectedTitle = expectedTitle
        self.expectedBody = expectedBody
    }
}

public struct FeedbackEditResponse: Codable, Sendable, Equatable {
    public var number: Int
    /// Its page on GitHub.
    public var url: String
    public var title: String
    /// The body without the footer, as GitHub now has it.
    public var body: String

    public init(number: Int, url: String, title: String, body: String) {
        self.number = number
        self.url = url
        self.title = title
        self.body = body
    }
}

/// Whether the github.com sign-in has starred Apelin's own repository
/// (`FeedbackRules.repository`), read before the app asks the reader to
/// star it, so one who already has is never asked. The app's alone. Without
/// a sign-in, `denied` with reason `authenticationRequired`.
public struct FeedbackStarStateRequest: OperationRequest {
    public typealias Response = FeedbackStarResponse
    public static let operation = AppOperation.feedbackStarState

    public init() {}
}

/// Stars Apelin's own repository with the github.com sign-in: sent only
/// when the reader taps Star Now in the app's prompt, never by an agent
/// and never by the console. Starring it again changes nothing. Without a
/// sign-in, `denied` with reason `authenticationRequired`.
public struct FeedbackStarRequest: OperationRequest {
    public typealias Response = FeedbackStarResponse
    public static let operation = AppOperation.feedbackStar

    public init() {}
}

public struct FeedbackStarResponse: Codable, Sendable, Equatable {
    /// `FeedbackRules.repository`.
    public var repository: String
    public var starred: Bool

    public init(repository: String, starred: Bool) {
        self.repository = repository
        self.starred = starred
    }
}

public extension ApelinService {
    func distributionRepositoryList(repositories: Bool = true) async throws -> DistributionRepositoryListResponse {
        try await send(DistributionRepositoryListRequest(repositories: repositories))
    }

    /// Starts the creation; follow it with `events(of:)`.
    func distributionRepositoryCreate(name: String, description: String? = nil, owner: String? = nil) async throws -> TaskHandle {
        try await send(DistributionRepositoryCreateRequest(name: name, description: description, owner: owner))
    }

    /// Starts the link; follow it with `events(of:)`.
    func distributionRepositoryLink(fullName: String, overwrite: Bool = false) async throws -> TaskHandle {
        try await send(DistributionRepositoryLinkRequest(fullName: fullName, overwrite: overwrite))
    }

    func distributionRepositoryUnlink() async throws {
        _ = try await send(DistributionRepositoryUnlinkRequest())
    }

    /// Starts publishing; follow it with `events(of:)`.
    func distributionPublish(files: [String], digests: [String]? = nil, repository: String? = nil) async throws -> TaskHandle {
        try await send(DistributionPublishRequest(files: files, digests: digests, repository: repository))
    }

    /// Starts the release; follow it with `events(of:)`.
    func distributionRelease(_ request: DistributionReleaseRequest) async throws -> TaskHandle {
        try await send(request)
    }

    func feedbackSend(title: String, body: String) async throws -> FeedbackSendResponse {
        try await send(FeedbackSendRequest(title: title, body: body))
    }

    func feedbackRead(number: Int) async throws -> FeedbackReadResponse {
        try await send(FeedbackReadRequest(number: number))
    }

    func feedbackEdit(_ request: FeedbackEditRequest) async throws -> FeedbackEditResponse {
        try await send(request)
    }

    func feedbackStarState() async throws -> FeedbackStarResponse {
        try await send(FeedbackStarStateRequest())
    }

    func feedbackStar() async throws -> FeedbackStarResponse {
        try await send(FeedbackStarRequest())
    }
}
