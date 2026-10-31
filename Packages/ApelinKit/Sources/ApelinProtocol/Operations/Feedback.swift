import ApelinCore
import Foundation

/// What feedback filed on Apelin's own repository may say (`feedbackSend`,
/// the agent's `apelin_feedback_send`; owner, 2026-10-29). It is a public
/// issue under the user's GitHub account, so the repository is fixed here,
/// never a request's, and the title and body are checked — by the agent
/// before it asks, by apelin-environment again before it posts, with this
/// device's own paths and name — for what would say which device sent it
/// or let someone in: a home or install path, a local network address or
/// name, a device identifier, a token or key. The check reads shapes; it
/// cannot prove a text holds nothing private, which is why Strict shows the
/// user the whole text first. Below the body apelin-environment writes
/// `footer`: Apelin's version, the iOS version and the bootstrap, naming
/// no device. An edit of an issue the account opened (`feedbackEdit`;
/// owner, 2026-10-30) checks the title or body it puts in the same way,
/// and keeps below the body the footer the issue had (`split`).
public enum FeedbackRules {
    public static let repository = "owngoal-dev/Apelin"
    public static let maximumTitleLength = 120
    public static let maximumBodyBytes = 16 * 1024

    /// Nil when the title and body may be posted, else why not, naming the
    /// kind of data and never quoting it. `paths` are this device's own
    /// (mobile's home, the install root) and `names` what it calls itself
    /// (its host name), beside the shapes every device's have.
    public static func problem(title: String, body: String, paths: [String] = [], names: [String] = []) -> String? {
        textProblem(title: title, body: body, paths: paths, names: names)
    }

    /// For an edit: nil when the new title, the new body or both may be put
    /// in, else why not, as `problem` says it; nil stands for a field that
    /// stays. Only what changes is read, so words the user wrote on GitHub
    /// themselves never hold an edit up. A body that ends with Apelin's
    /// footer is refused: the footer the issue has stays below it.
    public static func editProblem(title: String?, body: String?, paths: [String] = [], names: [String] = []) -> String? {
        guard title != nil || body != nil else {
            return "it changes neither the title nor the body"
        }
        if let body, split(issueBody: body).footer != nil {
            return "the body ends with the line Apelin adds below it, which stays as it is: leave it out"
        }
        return textProblem(title: title, body: body, paths: paths, names: names)
    }

    private static func textProblem(title: String?, body: String?, paths: [String], names: [String]) -> String? {
        var parts: [String] = []
        if let title {
            let heading = title.trimmingCharacters(in: .whitespaces)
            guard !heading.isEmpty else { return "the title is empty" }
            guard heading.count <= maximumTitleLength, !heading.contains(where: \.isNewline) else {
                return "the title is one line of at most \(maximumTitleLength) characters"
            }
            parts.append(heading)
        }
        if let body {
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "the body is empty" }
            guard body.utf8.count <= maximumBodyBytes else { return "the body is at most \(maximumBodyBytes / 1024) KB" }
            parts.append(body)
        }
        let text = parts.joined(separator: "\n")
        guard !text.unicodeScalars.contains("\0") else { return "the title or body holds a NUL character" }
        guard let kind = privateKind(in: text, paths: paths, names: names) else { return nil }
        return "the title or body holds \(kind), which a public issue must not carry: leave it out and send again"
    }

    /// The line apelin-environment writes below the body: only what a report
    /// needs to be reproduced, never the device's name, model or identifier.
    public static func footer(appVersion: String?, appBuild: String?, osVersion: String, bootstrap: BuildBootstrap) -> String {
        var apelin = "Apelin " + (appVersion ?? "(version unknown)")
        if appVersion != nil, let appBuild {
            apelin += " (\(appBuild))"
        }
        return "Sent with \(apelin) · iOS \(osVersion) · \(bootstrap.rawValue)"
    }

    /// The issue's body: the text as given, then a rule and the footer.
    public static func issueBody(_ body: String, footer: String) -> String {
        trimmingTrailingWhitespace(body) + "\n\n---\n" + footer
    }

    /// An issue's body as feedback reads it: what was written, and the
    /// footer `issueBody` put below it while the body still ends with it.
    public struct IssueBody: Sendable, Equatable {
        /// The body without the footer.
        public var text: String
        /// The footer's line, nil when the body does not end with one.
        public var footer: String?
        /// The rule and the footer exactly as the body ends with them,
        /// GitHub's line ends included; empty without a footer.
        public var tail: String

        /// The body with `text` in place of what was written, and the
        /// footer as it was, never written again with this device's version.
        public func replacingText(_ text: String) -> String {
            tail.isEmpty ? text : FeedbackRules.trimmingTrailingWhitespace(text) + tail
        }
    }

    /// `body` split at the footer it ends with: a rule on a line of its own
    /// after a blank line, then `Sent with Apelin … · iOS … · <bootstrap>`,
    /// with `\n` or GitHub's `\r\n` line ends.
    public static func split(issueBody body: String) -> IssueBody {
        guard let match = footerPattern.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let whole = Range(match.range, in: body), let line = Range(match.range(at: 1), in: body)
        else { return IssueBody(text: body, footer: nil, tail: "") }
        return IssueBody(text: String(body[..<whole.lowerBound]), footer: String(body[line]), tail: String(body[whole]))
    }

    private static let footerPattern = pattern(
        #"(?:\r?\n){2}---[ \t]*\r?\n(Sent with Apelin [^\r\n]* · iOS [^\r\n]* · (?:"#
            + BuildBootstrap.allCases.map(\.rawValue).joined(separator: "|")
            + #"))[ \t\r\n]*\z"#,
    )

    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var text = text
        while text.last?.isWhitespace == true {
            text.removeLast()
        }
        return text
    }

    // MARK: Private data

    /// The kind of private data `text` holds, by the shapes every device's
    /// takes (`PrivateShapes`, which a diagnostic log replaces too) and
    /// this device's own paths and names.
    private static func privateKind(in text: String, paths: [String], names: [String]) -> String? {
        if PrivateShapes.matches(PrivateShapes.credential, text) || PrivateShapes.matches(PrivateShapes.bearer, text)
            || PrivateShapes.matches(PrivateShapes.privateKey, text)
        {
            return "a token or key"
        }
        let lowered = text.lowercased()
        // `/var/jb`, rootless's install root, is every rootless device's.
        let ownPaths = paths.filter { $0.count > 1 && $0 != "/var/jb" }
        if PrivateShapes.matches(PrivateShapes.homePath, text) || ownPaths.contains(where: { lowered.contains($0.lowercased()) }) {
            return "a home or install path (write ~ for mobile's home)"
        }
        if names.contains(where: { PrivateShapes.isOwnName($0) && !PrivateShapes.ranges(ofWord: $0, in: text).isEmpty }) {
            return "this device's name"
        }
        if PrivateShapes.matches(PrivateShapes.localName, text) || PrivateShapes.matches(PrivateShapes.localIPv6, text)
            || !PrivateShapes.localIPv4(in: text).isEmpty
        {
            return "a local network address or name"
        }
        if PrivateShapes.matches(PrivateShapes.deviceIdentifier, text) {
            return "what looks like a device identifier (a UDID, serial number or MAC address; a commit hash reads the same, so shorten it)"
        }
        return nil
    }

    private static func pattern(_ text: String) -> NSRegularExpression {
        // The patterns are constants; one that does not compile is a bug
        // the tests catch.
        try! NSRegularExpression(pattern: text)
    }
}
