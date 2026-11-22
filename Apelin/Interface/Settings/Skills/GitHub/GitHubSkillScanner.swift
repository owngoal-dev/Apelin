import CryptoKit
import Foundation

/// Why GitHub gave no skills to list or import. GitHub's own words, when it
/// gave any, ride along for the sheet to quote.
enum GitHubSkillFailure: Error, Equatable {
    /// No public repository of that name: private, renamed away or never there.
    case repositoryNotFound(String, words: String?)
    /// No branch, tag or commit begins the link's path.
    case refNotFound(String, words: String?)
    /// No such folder, or no `SKILL.md`, at the ref.
    case pathNotFound(String)
    /// The hourly allowance for requests without a sign-in is spent, or
    /// GitHub asked to slow down.
    case rateLimited(resetsAt: Date?, retryAfter: TimeInterval?, words: String?)
    /// Any other refusal.
    case refused(status: Int, words: String?)
    /// The folder's tree is past what GitHub lists in one answer.
    case tooManyFiles
    /// An answer that is not GitHub's shape.
    case unreadable
    /// A file whose bytes are not the commit's.
    case changed(String)
}

/// A scan: where the link points, the skills found there and how many more
/// there were than a scan lists.
struct GitHubSkillScan: Equatable, Sendable {
    let place: GitHubSkillPlace
    let candidates: [GitHubSkillCandidate]
    let omitted: Int
}

/// GitHub as Settings ▸ Skills ▸ From GitHub reads it: public repositories,
/// without a sign-in, from the app, which has the network (the github.com
/// token is apelin-environment's and never the app's).
///
/// The REST API (version `2026-03-10`) answers what the link names, in three
/// to five requests of the sixty an hour GitHub allows a device that has not
/// signed in: the repository's default branch (`GET /repos/{owner}/{repo}`)
/// or the refs a path begins with (`GET …/git/matching-refs/heads/{word}`,
/// then `tags/`), so a branch with slashes in its name is told from the
/// path after it; the commit and its tree
/// (`GET …/commits/{ref}?per_page=1`); the folder's tree from its parent's
/// listing (`GET …/contents/{parent}?ref={commit}`); and every entry below
/// it (`GET …/git/trees/{sha}?recursive=1`), refused when GitHub cuts the
/// list short (`truncated`). Files come from raw.githubusercontent.com at
/// that commit, where GitHub serves raw files and which the contents API's
/// `download_url` names: none of them costs a request of the sixty. Each
/// is held to the blob ID the tree gave, so every byte is the commit's.
///
/// Nothing here runs anything, and the session keeps no cookie, cache or
/// credential.
struct GitHubSkillScanner: Sendable {
    static let apiVersion = "2026-03-10"
    /// Requests in flight to raw.githubusercontent.com at once.
    static let concurrentReads = 4

