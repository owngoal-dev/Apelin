import Foundation

/// What a diagnostic log may keep of a text: credentials, e-mail
/// addresses, the paths that name this device's install, local network
/// addresses and names and device identifiers taken out, then cut to a
/// bound that says how long the text was. A log is shared to report a
/// problem, so the agent's journals and the app's own lines about a
/// conversation run every text through this before it is written.
///
/// It goes by shapes (`PrivateShapes`, which feedback refuses too) and by
/// what names a secret (`isSecretName`: a field, a header, an environment
/// variable or a command line's option), and proves nothing; a key of a
/// shape it does not know, under a name that says nothing, goes through.
/// Every rule runs in time linear in the text, and a long text is redacted
/// only as far as it could be kept.
public struct LogRedaction: Sendable {
    /// Paths this device's own install is at, longest first, each with what
    /// stands for it: mobile's home and the install root.
    private let places: [(path: String, placeholder: String)]
    /// What this device calls itself on the network.
    private let names: [String]

    public static let redacted = "<redacted>"
    /// How much of a text past its bound is redacted before it is cut: the
    /// bound this many times over, which nothing redaction takes out
    /// brings back within it.
    static let headRatio = 4

    /// `home` is mobile's home; `installRoot` the install root, rootless's
    /// `/var/jb` being every rootless device's and left as it is; `names`
    /// what the device calls itself (`PrivateShapes.currentHostName`).
    public init(home: String?, installRoot: String?, names: [String] = []) {
        var places: [(String, String)] = []
        if let home, home.count > 1 {
            places.append((home, "~"))
            places.append(("/private" + home, "~"))
        }
        if let installRoot, installRoot.count > 1, installRoot != "/var/jb" {
            places.append((installRoot, "<install root>"))
            places.append(("/private" + installRoot, "<install root>"))
        }
        self.places = places.sorted { $0.0.count > $1.0.count }
        self.names = names.filter(PrivateShapes.isOwnName)
    }

    /// `text` redacted, then cut to `limit` bytes of UTF-8 and marked with
    /// how long it was. Only its head — `headRatio` times `limit`, ending
    /// where a word does — is read: a megabyte of output costs no more than
    /// a few kilobytes, and no secret is split where it is cut.
    public func text(_ text: String, limit: Int) -> String {
        let total = text.utf8.count
        let head = Self.head(of: text, bytes: limit * Self.headRatio)
        let kept = redacted(head)
        guard kept.utf8.count > limit || head.utf8.count < total else { return kept }
        return Self.prefix(of: kept, bytes: limit) + Self.cut(from: total)
    }

    /// `text` with every credential, e-mail address, path of this install,
    /// local address and name and device identifier replaced.
    public func redacted(_ text: String) -> String {
        var text = Self.replacing(PrivateShapes.privateKey, in: text, with: "<private key>")
        text = Self.replacing(PrivateShapes.bearer, in: text, with: "$1$2" + Self.redacted)
        text = Self.maskingValues(in: text, after: Self.assignment, header: true)
        text = Self.maskingValues(in: text, after: Self.option, header: false)
        text = Self.maskingValues(in: text, after: Self.userOption, header: false, named: false)
        text = Self.replacing(PrivateShapes.credential, in: text, with: Self.redacted)
        text = Self.replacing(Self.userInfo, in: text, with: "$1" + Self.redacted + "@")
        text = Self.replacing(Self.email, in: text, with: "<email>")
        for place in places {
            text = text.replacingOccurrences(of: place.path, with: place.placeholder)
        }
        for rule in Self.pathRules {
            text = Self.replacing(rule.expression, in: text, with: rule.template)
        }
        text = Self.replacing(PrivateShapes.deviceIdentifier, in: text, with: "<device id>")
        text = Self.replacing(PrivateShapes.localIPv6, in: text, with: "<local address>")
        text = Self.replacing(PrivateShapes.localIPv4(in: text), in: text, with: "<local address>")
        text = Self.replacing(PrivateShapes.localName, in: text, with: "<local name>")
        for name in names {
            text = Self.replacing(PrivateShapes.ranges(ofWord: name, in: text), in: text, with: "<device name>")
        }
        return text
    }

    /// `text` within `limit` bytes of UTF-8, cut on a character and marked
    /// with how long it was: `… [truncated from 18,342 bytes]`.
    public static func truncated(_ text: String, limit: Int) -> String {
        let total = text.utf8.count
        guard total > limit else { return text }
        return prefix(of: text, bytes: limit) + cut(from: total)
    }

