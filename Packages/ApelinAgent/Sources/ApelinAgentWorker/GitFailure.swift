import ApelinAgent
import ApelinProtocol
import Foundation

/// A git refusal in words the model can act on and pass on to the user.
enum GitFailure {
    /// `ApelinError.description` is `<code>: <message>`, which is how a
    /// task's final `state` carries a failure.
    static func split(_ text: String?) -> (ApelinError.Code?, String) {
        guard let text, !text.isEmpty else { return (nil, "") }
        if let colon = text.firstIndex(of: ":"), let code = ApelinError.Code(rawValue: String(text[..<colon])) {
            return (code, text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        if let code = ApelinError.Code(rawValue: text) {
            return (code, "")
        }
        return (nil, text)
    }

    static func describe(
        _ operation: String,
        code: ApelinError.Code?,
        message: String,
        reason: String?,
        host: String?,
        forced: Bool = false,
    ) -> GitToolFailure {
        let detail = message.isEmpty ? (code?.rawValue ?? "no reason given") : message
        var text = "\(forced ? "forced " : "")\(operation) failed: \(detail)"
        if !text.hasSuffix(".") {
            text += "."
        }
        if forced, let hint = forcedHint(code: code, reason: reason) {
            return GitToolFailure(message: text + " " + hint)
        }
        if let hint = hint(operation, code: code, message: message, reason: reason, host: host) {
            text += " " + hint
        }
        return GitToolFailure(message: text)
    }

    static func isAuthentication(_ message: String, reason: String?) -> Bool {
        let words = (message + " " + (reason ?? "")).lowercased()
        // Not "auth" alone: a commit's missing author is not a credential.
        return ["authenticat", "authoriz", "credential", "forbidden", "token", "password"].contains { words.contains($0) }
            || words.range(of: #"\b40[13]\b"#, options: .regularExpression) != nil
    }

    private static func hint(
        _ operation: String,
        code: ApelinError.Code?,
        message: String,
        reason: String?,
        host: String?,
    ) -> String? {
        // A reason the host named comes before any guess from the words,
        // which a project's name or a URL could set off.
        if reason == ApelinError.Reason.notARepository.rawValue {
            return "This project has no repository yet: make one with git_init, then commit with git_commit and all: true."
        }
        if reason == ApelinError.Reason.noSuchRemote.rawValue {
            guard operation == "git push" else { return nil }
            return "The project has no such remote yet: ask the user whether to create a GitHub repository for it with apelin_git_create_repository, and with which owner, name and visibility, or for the HTTPS address of an empty repository they made (no README, licence or .gitignore); then git_push with url."
        }
        if reason == ApelinError.Reason.remoteURLDiffers.rawValue {
            // The message says where the remote points and what to do instead.
            return nil
        }
        if isAuthentication(message, reason: reason) {
            if host == "github.com" {
                return "The remote wants a credential Apelin does not have for github.com, or refused the saved one: ask the user to sign in with Sign In with GitHub in Settings ▸ Git, then try again."
            }
            let place = host.map { "for \($0) " } ?? ""
            return "The remote wants a credential Apelin does not have, or refused the saved one: ask the user for a token \(place)to save with apelin_git_save_credential, then try again."
        }
        if operation == "git commit", message.lowercased().contains("author") {
            return "Ask the user to set the commit author in Settings ▸ Git."
        }
        guard code == .conflict else { return nil }
        switch operation {
        case "git pull":
            return "Pull only fast-forwards: the branch has diverged from its upstream, or a local change is in the way. Tell the user; do not force it."
        case "git push":
            return "The remote has commits this branch does not. Fetch and pull first (pull only fast-forwards), then merge or rebase as the user agrees. A refused push is never a reason to force it: force_with_lease is only for a forced push the user explicitly asked for."
        case "git clone":
            return "The workspace already has a repository, or files with the same names as the repository's. Tell the user; do not delete their files to make room."
        default:
            return nil
        }
    }

    /// A forced push's refusal: the lease that did not hold, or the
    /// remote's own no. Nothing was pushed either way.
    private static func forcedHint(code: ApelinError.Code?, reason: String?) -> String? {
        switch reason {
        case ApelinError.Reason.remoteChanged.rawValue:
            return "The remote's branch changed after the user approved overwriting it, so nothing was pushed. Tell the user what it is at now; to overwrite it still, call git_push with force_with_lease again, which fetches and asks them again with what would be lost now."
        case ApelinError.Reason.localChanged.rawValue:
            return "This branch moved after the user approved the forced push, so nothing was pushed. Tell the user; to push it still, call git_push with force_with_lease again, which asks them again with the commit sent now."
        default:
            guard code == .conflict else { return nil }
            return "The remote refused the forced push in its own words above, and nothing was pushed: a protected branch, for one, is the user's to change on the remote. Tell the user what blocks it; never try to get around it."
        }
    }
}
