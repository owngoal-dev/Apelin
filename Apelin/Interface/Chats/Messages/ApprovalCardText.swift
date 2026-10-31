import ApelinCore
import ApelinProtocol
import Foundation

/// What a pending approval's card says under its title, from the session's
/// `approvalRequested` and the call's own `toolCall`: why the agent made the
/// call (its `reason`), why the gate asks, a changed description's diff,
/// then the arguments by name (`ToolCallDetail`). A shell_run's argv reads
/// as the command line (`CommandLineText`). For a command as root the red
/// line on the card already says what the gate's sentence and the `root`
/// argument would, so both are left out. Display only: the approval stays
/// bound to what the host reads, `detail.command` or `detail.rootCommand`
/// and the working directory.
enum ApprovalCardText {
    struct Section: Hashable {
        var title: String?
        var text: String
        var isCode = false
    }

    static func sections(_ payload: JSONValue?, title: String, callReason: String?) -> [Section] {
        let root = isRoot(payload)
        var result = [callReason, root ? nil : payload?["reason"]?.stringValue]
            .compactMap(\.self).filter { !$0.isEmpty }.map { Section(text: $0) }
        if let diff = payload?["detail"]?["descriptionChanged"]?["diff"]?.stringValue, !diff.isEmpty {
            result.append(Section(text: diff, isCode: true))
        }
        if let json = payload?["arguments"]?.stringValue {
            let shell = AgentToolName.canonical(payload?["tool"]?.stringValue ?? "") == .shellRun
            result += argumentsDetail(json, payload: payload, title: title, root: root).sections.map { part in
                let command = shell && ["argv", "command", "script"].contains(part.name ?? "")
                return Section(title: command ? String(localized: "Command") : part.name,
                               text: part.value, isCode: command)
            }
        }
        return result
    }

    /// Whether an `approvalRequested` is for a command that runs as root: the
    /// host binds such an approval to its own `detail.rootCommand` key,
    /// never the ordinary `detail.command`, so the key alone tells them apart.
    static func isRoot(_ payload: JSONValue?) -> Bool {
        payload?["detail"]?[RunCodeApproval.rootCommandDetail] != nil
    }

    /// The card's title when it is not the call's own: a git_push the host
    /// binds to a lease (`detail.forcePush`) overwrites the remote's branch,
    /// which the title says. Nil for any other request.
    static func title(_ payload: JSONValue?) -> String? {
        payload?["detail"]?[forcePushDetail] != nil ? String(localized: "Force-push to the remote") : nil
    }

    private static let forcePushDetail = "forcePush"

