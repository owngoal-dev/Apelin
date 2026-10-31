import Foundation

/// An `apelin://` link: what a widget, the Live Activity, a link in a
/// conversation or another app opens.
///
/// - `apelin://conversation/<id>` opens a conversation: `<id>` is its agent
///   session ID (what the agent's conversation tools return), or the app's
///   own chat ID.
/// - `apelin://project/<id>` opens a project, by its manifest `projectID` or
///   its folder name, on its most recent conversation.
/// - `apelin://chat?prompt=<text>` opens a new General Chat with `<text>`
///   in the composer and the keyboard up. Nothing is sent: the reader reads
///   it and taps Send. Without `prompt` the composer is empty.
/// - `apelin://import?url=<address>&branch=<name>` asks whether to import a
///   Git repository into a new project: Open in Apelin on a README, through
///   the page at `https://owngoal-dev.github.io/Apelin/open/`. It carries
///   the repository's HTTPS address and, optionally, a branch, each named
///   once, and nothing else: any other parameter is ignored. One whose
///   address or branch Apelin would not take is `invalidImport`.
/// - `apelin://` opens the app as it is.
///
/// Anything else with the scheme is `unknown`: the app opens and nothing it
/// shows changes. The format is fixed — the agent writes these links too.
enum ApelinLink: Hashable, Sendable {
    case app
    case conversation(String)
    case project(String)
    /// A new General Chat, its composer holding the text, unsent.
    case chat(prompt: String)
    /// The import confirmation for a repository: an address
    /// `isRepositoryAddress` takes, and a branch `isBranchName` takes or
    /// nil for the repository's default branch.
    case importRepository(url: String, branch: String?)
    /// An import link that names no repository Apelin can import.
    case invalidImport
    case unknown

    static let scheme = "apelin"

    /// The longest prompt a link may carry, in UTF-8 bytes.
    static let maximumPromptLength = 32768
    /// The longest repository address an import link may carry, in bytes.
    static let maximumAddressLength = 2048
    /// The longest branch name an import link may carry, in UTF-8 bytes.
    static let maximumBranchLength = 255

