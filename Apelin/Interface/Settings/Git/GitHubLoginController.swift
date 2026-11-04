import ApelinProtocol
import SnapKit
import SPIndicator
import Then
import UIKit

/// Settings ▸ Git ▸ Sign In with GitHub: the device flow `gh auth login`
/// runs (`GitHubDeviceFlow`), so github.com needs no token typed in. The
/// page shows GitHub's code, copies it and opens github.com/login/device in
/// `SignInBrowser` by itself; when the user approves there, the token and
/// the account's login are saved as github.com's credential through
/// `gitCredentialSet`, replacing the one it had, and the page goes back —
/// popped in Settings ▸ Git, dismissed when it is a sheet of its own (the
/// welcome pages). The token is in this page's memory only on its way.
/// Leaving the page ends the sign-in. Laid out as a provider's sign-in is
/// (`ProviderLoginController`): the mark, the name, one line, the code.
final class GitHubLoginController: UIViewController {
    /// Told once signed in, with the account's login.
    @objc dynamic var onSignedIn: ((String) -> Void)?

    private enum Step: Equatable {
        case starting
        case code(GitHubDeviceFlow.Code)
        case saving
        case failed(String)
    }

    private var step = Step.starting
    private var flow: Task<Void, Never>?
    /// The page opened by itself: once per code.
    @objc private dynamic var openedCode: String?

    @objc private dynamic lazy var browser = SignInBrowser(anchor: view)

    private let scrollView = UIScrollView().then {
        $0.alwaysBounceVertical = true
    }

