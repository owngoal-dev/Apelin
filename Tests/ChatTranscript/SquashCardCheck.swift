import ApelinCore
import Foundation

/// A git_squash card shows what the approval is bound to, `detail.squash`,
/// never the call's own arguments: the branch, the base kept, the head
/// replaced, the new message and each commit combined.
func checkSquashCard() {
    let base = String(repeating: "a", count: 40)
    let head = String(repeating: "d", count: 40)
    let payload: JSONValue = .object([
        "approvalID": .string("squash-1"),
        "tool": .string("git_squash"),
        "arguments": .string(#"{"count":3,"message":"Something the call said"}"#),
        "reason": .string("Squashes 3 commits on main into one with the message below."),
        "detail": .object(["squash": .object([
            "projectID": .string("p"), "branch": .string("main"), "base": .string(base), "expectedHead": .string(head),
            "message": .string("Add the clock\n\nThe hand and the face."), "count": .number(3), "published": .number(0),
            "commits": .array([
                .object(["commit": .string(head), "subject": .string("Fix the hand")]),
                .object(["commit": .string(String(repeating: "c", count: 40)), "subject": .string("Draw the face")]),
            ]),
        ])]),
    ])
    precondition(ApprovalCardText.title(payload) == nil, "the call's own title, Squash commits")
    let sections = ApprovalCardText.sections(payload, title: "Squash commits", callReason: nil)
    func shown(_ name: String) -> String? {
        sections.first { $0.title == name }?.text
    }
    precondition(sections.first?.text.hasPrefix("Squashes 3 commits on main") == true, "\(sections)")
    precondition(shown("branch") == "main" && shown("base") == base && shown("head") == head, "\(sections)")
    precondition(shown("message") == "Add the clock\n\nThe hand and the face.", "the message bound, not the call's")
    precondition(shown("commits") == "ddddddd Fix the hand\nccccccc Draw the face", "\(sections)")
    precondition(shown("count") == "3")
}
