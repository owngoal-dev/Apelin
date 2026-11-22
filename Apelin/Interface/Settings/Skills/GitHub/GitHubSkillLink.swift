import ApelinProtocol
import Foundation

/// A link Settings ▸ Skills ▸ From GitHub takes: a repository
/// (`https://github.com/<owner>/<name>`), a folder in one
/// (`…/tree/<ref>/<path>`), or one `SKILL.md` (`…/blob/<ref>/<path>/SKILL.md`,
/// or `https://raw.githubusercontent.com/<owner>/<name>/<ref>/<path>/SKILL.md`,
/// with or without `refs/heads/` or `refs/tags/` before the ref).
///
/// HTTPS only, github.com (or www.github.com) and raw.githubusercontent.com
/// only, no user, password or port but 443, and an owner and a name of the
/// shapes GitHub gives them (`GitHubName`). A query or a fragment, which a
/// browser's address may carry (`?plain=1`, `#L12`), is not read. A ref may
/// hold slashes, so where it ends and the path begins is left to the
/// repository's refs (`GitHubSkillScanner.locate`): `words` keeps the two
/// together.
struct GitHubSkillLink: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// The default branch's whole tree.
        case repository
        /// A folder at a ref, the whole tree when the path is empty.
        case folder
        /// One `SKILL.md`: its folder, and nothing below it but its files.
        case skillFile
    }

    /// Which refs `words` begin with, when the link says (raw's `refs/heads/`).
    enum Namespace: String, Equatable, Sendable {
        case heads
        case tags
    }

    static let skillFileName = "SKILL.md"

    let owner: String
    let repository: String
    let target: Target
    /// The decoded path words after the ref's place: the ref, then the
    /// path, `SKILL.md` last for a file. Empty for a repository.
    let words: [String]
    let namespace: Namespace?

    var fullName: String {
        owner + "/" + repository
    }

    /// Nil for anything else, which the sheet says is not such a link.
    static func parse(_ text: String) -> GitHubSkillLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 4096, !trimmed.contains(where: \.isWhitespace),
              let parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), var words = Self.words(parts.percentEncodedPath)
        else { return nil }
        switch host {
        case "github.com", "www.github.com":
            guard words.count >= 2 else { return nil }
            let owner = words.removeFirst()
            var repository = words.removeFirst()
            if words.isEmpty, repository.lowercased().hasSuffix(".git") {
                // a clone address
                repository.removeLast(4)
            }
            guard GitHubName.isLogin(owner), GitHubName.isRepository(repository) else { return nil }
            guard let kind = words.first else {
                return GitHubSkillLink(owner: owner, repository: repository, target: .repository, words: [], namespace: nil)
            }
            words.removeFirst()
            switch kind {
            case "tree" where !words.isEmpty:
                return GitHubSkillLink(owner: owner, repository: repository, target: .folder, words: words, namespace: nil)
            case "blob" where words.count >= 2 && words.last == skillFileName:
                return GitHubSkillLink(owner: owner, repository: repository, target: .skillFile, words: words, namespace: nil)
            default:
                return nil
            }
        case "raw.githubusercontent.com":
            guard words.count >= 4, words.last == skillFileName else { return nil }
            let owner = words.removeFirst()
            let repository = words.removeFirst()
            guard GitHubName.isLogin(owner), GitHubName.isRepository(repository) else { return nil }
            var namespace: Namespace?
            if words.count >= 4, words[0] == "refs", let named = Namespace(rawValue: words[1]) {
                namespace = named
                words.removeFirst(2)
            }
            return GitHubSkillLink(owner: owner, repository: repository, target: .skillFile, words: words, namespace: namespace)
        default:
            return nil
        }
    }

    /// The path's words, decoded: nil for an empty word inside it (one
    /// trailing slash is fine), a word that does not decode, or one that
    /// decodes to a slash, a NUL, `.` or `..`.
    private static func words(_ path: String) -> [String]? {
        var raw = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard raw.first == "" else { return nil }
        raw.removeFirst()
        if raw.last == "" {
            raw.removeLast()
        }
        var words: [String] = []
        for word in raw {
            guard !word.isEmpty, let decoded = word.removingPercentEncoding, !decoded.isEmpty,
                  !decoded.contains("/"), !decoded.contains("\0"), decoded != ".", decoded != ".."
            else { return nil }
            words.append(decoded)
        }
        return words
    }
}
