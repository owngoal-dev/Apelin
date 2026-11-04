import AuthenticationServices
import UIKit

/// A sign-in page in the system's sign-in browser, which shares Safari's
/// cookies (not `SFSafariViewController`, which does not), so an account
/// already signed in there stays signed in. The sign-in ends elsewhere — a
/// device code approved, a loopback reached — so the session waits on a
/// scheme nothing redirects to and is closed from here when it ends. The
/// user closing it first, or declining the system's prompt, is told to
/// `onClosedByUser`; the sign-in goes on waiting. With no in-app browser to
/// be had the page opens in Safari.
final class SignInBrowser: NSObject {
    @objc dynamic var onClosedByUser: (() -> Void)?
    @objc private dynamic weak var anchor: UIView?
    @objc private dynamic var session: ASWebAuthenticationSession?

    /// Presents over `anchor`'s window.
    init(anchor: UIView) {
        self.anchor = anchor
    }

    @objc dynamic func open(_ page: URL) {
        close()
        var session: ASWebAuthenticationSession?
        session = ASWebAuthenticationSession(url: page, callbackURLScheme: "apelin-sign-in") { [weak self] _, _ in
            // closed here on purpose, the session is already let go
            guard let self, let current = session, self.session === current else { return }
            self.session = nil
            onClosedByUser?()
        }
        guard let session else { return }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            self.session = nil
            UIApplication.shared.open(page)
        }
    }

    /// Let go first, then cancel: the session's own completion then knows
    /// it was closed from here.
    @objc dynamic func close() {
        let session = session
        self.session = nil
        session?.cancel()
    }
}

extension SignInBrowser: ASWebAuthenticationPresentationContextProviding {
    @objc dynamic func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor?.window ?? ASPresentationAnchor()
    }
}
