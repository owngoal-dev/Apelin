import AlertController
import ApelinCore
import ApelinProtocol
import SnapKit
import SPIndicator
import Then
import UIKit

/// Settings ▸ Model Providers ▸ a provider: one sign-in, followed to its end.
///
/// API keys use a native inset grouped form; browser and device flows
/// use one centred column with little to read: the provider's mark, its name, one line under it, then what the
/// step needs — the device code, or the fields of a key with Sign In as the
/// one prominent button. The provider's page opens inside Apelin by itself
/// once it is known (a code it needs is on the clipboard, which the
/// keyboard offers), in `SignInBrowser`: Safari's own cookies, so an
/// account already signed in there stays signed in, and nothing leaves the
/// app. It closes by itself when the sign-in ends; the
/// user closing it first (or declining the system's prompt) leaves the
/// sign-in waiting, with Continue to open the page again. While the
/// flow waits the bar carries a spinner; signing in another way is a quiet
/// underlined link.
///
/// The flow is kwwk's and runs in apelin-agent; this page only shows what it
/// asks for and hands back what the user types, once. The configuration
/// editor also reads saved API-key fields directly; the key stays in a
/// secure field and never enters the sign-in event log. Leaving the page ends the
/// sign-in: nothing else would answer it. It is a sheet of its own, which
/// a swipe does not close (`isModalInPresentation`); the cross does.
/// Its name avoids "SignIn": the vphone guests' VPSignInFix blocks any
/// controller whose class name has it, taking it for Apple's own sign-in.
final class ProviderLoginController: UIViewController {
    /// Told each time a sign-in has ended (Try Again starts another), so
    /// Settings reads the accounts again.
    @objc dynamic var onFinish: (() -> Void)?

    private let provider: AgentProvider
    private let isEditingConfiguration: Bool
    @objc private dynamic var savedValues: [String: String] = [:]
    /// Every way this provider signs in, its own first, as apelin-agent
    /// listed them; the page runs `method`.
    private let methods: [AgentSignInMethod]
    private var method: AgentSignInMethod
    private var handle: TaskHandle?
    private var progress = SignInProgress()
    private var follower: Task<Void, Never>?
    @objc private dynamic var submitting = false
    /// The page opened by itself: once per sign-in.
    @objc private dynamic var openedPage: URL?
    @objc private dynamic var isWaitingForContinue = false
    /// The in-app browser on the provider's page.
    @objc private dynamic lazy var browser = SignInBrowser(anchor: view).then {
        $0.onClosedByUser = { [weak self] in self?.webClosedByUser() }
    }

    /// What the body shows now, so an event that repeats it redraws nothing.
    private var shownStep: SignInProgress.Step?

    // MARK: Views

    private let scrollView = UIScrollView().then {
        $0.alwaysBounceVertical = true
        $0.keyboardDismissMode = .interactive
    }

    private let column = UIStackView().then {
        $0.axis = .vertical
        $0.alignment = .fill
        $0.spacing = 28
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

    /// What the step asks for: the code, the fields.
    private let body = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = 12
    }

    private let primaryButton = UIButton(configuration: .filled()).then {
        $0.configuration?.cornerStyle = .large
        $0.configuration?.buttonSize = .large
        $0.configuration?.imagePadding = 8
        // the fill is the tint, white in the dark before iOS 26
        $0.configuration?.baseForegroundColor = AppAccent.foreground(glass: .white)
        $0.snp.makeConstraints { $0.height.greaterThanOrEqualTo(52) }
    }

    /// The quiet ways out, under the button.
    private let links = UIStackView().then {
        $0.axis = .vertical
        $0.alignment = .center
        $0.spacing = 4
    }

    @objc private dynamic var primaryAction: (() -> Void)?
    @objc private dynamic var keyForm: ProviderKeyFormController?

