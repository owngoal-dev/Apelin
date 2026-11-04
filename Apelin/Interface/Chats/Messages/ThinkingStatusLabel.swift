import LitextAnimation
import UIKit

/// A summary's title. On screen it changes at most once a second: the
/// first change shows at once, and whatever arrives within the second waits,
/// the latest of it shown when the second is up, so a run flipping between
/// "Thinking…" and "Executing…" never cuts a transition short.
final class ThinkingStatusLabel: LTXAnimatableLabel {
    private static let minimumInterval: TimeInterval = 1

    @objc dynamic var font = UIFont.preferredFont(forTextStyle: .body) {
        didSet { updateText(animated: false) }
    }

    @objc dynamic var text: String? {
        didSet { requestText() }
    }

    /// Called whenever what is drawn changes, and whether it animates: what
    /// sits after the text moves with it.
    @objc dynamic var onShownTextChange: ((_ animated: Bool) -> Void)?

    /// How wide the drawn text is.
    @objc dynamic var shownTextWidth: CGFloat {
        ceil(NSAttributedString(string: shown ?? "", attributes: [.font: font]).size().width)
    }

    /// What is drawn, which trails `text` while a change waits its turn.
    @objc dynamic private var shown: String?
    @objc dynamic private var shownIdentity: AnyHashable?
    @objc dynamic private var lastChange: Date = .distantPast
    private var pending: DispatchWorkItem?

    @objc dynamic var isThinking = false {
        didSet {
            if isThinking != oldValue {
                updateShimmer()
            }
        }
    }

    private let shimmer = ShimmerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        animator = LTXNumericTransitionAnimator()
        animationPolicy = LTXNumericTransitionAnimator.policy
        isSelectable = false
        isAccessibilityElement = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateShimmer),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// Another row's text, or a label off screen, takes the text at once.
    @objc dynamic private func requestText() {
        guard text != shown || pending != nil else { return }
        pending?.cancel()
        pending = nil
        guard window != nil, shownIdentity == animationIdentity else {
            show(animated: false)
            return
        }
        let wait = lastChange.addingTimeInterval(Self.minimumInterval).timeIntervalSinceNow
        guard wait > 0 else {
            show(animated: true)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pending = nil
            show(animated: window != nil)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    @objc dynamic private func show(animated: Bool) {
        shownIdentity = animationIdentity
        guard text != shown else { return }
        shown = text
        if animated {
            lastChange = Date()
        }
        updateText(animated: animated)
    }

    /// While thinking the text is opaque and the shimmer's resting half
    /// alpha dims it to the same 50% a finished header is drawn in. Right
    /// to left it is set against the right edge, where the shimmer is.
    @objc dynamic private func updateText(animated: Bool) {
        let color = layer.mask == nil ? UIColor.label.withAlphaComponent(0.5) : .label
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if laysOutRightToLeft {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            attributes[.paragraphStyle] = paragraph
        }
        let animates = animated && !UIAccessibility.isReduceMotionEnabled
        setAttributedText(NSAttributedString(string: shown ?? "", attributes: attributes), animated: animates)
        setNeedsLayout()
        onShownTextChange?(animates)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        font = .preferredFont(forTextStyle: .body)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shimmer.fit(width: shownTextWidth, in: bounds, rightToLeft: laysOutRightToLeft)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateShimmer()
    }

    @objc dynamic private func updateShimmer() {
        shimmer.stop()
        let shimmers = isThinking && window != nil && !UIAccessibility.isReduceMotionEnabled
        if shimmers != (layer.mask != nil) {
            layer.mask = shimmers ? shimmer : nil
            updateText(animated: false)
        }
        if shimmers {
            shimmer.start()
        }
    }
}
