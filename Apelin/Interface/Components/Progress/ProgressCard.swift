import AlertController
import SnapKit
import Then
import UIKit

/// Work that makes the user wait, under Fila's progress card: the app's icon,
/// a title, what is being worked on, a bar (or a spinner while the amount is
/// not known) with a count under it, and Cancel. The card appears only once
/// the work has taken a moment, so work that ends in a blink shows nothing,
/// and it is gone before `run` returns: an alert the caller shows next would
/// otherwise be presented into the card's dismissal and never appear.
///
/// Cancel is enabled only where `cancellable` says the work can stop
/// part-way; it cancels the work's task, and `run` throws
/// `CancellationError` once the work has stopped. Fila's `ProgressCard`,
/// `JobCover` and `OperationCoverViewController`, folded into one.
@MainActor
enum ProgressCard {
    /// What the card says while the work runs.
    struct Status {
        var subtitle: String
        /// 0…1, or nil for a spinner.
        var fraction: Double?
        /// Under the bar: "3 of 7", "120 MB of 700 MB".
        var count: String?

        init(subtitle: String, fraction: Double? = nil, count: String? = nil) {
            self.subtitle = subtitle
            self.fraction = fraction
            self.count = count
        }
    }

    static let revealDelay: TimeInterval = 0.35

    static func run<T>(
        title: String,
        message: String,
        cancellable: Bool,
        from presenter: UIViewController,
        operation: @escaping @MainActor (_ update: @escaping @MainActor (Status) -> Void) async throws -> T,
    ) async throws -> T {
        let card = ProgressCardController(title: title, status: Status(subtitle: message), cancellable: cancellable)
        let work = Task { @MainActor in
            try await operation { [weak card] in card?.status = $0 }
        }
        card.onCancel = { work.cancel() }
        card.present(after: revealDelay, from: presenter)
        let result = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        await card.finish()
        // The work's own outcome: one that finished is kept whatever Cancel
        // was tapped while the card left, and a failure the work reported
        // after a cancel (what it could not take back) is said, not hidden
        // behind the cancel.
        switch result {
        case let .success(value):
            return value
        case let .failure(error) where work.isCancelled && !(error is CancellationError):
            throw error
        case .failure where work.isCancelled:
            throw CancellationError()
        case let .failure(error):
            throw error
        }
    }
}

/// The card itself, hosted by `AlertViewController`.
private final class ProgressCardController: UIViewController {
    var status: ProgressCard.Status {
        didSet { update() }
    }

    var onCancel: () -> Void = {}

    private let cancellable: Bool
    private var isFinished = false
    private var isShown = false
    private var isClosing = false
    private var dismissed: [CheckedContinuation<Void, Never>] = []

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let separator = UIView()
    private let countLabel = UILabel()
    private let cancelButton = UIButton(type: .system)

