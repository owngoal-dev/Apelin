import Darwin
import Foundation

/// A bounded listing of a project folder for the model's first message, so
/// it does not spend its first turns listing files.
///
/// Breadth first, so a large project shows its top levels rather than one
/// deep corner: at most `maximumEntries` entries, folders opened to
/// `maximumDepth` levels, each folder read for at most
/// `maximumNamesPerFolder` names and `maximumExamined` in all. `.git`,
/// `.DS_Store`, the top-level `Builds`, Apelin's own temporary files and
/// what the project's `.gitignore` files name are left out; the top-level
/// `Attachments` (the chat's saved files) is shown but not opened. Nothing
/// is followed: a link is listed as a link, whatever it points to.
struct ProjectTree {
    static let maximumEntries = 200
    static let maximumDepth = 6
    static let maximumNamesPerFolder = 2000
    /// Names looked at in all, ignored ones included, so a project of many
    /// ignored files costs no more than that many `lstat`s.
    static let maximumExamined = 20000

    /// The listing, one entry per line, two spaces per level.
    let lines: [String]
    /// Whether a cap stopped the listing.
    let truncated: Bool

    private final class Node {
        enum Kind { case file, folder, link }
        let name: String
        let kind: Kind
        var children: [Node] = []
        /// Its entries were read.
        @objc dynamic var opened = false
        /// Every entry it has, ignored ones aside, is listed.
        @objc dynamic var complete = true

        init(name: String, kind: Kind) {
            self.name = name
            self.kind = kind
        }
    }

    /// `root` is the project's canonical path.
    init(root: String) {
        let top = Node(name: "", kind: .folder)
        var queue: [(node: Node, relative: String, depth: Int, rules: [IgnoreRules])] = [(top, "", 0, [])]
        var listed = 0
        var examined = 0
        var truncated = false
        var next = 0
        while next < queue.count {
            let (node, relative, depth, inherited) = queue[next]
            next += 1
            if truncated {
                continue
            }
            let folder = relative.isEmpty ? root : root + "/" + relative
            let (names, complete) = Self.names(in: folder)
            node.opened = true
            node.complete = complete
            var rules = inherited
            if let local = IgnoreRules.read(folder: folder, relative: relative) {
                rules.append(local)
            }
            for name in names where !Self.skipped(name, atTop: depth == 0) {
                examined += 1
                guard examined <= Self.maximumExamined else {
                    node.complete = false
                    truncated = true
                    break
                }
                let childRelative = relative.isEmpty ? name : relative + "/" + name
                var metadata = stat()
                guard lstat(folder + "/" + name, &metadata) == 0 else { continue }
                let kind: Node.Kind = switch metadata.st_mode & S_IFMT {
                case S_IFDIR: .folder
                case S_IFLNK: .link
                default: .file
                }
                if IgnoreRules.ignores(childRelative, isFolder: kind == .folder, rules) {
                    continue
                }
                guard listed < Self.maximumEntries else {
                    node.complete = false
                    truncated = true
                    break
                }
                let child = Node(name: name, kind: kind)
                node.children.append(child)
                listed += 1
                if kind == .folder, depth + 1 < Self.maximumDepth, !(depth == 0 && name == "Attachments") {
                    queue.append((child, childRelative, depth + 1, rules))
                }
            }
        }
        var lines: [String] = []
        Self.render(top, depth: 0, into: &lines)
        self.lines = lines
        self.truncated = truncated
    }

    private static func render(_ node: Node, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        for child in node.children {
            var line = indent + printable(child.name)
            switch child.kind {
            case .folder: line += child.opened ? "/" : "/ …"
            case .link: line += "@"
            case .file: break
            }
            lines.append(line)
            if child.opened {
                render(child, depth: depth + 1, into: &lines)
            }
        }
        if node.opened, !node.complete {
            lines.append(indent + "…")
        }
    }

    /// Left out wherever they are, or at the top only.
    private static func skipped(_ name: String, atTop: Bool) -> Bool {
        if name == ".git" || name == ".DS_Store" {
            return true
        }
        // What the project metadata writer and the file tools write beside a
        // file they replace, for a moment.
        if name.hasPrefix(".apelin-metadata-") || (name.hasPrefix(".") && name.contains(".apelin-")) {
            return true
        }
        return atTop && name == "Builds"
    }

