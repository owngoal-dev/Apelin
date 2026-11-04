// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
// Copied from Xrash WelcomeNotificationsController; text and permission callbacks adapted.
import AlertController
import SnapKit
import Then
import UIKit
import UserNotifications

/// The last welcome page, and only for someone the system has not asked yet:
/// what a crash notification looks like, and the button that asks.
///
/// The system's prompt is one sentence over two buttons and can be shown once.
/// Asked cold, behind a sheet that has just gone away, it is a question about
/// nothing; asked from here it is the answer to a page that has just shown
/// what is on offer. The second page's skeleton — the same stack at the same
/// margin over the same action bar — with a notification drawn where the
/// stages were.
final class WelcomeNotificationsPage: UIViewController {
    private let flow: WelcomeFlow
    @objc private dynamic var authorization: UNAuthorizationStatus = .notDetermined
    private var request: Task<Void, Never>?
    deinit { request?.cancel(); NotificationCenter.default.removeObserver(self) }

    @objc private dynamic lazy var actionBar = WelcomeActionBar(
        title: String(localized: "Turn On Notifications"),
        secondaryTitle: String(localized: "Not Now"),
        action: { [weak self] in self?.turnOn() },
        secondaryAction: { [weak self] in self?.decline() },
    )

    init(flow: WelcomeFlow) {
        self.flow = flow
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = WelcomeStyle.background
        view.tintColor = WelcomeStyle.accent
        setupLayout()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshAuthorization),
            name: UIApplication.didBecomeActiveNotification,
            object: nil,
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.view.tintColor = WelcomeStyle.accent
        // Keep the welcome sheet presented while allowing navigation back.
        navigationController?.isModalInPresentation = true
        refreshAuthorization()
    }

    /// Return on a keyboard is the button, as on the pages before.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(activatePrimaryButton))]
    }

    @objc private dynamic func activatePrimaryButton() {
        actionBar.activate()
    }

    // MARK: Answers

    /// The switch in Settings is what the answer becomes, either way: a
    /// refusal leaves it off rather than on and silent.
    @objc private dynamic func refreshAuthorization() {
        guard actionBar.isEnabled else { return }
        request?.cancel()
        request = Task { [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard !Task.isCancelled, let self else { return }
            authorization = settings.authorizationStatus
            switch authorization {
            case .authorized, .provisional, .ephemeral: actionBar.title = String(localized: "Continue")
            case .denied: actionBar.title = String(localized: "Open Settings")
            default: actionBar.title = String(localized: "Turn On Notifications")
            }
        }
    }

    @objc private dynamic func turnOn() {
        switch authorization {
        case .authorized, .provisional, .ephemeral: flow.showCaution()
        case .denied:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        default:
            actionBar.isEnabled = false
            request = Task { [weak self] in
                guard let self else { return }
                defer { actionBar.isEnabled = true }
                do {
                    _ = try await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound, .badge])
                    guard !Task.isCancelled else { return }
                    flow.showCaution()
                } catch { presentNotice(title: "Notifications Unavailable", message: error.readableMessage) }
            }
        }
    }

    @objc private dynamic func decline() {
        flow.showCaution()
    }

    // MARK: Layout

    @objc private dynamic func setupLayout() {
        let heading = UILabel().then {
            $0.text = String(localized: "Notifications")
            $0.font = WelcomeStyle.titleFont
            $0.textColor = WelcomeStyle.titleColor
            $0.numberOfLines = 1
            $0.adjustsFontSizeToFitWidth = true
            $0.minimumScaleFactor = 0.7
        }
        let intro = UILabel().then {
            // The same sentence Settings words its footer with.
            $0.text = String(localized: "Allow notifications from Apelin. You can change permission in Settings at any time.")
            $0.font = WelcomeStyle.subtitleFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 0
        }
        let rule = UIView().then { $0.backgroundColor = .separator }
        rule.snp.makeConstraints { $0.height.equalTo(0.5) }
        // The drawn notification says what one is; nothing under it repeats it.
        let stack = UIStackView(arrangedSubviews: [heading, intro, rule, WelcomeNoticePreview()]).then {
            $0.axis = .vertical
            $0.spacing = 24
            $0.alignment = .fill
            $0.setCustomSpacing(8, after: heading)
        }

        let scrollView = UIScrollView().then { $0.alwaysBounceVertical = true }
        scrollView.hideTopEdgeEffect()
        let contentView = UIView()
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stack)
        view.addSubview(actionBar)

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.snp.makeConstraints { x in
            x.top.equalToSuperview()
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            x.bottom.equalTo(actionBar.snp.top).offset(-8)
        }
        contentView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
            x.width.equalTo(scrollView.snp.width)
        }
        stack.snp.makeConstraints { x in
            x.top.equalToSuperview().inset(WelcomeStyle.headingTopMargin)
            x.bottom.equalToSuperview().inset(28)
            x.leading.trailing.equalToSuperview().inset(WelcomeStyle.horizontalMargin)
        }
        actionBar.snp.makeConstraints { x in
            x.leading.trailing.bottom.equalToSuperview()
        }
    }
}

/// A notification as it will arrive, drawn rather than described: this app's
/// icon, `Dopamine Crashed`, and the list row's line under it.
private final class WelcomeNoticePreview: UIView {
    init() {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        isAccessibilityElement = false

        let icon = UIImageView(image: AlertControllerConfiguration.alertImage).then {
            $0.contentMode = .scaleAspectFill
            $0.layer.cornerRadius = 9
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
        }
        let title = UILabel().then {
            // The words the notification itself uses, from the same key.
            $0.text = "Apelin"
            $0.font = WelcomeStyle.featureTitleFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.titleColor
        }
        let time = UILabel().then {
            $0.text = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            $0.font = WelcomeStyle.detailFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let body = UILabel().then {
            // A report's own words are in no language.
            $0.text = String(localized: "Notifications from Apelin will appear here.")
            $0.font = WelcomeStyle.detailFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.titleColor
            $0.lineBreakMode = .byTruncatingTail
        }
        let headline = UIStackView(arrangedSubviews: [title, time]).then {
            $0.axis = .horizontal
            $0.spacing = 8
            $0.alignment = .firstBaseline
        }
        let words = UIStackView(arrangedSubviews: [headline, body]).then {
            $0.axis = .vertical
            $0.spacing = 2
            $0.alignment = .fill
        }
        let content = UIStackView(arrangedSubviews: [icon, words]).then {
            $0.axis = .horizontal
            $0.spacing = 12
            $0.alignment = .center
        }
        addSubview(content)
        icon.snp.makeConstraints { x in
            x.width.height.equalTo(38)
        }
        content.snp.makeConstraints { x in
            x.edges.equalToSuperview().inset(14)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

extension UIScrollView {
    /// iOS 26 blurs whatever scrolls under the top edge. On a welcome page
    /// that edge is the heading's own margin, and the blur sat on the heading.
    func hideTopEdgeEffect() {
        if #available(iOS 26.0, *) {
            topEdgeEffect.isHidden = true
        }
    }
}
