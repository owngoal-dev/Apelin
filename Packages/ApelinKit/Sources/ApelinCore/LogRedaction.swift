import Foundation

/// What a diagnostic log may keep of a text: credentials, e-mail addresses
/// and the paths that name this device's install taken out, then cut to a
/// bound that says how long the text was. A log is shared to report a
/// problem, so the agent's journals and the app's own lines about a
/// conversation run every text through this before it is written.
///
/// It goes by shapes — the ones `FeedbackRules` refuses in an issue, the
/// keys of the providers Apelin signs in to, what names a secret — and
/// proves nothing; a key of a shape it does not know goes through.
public struct LogRedaction: Sendable {
    /// Paths this device's own install is at, longest first, each with what
    /// stands for it: mobile's home and the install root.
    private let places: [(path: String, placeholder: String)]

    public static let redacted = "<redacted>"

    /// `home` is mobile's home; `installRoot` the install root, rootless's
    /// `/var/jb` being every rootless device's and left as it is.
    public init(home: String?, installRoot: String?) {
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
    }

    /// `text` redacted and cut to `limit` bytes of UTF-8, marked with how
    /// long it was. A long text is redacted only as far as could be kept —
    /// 64 times `limit`, which nothing redaction takes out brings back
    /// within it — so a megabyte of output costs no more than its head.
    public func text(_ text: String, limit: Int) -> String {
        let total = text.utf8.count
        let head = total > limit * 64 ? Self.prefix(of: text, bytes: limit * 64) : text
        let kept = redacted(head)
        guard kept.utf8.count > limit || head.utf8.count < total else { return kept }
        return Self.prefix(of: kept, bytes: limit) + Self.cut(from: total)
    }

    /// `text` with credentials, e-mail addresses and this device's paths
    /// replaced.
    public func redacted(_ text: String) -> String {
        var text = Self.replacing(Self.rules, in: text)
        for place in places {
            text = text.replacingOccurrences(of: place.path, with: place.placeholder)
        }
        return Self.replacing(Self.pathRules, in: text)
    }

    /// `text` within `limit` bytes of UTF-8, cut on a character and marked
    /// with how long it was: `… [truncated from 18,342 bytes]`.
    public static func truncated(_ text: String, limit: Int) -> String {
        let total = text.utf8.count
        guard total > limit else { return text }
        return prefix(of: text, bytes: limit) + cut(from: total)
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

    // MARK: - Patterns

    private struct Rule: @unchecked Sendable {
        let expression: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String) {
            // The patterns are constants; one that does not compile is a bug
            // the tests catch.
            expression = try! NSRegularExpression(pattern: pattern)
            self.template = template
        }
    }

    private static func replacing(_ rules: [Rule], in text: String) -> String {
        rules.reduce(text) { text, rule in
            rule.expression.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: rule.template,
            )
        }
    }

    /// Credentials by their shape, by the header or field that names them,
    /// in an address; then e-mail addresses.
    private static let rules: [Rule] = [
        Rule(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#, "<private key>"),
        Rule(#"(?i)\b(bearer|basic)(\s+)[A-Za-z0-9._~+/=-]{12,}"#, "$1$2<redacted>"),
        Rule(
            #"(?i)(?<![A-Za-z0-9])("?(?:authorization|x-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|id[-_]?token"#
                + #"|client[-_]?secret|password|passwd|secret|token)"?\s*[:=]\s*"?)[^\s"',;&}\]]{4,}"#,
            "$1<redacted>",
        ),
        Rule(
            #"gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|(?<![\w-])sk-[A-Za-z0-9_-]{12,}|oc_sk_[A-Za-z0-9_-]{8,}"#
                + #"|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}"#
                + #"|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*"#,
            "<redacted>",
        ),
        // a user and password in an address
        Rule(#"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, "$1<redacted>@"),
        // a domain starts with a letter: `icon@2x.png` is a file
        Rule(#"[A-Za-z0-9._%+-]+@[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#, "<email>"),
    ]

    /// Homes and the folders named for one install, after this device's
    /// own: mobile's and root's homes, roothide's jbroot (named for its
    /// install), an app's container, a Mac's home.
    private static let pathRules: [Rule] = [
        Rule(#"(?:/private)?/var/mobile(?![\w.-])"#, "~"),
        Rule(#"(?:/private)?/var/root(?![\w.-])"#, "<root home>"),
        Rule(#"\.jbroot-[A-Za-z0-9]+"#, ".jbroot-<id>"),
        Rule(#"(/var/containers/(?:Bundle|Data|Shared)/[A-Za-z]+/)[0-9A-Fa-f-]{36}"#, "$1<id>"),
        Rule(#"/Users/[^/\s"']+"#, "/Users/<user>"),
    ]
}