    @objc private dynamic lazy var spinnerItem: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.isAccessibilityElement = true
        spinner.accessibilityLabel = String(localized: "Waiting")
        spinner.startAnimating()
        return UIBarButtonItem(customView: spinner)
    }()

    init(account: AgentAccount) {
        provider = account.provider
        methods = [account.method] + (account.alternativeMethods ?? []).filter { $0 != account.method }
        isEditingConfiguration = account.signedIn && account.isAPIKeyAccount
        method = account.isAPIKeyAccount ? .apiKey : account.method
        super.init(nibName: nil, bundle: nil)
        title = account.provider.displayName
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(account:)")
    }

    deinit {
        follower?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.largeTitleDisplayMode = .never

        primaryButton.addAction(UIAction { [weak self] _ in self?.primaryAction?() }, for: .primaryActionTriggered)

        let header = UIStackView(arrangedSubviews: [iconView, titleLabel, subtitleLabel]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = 10
            $0.setCustomSpacing(18, after: iconView)
        }
        iconView.snp.makeConstraints { $0.size.equalTo(72) }
        titleLabel.snp.makeConstraints { $0.width.equalToSuperview() }
        subtitleLabel.snp.makeConstraints { $0.width.equalToSuperview() }

        column.addArrangedSubview(header)
        column.addArrangedSubview(body)
        column.addArrangedSubview(primaryButton)
        column.addArrangedSubview(links)
        column.setCustomSpacing(16, after: primaryButton)

        view.addSubview(scrollView)
        scrollView.addSubview(column)
        scrollView.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview()
            $0.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
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

    /// Leaving the page — back, or the sheet closed — ends the sign-in; an
    /// interactive back that is called off does not.
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
        browser.close()
        guard !progress.isFinished else { return }
        follower?.cancel()
        if let handle {
            Task { try? await ApelinService.app.agentSignInCancel(taskID: handle.taskID) }
        }
    }

    // MARK: - Following

    /// Ends the sign-in on screen, if it is still going, and starts the one
    /// `method` names.
    private func switchMethod(to next: AgentSignInMethod) {
        abandon()
        method = next
        view.endEditing(true)
        start()
    }

    @objc private dynamic func start() {
        follower?.cancel()
        progress = SignInProgress()
        handle = nil
        submitting = false
        openedPage = nil
        isWaitingForContinue = false
        shownStep = nil
        render()
        let method = method == methods.first ? nil : method
        let editing = isEditingConfiguration && method != .browser && method != .deviceCode
        follower = Task { [weak self, provider] in
            let handle: TaskHandle
            do {
                if editing {
                    let configuration = try await ApelinService.app.agentAPIConfiguration(provider: provider)
                    guard !Task.isCancelled else { return }
                    self?.savedValues = configuration.values
                }
                handle = try await ApelinService.app.agentSignIn(provider: provider, method: method)
            } catch {
                guard !Task.isCancelled else { return }
                self?.lose(error)
                return
            }
            guard !Task.isCancelled else {
                try? await ApelinService.app.agentSignInCancel(taskID: handle.taskID)
                return
            }
            self?.handle = handle
            var cursor = EventSeq.start
            while !Task.isCancelled {
                do {
                    for try await event in ApelinService.app.events(of: handle, afterSeq: cursor) {
                        cursor = event.seq
                        self?.receive(event)
                    }
                    return
                } catch {
                    if Task.isCancelled {
                        return
                    }
                    if let error = error as? ApelinError, error.code.endsTaskFollowing {
                        self?.lose(error)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func receive(_ event: TaskEvent) {
        let wasFinished = progress.isFinished
        progress.apply(event)
        guard !submitting else { return }
        if progress.isFinished, !wasFinished {
            finished()
        }
        render()
    }

    @objc private dynamic func lose(_ error: Error) {
        guard !progress.isFinished else { return }
        progress.lost(Self.unavailableText(error))
        finished()
        render()
    }

    @objc dynamic static func unavailableText(_ error: Error) -> String {
        if let error = error as? ApelinError, error.code == .backendUnavailable {
            return String(localized: """
            Apelin’s background service is unavailable. Reinstall Apelin with your preferred package \
            manager to sign in.
            """)
        }
        return error.readableMessage
    }

    @objc private dynamic func finished() {
        onFinish?()
        // the provider's page has done its part either way
        browser.close()
        guard case .ended(.succeeded, _) = progress.step else {
            // it may have ended while the user was in Safari
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Sign-in did not finish"))
            return
        }
        view.endEditing(true)
        SPIndicator.present(
            title: isEditingConfiguration ? String(localized: "Configuration Updated") : String(localized: "Signed In"),
            preset: .done,
            haptic: .success,
        )
        chooseModels()
    }

    @objc private dynamic func chooseModels() {
        guard !submitting else { return }
        submitting = true
        updatePrimary()
        Task { [weak self] in
            guard let self else { return }
            defer { submitting = false; updatePrimary() }
            do {
                let accounts = try await ApelinService.app.agentAccountList().accounts
                guard let account = accounts.first(where: { $0.provider == self.provider && $0.signedIn }),
                      let navigation = navigationController, navigation.presentingViewController != nil
                else { return }
                let page = ModelActivationController(account: account)
                page.navigationItem.leftBarButtonItem = UIBarButtonItem(
                    image: UIImage(systemName: "xmark"),
                    primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) },
                )
                page.navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Close")
                navigation.isModalInPresentation = false
                navigation.setViewControllers([page], animated: true)
            } catch {
                presentNotice(title: "Models Unavailable", message: error.readableMessage)
            }
        }
    }

    // MARK: - Drawing

    @objc private dynamic func render() {
        let step = progress.step
        let waiting: Bool = switch step {
        case .starting: true
        case .deviceCode, .browser: !isWaitingForContinue
        case .keys: submitting
        case .ended: false
        }
        let barItem: UIBarButtonItem? = if waiting {
            spinnerItem
        } else if case .keys = step {
            keyForm?.submitItem
        } else {
            nil
        }
        if navigationItem.rightBarButtonItem !== barItem {
            navigationItem.rightBarButtonItem = barItem
        }
        guard step != shownStep else {
            updatePrimary()
            return
        }
        shownStep = step

        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        links.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let form = keyForm {
            form.willMove(toParent: nil)
            form.view.removeFromSuperview()
            form.removeFromParent()
            keyForm = nil
        }
        scrollView.isHidden = false
        iconView.image = provider.icon
        iconView.tintColor = nil
        titleLabel.text = provider.displayName
        subtitleLabel.text = provider.signInSummary
        primaryButton.isHidden = false
        body.isHidden = false

        switch step {
        case .starting:
            primaryButton.isHidden = true
            body.isHidden = true
        case let .deviceCode(code, page, pageHoldsCode):
            // the page opens by itself with the code on the clipboard, which
            // the keyboard offers to paste: no button, a link to open it again
            body.addArrangedSubview(DeviceCodeView(code: code))
            primaryButton.isHidden = true
            openOnce(page, copying: pageHoldsCode ? nil : code)
        case let .browser(page, _):
            body.isHidden = true
            primaryButton.isHidden = true
            openOnce(page, copying: nil)
        case let .keys(keys):
            let form = ProviderKeyFormController(
                keys: keys,
                alternatives: methods.filter { $0 != method },
                initialValues: savedValues,
            )
            form.onSubmit = { [weak self] values in self?.send(values) }
            form.onSwitchMethod = { [weak self] method in self?.switchMethod(to: method) }
            addChild(form)
            view.addSubview(form.view)
            form.view.snp.makeConstraints {
                $0.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
                $0.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
            }
            form.didMove(toParent: self)
            keyForm = form
            form.loadViewIfNeeded()
            navigationItem.rightBarButtonItem = form.submitItem
            scrollView.isHidden = true
            updatePrimary()
            return
        case let .ended(state, message):
            body.isHidden = true
            let succeeded = state == .succeeded
            iconView.image = UIImage(systemName: succeeded ? "checkmark.circle.fill"
                : state == .cancelled ? "xmark.circle.fill" : "exclamationmark.circle.fill")
            iconView.tintColor = succeeded ? .systemGreen : state == .cancelled ? .secondaryLabel : .systemOrange
            titleLabel.text = succeeded
                ? (isEditingConfiguration ? String(localized: "Configuration Updated") : String(localized: "Signed In"))
                : state == .cancelled
                ? String(localized: "Cancelled")
                : (isEditingConfiguration
                    ? String(localized: "Unable to Load Configuration")
                    : String(localized: "Sign-In Failed"))
            subtitleLabel.text = message
            if succeeded {
                setPrimary(String(localized: "Enable Models")) { [weak self] in self?.chooseModels() }
            } else {
                setPrimary(String(localized: "Try Again")) { [weak self] in self?.start() }
            }
        }
        // the other ways in, under everything but a finished sign-in
        if !isSucceeded {
            for other in methods where other != method {
                addLink(other.switchTitle) { [weak self] in self?.switchMethod(to: other) }
            }
        }
        links.isHidden = links.arrangedSubviews.isEmpty
        updatePrimary()
    }

    @objc private dynamic var isSucceeded: Bool {
        if case .ended(.succeeded, _) = progress.step {
            return true
        }
        return false
    }

    @objc private dynamic func setPrimary(_ title: String, action: @escaping () -> Void) {
        primaryButton.configuration?.title = title
        primaryAction = action
    }

    /// Sign In waits for every required field, and spins while it is sent.
    @objc private dynamic func updatePrimary() {
        keyForm?.isSubmitting = submitting
        primaryButton.isEnabled = !submitting
        primaryButton.configuration?.showsActivityIndicator = submitting
    }

    /// A quiet way out: footnote-sized, grey and underlined.
    @objc private dynamic func addLink(_ title: String, action: @escaping () -> Void) {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .secondaryLabel
        configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.preferredFont(forTextStyle: .footnote),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        links.addArrangedSubview(UIButton(configuration: configuration, primaryAction: UIAction { _ in action() }))
    }

    /// Opens the page the first time it is known, a moment after the sheet
    /// is drawn so the code is seen on the way; a page that does not take
    /// the code from its link gets it on the clipboard first.
    @objc private dynamic func openOnce(_ page: URL, copying code: String?) {
        guard openedPage != page else { return }
        openedPage = page
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, view.window != nil, UIApplication.shared.applicationState == .active,
                  !progress.isFinished
            else { return }
            open(page, copying: code)
        }
    }

    // MARK: - Acting

    /// The provider's page in the in-app browser. The flow ends on kwwk's
    /// side — a device code approved, the loopback reached — and the page
    /// is closed from here when the task ends. Closing it by hand leaves the
    /// sign-in waiting; Continue opens it again.
    @objc private dynamic func open(_ page: URL, copying code: String?) {
        isWaitingForContinue = false
        primaryButton.isHidden = true
        render()
        if let code {
            UIPasteboard.general.string = code
            SPIndicator.present(title: String(localized: "Code Copied"), preset: .done, haptic: .success)
        }
        browser.open(page)
    }

    /// The page closed by the user, or the system's prompt declined. The
    /// sign-in goes on waiting — a code already entered, or a grant already
    /// made, still finishes it — and Continue opens the page again.
    @objc private dynamic func webClosedByUser() {
        guard !progress.isFinished, let page = openedPage else { return }
        isWaitingForContinue = true
        render()
        let code: String? = if case let .deviceCode(code, _, false) = progress.step {
            code
        } else {
            nil
        }
        primaryButton.isHidden = false
        setPrimary(String(localized: "Continue")) { [weak self] in self?.open(page, copying: code) }
    }

    /// What the user typed goes to the sign-in once and is not kept here.
    private func send(_ values: [AgentSignInField: String]) {
        guard let handle, !submitting else { return }
        submitting = true
        render()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ProviderProgress.run(title: "Fetching Models", from: self, cancel: {
                    try? await ApelinService.app.agentSignInCancel(taskID: handle.taskID)
                }) {
                    try await ApelinService.app.agentSignInRespond(
                        taskID: handle.taskID,
                        fields: values,
                        verifyModel: false,
                    )
                    for try await event in ApelinService.app.events(of: handle) {
                        self.receive(event)
                        if self.progress.isFinished {
                            break
                        }
                    }
                    try Task.checkCancellation()
                }
                submitting = false
                if progress.isFinished {
                    finished()
                }
                render()
            } catch {
                submitting = false
                render()
                if !(error is CancellationError) {
                    presentNotice(title: "Check the Details", message: error.readableMessage)
                }
            }
        }
    }
}
