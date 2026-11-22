import ApelinCore
import ApelinProtocol
import Foundation

/// A repository's releases and their files, as `distributionRelease` uses
/// them, after GitHub's REST API (2022-11-28) on docs.github.com: Releases,
/// Release assets and Git references. A published release is found by its
/// tag; a draft only by listing the releases, which an account that can
/// push sees drafts in, since the tag lookup is "Get a published release
/// with the specified tag".
extension GitHubAPI {
    struct Release: Decodable, Sendable {
        let id: Int
        let tagName: String
        let name: String?
        /// Nil or empty for a release with no notes.
        let body: String?
        let draft: Bool
        let prerelease: Bool
        /// Whether GitHub locks its files and its tag once it is published;
        /// absent where immutable releases are not on.
        let immutable: Bool?
        let htmlURL: String
        /// An RFC 6570 template, `https://uploads.github.com/…/assets{?name,label}`.
        let uploadURL: String

        enum CodingKeys: String, CodingKey {
            case id, name, body, draft, prerelease, immutable
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case uploadURL = "upload_url"
        }
    }

    /// A release's file.
    struct Asset: Decodable, Sendable {
        let id: Int
        let name: String
        /// `uploaded` once whole. An upload GitHub lost part way leaves one
        /// in another state, which "can be safely deleted".
        let state: String
        let size: Int
        /// `sha256:<hex>`; nil for a file GitHub keeps no digest of.
        let digest: String?
    }

    private struct Reference: Decodable {
        let object: Target
    }

    private struct Target: Decodable {
        let type: String
        let sha: String
    }

    private struct AnnotatedTag: Decodable {
        let object: Target
    }

    /// Lists are read 100 at a time, at most this many pages: a release
    /// holds at most 1,000 files.
    static let maximumPages = 10
    /// Where a release's files go; the sign-in is sent nowhere else with them.
    static let uploadHost = "uploads.github.com"

    /// The repository, when the signed-in account can see it and push to
    /// it, which making a release takes.
    func pushableRepository(_ fullName: String) async throws -> Repository {
        let path = "/repos/\(fullName)"
        let (data, response) = try await exchange(request("GET", path, body: nil))
        if response.statusCode == 404 {
            throw ApelinError(
                .notFound,
                "GitHub shows the signed-in account no repository \(fullName): its owner or name is not one GitHub has, or the account cannot see it.",
            )
        }
        try Self.check(response, data)
        let repository = try Self.decode(Repository.self, data, "GET", path)
        guard repository.permissions?.push != false else {
            throw ApelinError(.denied, "The signed-in account cannot push to \(repository.fullName), so it cannot make a release there.")
        }
        return repository
    }

    /// The commit `tag` names on GitHub, an annotated tag followed to it;
    /// nil when GitHub has no such tag.
    func tagCommit(_ fullName: String, tag: String) async throws -> String? {
        let path = "/repos/\(fullName)/git/ref/tags/\(tag)"
        let (data, response) = try await exchange(request("GET", path, body: nil))
        // 404: "If the :ref doesn't match an existing ref"; 409: an empty
        // repository, which has no tag either
        if response.statusCode == 404 || response.statusCode == 409 {
            return nil
        }
        try Self.check(response, data)
        var target = try Self.decode(Reference.self, data, "GET", path).object
        var hops = 0
        while target.type == "tag", hops < 4 {
            target = try await send("GET", "/repos/\(fullName)/git/tags/\(target.sha)", as: AnnotatedTag.self).object
            hops += 1
        }
        guard target.type == "commit" else {
            throw ApelinError(
                .conflict,
                "The tag \(tag) on \(fullName) names a \(target.type), not a commit. A tag is never moved: release another version.",
            )
        }
        return target.sha
    }

    /// The release of `tag`: the published one GitHub finds by its tag,
    /// else the draft that names it, else nil. Two drafts of one tag are
    /// `conflict`: which one to fill in is the user's to say.
    func release(_ fullName: String, tag: String) async throws -> Release? {
        let path = "/repos/\(fullName)/releases/tags/\(tag)"
        let (data, response) = try await exchange(request("GET", path, body: nil))
        if response.statusCode != 404 {
            try Self.check(response, data)
            return try Self.decode(Release.self, data, "GET", path)
        }
        var drafts: [Release] = []
        for page in 1 ... Self.maximumPages {
            let releases = try await send("GET", "/repos/\(fullName)/releases?per_page=100&page=\(page)", as: [Release].self)
            drafts += releases.filter { $0.draft && $0.tagName == tag }
            if releases.count < 100 {
                break
            }
        }
        guard drafts.count <= 1 else {
            throw ApelinError(
                .conflict,
                "\(fullName) has \(drafts.count) draft releases of \(tag). Delete all but one on GitHub, then release again.",
            )
        }
        return drafts.first
    }

    /// Every file of release `id`.
    func assets(_ fullName: String, release id: Int) async throws -> [Asset] {
        var assets: [Asset] = []
        for page in 1 ... Self.maximumPages {
            let batch = try await send(
                "GET",
                "/repos/\(fullName)/releases/\(id)/assets?per_page=100&page=\(page)",
                as: [Asset].self,
            )
            assets += batch
            if batch.count < 100 {
                break
            }
        }
        return assets
    }

