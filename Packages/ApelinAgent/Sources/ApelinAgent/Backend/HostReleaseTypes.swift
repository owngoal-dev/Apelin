import Foundation

// MARK: - apelin_package_release

/// What apelin_package_release reads before anyone is asked: the session
/// project's commit and its remotes on github.com, whether the user is
/// signed in to GitHub, and what each build recorded of its package.
public struct PackageReleaseFactsRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// Builds by their ID, which is also their package artifact's.
    public var buildIDs: [String]
    public init(context: HostCallContext, buildIDs: [String]) {
        self.context = context
        self.buildIDs = buildIDs
    }
}

public struct PackageReleaseFacts: Sendable, Hashable, Codable {
    /// The project's HEAD; nil when it has no repository or no commit.
    public var commit: String?
    /// The branch checked out; nil on a detached HEAD.
    public var branch: String?
    /// `owner/name` of each of the project's remotes on github.com, its
    /// `origin` first.
    public var githubRemotes: [String]
    /// Whether a github.com sign-in is saved; nil when it could not be read.
    public var signedIn: Bool?
    /// One for each build asked about, in order; nil for a build that left
    /// no package record.
    public var builds: [PackageBuildRecord?]
    public init(commit: String?, branch: String?, githubRemotes: [String], signedIn: Bool?, builds: [PackageBuildRecord?]) {
        self.commit = commit
        self.branch = branch
        self.githubRemotes = githubRemotes
        self.signedIn = signedIn
        self.builds = builds
    }
}

/// The release apelin_package_release's card named: its packages' files
/// and digests to the repository, tag and commit it named, nothing else.
public struct PackageReleaseToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var release: PackageReleaseApproval
    public init(context: HostCallContext, release: PackageReleaseApproval) {
        self.context = context
        self.release = release
    }
}

public struct PackageReleaseToolResponse: Sendable, Hashable, Codable {
    /// `owner/name`.
    public var repository: String
    public var tag: String
    public var commit: String
    /// The release's page, which the user is given.
    public var url: String
    /// The package files uploaded to it.
    public var uploaded: [String]
    /// The package files it held already with the same bytes.
    public var alreadyThere: [String]
    /// What became of `SHA256SUMS`: `added`, `replaced` or `unchanged`.
    public var checksums: String
    /// Whether the release was made now, rather than filled in.
    public var created: Bool
    public var warnings: [String]
    /// What happens next, in words.
    public var next: String
    public init(
        repository: String,
        tag: String,
        commit: String,
        url: String,
        uploaded: [String],
        alreadyThere: [String],
        checksums: String,
        created: Bool,
        warnings: [String],
        next: String,
    ) {
        self.repository = repository
        self.tag = tag
        self.commit = commit
        self.url = url
        self.uploaded = uploaded
        self.alreadyThere = alreadyThere
        self.checksums = checksums
        self.created = created
        self.warnings = warnings
        self.next = next
    }
}

/// A release that did not happen, in words the model can act on and pass
/// on to the user.
public struct PackageReleaseToolFailure: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var errorDescription: String? {
        message
    }

    public init(message: String) {
        self.message = message
    }
}