    /// The folder's names, sorted, and whether all of them were read.
    private static func names(in folder: String) -> ([String], Bool) {
        // A folder swapped for a link since it was listed is not followed.
        let descriptor = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return ([], true) }
        guard let directory = fdopendir(descriptor) else {
            close(descriptor)
            return ([], true)
        }
        defer { closedir(directory) }
        var names: [String] = []
        var complete = true
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." {
                continue
            }
            guard names.count < maximumNamesPerFolder else {
                complete = false
                break
            }
            names.append(name)
        }
        return (names.sorted(), complete)
    }

    /// A name on one line: control characters, a line break among them,
    /// become `?`.
    static func printable(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map {
            $0.properties.generalCategory == .control ? "?" : $0
        }))
    }
}

/// One folder's `.gitignore`, read the way git reads one, closely enough to
/// keep the listing short: comments, `!` negation, a trailing `/` for
/// folders only, a pattern with a `/` anchored to the folder, otherwise
/// matched against the name at any depth, and `*`, `?`, `[…]` and `**`.
/// The git tools stay the authority on what the repository tracks.
struct IgnoreRules {
    struct Rule {
        var expression: NSRegularExpression
        var negated: Bool
        var foldersOnly: Bool
        var anchored: Bool
    }

    static let maximumFileBytes = 64 * 1024
    static let maximumRules = 512

    /// The folder this file is in, relative to the project ("" at the top).
    let base: String
    let rules: [Rule]

    static func read(folder: String, relative: String) -> IgnoreRules? {
        let descriptor = open(folder + "/.gitignore", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              let data = try? handle.read(upToCount: maximumFileBytes)
        else { return nil }
        let rules = parse(String(decoding: data, as: UTF8.self))
        return rules.isEmpty ? nil : IgnoreRules(base: relative, rules: rules)
    }

    static func parse(_ text: String) -> [Rule] {
        var rules: [Rule] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(raw)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            while line.hasSuffix(" "), !line.hasSuffix("\\ ") {
                line.removeLast()
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var negated = false
            if line.hasPrefix("!") {
                negated = true
                line.removeFirst()
            } else if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
                line.removeFirst()
            }
            var foldersOnly = false
            if line.hasSuffix("/") {
                foldersOnly = true
                line.removeLast()
            }
            let anchored = line.contains("/")
            if line.hasPrefix("/") {
                line.removeFirst()
            }
            guard !line.isEmpty,
                  let expression = try? NSRegularExpression(pattern: regularExpression(line))
            else { continue }
            rules.append(Rule(expression: expression, negated: negated, foldersOnly: foldersOnly, anchored: anchored))
            if rules.count == maximumRules {
                break
            }
        }
        return rules
    }

    /// Whether `path` (relative to the project) is ignored: every file from
    /// the top down to the deepest, each rule in order, the last match wins.
    static func ignores(_ path: String, isFolder: Bool, _ sets: [IgnoreRules]) -> Bool {
        var ignored = false
        let name = path.split(separator: "/").last.map(String.init) ?? path
        for set in sets {
            let inside = set.base.isEmpty ? path : String(path.dropFirst(set.base.count + 1))
            for rule in set.rules where !rule.foldersOnly || isFolder {
                let subject = rule.anchored ? inside : name
                let range = NSRange(subject.startIndex..., in: subject)
                if rule.expression.firstMatch(in: subject, range: range) != nil {
                    ignored = !rule.negated
                }
            }
        }
        return ignored
    }

    /// The glob as an anchored regular expression: `*` and `?` stay within
    /// one name, a leading `**/` is any folders or none, a trailing `/**`
    /// everything inside, `[!…]` a negated set.
    static func regularExpression(_ glob: String) -> String {
        let characters = Array(glob)
        var pattern = "^"
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                let double = index + 1 < characters.count && characters[index + 1] == "*"
                let atStart = index == 0 || characters[index - 1] == "/"
                if double, atStart, index + 2 < characters.count, characters[index + 2] == "/" {
                    pattern += "(?:.*/)?"
                    index += 3
                    continue
                }
                if double, atStart, index + 2 == characters.count {
                    pattern += ".*"
                    index += 2
                    continue
                }
                pattern += "[^/]*"
                index += double ? 2 : 1
                continue
            case "?":
                pattern += "[^/]"
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]"), close > index + 1 {
                    var set = String(characters[(index + 1) ..< close])
                    if set.hasPrefix("!") {
                        set = "^" + set.dropFirst()
                    }
                    pattern += "[" + set.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "[", with: "\\[") + "]"
                    index = close + 1
                    continue
                }
                pattern += "\\["
            case "\\" where index + 1 < characters.count:
                pattern += NSRegularExpression.escapedPattern(for: String(characters[index + 1]))
                index += 2
                continue
            default:
                pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return pattern + "$"
    }
}