    /// A draft release of `tag` at `commit`, named by its tag. GitHub
    /// makes the tag only when the release is published, and from
    /// `target_commitish` only when the tag does not exist then.
    func createDraftRelease(_ fullName: String, tag: String, commit: String, notes: String?) async throws -> Release {
        var fields: [String: Any] = [
            "tag_name": tag, "target_commitish": commit, "name": tag, "draft": true, "prerelease": false,
        ]
        if let notes {
            fields["body"] = notes
        }
        let path = "/repos/\(fullName)/releases"
        let (data, response) = try await exchange(request("POST", path, body: fields))
        try Self.releaseCheck(response, data, doing: "make the release \(tag)", on: fullName)
        return try Self.decode(Release.self, data, "POST", path)
    }

    /// Release `id` with `fields` changed, by GitHub's names for them.
    func updateRelease(_ fullName: String, id: Int, _ fields: [String: Any], doing what: String) async throws -> Release {
        let path = "/repos/\(fullName)/releases/\(id)"
        let (data, response) = try await exchange(request("PATCH", path, body: fields))
        try Self.releaseCheck(response, data, doing: what, on: fullName)
        return try Self.decode(Release.self, data, "PATCH", path)
    }

    /// The repository's latest release, nil when it has none.
    func latestRelease(_ fullName: String) async throws -> Release? {
        let path = "/repos/\(fullName)/releases/latest"
        let (data, response) = try await exchange(request("GET", path, body: nil))
        if response.statusCode == 404 {
            return nil
        }
        try Self.check(response, data)
        return try Self.decode(Release.self, data, "GET", path)
    }

    /// Takes a release's file away; one already gone stays gone.
    func deleteAsset(_ fullName: String, _ asset: Asset) async throws {
        let (data, response) = try await exchange(request("DELETE", "/repos/\(fullName)/releases/assets/\(asset.id)", body: nil))
        guard response.statusCode != 404 else { return }
        try Self.releaseCheck(response, data, doing: "remove \(asset.name) from the release", on: fullName)
    }

    /// `file` uploaded to `release` as `name`, at the address the release
    /// names for its files (`upload_url`, its `{?name,label}` filled in),
    /// which must be uploads.github.com. A name the release has already is
    /// 422: the old file has to go first.
    func uploadAsset(
        _ fullName: String,
        release: Release,
        name: String,
        contentType: String,
        file: URL,
    ) async throws -> Asset {
        let template = String(release.uploadURL.prefix { $0 != "{" })
        guard var components = URLComponents(string: template), components.scheme?.lowercased() == "https",
              components.host?.lowercased() == Self.uploadHost, components.port == nil, components.query == nil
        else {
            throw ApelinError(.unavailable, "GitHub named an address for the release's files that Apelin does not send the sign-in to.")
        }
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else {
            throw ApelinError(.badRequest, "\(name) cannot be named in an upload.")
        }
        var sending = URLRequest(url: url)
        sending.httpMethod = "POST"
        authorize(&sending)
        // GitHub reads the file's type from this header, its length from Content-Length
        sending.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await upload(sending, file)
        if response.statusCode == 422 {
            throw ApelinError(
                .conflict,
                "GitHub refused \(name) on the release \(release.tagName) of \(fullName): a file of that name is there already (GitHub: \(Self.words(response, data))).",
            )
        }
        try Self.releaseCheck(response, data, doing: "upload \(name)", on: fullName)
        return try Self.decode(Asset.self, data, "POST", "/repos/\(fullName)/releases/\(release.id)/assets")
    }

    /// `sha256:<hex>` of a release's file: the digest GitHub keeps, else
    /// the file read back from GitHub and hashed.
    func digest(of asset: Asset, in fullName: String) async throws -> String {
        if let digest = asset.digest?.lowercased(), DistributionPublishRequest.isDigest(digest) {
            return digest
        }
        var asking = try request("GET", "/repos/\(fullName)/releases/assets/\(asset.id)", body: nil)
        // the file itself rather than its description
        asking.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return try await download(asking).digest
    }

    /// A refusal of a change to a release, in GitHub's words, saying what
    /// blocks it: the account cannot see what it names, GitHub does not let
    /// it change it, or GitHub's validation refused it.
    static func releaseCheck(_ response: HTTPURLResponse, _ data: Data, doing what: String, on fullName: String) throws {
        guard !(200 ..< 300).contains(response.statusCode) else { return }
        let message = words(response, data)
        switch response.statusCode {
        case 404:
            // GitHub answers 404 too when the commit changes a workflow and the
            // sign-in may not change workflows
            throw ApelinError(
                .notFound,
                "GitHub did not let the signed-in account \(what) on \(fullName): it cannot see what that names, or the commit changes a file in .github/workflows, which a sign-in without workflow access may not release (GitHub: \(message)).",
            )
        case 403:
            throw ApelinError(.denied, "GitHub does not let the signed-in account \(what) on \(fullName): \(message)")
        case 422:
            throw ApelinError(.conflict, "GitHub refused to \(what) on \(fullName): \(message)")
        default:
            try check(response, data)
        }
    }
}