    /// `number` with a comma every three digits, whatever the locale: a
    /// log is read by whoever it is sent to.
    public static func grouped(_ number: Int) -> String {
        let digits = String(number.magnitude)
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 {
                out.append(",")
            }
            out.append(digit)
        }
        return number < 0 ? "-" + out : out
    }

    // MARK: - What names a secret

    /// Whether a field, header, variable or option of this name holds a
    /// credential, read word by word whatever its spelling (`authToken`,
    /// `AWS_SECRET_ACCESS_KEY`, `x-api-key`, `--password`): one of the
    /// words is a token, password, pass, passphrase, secret, credential,
    /// cookie, authorization or auth, the last is key, or the name is an
    /// OAuth `access` or `refresh` alone. `max_tokens` counts them.
    public static func isSecretName(_ name: String) -> Bool {
        let words = words(of: name)
        guard let last = words.last else { return false }
        if words.count == 1, ["access", "refresh"].contains(last) {
            return true
        }
        let secret: Set<String> = [
            "token", "password", "passwd", "passphrase", "pwd", "pass", "secret", "secrets", "credential",
            "credentials", "cookie", "authorization", "auth", "apikey", "privatekey", "accesskey",
        ]
        return last == "key" || words.contains(where: secret.contains)
    }

    /// `name`'s words, lowercased: split at anything not a letter or digit
    /// and where a capital starts a word (`apiKey`, `APIKey`).
    static func words(of name: String) -> [String] {
        var words: [String] = []
        var word = ""
        let characters = Array(name)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !word.isEmpty {
                    words.append(word)
                }
                word = ""
                continue
            }
            if character.isUppercase, let previous = word.last {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && next?.isLowercase == true) {
                    words.append(word)
                    word = ""
                }
            }
            word.append(character)
        }
        if !word.isEmpty {
            words.append(word)
        }
        return words.map { $0.lowercased() }
    }

    // MARK: - Values after a name

    /// `name: value`, `name=value`, `"name": "value"` and, inside JSON
    /// written as a string, `\"name\":\"value\"`: `$1` the name.
    private static let assignment = PrivateShapes.pattern(
        #"(?<![A-Za-z0-9_.-])([A-Za-z][A-Za-z0-9_.-]{0,63})\\?["']?[ \t]{0,4}[:=][ \t]{0,4}"#,
    )

    /// A command line's `--name value` or `--name=value`: `$1` the name.
    private static let option = PrivateShapes.pattern(
        #"(?<![A-Za-z0-9_-])--([A-Za-z][A-Za-z0-9_-]{0,63})(?:=|[ \t]{1,4})"#,
    )

    /// curl's `-u user:password` and `--user user:password`, up to the
    /// password.
    private static let userOption = PrivateShapes.pattern(
        #"(?<![A-Za-z0-9_-])(?:-u|--user)[ \t]{1,4}["']?[^\s:"']{1,256}:"#,
    )

    /// Headers whose whole value is the credential, to the end of the line.
    private static let credentialHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key", "x-auth-token",
    ]

    /// The longest value read after a name.
    private static let valueLimit = 4096

    /// Replaces the value after each of `expression`'s matches whose name
    /// (`$1`) names a secret, or after every match when `named` is false:
    /// a quoted value to its closing quote — `\"`, `"` or `'` —, a header's
    /// to the end of the line, any other to the next space, quote or
    /// separator. A value that opens an object or a list is left: its own
    /// fields are read by their names.
    private static func maskingValues(
        in text: String,
        after expression: NSRegularExpression,
        header: Bool,
        named: Bool = true,
    ) -> String {
        let source = text as NSString
        var masks: [NSRange] = []
        var after = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let start = match.range.location + match.range.length
            guard match.range.location >= after else { continue }
            var name = ""
            if named {
                name = source.substring(with: match.range(at: 1))
                guard isSecretName(name) else { continue }
            }
            let isHeader = header && credentialHeaders.contains(name.lowercased())
                && source.substring(with: match.range).contains(":")
            guard let value = valueRange(in: source, at: start, toLineEnd: isHeader) else { continue }
            masks.append(value)
            after = value.location + value.length
        }
        guard !masks.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for range in masks.reversed() {
            out.replaceCharacters(in: range, with: Self.redacted)
        }
        return out as String
    }

    /// The value at `start`: inside its quotes when it is quoted, else up
    /// to a space, quote or separator (or the line's end for a header);
    /// nil for none, an empty one, or one that opens an object or list.
    private static func valueRange(in text: NSString, at start: Int, toLineEnd: Bool) -> NSRange? {
        let length = text.length
        guard start < length else { return nil }
        let first = text.character(at: start)
        let backslash: unichar = 0x5C, quote: unichar = 0x22, apostrophe: unichar = 0x27
        var open = start
        var closing: [unichar] = []
        if first == backslash, start + 1 < length, text.character(at: start + 1) == quote {
            open = start + 2
            closing = [backslash, quote]
        } else if first == quote || first == apostrophe {
            open = start + 1
            closing = [first]
        } else if [0x7B, 0x5B, 0x28].contains(first) {
            return nil
        } else if first == 0x3C, isPlaceholder(in: text, at: start) {
            // already taken out by an earlier rule
            return nil
        }
        let end = min(length, open + valueLimit)
        var index = open
        while index < end {
            let character = text.character(at: index)
            if closing.isEmpty {
                if character == 0x0A || character == 0x0D {
                    break
                }
                // a header written inside a quoted argument ends with it
                if toLineEnd ? isQuote(character) : isValueEnd(character) {
                    break
                }
            } else if closing.count == 2 {
                if character == backslash, index + 1 < length, text.character(at: index + 1) == quote {
                    break
                }
            } else if character == closing[0], index == open || text.character(at: index - 1) != backslash {
                break
            }
            index += 1
        }
        return index > open ? NSRange(location: open, length: index - open) : nil
    }

    private static func isQuote(_ character: unichar) -> Bool {
        character == 0x22 || character == 0x27 || character == 0x5C
    }

    /// Whether a placeholder this redaction writes, `<redacted>`, `<email>`,
    /// `<local address>` and the like, starts at `start`.
    private static func isPlaceholder(in text: NSString, at start: Int) -> Bool {
        let window = text.substring(with: NSRange(location: start, length: min(32, text.length - start)))
        return window.range(of: #"^<[a-z][a-z ]{0,30}>"#, options: .regularExpression) != nil
    }

    private static func isValueEnd(_ character: unichar) -> Bool {
        // space, tab, quotes, and , ; & } ] ) >
        [0x20, 0x09, 0x22, 0x27, 0x2C, 0x3B, 0x26, 0x7D, 0x5D, 0x29, 0x3E, 0x5C].contains(character)
    }

    // MARK: - Patterns

    /// A user and password in an address: `$1` the scheme.
    private static let userInfo = PrivateShapes.pattern(
        #"(?i)(?<![a-z0-9+.-])([a-z][a-z0-9+.-]{0,31}://)[^/\s:@]{1,256}:[^/\s@]{1,256}@"#,
    )

    /// An e-mail address. A domain starts with a letter: `icon@2x.png` is
    /// a file.
    private static let email = PrivateShapes.pattern(
        #"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]{1,64}@[A-Za-z][A-Za-z0-9-]{0,62}(?:\.[A-Za-z0-9-]{1,63}){0,8}\.[A-Za-z]{2,24}"#,
    )

    private struct Rule: @unchecked Sendable {
        let expression: NSRegularExpression
        let template: String
    }

    /// Homes and the folders named for one install, after this device's
    /// own: mobile's and root's homes, roothide's jbroot (named for its
    /// install), the preboot volume and the folder rootless's bootstrap
    /// lives in, an app's container, a Mac's or Linux's home.
    private static let pathRules: [Rule] = [
        Rule(expression: PrivateShapes.pattern(#"(?:/private)?/var/mobile(?![\w.-])"#), template: "~"),
        Rule(expression: PrivateShapes.pattern(#"(?:/private)?/var/root(?![\w.-])"#), template: "<root home>"),
        Rule(expression: PrivateShapes.pattern(#"\.jbroot-[A-Za-z0-9]{1,64}"#), template: ".jbroot-<id>"),
        Rule(expression: PrivateShapes.pattern(#"(?:/private)?/preboot/[0-9A-Fa-f-]{16,64}"#), template: "/private/preboot/<id>"),
        Rule(expression: PrivateShapes.pattern(#"/((?:jb|dopamine)-)[A-Za-z0-9]{4,64}"#), template: "/$1<id>"),
        Rule(
            expression: PrivateShapes.pattern(#"(/var/containers/(?:Bundle|Data|Shared)/[A-Za-z]{1,32}/)[0-9A-Fa-f-]{36}"#),
            template: "$1<id>",
        ),
        Rule(expression: PrivateShapes.pattern(#"/Users/[^/\s"']{1,255}"#), template: "/Users/<user>"),
        Rule(expression: PrivateShapes.pattern(#"/home/[^/\s"']{1,255}"#), template: "/home/<user>"),
    ]

    private static func replacing(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template,
        )
    }

    private static func replacing(_ ranges: [NSRange], in text: String, with replacement: String) -> String {
        guard !ranges.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            out.replaceCharacters(in: range, with: replacement)
        }
        return out as String
    }

    // MARK: - Cutting

    /// What of `text` is read: all of it within `bytes`, else its first
    /// `bytes` ending after the last space or separator in their second
    /// half, so that no token is split where it is cut.
    private static func head(of text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        let head = prefix(of: text, bytes: bytes)
        let half = head.index(head.startIndex, offsetBy: head.count / 2)
        guard let edge = head[half...].lastIndex(where: { $0.isWhitespace || ",;&\"'".contains($0) }) else {
            return head
        }
        return String(head[...edge])
    }

    /// The characters of `text` that fit in `bytes` bytes of UTF-8.
    private static func prefix(of text: String, bytes: Int) -> String {
        var kept = 0
        var end = text.startIndex
        for index in text.indices {
            let next = kept + text[index].utf8.count
            guard next <= bytes else { break }
            kept = next
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    private static func cut(from total: Int) -> String {
        "… [truncated from \(grouped(total)) bytes]"
    }
}
