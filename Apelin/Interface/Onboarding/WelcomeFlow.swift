// Adapted from Irisin's welcome navigation and Xrash's notification step.
// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
import SnapKit
import UIKit

@MainActor
final class WelcomeFlow {
    private static let seenKey = "onboarding.seenVersion"
    @objc dynamic static var shouldPresent: Bool {
        UserDefaults.standard.integer(forKey: seenKey) < 1
    }

    @objc private dynamic weak var navigation: UINavigationController?
    @objc private dynamic var finished = false
    private let onFinish: (ProjectSummary?) -> Void
    var project: ProjectSummary?
    @objc dynamic var projectTemplateID: String?

    private init(onFinish: @escaping (ProjectSummary?) -> Void) {
        self.onFinish = onFinish
    }

    static func present(from presenter: UIViewController, onFinish: @escaping (ProjectSummary?) -> Void) {
        let flow = WelcomeFlow(onFinish: onFinish)
        let navigation = UINavigationController(rootViewController: WelcomeController(flow: flow))
        navigation.isModalInPresentation = true
        navigation.navigationBar.prefersLargeTitles = true
        navigation.view.backgroundColor = WelcomeStyle.background
        navigation.view.tintColor = WelcomeStyle.accent
        navigation.navigationBar.tintColor = WelcomeStyle.accent
        navigation.modalTransitionStyle = .coverVertical
        navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = CGSize(width: 520, height: 620)
        navigation.viewControllers.first?.navigationItem.largeTitleDisplayMode = .never
        flow.navigation = navigation
        presenter.present(navigation, animated: true)
    }

    @objc dynamic func showEnvironment() {
        push(WelcomeEnvironmentPage(flow: self))
    }

    @objc dynamic func showProviders() {
        push(WelcomeProvidersPage(flow: self))
    }

    @objc dynamic func showGitHub() {
        push(WelcomeGitHubPage(flow: self))
    }

    @objc dynamic func showProject() {
        push(WelcomeProjectPage(flow: self))
    }

    @objc dynamic func showNotifications() {
        push(WelcomeNotificationsPage(flow: self))
    }

    @objc dynamic func showCaution() {
        push(WelcomeCautionController(flow: self))
    }

    @objc private dynamic func push(_ page: UIViewController) {
        navigation?.pushViewController(page, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc dynamic func finish() {
        guard !finished else { return }
        finished = true
        if Self.shouldPresent {
            UserDefaults.standard.set(1, forKey: Self.seenKey)
        }
        // Prepare the destination behind the sheet before it is revealed.
        onFinish(project)
        navigation?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
