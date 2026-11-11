import ApelinCore
import ApelinProtocol
import Foundation

/// A sign-in page this device cannot show is signed in to on another
/// device (`SignInProgress.Step.elsewhere`, #49): a device code is entered
/// there unless the page's link carries it, a page the flow polls is
/// signed in to there, a loopback's redirect is pasted back, and a page
/// that returns to a listener here which takes no pasted address has no
/// such way.
func checkSignInElsewhere() {
    func step(after kind: String, _ values: [String: JSONValue]) -> SignInProgress.Step {
        var progress = SignInProgress()
        progress.apply(event(1, kind, values))
        return progress.step
    }

    let typed = step(after: "deviceCode", [
        "code": .string("WDJB-MJHT"), "verificationURL": .string("https://github.com/login/device"),
        "pageHoldsCode": .bool(false),
    ])
    precondition(typed.elsewhere == .code, "a code the user types is entered on the other device")
    let carried = step(after: "deviceCode", [
        "code": .string("WDJB-MJHT"), "verificationURL": .string("https://www.kimi.com/code/authorize?user_code=WDJB-MJHT"),
        "pageHoldsCode": .bool(true),
    ])
    precondition(carried.elsewhere == .page, "a code the link carries leaves only the page")

    let claude = "https://claude.ai/oauth/authorize?client_id=c&redirect_uri=http%3A%2F%2Flocalhost%3A53692%2Fcallback&state=s"
    precondition(
        step(after: "authorize", ["url": .string(claude), "acceptsCallbackURL": .bool(true)]).elsewhere == .redirect,
        "a loopback that takes a pasted address is finished by pasting it",
    )
    let polled = "https://cursor.com/loginDeepControl?challenge=c&uuid=u&mode=login"
    precondition(
        step(after: "authorize", ["url": .string(polled), "acceptsCallbackURL": .bool(false)]).elsewhere == .page,
        "a page the flow polls is signed in to anywhere",
    )
    for kiro in [
        "https://app.kiro.dev/signin?state=s&redirect_uri=http%3A%2F%2Flocalhost%3A49153&redirect_from=KiroIDE",
        "https://example.com/authorize?redirect_uri=http://127.0.0.1:3128/oauth/callback",
        "https://example.com/authorize?return=http%3A%2F%2F%5B%3A%3A1%5D%3A8080%2F",
    ] {
        precondition(
            step(after: "authorize", ["url": .string(kiro), "acceptsCallbackURL": .bool(false)]).elsewhere == nil,
            "a page that returns to this device and takes no pasted address cannot be finished elsewhere: \(kiro)",
        )
    }
    precondition(!SignInProgress.Step.returnsToThisDevice(URL(string: "https://example.com/?next=https%3A%2F%2Fexample.com%2Fdone")!))
    precondition(!SignInProgress.Step.returnsToThisDevice(URL(string: "https://localhost.example.com/authorize?state=localhost")!))

    precondition(SignInProgress.Step.starting.elsewhere == nil && SignInProgress.Step.keys([]).elsewhere == nil)
    precondition(SignInProgress.Step.ended(.failed, message: nil).elsewhere == nil)
    print("ok: a sign-in page says how another device finishes it, and says nothing where none can")
}
