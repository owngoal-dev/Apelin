import enum ApelinProtocol.FeedbackRules
import CryptoKit
import Foundation
import KWWKAI

/// apelin_feedback_read and apelin_feedback_edit (owner, 2026-10-30): an
/// issue on Apelin's own repository read, and one the user's GitHub account
/// opened there changed, rather than filed again. The edit names the
/// revision of the read it was made against; before anyone is asked the
/// tool reads the issue again and refuses an edit of another account's
/// issue, of an issue that changed since that read (the user may have
/// edited it on GitHub), one that changes nothing, and text `FeedbackRules`
/// refuses. The card then names the issue and the whole new text, and
/// apelin-environment writes it only while the issue still says what this
/// read saw, keeping its footer.
enum FeedbackEdit {
    static let numberKey = "number"
    static let revisionKey = "revision"

    /// A short name for an issue's title and body as one read saw them.
    static func revision(title: String, body: String) -> String {
        let data = (try? JSONEncoder().encode([title, body])) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The issue a call names.
    static func number(_ arguments: JSONValue) throws -> Int {
        guard let number = arguments.argInt(numberKey), number >= 1 else {
            throw ToolArgumentError("Name the issue by its number on \(FeedbackRules.repository), such as 12.")
        }
        return number
    }

    /// What the card names, from the issue as it was just read; refused,
    /// with what to do, when no edit could be made.
    static func approval(for arguments: JSONValue, issue: FeedbackReadToolResponse) throws -> FeedbackEditApproval {
        guard issue.openedByUser else {
            throw ToolDeniedError(message: "Nothing was changed: #\(issue.issue) was opened by \(issue.author), not by the user's GitHub account, and only an issue the account opened can be edited. The user can comment on it on GitHub.")
        }
        guard let revision = arguments.argNonEmptyString(revisionKey) else {
            throw ToolArgumentError("Nothing was changed: read the issue with apelin_feedback_read first and pass the revision it answered.")
        }
        guard revision == issue.revision else {
            throw ToolDeniedError(message: "Nothing was changed: #\(issue.issue) changed on GitHub since the read that revision came from, perhaps by the user. Read it again with apelin_feedback_read, keep what changed there, and show the user the edit against what it says now before asking again.")
        }
        let title = arguments.argString("title").map { $0.trimmingCharacters(in: .whitespaces) }
        let body = arguments.argString("body")
        let newTitle = title == issue.title ? nil : title
        let newBody = body == issue.body ? nil : body
        if let refusal = FeedbackRules.editRefusal(title: newTitle, body: newBody) {
            throw ToolArgumentError("Nothing was changed: \(refusal.explanation).")
        }
        return FeedbackEditApproval(
            repository: issue.repository,
            number: issue.issue,
            url: issue.url,
            title: newTitle,
            body: newBody,
            currentTitle: issue.title,
            currentBody: issue.body,
        )
    }
}
