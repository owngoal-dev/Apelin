import AlertController
import ApelinCore
import UIKit

/// Not `@main`: `main.swift` clears saved scenes before `UIApplicationMain`.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    @objc dynamic func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?,
    ) -> Bool {
        ExecutableWatch.start {
            let alert = UIAlertController(
                title: String(localized: "Apelin Updated or Removed"),
                message: String(localized: "Quit to apply the change, or keep using this version for now."),
                preferredStyle: .alert,
            )
            alert.addAction(UIAlertAction(title: String(localized: "Later"), style: .cancel))
            alert.addAction(UIAlertAction(title: String(localized: "Quit"), style: .destructive) { _ in
                QuietExit.run()
            })
            Self.presentWhenActive(alert, in: application)
        }
        // before anything reads the data folder
        let recovered = DataFolder.container.flatMap { ContainerDataFolder.recover(from: $0, into: .app) }
        AppJournal.start()
        if let recovered {
            AppJournal.note(recovered)
        }
        NetworkAccess.start()
        ConversationNotices.start()
        // the progress card and the alerts carry the app's icon, as Fila's do
        AlertControllerConfiguration.alertImage = UIImage(named: "AppIconMark")
        // the app's own accent (`AppAccent`); the library's default is red
        AlertControllerConfiguration.accentColor = AppAccent.color(glass: .systemBlue)
        AlertControllerConfiguration.accentForegroundColor = AppAccent.foreground(glass: .white)
        ConsoleLaunch.start()
        return true
    }

    /// A quit takes the Live Activity with it: nothing would update it
    /// after (`ChatWidgetPublisher.endActivitiesForQuit`).
    @objc dynamic func applicationWillTerminate(_: UIApplication) {
        ChatWidgetPublisher.endActivitiesForQuit()
    }

    @objc dynamic func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions,
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// The watch fires once, and may fire with no scene active: at launch,
    /// in the background, or on resume before the scene activates. The
    /// notice then waits for the next activation instead of being lost.
    @objc private dynamic static func presentWhenActive(_ alert: UIAlertController, in application: UIApplication) {
        let active = application.connectedScenes.first { $0.activationState == .foregroundActive }
        guard let scene = active as? UIWindowScene else {
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main,
            ) { _ in
                MainActor.assumeIsolated {
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    presentWhenActive(alert, in: application)
                }
            }
            return
        }
        // In front of whatever the scene shows: a root already presenting a
        // sheet or another alert would drop it.
        guard var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        top.present(alert, animated: true)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    @objc dynamic var window: UIWindow?

    @objc dynamic func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions,
    ) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.tintColor = AppAccent.windowTint
        window.rootViewController = RootInterfaceController()
        window.makeKeyAndVisible()
        self.window = window
        // A cold launch by Open in Apelin or an `apelin://` link: the URL
        // comes with the scene. Opened on the next turn, once the root is on
        // screen to present from.
        DispatchQueue.main.async { [weak self] in self?.openURLs(connectionOptions.urlContexts, in: scene) }
    }

    /// Open in Apelin, or an `apelin://` link, while the app runs.
    @objc dynamic func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let scene = scene as? UIWindowScene else { return }
        openURLs(contexts, in: scene)
    }

    /// An `apelin://` link goes to its conversation or project
    /// (`ApelinLinkRouter`); anything else is a transfer file, and the
    /// opener refuses what is not one with a notice. One at a time: a
    /// second sheet could not be presented over the first.
    @objc private dynamic func openURLs(_ contexts: Set<UIOpenURLContext>, in scene: UIWindowScene) {
        guard let context = contexts.first, !ApelinLinkRouter.open(context.url, in: scene) else { return }
        TransferOpener.open(context.url, in: scene)
    }
}