    private let iconView = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.isAccessibilityElement = false
    }

    private let titleLabel = UILabel().then {
        $0.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .bold))
        $0.adjustsFontForContentSizeCategory = true
        $0.textAlignment = .center
        $0.numberOfLines = 0
        $0.accessibilityTraits = .header
    }

    private let subtitleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .subheadline)
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.numberOfLines = 0
    }

    /// The code, while GitHub waits for it.
    private let body = UIStackView().then {
        $0.axis = .vertical
    }

    private let primaryButton = UIButton(configuration: .filled()).then {
        $0.configuration?.cornerStyle = .large
        $0.configuration?.buttonSize = .large
        // the fill is the tint, white in the dark before iOS 26
        $0.configuration?.baseForegroundColor = AppAccent.foreground(glass: .white)
        $0.snp.makeConstraints { $0.height.greaterThanOrEqualTo(52) }
    }

    private let footnoteLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .footnote)
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.numberOfLines = 0
        $0.text = String(localized: """
        GitHub’s page asks you to authorize GitHub CLI: Apelin signs in through its app. The token is \
        kept only in this device’s keychain and used for remotes on github.com.
        """)
    }

    @objc private dynamic lazy var spinnerItem: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.isAccessibilityElement = true
        spinner.accessibilityLabel = String(localized: "Waiting")
        spinner.startAnimating()
        return UIBarButtonItem(customView: spinner)
    }()

    init() {
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "GitHub")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    deinit {
        flow?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        primaryButton.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .primaryActionTriggered)

        let header = UIStackView(arrangedSubviews: [iconView, titleLabel, subtitleLabel]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = 10
            $0.setCustomSpacing(18, after: iconView)
        }
        iconView.snp.makeConstraints { $0.size.equalTo(72) }
        titleLabel.snp.makeConstraints { $0.width.equalToSuperview() }
        subtitleLabel.snp.makeConstraints { $0.width.equalToSuperview() }
        let column = UIStackView(arrangedSubviews: [header, body, primaryButton, footnoteLabel]).then {
            $0.axis = .vertical
            $0.spacing = 28
            $0.setCustomSpacing(16, after: primaryButton)
        }
        view.addSubview(scrollView)
        scrollView.addSubview(column)
        scrollView.snp.makeConstraints { $0.edges.equalToSuperview() }
        column.snp.makeConstraints {
            $0.top.equalTo(scrollView.contentLayoutGuide).inset(40)
            $0.bottom.equalTo(scrollView.contentLayoutGuide).inset(32)
            $0.centerX.equalTo(scrollView.frameLayoutGuide)
            $0.width.lessThanOrEqualTo(420)
            $0.leading.greaterThanOrEqualTo(scrollView.frameLayoutGuide).inset(32)
            $0.trailing.lessThanOrEqualTo(scrollView.frameLayoutGuide).inset(32)
            $0.width.equalTo(scrollView.frameLayoutGuide).offset(-64).priority(.high)
        }
        start()
    }

    /// Leaving the page ends the sign-in; an interactive back that is
    /// called off does not.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent || navigationController?.isBeingDismissed == true else { return }
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                if !context.isCancelled {
                    self?.abandon()
                }
            }
        } else {
            abandon()
        }
    }

    @objc private dynamic func abandon() {
        flow?.cancel()
        flow = nil
        browser.close()
    }

    // MARK: - The flow

    @objc private dynamic func start() {
        flow?.cancel()
        openedCode = nil
        show(.starting)
        flow = Task { [weak self] in
            let github = GitHubDeviceFlow.live
            do {
                let code = try await github.requestCode()
                guard !Task.isCancelled else { return }
                self?.show(.code(code))
                let token = try await github.token(for: code)
                guard !Task.isCancelled else { return }
                self?.show(.saving)
                let login = try await github.login(token: token)
                try await ApelinService.app.gitCredentialSet(GitCredentialSetRequest(
                    host: GitHubDeviceFlow.host,
                    username: login,
                    token: token,
                ))
                guard !Task.isCancelled else { return }
                self?.signedIn(as: login)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.show(.failed(Self.failureText(error)))
            }
        }
    }

    @objc private dynamic func signedIn(as login: String) {
        browser.close()
        SPIndicator.present(title: String(localized: "Signed In"), message: login, preset: .done, haptic: .success)
        onSignedIn?(login)
        if navigationController?.viewControllers.first === self {
            navigationController?.dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    @objc dynamic static func failureText(_ error: Error) -> String {
        switch error as? GitHubDeviceFlow.Failure {
        case .denied: String(localized: "The sign-in was declined on GitHub.")
        case .expired: String(localized: "The code expired before it was entered.")
        case let .refused(reason): String(localized: "GitHub refused the sign-in: \(reason)")
        case .unreadable: String(localized: "GitHub’s answer could not be read.")
        case nil: ProviderLoginController.unavailableText(error)
        }
    }

    @objc private dynamic func primaryTapped() {
        switch step {
        case let .code(code): open(code)
        case .failed: start()
        case .starting, .saving: break
        }
    }

    /// GitHub's page with the code on the clipboard, which its field offers
    /// to paste.
    private func open(_ code: GitHubDeviceFlow.Code) {
        UIPasteboard.general.string = code.userCode
        SPIndicator.present(title: String(localized: "Code Copied"), preset: .done, haptic: .success)
        browser.open(code.verificationURL)
    }

    // MARK: - Drawing

    private func show(_ next: Step) {
        step = next
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        iconView.image = UIImage(named: "ProviderGitHubCopilot")
        iconView.tintColor = nil
        titleLabel.text = String(localized: "GitHub")
        subtitleLabel.text = String(localized: "Enter this code on GitHub to sign in.")
        primaryButton.isHidden = true
        body.isHidden = true
        switch next {
        case .starting, .saving:
            break
        case let .code(code):
            body.isHidden = false
            body.addArrangedSubview(DeviceCodeView(code: code.userCode))
            primaryButton.isHidden = false
            primaryButton.configuration?.title = String(localized: "Open GitHub")
            // a moment after the code is drawn, so it is seen on the way
            if openedCode != code.deviceCode {
                openedCode = code.deviceCode
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, step == next, view.window != nil,
                          UIApplication.shared.applicationState == .active
                    else { return }
                    open(code)
                }
            }
        case let .failed(message):
            browser.close()
            iconView.image = UIImage(systemName: "exclamationmark.circle.fill")
            iconView.tintColor = .systemOrange
            titleLabel.text = String(localized: "Sign-In Failed")
            subtitleLabel.text = message
            primaryButton.isHidden = false
            primaryButton.configuration?.title = String(localized: "Try Again")
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Sign-In Failed"))
        }
        let waiting = if case .failed = next {
            false
        } else {
            true
        }
        navigationItem.rightBarButtonItem = waiting ? spinnerItem : nil
    }
}
