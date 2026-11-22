import ApelinCore
import Foundation

/// The private data `FeedbackRules` looks for in a public issue's title and
/// body, and what it says when it finds some. apelin-environment answers
/// with `Refusal.reason`, which names the kind and quotes nothing; the
/// agent's tools answer their model with `Refusal.explanation`, which says
/// what matched and where (issue #79: "holds what looks like a device
/// identifier", with nothing named, left the model guessing which words to
/// change). The model wrote the text, so it may read it back, but a tool's
/// answer goes to the provider again and into the journal, so a token or
/// key is shown only by its first characters and its length.
public extension FeedbackRules {
    /// A kind of private data, in the order they are looked for: the first
    /// one a text holds is the one `problem` names.
    enum PrivateKind: Sendable, Equatable, CaseIterable {
        case tokenOrKey
        case homeOrInstallPath
        case deviceName
        case localNetwork
        case deviceIdentifier

        /// How `problem` names it.
        public var reason: String {
            switch self {
            case .tokenOrKey: "a token or key"
            case .homeOrInstallPath: "a home or install path (write ~ for mobile's home)"
            case .deviceName: "this device's name"
            case .localNetwork: "a local network address or name"
            case .deviceIdentifier:
                "what looks like a device identifier (a UDID, serial number or MAC address; a commit hash reads the same, so shorten it)"
            }
        }

        /// What it is, beside what matched.
        public var label: String {
            switch self {
            case .tokenOrKey: "a token or key"
            case .homeOrInstallPath: "a home or install path"
            case .deviceName: "this device's name"
            case .localNetwork: "a local network address or name"
            case .deviceIdentifier: "reads as a device identifier"
            }
        }
    }

    /// One piece of private data found, as the writer of the text may be
    /// shown it.
    struct Match: Sendable, Equatable {
        public enum Place: Sendable, Equatable {
            case title
            /// On this line of the body, from 1.
            case body(line: Int)
        }

        public var kind: PrivateKind
        public var place: Place
        /// What matched: the text itself, or for a token or key its first
        /// characters only.
        public var shown: String
        /// More about it: a token's length, the shape that made a commit
        /// hash or a word read as an identifier.
        public var note: String?

        public init(kind: PrivateKind, place: Place, shown: String, note: String? = nil) {
            self.kind = kind
            self.place = place
            self.shown = shown
            self.note = note
        }

        /// "`3ce304f…` (reads as a device identifier; …) on line 4 of the body".
        public var description: String {
            let details = [kind.label, note].compactMap(\.self).joined(separator: "; ")
            let place = switch place {
            case .title: "in the title"
            case let .body(line): "on line \(line) of the body"
            }
            return "`\(shown)` (\(details)) \(place)"
        }
    }

    /// Why a title and body may not be posted.
    struct Refusal: Sendable, Equatable {
        /// Why, naming the kind of data and never quoting it.
        public var reason: String
        /// The private data found, in the order the text has it; empty when
        /// the text was refused for its shape (empty, too long, two lines).
        public var matches: [Match]

        /// At most this many matches are named; the rest are counted.
        public static let maximumNamed = 8

        public init(_ reason: String, matches: [Match] = []) {
            self.reason = reason
            self.matches = matches
        }

        /// `reason`, then what matched and where, for the one who wrote the
        /// text.
        public var explanation: String {
            guard !matches.isEmpty else { return reason }
            var named = matches.prefix(Self.maximumNamed).map(\.description)
            if matches.count > Self.maximumNamed {
                named.append("and \(matches.count - Self.maximumNamed) more")
            }
            return reason + ". What matched: " + named.joined(separator: "; ")
        }
    }
}

extension FeedbackRules {
    /// A match and where it starts in the text checked (UTF-16 offset).
    struct Found {
        var match: Match
        var offset: Int
        var kind: PrivateKind {
            match.kind
        }
    }