    /// `callReason`: the reason the agent gave on the call's `toolCall`.
    static func detail(_ payload: JSONValue?, title: String, callReason: String?) -> String {
        let root = isRoot(payload)
        let arguments = payload?["arguments"]?.stringValue.map {
            argumentsText($0, payload: payload, title: title, root: root)
        }
        return [
            callReason,
            root ? nil : payload?["reason"]?.stringValue,
            payload?["detail"]?["descriptionChanged"]?["diff"]?.stringValue,
            arguments,
        ].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The arguments by name. For a shell_run, the command and directory are
    /// the ones the approval is bound to — the request's `detail.rootCommand`
    /// or `detail.command` and its `workingDirectory` — wherever it names
    /// them, so the card never shows one command while approving another;
    /// an argv reads as its command line, and a root card's `root` flag is
    /// left out.
    static func argumentsText(_ json: String, payload: JSONValue?, title: String, root: Bool) -> String {
        argumentsDetail(json, payload: payload, title: title, root: root).text
    }

    private static func argumentsDetail(_ json: String, payload: JSONValue?, title: String, root: Bool) -> ToolCallDetail {
        if let published = publishedPackages(payload) {
            return ToolCallDetail(detail: published, title: title)
        }
        if let edited = editedIssue(payload) {
            return ToolCallDetail(detail: edited, title: title)
        }
        if let forced = forcedPush(payload) {
            return ToolCallDetail(detail: forced, title: title)
        }
        if let squashed = squashedCommits(payload) {
            return ToolCallDetail(detail: squashed, title: title)
        }
        guard AgentToolName.canonical(payload?["tool"]?.stringValue ?? "") == .shellRun,
              case var .object(values)? = try? JSONCoding.decode(JSONValue.self, from: Data(json.utf8))
        else { return ToolCallDetail(detail: json, title: title) }
        if root {
            values["root"] = nil
        }
        let bound = payload?["detail"]?[root ? RunCodeApproval.rootCommandDetail : "command"]
        if let bound, let shown = boundCommand(bound) {
            for key in ["argv", "command", "script", "interpreter"] {
                values[key] = nil
            }
            values.merge(shown) { _, bound in bound }
        } else if case let .array(items)? = values["argv"] {
            let words = items.compactMap(\.stringValue)
            if words.count == items.count {
                values["argv"] = .string(CommandLineText.quoted(words))
            }
        }
        if let directory = payload?["workingDirectory"]?.stringValue {
            values["cwd"] = directory.isEmpty || directory == "." ? nil : .string(directory)
        }
        guard let encoded = try? JSONCoding.encode(JSONValue.object(values)) else {
            return ToolCallDetail(detail: json, title: title)
        }
        return ToolCallDetail(detail: String(decoding: encoded, as: UTF8.self), title: title)
    }

    /// An apelin_package_publish card's arguments: not the build IDs the
    /// call names but what the approval is bound to, its
    /// `detail.packagePublish` — the repository, then each package by its
    /// ID, version and architecture with the digest it is held to. Nil for
    /// any other request.
    private static func publishedPackages(_ payload: JSONValue?) -> String? {
        guard let detail = payload?["detail"]?["packagePublish"],
              let repository = detail["repository"]?.stringValue,
              case let .array(packages)? = detail["packages"]
        else { return nil }
        var shown: [String: JSONValue] = ["repository": .string(repository)]
        for package in packages {
            guard let id = package["packageID"]?.stringValue, let version = package["version"]?.stringValue,
                  let architecture = package["architecture"]?.stringValue, let digest = package["digest"]?.stringValue
            else { return nil }
            shown["\(id) \(version) (\(architecture))"] = .string(digest)
        }
        return (try? JSONCoding.encode(JSONValue.object(shown))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// An apelin_feedback_edit card's arguments: not the call's, which carry
    /// the revision it was read at, but what the approval is bound to, its
    /// `detail.feedbackEdit` — the repository, the issue, and the new title
    /// or body in full, each only when it changes. Nil for any other request.
    private static func editedIssue(_ payload: JSONValue?) -> String? {
        guard let detail = payload?["detail"]?["feedbackEdit"],
              let repository = detail["repository"]?.stringValue,
              let number = detail["number"]?.doubleValue
        else { return nil }
        var shown: [String: JSONValue] = ["repository": .string(repository), "issue": .string("#\(Int(number))")]
        for field in ["title", "body"] {
            if let text = detail[field]?.stringValue {
                shown[field] = .string(text)
            }
        }
        return (try? JSONCoding.encode(JSONValue.object(shown))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A forced git_push card's arguments: not the call's but what the
    /// approval is bound to, its `detail.forcePush` — the remote and the
    /// address it pushes to, the branch, the remote's commit replaced and the
    /// local one sent in its place, and the commits that leave the branch,
    /// newest first. Nil for any other request.
    private static func forcedPush(_ payload: JSONValue?) -> String? {
        guard let detail = payload?["detail"]?[forcePushDetail],
              let remote = detail["remote"]?.stringValue, let branch = detail["branch"]?.stringValue,
              let expected = detail["expectedCommit"]?.stringValue, let local = detail["localCommit"]?.stringValue,
              case let .array(lost)? = detail["overwritten"], let count = detail["overwrittenCount"]?.doubleValue
        else { return nil }
        let subject = detail["localSubject"]?.stringValue.map { " \($0)" } ?? ""
        let commits: [String] = lost.compactMap { entry in
            guard let commit = entry["commit"]?.stringValue else { return nil }
            return "\(commit.prefix(7)) \(entry["subject"]?.stringValue ?? "")"
        }
        var shown: [String: JSONValue] = [
            "remote": .string(remote),
            "branch": .string(branch),
            "expected_commit": .string(expected),
            "local_commit": .string(local + subject),
            "overwritten": .string(commits.joined(separator: "\n")),
            "overwritten_count": .string(String(Int(count))),
        ]
        shown["url"] = detail["url"]?.stringValue.map { .string($0) }
        return (try? JSONCoding.encode(JSONValue.object(shown))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A git_squash card's arguments: not the call's, which may name a count,
    /// but what the approval is bound to, its `detail.squash` — the branch,
    /// the base kept, the head replaced, the message and each commit
    /// combined, newest first. Nil for any other request.
    private static func squashedCommits(_ payload: JSONValue?) -> String? {
        guard let detail = payload?["detail"]?["squash"],
              let branch = detail["branch"]?.stringValue, let base = detail["base"]?.stringValue,
              let head = detail["expectedHead"]?.stringValue, let message = detail["message"]?.stringValue,
              case let .array(commits)? = detail["commits"], let count = detail["count"]?.doubleValue
        else { return nil }
        let lines: [String] = commits.compactMap { entry in
            guard let commit = entry["commit"]?.stringValue else { return nil }
            return "\(commit.prefix(7)) \(entry["subject"]?.stringValue ?? "")"
        }
        let shown: [String: JSONValue] = [
            "branch": .string(branch),
            "base": .string(base),
            "head": .string(head),
            "message": .string(message),
            "commits": .string(lines.joined(separator: "\n")),
            "count": .string(String(Int(count))),
        ]
        return (try? JSONCoding.encode(JSONValue.object(shown))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A bound invocation, in the shape apelin-agent writes it
    /// (`RunCodeInvocation`'s synthesized Codable), as the arguments it came
    /// from: an argv as its command line, shell text as `command`, a script
    /// with its interpreter. Nil for a shape it does not know.
    private static func boundCommand(_ invocation: JSONValue) -> [String: JSONValue]? {
        if case let .array(items)? = invocation["argv"]?["_0"] {
            let words = items.compactMap(\.stringValue)
            guard words.count == items.count else { return nil }
            return ["argv": .string(CommandLineText.quoted(words))]
        }
        if let text = invocation["shell"]?["_0"]?.stringValue {
            return ["command": .string(text)]
        }
        if let script = invocation["script"], let source = script["source"]?.stringValue,
           let interpreter = script["interpreter"]?.stringValue
        {
            return ["script": .string(source), "interpreter": .string(interpreter)]
        }
        return nil
    }
}

/// An argv as a POSIX shell reads it back, so two different argvs never
/// read the same: a word of ASCII letters, digits and `-_./=:@+,%` alone as
/// it is; any other word in single quotes, `'\''` for a quote, `''` for an
/// empty one; and one holding a character that does not show — a control,
/// a format character, a separator other than the space, a private-use or
/// unassigned code point — as `$'…'` with that character escaped.
enum CommandLineText {
    static func quoted(_ argv: [String]) -> String {
        argv.map(word).joined(separator: " ")
    }

    static func word(_ word: String) -> String {
        if !word.isEmpty, word.unicodeScalars.allSatisfy(isPlain) {
            return word
        }
        guard word.unicodeScalars.contains(where: isHidden) else {
            return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }
        var escaped = "$'"
        for scalar in word.unicodeScalars {
            switch scalar {
            case "\\": escaped += #"\\"#
            case "'": escaped += #"\'"#
            case "\n": escaped += #"\n"#
            case "\t": escaped += #"\t"#
            case "\r": escaped += #"\r"#
            case _ where isHidden(scalar):
                escaped += scalar.value > 0xFFFF
                    ? String(format: "\\U%08X", scalar.value)
                    : String(format: "\\u%04X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "'"
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0" ... "9").contains(scalar)
            || "-_./=:@+,%".unicodeScalars.contains(scalar))
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
            true
        case .spaceSeparator:
            scalar != " "
        default:
            false
        }
    }
}
