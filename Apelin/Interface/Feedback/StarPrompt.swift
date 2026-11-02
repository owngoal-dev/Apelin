import AlertController
import ApelinProtocol
import SPIndicator
import UIKit

/// Once the reader has signed in with GitHub, builds that complete ask
/// whether they like Apelin, and Star Now stars its repository with that
/// sign-in (owner, 2026-10-29), as `StarPromptState` paces it: after ten
/// builds, again ten builds after each Maybe Later, three times at most.
/// Only builds that complete while the sign-in is there count: a
/// conversation's (`CompletedBuilds`) and the distribution page's. Before
/// it asks, it reads in the background whether the account has starred
/// Apelin, at most once a day, and one that has is never asked. Whatever
/// keeps it from asking — the app in the background, another alert up,
/// GitHub not answering — waits for a build on a later day.
@MainActor
enum StarPrompt {
    private static let stateKey = "starPrompt.state"
    /// GitHub is being asked whether there is a star already, so a build
    /// completing meanwhile does not ask twice.
    private static var isChecking = false

    private static var state: StarPromptState {
        get {
            UserDefaults.standard.data(forKey: stateKey)
                // persisted-read: one preference, the prompt's pacing; its default only asks again
                .flatMap { try? JSONDecoder().decode(StarPromptState.self, from: $0) } ?? StarPromptState()
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: stateKey)
        }
    }

    /// `count` builds completed; the prompt goes over whatever is on top of
    /// `controller`'s window.
    static func buildsCompleted(_ count: Int, from controller: UIViewController) {
        guard count > 0, state.isOpen else { return }
        Task { [weak controller] in
            guard await isSignedInWithGitHub() else { return }
            state.count(count)
            let now = Date()
            guard state.mayCheck(at: now), !isChecking else { return }
            isChecking = true
            defer { isChecking = false }
            state.recordCheck(at: now)
            guard let starred = try? await ApelinService.app.feedbackStarState().starred else { return }
            guard !starred else {
                state.finish()
                return
            }
            guard let page = controller.flatMap({ topPage(over: $0) }) else { return }
            page.presentConfirmation(
                title: "Do You Like Apelin?",
                message: "Please star us on GitHub. It helps us go further.",
                cancelTitle: "Maybe Later",
                confirmTitle: "Star Now",
            ) {
                state.finish()
                star(from: page)
            }
            // asked only once UIKit took the alert
            if page.presentedViewController is AlertBaseController {
                state.recordAsk()
            }
        }
    }

    private static func isSignedInWithGitHub() async -> Bool {
        guard let settings = try? await ApelinService.app.gitSettings() else { return false }
        return settings.credentials.contains { $0.host == GitHubDeviceFlow.host }
    }

    private static func star(from page: UIViewController) {
        Task {
            do {
                _ = try await ApelinService.app.feedbackStar()
                let star = UIImage(systemName: "star.fill")?.withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
                SPIndicator.present(
                    title: String(localized: "Thank You"),
                    message: String(localized: "Starred on GitHub"),
                    preset: star.map { .custom($0) } ?? .done,
                    haptic: .success,
                )
            } catch {
                (topPage(over: page) ?? page).presentNotice(title: "Unable to Star Apelin", message: error.readableMessage)
            }
        }
    }

    /// The page at the top of `controller`'s window, while the app is in
    /// front and nothing is coming or going there; never an alert, so one
    /// question is asked at a time.
    private static func topPage(over controller: UIViewController) -> UIViewController? {
        guard UIApplication.shared.applicationState == .active,
              var page = controller.view.window?.rootViewController
        else { return nil }
        while let presented = page.presentedViewController {
            guard !presented.isBeingDismissed else { return nil }
            page = presented
        }
        guard !page.isBeingPresented, !(page is AlertBaseController), !(page is UIAlertController) else { return nil }
        return page
    }
}