    /// The private data `text` holds, by the shapes every device's takes
    /// (`PrivateShapes`, which a diagnostic log replaces too) and this
    /// device's own paths and names, a kind at a time in `PrivateKind`'s
    /// order, so the first found is the kind `problem` names; a match
    /// inside one found before it is not counted twice. `text` is the
    /// title, a line break and the body, or the body alone when
    /// `titleLength` (UTF-16) is nil.
    static func privateMatches(in text: String, titleLength: Int?, paths: [String], names: [String]) -> [Found] {
        let nsText = text as NSString
        var found: [Found] = []
        var taken: [NSRange] = []
        func add(_ kind: PrivateKind, _ ranges: [NSRange], shown: (String) -> (String, String?)) {
            for range in ranges.sorted(by: { $0.location < $1.location }) {
                guard !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                taken.append(range)
                let (quote, note) = shown(nsText.substring(with: range))
                let place = place(of: range.location, in: nsText, titleLength: titleLength)
                found.append(Found(match: Match(kind: kind, place: place, shown: quote, note: note), offset: range.location))
            }
        }
        func ranges(_ expression: NSRegularExpression) -> [NSRange] {
            PrivateShapes.ranges(expression, in: text)
        }

        add(.tokenOrKey, ranges(PrivateShapes.credential), shown: tokenShown)
        add(.tokenOrKey, ranges(PrivateShapes.bearer), shown: bearerShown)
        add(.tokenOrKey, ranges(PrivateShapes.privateKey), shown: privateKeyShown)
        // `/var/jb`, rootless's install root, is every rootless device's.
        let ownPaths = paths.filter { $0.count > 1 && $0 != "/var/jb" }
        add(.homeOrInstallPath, ranges(PrivateShapes.homePath) + ownPaths.flatMap { occurrences(of: $0, in: text) }, shown: wholeShown)
        let ownNames = names.filter(PrivateShapes.isOwnName)
        add(.deviceName, ownNames.flatMap { PrivateShapes.ranges(ofWord: $0, in: text) }, shown: wholeShown)
        add(
            .localNetwork,
            ranges(PrivateShapes.localName) + ranges(PrivateShapes.localIPv6) + PrivateShapes.localIPv4(in: text),
            shown: wholeShown,
        )
        add(.deviceIdentifier, ranges(PrivateShapes.deviceIdentifier), shown: identifierShown)
        return found
    }

    /// The title, or the body's line, `offset` falls in.
    private static func place(of offset: Int, in text: NSString, titleLength: Int?) -> Match.Place {
        if let titleLength, offset < titleLength {
            return .title
        }
        // The body starts after the title and the line break joining them.
        let start = titleLength.map { $0 + 1 } ?? 0
        let before = text.substring(with: NSRange(location: start, length: max(0, offset - start)))
        return .body(line: before.utf16.filter { $0 == 0x0A }.count + 1)
    }

    /// Every place `path` stands in `text`, whatever its case.
    private static func occurrences(of path: String, in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var searched = text.startIndex ..< text.endIndex
        while let found = text.range(of: path, options: .caseInsensitive, range: searched) {
            ranges.append(NSRange(found, in: text))
            searched = found.upperBound ..< text.endIndex
        }
        return ranges
    }

    /// Longer text is cut, so one long path does not fill the answer.
    static let longestShown = 100

    private static func wholeShown(_ matched: String) -> (String, String?) {
        guard matched.count > longestShown else { return (matched, nil) }
        return (String(matched.prefix(longestShown - 1)) + "…", nil)
    }

    /// A token by its first four characters, which its prefix (`ghp_`,
    /// `sk-`, `eyJ`) mostly is, and its length.
    private static func tokenShown(_ matched: String) -> (String, String?) {
        (String(matched.prefix(4)) + "…", "\(matched.count) characters; only its start is shown")
    }

    /// The word that names a Bearer or Basic credential, never the
    /// credential.
    private static func bearerShown(_ matched: String) -> (String, String?) {
        let word = matched.prefix { !$0.isWhitespace }
        let credential = matched.dropFirst(word.count).drop(while: \.isWhitespace)
        return ("\(word) …", "a credential of \(credential.count) characters after it, not shown")
    }

    /// A private key by its first line, which holds none of the key.
    private static func privateKeyShown(_ matched: String) -> (String, String?) {
        let header = matched.range(of: "PRIVATE KEY-----").map { String(matched[..<$0.upperBound]) } ?? "-----BEGIN"
        return (header, "the key after it is not shown")
    }

    /// An identifier whole, with what shape of it matched: a commit hash
    /// and a word of capitals and digits read as one too.
    private static func identifierShown(_ matched: String) -> (String, String?) {
        let note: String? = if matched.count == 40, matched.allSatisfy(\.isHexDigit) {
            "40 hex digits, as a commit hash is written: give a commit by its first 7 to 12"
        } else if matched.count <= 12, !matched.contains(where: { $0 == ":" || $0 == "-" }) {
            "10 to 12 capital letters and digits, as an Apple serial number is written"
        } else {
            nil
        }
        return (matched, note)
    }
}
