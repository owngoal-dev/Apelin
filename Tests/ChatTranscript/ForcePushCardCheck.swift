import ApelinCore
import Foundation

/// A forced git_push's card (issue #29) says it force-pushes, and shows
/// what the approval is bound to, `detail.forcePush`, never the call's own
/// arguments: the remote and its address, the branch, the commit replaced,
/// the one sent, and the commits that leave the branch.
func checkForcePushCard() {
    let theirs = String(repeating: "a", count: 40)
    let mine = String(repeating: "b", count: 40)
    let payload: JSONValue = .object([
        "approvalID": .string("force-1"),
        "tool": .string("git_push"),
        "arguments": .string(#"{"force_with_lease":true,"remote":"elsewhere","branch":"other"}"#),
        "reason": .string("Force-pushes main to origin, overwriting its history there."),
        "detail": .object(["forcePush": .object([
            "projectID": .string("p"), "remote": .string("origin"), "url": .string("https://github.com/someone/clock.git"),
            "branch": .string("main"), "expectedCommit": .string(theirs), "localCommit": .string(mine),
            "localSubject": .string("Rewrite the clock"),
            "overwritten": .array([
                .object(["commit": .string(theirs), "subject": .string("Theirs")]),
                .object(["commit": .string(String(repeating: "c", count: 40)), "subject": .string("Older")]),
            ]),
            "overwrittenCount": .number(3),
        ])]),
    ])
    precondition(ApprovalCardText.title(payload) == "Force-push to the remote", "the title says it forces")
    precondition(ApprovalCardText.title(.object(["tool": .string("git_push")])) == nil, "an ordinary push keeps its own")

    let sections = ApprovalCardText.sections(payload, title: "Force-push to the remote", callReason: nil)
    func shown(_ name: String) -> String? {
        sections.first { $0.title == name }?.text
    }
    precondition(sections.first?.text.hasPrefix("Force-pushes main to origin") == true, "the gate's sentence first: \(sections)")
    precondition(shown("remote") == "origin" && shown("branch") == "main", "the remote and branch bound, not the call's: \(sections)")
    precondition(shown("url") == "https://github.com/someone/clock.git")
    precondition(shown("expected_commit") == theirs)
    precondition(shown("local_commit") == mine + " Rewrite the clock")
    precondition(shown("overwritten") == "aaaaaaa Theirs\nccccccc Older", "\(sections)")
    precondition(shown("overwritten_count") == "3")
    precondition(shown("force_with_lease") == nil, "the call's own arguments are not shown")
}