    init(title: String, status: ProgressCard.Status, cancellable: Bool) {
        self.status = status
        self.cancellable = cancellable
        super.init(nibName: nil, bundle: nil)
        titleLabel.text = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:status:cancellable:)")
    }

    func present(after delay: TimeInterval, from presenter: UIViewController) {
        Task { @MainActor [weak self, weak presenter] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !isFinished, let presenter, presenter.viewIfLoaded?.window != nil,
                  presenter.presentedViewController == nil, !presenter.isBeingDismissed
            else { return }
            let alert = AlertViewController(contentViewController: self)
            presenter.present(alert, animated: true)
            // a refused presentation sets nothing
            isShown = alert.presentingViewController != nil
        }
    }

    /// Closes the card, and returns once it is off the screen; at once where
    /// none was shown.
    func finish() async {
        isFinished = true
        guard isShown else { return }
        await withCheckedContinuation { continuation in
            dismissed.append(continuation)
            close()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        update()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // here rather than in `close`: the screen underneath can take the
        // card down without asking
        isShown = false
        let waiting = dismissed
        dismissed.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func build() {
        view.backgroundColor = AlertControllerConfiguration.backgroundColor.withAlphaComponent(0.5)
        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        view.addSubview(material)
        material.snp.makeConstraints { $0.edges.equalToSuperview() }

        let artwork = UIImageView(image: AlertControllerConfiguration.alertImage).then {
            $0.contentMode = .scaleAspectFill
            $0.layer.cornerRadius = 12
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
            $0.isAccessibilityElement = false
        }
        artwork.snp.makeConstraints { $0.size.equalTo(64) }
        titleLabel.do {
            $0.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
            $0.adjustsFontForContentSizeCategory = true
            $0.textAlignment = .center
            $0.numberOfLines = 0
            $0.accessibilityTraits = .header
        }
        for label in [subtitleLabel, countLabel] {
            label.do {
                $0.font = .preferredFont(forTextStyle: .footnote)
                $0.adjustsFontForContentSizeCategory = true
                $0.textAlignment = .center
                $0.textColor = .secondaryLabel
                $0.numberOfLines = 0
            }
        }
        subtitleLabel.textColor = .label
        subtitleLabel.numberOfLines = 2
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        spinner.hidesWhenStopped = true
        bar.progressTintColor = AlertControllerConfiguration.accentColor
        let gauge = UIView()
        gauge.addSubview(bar)
        gauge.addSubview(spinner)
        gauge.snp.makeConstraints { $0.height.equalTo(24) }
        bar.snp.makeConstraints { $0.leading.trailing.centerY.equalToSuperview() }
        spinner.snp.makeConstraints { $0.center.equalToSuperview() }
        separator.backgroundColor = AlertControllerConfiguration.separatorColor
        // a hairline at the scale of the display the card is on: a device
        // with two displays has no one main screen to ask
        separator.snp.makeConstraints { $0.height.equalTo(1 / max(traitCollection.displayScale, 1)) }

        // the library fills a card's only action, so the card's only button
        // is filled, and as tall as the library's: its title and 8 pt above
        // and below
        var button = UIButton.Configuration.plain()
        button.title = String(localized: "Cancel")
        button.baseForegroundColor = AlertControllerConfiguration.accentForegroundColor
        button.background.backgroundColor = AlertControllerConfiguration.accentColor
        button.background.cornerRadius = 12
        button.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        button.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFontMetrics(forTextStyle: .body)
                .scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
            return outgoing
        }
        cancelButton.configuration = button
        // a fill does not dim with its title; work that cannot stop
        // part-way must not look pressable
        cancelButton.configurationUpdateHandler = { $0.alpha = $0.isEnabled ? 1 : 0.4 }
        cancelButton.isEnabled = cancellable
        cancelButton.addAction(UIAction { [weak self] _ in
            guard let self, cancellable else { return }
            onCancel()
            close()
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            artwork, titleLabel, subtitleLabel, separator, gauge, countLabel, cancelButton,
        ]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = 16
            $0.setCustomSpacing(8, after: gauge)
        }
        // the same compact card at ordinary text sizes, scrolled when
        // accessibility text or a short window exceeds it
        let scroll = UIScrollView()
        view.addSubview(scroll)
        scroll.snp.makeConstraints { $0.edges.equalToSuperview() }
        scroll.addSubview(stack)
        stack.snp.makeConstraints {
            $0.edges.equalTo(scroll.contentLayoutGuide).inset(16)
            $0.width.equalTo(scroll.frameLayoutGuide).offset(-32)
        }
        view.snp.makeConstraints { $0.height.equalTo(stack).offset(32).priority(.high) }
        for child in stack.arrangedSubviews where child !== artwork {
            child.snp.makeConstraints { $0.width.equalTo(stack) }
        }
    }

    private func update() {
        guard isViewLoaded, !isClosing else { return }
        subtitleLabel.text = status.subtitle.isEmpty ? String(localized: "Preparing…") : status.subtitle
        if let fraction = status.fraction {
            bar.setProgress(Float(fraction), animated: view.window != nil && !UIAccessibility.isReduceMotionEnabled)
            bar.isHidden = false
            spinner.stopAnimating()
        } else {
            bar.isHidden = true
            spinner.startAnimating()
        }
        // a rule above a spinner divides the card into nothing
        separator.isHidden = bar.isHidden
        countLabel.text = status.count
        countLabel.isHidden = status.count?.isEmpty != false
    }

    private func close() {
        guard !isClosing, let alert = parent else { return }
        isClosing = true
        cancelButton.isEnabled = false
        alert.dismiss(animated: true)
    }
}
