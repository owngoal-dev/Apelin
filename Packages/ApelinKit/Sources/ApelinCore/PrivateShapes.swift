import Foundation

/// The shapes private data takes in a text: credentials, homes and the
/// paths one install is named by, local network addresses and names, and
/// device identifiers. Feedback refuses a text that holds one
/// (`FeedbackRules`); a diagnostic log replaces each (`LogRedaction`). They
/// read shapes and prove nothing.
///
/// Every pattern runs in time linear in the text: each starts only at the
/// left edge of a run of the characters it reads (a lookbehind) and every
/// repetition is bounded, so a long run that is no match — a hex dump, a
/// base64 blob — is read once, never from each of its characters again.
public enum PrivateShapes {
    /// Keys and tokens by their shape: GitHub's, OpenAI's and Anthropic's
    /// `sk-`, Stripe's live and test keys, OpenCode's, xAI's, GitLab's,
    /// Hugging Face's, Groq's, npm's, AWS access key IDs, Slack's, Google's
    /// and JSON Web Tokens.
    public static let credential = pattern(
        #"(?<![A-Za-z0-9_-])(?:gh[pousr]_[A-Za-z0-9]{16,255}|github_pat_[A-Za-z0-9_]{16,255}"#
            + #"|sk-[A-Za-z0-9_-]{12,255}|[sr]k_(?:live|test)_[A-Za-z0-9]{16,255}|oc_sk_[A-Za-z0-9_-]{8,255}"#
            + #"|xai-[A-Za-z0-9]{20,255}|glpat-[A-Za-z0-9_-]{20,255}|hf_[A-Za-z0-9]{20,255}|gsk_[A-Za-z0-9]{20,255}"#
            + #"|npm_[A-Za-z0-9]{30,255}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,255}|AIza[0-9A-Za-z_-]{35}"#
            + #"|eyJ[A-Za-z0-9_-]{10,4096}\.[A-Za-z0-9_-]{10,4096}\.[A-Za-z0-9_-]{0,4096})"#,
    )

    /// A Bearer or Basic credential after the word that names it: `$1`
    /// the word, `$2` the space.
    public static let bearer = pattern(#"(?i)(?<![A-Za-z0-9_-])(bearer|basic)([ \t]{1,4})[A-Za-z0-9._~+/=-]{12,4096}"#)

    /// A private key, from its first line to its last, or to the end of a
    /// text cut short.
    public static let privateKey = pattern(
        #"-----BEGIN [A-Z ]{0,32}PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]{0,32}PRIVATE KEY-----|$)"#,
    )

    /// Mobile's and root's homes, an app's container, roothide's jbroot
    /// (named for its install), the preboot volume rootless lives in, a
    /// Mac's or Linux's home.
    public static let homePath = pattern(
        #"/var/(?:mobile|root)(?![\w.-])|/var/containers/|\.jbroot-|/private/preboot/|/Users/[^/\s]{1,255}|/home/[^/\s]{1,255}"#,
    )

    /// A name on the local network, as mDNS and home routers spell them.
    public static let localName = pattern(
        #"(?i)(?<![A-Za-z0-9.-])[a-z0-9-]{1,63}(?:\.[a-z0-9-]{1,63}){0,8}\.(?:local|lan|home\.arpa)(?![\w-]|\.[\w-])"#,
    )

    /// A link-local or unique local IPv6 address, with its zone.
    public static let localIPv6 = pattern(
        #"(?i)(?<![0-9a-f:])(?:fe80|f[cd][0-9a-f]{2})(?::{1,2}[0-9a-f]{0,4}){1,8}(?:%[A-Za-z0-9]{1,16})?"#,
    )

    /// Any dotted IPv4 address; `localIPv4` says which are local.
    public static let ipv4 = pattern(#"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?!\d|\.\d)"#)

    /// A UDID (40 hex digits, or 8 and 16 since 2018), an Apple serial
    /// number (10 to 12 capital letters and digits, two of each at least,
    /// never the end of a UUID) or a MAC address.
    public static let deviceIdentifier = pattern(
        #"(?<![0-9A-Fa-f])[0-9A-Fa-f]{40}(?![0-9A-Fa-f])|(?<![0-9A-Fa-f-])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}(?![0-9A-Fa-f-])"#
            + #"|(?<![A-Za-z0-9_-])(?=(?:[A-Z]{0,12}[0-9]){2})(?=(?:[0-9]{0,12}[A-Z]){2})[A-Z0-9]{10,12}(?![A-Za-z0-9_-])"#
            + #"|(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])"#,
    )

    /// The ranges of `text` that are IPv4 addresses of a local network:
    /// 10/8, 172.16/12, 192.168/16, link-local 169.254/16 and the shared
    /// 100.64/10 a VPN's tailnet hands out.
    public static func localIPv4(in text: String) -> [NSRange] {
        ipv4.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { match in
            let octets = (1 ... 4).compactMap { index in
                Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
            }
            return octets.count == 4 && isLocal(octets)
        }.map(\.range)
    }

    /// Whether `host` names this network or this machine: localhost, a
    /// name with no dot or a local suffix, a loopback, local or link-local
    /// address.
    public static func isLocalHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if name.isEmpty || name == "localhost" || name == "::1" || !name.contains(where: { $0 == "." || $0 == ":" }) {
            return true
        }
        if [".local", ".lan", ".home.arpa", ".localhost", ".internal"].contains(where: { name.hasSuffix($0) }) {
            return true
        }
        let octets = name.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if octets.count == 4, octets.allSatisfy({ $0 != nil }) {
            let numbers = octets.compactMap(\.self)
            return numbers[0] == 127 || isLocal(numbers)
        }
        return matches(localIPv6, name)
    }

    /// A host name that names this device, not every device of its kind.
    public static func isOwnName(_ name: String) -> Bool {
        name.count >= 3 && !["localhost", "iphone", "ipad", "ipod", "ipod-touch"].contains(name.lowercased())
    }

    /// The ranges where `word` stands in `text` as a word of its own,
    /// whatever its case.
    public static func ranges(ofWord word: String, in text: String) -> [NSRange] {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard let expression = try? NSRegularExpression(pattern: #"(?i)(?<![\w-])"# + escaped + #"(?![\w-])"#) else {
            return []
        }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    public static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// What this device calls itself on the network, without `.local`.
    public static func currentHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        var name = String(cString: buffer)
        if name.lowercased().hasSuffix(".local") {
            name.removeLast(".local".count)
        }
        return name.isEmpty ? nil : name
    }

    private static func isLocal(_ octets: [Int]) -> Bool {
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return false }
        return switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): true
        case (172, 16 ... 31), (100, 64 ... 127): true
        default: false
        }
    }

    static func pattern(_ text: String) -> NSRegularExpression {
        // The patterns are constants; one that does not compile is a bug
        // the tests catch.
        try! NSRegularExpression(pattern: text)
    }
}