    /// The link `url` spells, or nil when it is not an `apelin:` URL.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // `apelin://conversation/x` names the kind as the host; a lenient
        // `apelin:conversation/x` has it as the first path component.
        var components = url.pathComponents.filter { $0 != "/" }
        if let host = url.host, !host.isEmpty {
            components.insert(host, at: 0)
        }
        switch components.count {
        case 0:
            self = .app
        case 1 where components[0].lowercased() == "chat":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let prompt = items.first { $0.name == "prompt" }?.value ?? ""
            self = Self.isPrompt(prompt) ? .chat(prompt: prompt) : .unknown
        case 1 where components[0].lowercased() == "import":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            self = Self.repositoryImport(items)
        case 2:
            let value = components[1]
            switch components[0].lowercased() {
            case "conversation" where Self.isIdentifier(value): self = .conversation(value)
            case "project" where Self.isIdentifier(value): self = .project(value)
            default: self = .unknown
            }
        default:
            self = .unknown
        }
    }

    /// The URL that opens this link.
    var url: URL {
        let path = switch self {
        case .app, .unknown: ""
        case let .conversation(id): "conversation/" + Self.escaped(id)
        case let .project(id): "project/" + Self.escaped(id)
        case let .chat(prompt) where prompt.isEmpty: "chat"
        case let .chat(prompt): "chat?prompt=" + Self.escapedQueryValue(prompt)
        case let .importRepository(address, nil): "import?url=" + Self.escapedQueryValue(address)
        case let .importRepository(address, branch?):
            "import?url=" + Self.escapedQueryValue(address) + "&branch=" + Self.escapedQueryValue(branch)
        case .invalidImport: "import"
        }
        // Every part is escaped above, so the string always parses.
        return URL(string: Self.scheme + "://" + path) ?? URL(fileURLWithPath: "/")
    }

    /// A session ID, a chat ID, a project ID or a folder name: one path
    /// component, short, with no control character (a NUL among them).
    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".."
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "/" }
    }

    /// Text for the composer: bounded, and no control character but a line
    /// break or a tab.
    private static func isPrompt(_ value: String) -> Bool {
        value.utf8.count <= maximumPromptLength
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) && !["\n", "\r", "\t"].contains($0)
            }
    }

    /// `url` and `branch`, each at most once: a link naming either twice is
    /// read no way at all, rather than one way here and another on the page
    /// that made it. An empty branch is the default branch.
    private static func repositoryImport(_ items: [URLQueryItem]) -> ApelinLink {
        let addresses = items.filter { $0.name == "url" }
        let branches = items.filter { $0.name == "branch" }
        guard addresses.count == 1, branches.count <= 1, let address = addresses[0].value,
              isRepositoryAddress(address)
        else { return .invalidImport }
        let branch = branches.first?.value.flatMap { $0.isEmpty ? nil : $0 }
        if let branch, !isBranchName(branch) {
            return .invalidImport
        }
        return .importRepository(url: address, branch: branch)
    }

    /// The characters an address may be spelt in: RFC 3986's unreserved and
    /// reserved ones but `?` and `#`, and `%` for an escape. Printable ASCII
    /// only, so every reader — URLComponents on any iOS, the landing page's
    /// script — parses it alike, and nothing in it hides or reorders what
    /// is shown: a name in another script comes percent-encoded.
    private static let addressCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/[]@!$&'()*+,;=%",
    )

    /// A repository an import may name: what the host clones (HTTPS, a host,
    /// no user or password: `GitClone.isAcceptedRemote`) and, as the session
    /// host asks of an address an agent hands it, no query or fragment
    /// either, where a token could ride. Spelt `https://` in lower case, so
    /// the scheme reads one way to the page, the host and git alike.
    /// Bounded, with a path that names something: a component at least,
    /// none `.` or `..`, and no control or format character once its
    /// escapes are decoded.
    static func isRepositoryAddress(_ address: String) -> Bool {
        guard address.hasPrefix("https://"), address.utf8.count <= maximumAddressLength,
              address.unicodeScalars.allSatisfy(addressCharacters.contains),
              hasWellFormedEscapes(address),
              let parts = URLComponents(string: address), parts.scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { return false }
        let names = parts.path.split(separator: "/")
        return !names.isEmpty && !names.contains { $0 == "." || $0 == ".." }
            && !parts.path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// A branch git takes (`git check-ref-format --branch`, which libgit2's
    /// `git_branch_name_is_valid` follows), bounded, and shown as it reads:
    /// no leading `-`, which reads as an option; not `HEAD` or `@`; no `..`,
    /// `@{`, `//`, leading or trailing `/` or trailing `.`; no component
    /// that starts with `.` or ends in `.lock`; none of `~ ^ : ? * [ \`, no
    /// white space and no control or format character (a direction
    /// override among them).
    static func isBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumBranchLength,
              !name.hasPrefix("-"), name != "HEAD", name != "@",
              !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."),
              !name.contains("//"), !name.contains(".."), !name.contains("@{"),
              !name.unicodeScalars.contains(where: branchForbidden.contains)
        else { return false }
        return !name.split(separator: "/").contains { $0.hasPrefix(".") || $0.hasSuffix(".lock") }
    }

    private static let branchForbidden = CharacterSet.controlCharacters
        .union(.whitespacesAndNewlines)
        .union(CharacterSet(charactersIn: "~^:?*[\\"))

    /// Every `%` begins an escape of two hexadecimal digits.
    private static func hasWellFormedEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "%") else {
                index += 1
                continue
            }
            guard index + 2 < bytes.count, isHexDigit(bytes[index + 1]), isHexDigit(bytes[index + 2]) else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        Character(Unicode.Scalar(byte)).isHexDigit
    }

    private static func escapedQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func escaped(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
