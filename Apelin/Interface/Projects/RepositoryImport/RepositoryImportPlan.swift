import Foundation

/// What Open in Apelin for a repository (`ApelinLink.importRepository`)
/// decides before anything is asked of the host: the project name it
/// suggests, whether a project on the device already has the repository,
/// and what a second link does while an import is shown or running.
enum RepositoryImportPlan {
    /// The repository a link names: an address `ApelinLink` took, and a
    /// branch, or nil for the default one.
    struct Request: Equatable {
        let address: String
        let branch: String?

        /// The same repository and branch, however the address is spelt.
        func isSame(as other: Request) -> Bool {
            branch == other.branch && RepositoryImportPlan.comparable(address) == RepositoryImportPlan.comparable(other.address)
        }
    }

    /// What a link does while another import is open.
    enum Arrival: Equatable {
        /// Nothing is open: show its confirmation.
        case start
        /// Its own confirmation or import is already on screen; nothing
        /// starts again.
        case showCurrent
        /// Another repository's import is open; this one waits for the user
        /// to finish or cancel that one.
        case busy
    }

    /// One import at a time: `current` is the request whose confirmation is
    /// shown or whose import runs, nil when none is.
    static func arrival(of request: Request, current: Request?) -> Arrival {
        guard let current else { return .start }
        return current.isSame(as: request) ? .showCurrent : .busy
    }

    /// An address as two spellings of one repository compare: host and path
    /// in lower case — GitHub's owners and names ignore case, and a
    /// mistaken match only offers to open a project — without the scheme,
    /// a user or password, the default port, a trailing `/` or `.git`.
    /// Nil when it names no host.
    static func comparable(_ address: String) -> String? {
        guard let parts = URLComponents(string: address), let host = parts.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        var path = parts.path.lowercased()
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasSuffix(".git") {
            path.removeLast(4)
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        let port = parts.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? ""
        return host + port + path
    }

    /// The longest name suggested, in UTF-8 bytes: well within the 255 a
    /// project folder may have, with room for a number after it.
    static let maximumSuggestionLength = 200

    /// The repository's name, as the project's: its last path component
    /// without `.git` and without leading dots, which a project name may not
    /// start with; else the one before it, else the host. Then the first of
    /// it, `<name> 2`, `<name> 3`… that no project in `taken` has, ignoring
    /// case.
    static func suggestedName(for address: String, taken: [String]) -> String {
        let parts = URLComponents(string: address)
        let components = (parts?.path ?? "").split(separator: "/").map(String.init)
        let candidates = components.reversed() + [parts?.host ?? ""]
        let base = candidates.lazy.map(cleaned).first { !$0.isEmpty } ?? "Repository"
        let occupied = Set(taken.map { $0.lowercased() })
        var name = base
        var number = 2
        while occupied.contains(name.lowercased()), number < 10000 {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    private static func cleaned(_ component: String) -> String {
        var name = component.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".git") {
            name.removeLast(4)
        }
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        while name.utf8.count > maximumSuggestionLength {
            name.removeLast()
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `remote.origin.url` in a repository's `.git/config`, read as text:
    /// enough to recognise a repository imported before, never to decide
    /// anything a wrong reading could harm. Nil when it names none.
    static func origin(inGitConfig text: String) -> String? {
        var inOrigin = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
                // the section's name ignores case, its subsection does not
                inOrigin = header.lowercased().hasPrefix("[remote") && header.dropFirst(7) == "\"origin\"]"
                continue
            }
            guard inOrigin else { continue }
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