    /// One HTTPS exchange; the harness answers for GitHub.
    let exchange: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let live: GitHubSkillScanner = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        return GitHubSkillScanner { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw GitHubSkillFailure.unreadable }
            return (data, response)
        }
    }()

    // MARK: - Scanning

    /// The skills at `link`, each `SKILL.md` read and judged; a skill named
    /// as one in `builtInNames` cannot be imported. `progress` hears how
    /// many `SKILL.md`s are read of how many.
    func scan(
        _ link: GitHubSkillLink,
        builtInNames: Set<String>,
        progress: @escaping @Sendable (_ read: Int, _ total: Int) async -> Void = { _, _ in },
    ) async throws -> GitHubSkillScan {
        let (place, tree) = try await locate(link)
        let entries = try await entries(of: tree, in: place)
        let (layouts, omitted) = GitHubSkillLayout.layouts(of: entries, topName: place.folderName, single: place.single)
        if place.single, layouts.isEmpty {
            throw GitHubSkillFailure.pathNotFound(Self.join(place.path, GitHubSkillLink.skillFileName))
        }
        var texts = [String?](repeating: nil, count: layouts.count)
        await progress(0, layouts.count)
        try await bounded(Array(layouts.indices)) { index in
            try await (index, text(of: layouts[index], in: place))
        } each: { done, result in
            texts[result.0] = result.1
            await progress(done, layouts.count)
        }
        let candidates = layouts.indices.map { layouts[$0].candidate(text: texts[$0], builtInNames: builtInNames) }
        return GitHubSkillScan(place: place, candidates: candidates, omitted: omitted)
    }

    /// The `SKILL.md` as text: nil when it is a link, over 1 MB or not UTF-8.
    private func text(of layout: GitHubSkillLayout, in place: GitHubSkillPlace) async throws -> String? {
        let entry = layout.instructions
        guard entry.kind == .file, entry.size <= GitHubSkillCandidate.maximumInstructionsBytes else { return nil }
        let data = try await raw(Self.join(place.path, entry.path), sha: entry.sha, in: place)
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Importing

    /// Writes `candidate`'s files and folders into `folder`, which is made
    /// here and must not exist, every file checked against its blob ID.
    /// `progress` hears each file written. Nothing is made executable.
    func download(
        _ candidate: GitHubSkillCandidate,
        from place: GitHubSkillPlace,
        into folder: URL,
        progress: @escaping @Sendable (_ file: String) async -> Void = { _ in },
    ) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        for path in candidate.folders.sorted() {
            try manager.createDirectory(at: folder.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
        }
        let base = Self.join(place.path, candidate.folder)
        try await bounded(candidate.files) { file in
            try await (file, raw(Self.join(base, file.path), sha: file.sha, in: place))
        } each: { _, result in
            let (file, data) = result
            let target = folder.appendingPathComponent(file.path, isDirectory: false)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .withoutOverwriting)
            await progress(file.path)
        }
    }

    // MARK: - Locating

    /// The commit `link` names, the folder in it and that folder's tree.
    func locate(_ link: GitHubSkillLink) async throws -> (place: GitHubSkillPlace, tree: String) {
        let words = link.words
        let first = words.first ?? ""
        // the ref's words, and the path's after them; a SKILL.md link keeps
        // at least the file's name for the path
        let reserved = link.target == .skillFile ? 1 : 0
        let ref: String
        let lookup: [String]
        let consumed: Int
        if link.target == .repository || (link.namespace == nil && first == "HEAD") {
            ref = try await defaultBranch(of: link)
            lookup = ["heads"] + ref.split(separator: "/").map(String.init)
            consumed = link.target == .repository ? 0 : 1
        } else if link.namespace == nil, Self.isCommitID(first, abbreviated: false) {
            (ref, lookup, consumed) = (first, [first], 1)
        } else if let (name, namespace) = try await matchingRef(of: link, leaving: reserved) {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            (ref, lookup, consumed) = (name, [namespace.rawValue] + parts, parts.count)
        } else if link.namespace == nil, Self.isCommitID(first, abbreviated: true) {
            (ref, lookup, consumed) = (first, [first], 1)
        } else {
            throw GitHubSkillFailure.refNotFound(first, words: nil)
        }
        let (commit, rootTree) = try await commit(lookup, ref: ref, of: link)
        var path = Array(words.dropFirst(consumed))
        if link.target == .skillFile {
            path.removeLast()
        }
        let place = GitHubSkillPlace(
            owner: link.owner,
            repository: link.repository,
            ref: ref,
            commit: commit,
            path: path.joined(separator: "/"),
            single: link.target == .skillFile,
        )
        guard !path.isEmpty else { return (place, rootTree) }
        return try await (place, folderTree(path, at: commit, of: link))
    }

    private func defaultBranch(of link: GitHubSkillLink) async throws -> String {
        let data = try await fetch(api(["repos", link.owner, link.repository])) { words in
            .repositoryNotFound(link.fullName, words: words)
        }
        guard let object = Self.object(data), let branch = object["default_branch"] as? String, !branch.isEmpty else {
            throw GitHubSkillFailure.unreadable
        }
        return branch
    }

    /// The longest branch (then tag) whose name is the path's first words,
    /// at least `leaving` words left after it. GitHub lists every ref whose
    /// name starts with the first word as text (`feature` finds
    /// `feature-x` too), which is narrowed here word by word.
    private func matchingRef(
        of link: GitHubSkillLink,
        leaving reserved: Int,
    ) async throws -> (String, GitHubSkillLink.Namespace)? {
        let words = link.words
        for namespace in link.namespace.map({ [$0] }) ?? [.heads, .tags] {
            let request = api(["repos", link.owner, link.repository, "git", "matching-refs", namespace.rawValue, words[0]])
            let data = try await fetch(request) { words in .repositoryNotFound(link.fullName, words: words) }
            guard let refs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                throw GitHubSkillFailure.unreadable
            }
            let prefix = "refs/\(namespace.rawValue)/"
            var best: [String] = []
            for ref in refs {
                guard let name = ref["ref"] as? String, name.hasPrefix(prefix) else { continue }
                let parts = name.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                if parts.count > best.count, parts.count + reserved <= words.count, Array(words.prefix(parts.count)) == parts {
                    best = parts
                }
            }
            if !best.isEmpty {
                return (best.joined(separator: "/"), namespace)
            }
        }
        return nil
    }

    /// The full SHA and root tree of the commit `lookup` names
    /// (`heads/<branch>`, `tags/<tag>` or a SHA). `per_page=1` keeps the
    /// commit's list of changed files to one.
    private func commit(_ lookup: [String], ref: String, of link: GitHubSkillLink) async throws -> (String, String) {
        let request = api(
            ["repos", link.owner, link.repository, "commits"] + lookup,
            query: [URLQueryItem(name: "per_page", value: "1")],
        )
        let data = try await fetch(request, missing: [404, 422]) { words in .refNotFound(ref, words: words) }
        guard let object = Self.object(data), let sha = object["sha"] as? String, Self.isCommitID(sha, abbreviated: false),
              let tree = ((object["commit"] as? [String: Any])?["tree"] as? [String: Any])?["sha"] as? String,
              Self.isCommitID(tree, abbreviated: false)
        else { throw GitHubSkillFailure.unreadable }
        return (sha, tree)
    }

    /// The tree of the folder at `path`, from its parent folder's listing.
    private func folderTree(_ path: [String], at commit: String, of link: GitHubSkillLink) async throws -> String {
        let shown = path.joined(separator: "/")
        let request = api(
            ["repos", link.owner, link.repository, "contents"] + path.dropLast(),
            query: [URLQueryItem(name: "ref", value: commit)],
        )
        let data = try await fetch(request) { _ in .pathNotFound(shown) }
        guard let listing = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let entry = listing.first(where: { $0["name"] as? String == path.last }),
              entry["type"] as? String == "dir", let sha = entry["sha"] as? String, Self.isCommitID(sha, abbreviated: false)
        else { throw GitHubSkillFailure.pathNotFound(shown) }
        return sha
    }

    /// Every entry below the tree `sha`, paths relative to it.
    private func entries(of sha: String, in place: GitHubSkillPlace) async throws -> [GitHubTreeEntry] {
        let request = api(
            ["repos", place.owner, place.repository, "git", "trees", sha],
            query: [URLQueryItem(name: "recursive", value: "1")],
        )
        let data = try await fetch(request) { _ in .pathNotFound(place.path) }
        guard let object = Self.object(data), let truncated = object["truncated"] as? Bool,
              let tree = object["tree"] as? [[String: Any]]
        else { throw GitHubSkillFailure.unreadable }
        guard !truncated else { throw GitHubSkillFailure.tooManyFiles }
        return tree.compactMap { item in
            guard let path = item["path"] as? String, let type = item["type"] as? String, let sha = item["sha"] as? String else {
                return nil
            }
            let kind: GitHubTreeEntry.Kind
            switch (type, item["mode"] as? String) {
            case ("blob", "120000"): kind = .link
            case ("blob", _): kind = .file
            case ("tree", _): kind = .folder
            case ("commit", _): kind = .submodule
            default: return nil
            }
            return GitHubTreeEntry(path: path, kind: kind, sha: sha, size: (item["size"] as? Int) ?? 0)
        }
    }

    // MARK: - Requests

    /// A REST API request for `path`, each word escaped on its own.
    private func api(_ path: [String], query: [URLQueryItem] = []) -> URLRequest {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "api.github.com"
        parts.percentEncodedPath = "/" + path.map(Self.escape).joined(separator: "/")
        parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// A file of the commit from raw.githubusercontent.com, held to the
    /// blob ID `sha` the tree gave.
    private func raw(_ path: String, sha: String, in place: GitHubSkillPlace) async throws -> Data {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "raw.githubusercontent.com"
        let words = [place.owner, place.repository, place.commit] + path.split(separator: "/").map(String.init)
        parts.percentEncodedPath = "/" + words.map(Self.escape).joined(separator: "/")
        let data = try await fetch(URLRequest(url: parts.url!)) { _ in .changed(path) }
        guard Self.blobID(of: data) == sha.lowercased() else { throw GitHubSkillFailure.changed(path) }
        return data
    }

    /// The body of a 200; a status in `missing` is `notFound`'s failure, a
    /// spent allowance `rateLimited`, anything else `refused`.
    private func fetch(
        _ request: URLRequest,
        missing: Set<Int> = [404],
        notFound: (_ words: String?) -> GitHubSkillFailure,
    ) async throws -> Data {
        let (data, response) = try await exchange(request)
        let status = response.statusCode
        if status == 200 {
            return data
        }
        let words = Self.words(in: data)
        if missing.contains(status) {
            throw notFound(words)
        }
        if status == 403 || status == 429 {
            // GitHub's "Exceeding the rate limit": 403 or 429, with a
            // remaining count of 0 or a retry-after, or its message saying so
            let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining")
            let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            if status == 429 || remaining == "0" || retryAfter != nil || words?.lowercased().contains("rate limit") == true {
                let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset")
                    .flatMap(TimeInterval.init)
                    .map(Date.init(timeIntervalSince1970:))
                throw GitHubSkillFailure.rateLimited(resetsAt: remaining == "0" ? reset : nil, retryAfter: retryAfter, words: words)
            }
        }
        throw GitHubSkillFailure.refused(status: status, words: words)
    }

    /// Runs `work` on each item, `concurrentReads` at a time, and hands
    /// each result to `each` as it comes, with how many have.
    private func bounded<Item: Sendable, Result: Sendable>(
        _ items: [Item],
        _ work: @escaping @Sendable (Item) async throws -> Result,
        each: (_ done: Int, Result) async throws -> Void,
    ) async throws {
        try await withThrowingTaskGroup(of: Result.self) { group in
            var next = items.makeIterator()
            for _ in 0 ..< Self.concurrentReads {
                guard let item = next.next() else { break }
                group.addTask { try await work(item) }
            }
            var done = 0
            while let result = try await group.next() {
                try Task.checkCancellation()
                done += 1
                try await each(done, result)
                if let item = next.next() {
                    group.addTask { try await work(item) }
                }
            }
        }
    }

    // MARK: - Reading answers

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// What GitHub said: the API's `message`, or a short plain answer
    /// (raw.githubusercontent.com's "404: Not Found").
    static func words(in data: Data) -> String? {
        if let message = object(data)?["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(500))
        }
        guard data.count <= 500, let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("{") || trimmed.hasPrefix("<") ? nil : trimmed
    }

    /// Git's ID of a blob: SHA-1 over `blob <size>\0` and the bytes.
    static func blobID(of data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Forty hex digits, or with `abbreviated` seven or more.
    static func isCommitID(_ text: String, abbreviated: Bool) -> Bool {
        let digits = Set("0123456789abcdefABCDEF")
        return (abbreviated ? (7 ... 40).contains(text.count) : text.count == 40) && text.allSatisfy(digits.contains)
    }

    /// A path word escaped for a URL: only letters, digits and `-._~` left.
    static func escape(_ word: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return word.addingPercentEncoding(withAllowedCharacters: allowed) ?? word
    }

    static func join(_ folder: String, _ path: String) -> String {
        folder.isEmpty ? path : path.isEmpty ? folder : folder + "/" + path
    }
}
