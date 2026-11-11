import SnapKit
import SPIndicator
import Then
import UIKit

/// A sign-in page's address on a rounded plate, for a browser on another
/// device: a tap copies the whole address. Only the page's host is shown;
/// the address itself is long and nothing in it is for reading. The glyph
/// at the trailing edge says the plate copies, and is a tick for a moment
/// after it did.
final class LoginLinkView: UIControl {
    private let badge = UIView().then {
        $0.isUserInteractionEnabled = false
        $0.layer.cornerCurve = .continuous
    }

    private let glyph = UIImageView().then {
        $0.image = UIImage(
            systemName: "link",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
                .applying(UIImage.SymbolConfiguration(weight: .semibold)),
        )
        $0.contentMode = .center
    }

    private let titleLabel = UILabel().then {
        $0.text = String(localized: "Sign-In Link")
        $0.font = .preferredFont(forTextStyle: .headline)
        $0.adjustsFontForContentSizeCategory = true
        $0.numberOfLines = 0
    }

    private let hostLabel = UILabel().then {
        $0.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.lineBreakMode = .byTruncatingMiddle
    }

    /// What a tap does, and for a moment that it did.
    private let statusView = UIImageView().then {
        $0.contentMode = .center
        $0.setContentHuggingPriority(.required, for: .horizontal)
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// Puts the copy glyph back; replaced by each tap.
    private var restoration: DispatchWorkItem?

    init(page: URL) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous

        let host = page.host ?? page.absoluteString
        hostLabel.text = host
        show(copied: false)

        let text = UIStackView(arrangedSubviews: [titleLabel, hostLabel]).then {
            $0.axis = .vertical
            $0.spacing = 2
            $0.isUserInteractionEnabled = false
        }
        badge.addSubview(glyph)
        addSubview(badge)
        addSubview(text)
        addSubview(statusView)
        glyph.snp.makeConstraints { $0.center.equalToSuperview() }
        badge.snp.makeConstraints {
            $0.leading.equalToSuperview().inset(16)
            $0.centerY.equalToSuperview()
            $0.size.equalTo(badgeSide)
            $0.top.greaterThanOrEqualToSuperview().inset(14)
        }
        text.snp.makeConstraints {
            $0.leading.equalTo(badge.snp.trailing).offset(12)
            $0.top.bottom.equalToSuperview().inset(14)
            $0.trailing.equalTo(statusView.snp.leading).offset(-12)
        }
        statusView.snp.makeConstraints {
            $0.trailing.equalToSuperview().inset(18)
            $0.centerY.equalToSuperview()
        }
        badge.layer.cornerRadius = badgeSide / 2
        tintColorDidChange()

        addAction(UIAction { [weak self] _ in
            UIPasteboard.general.string = page.absoluteString
            SPIndicator.present(title: String(localized: "Link Copied"), preset: .done, haptic: .success)
            self?.flashCopied()
        }, for: .touchUpInside)
        // one stop: what it is, where it leads, and that it copies
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Sign-In Link")
        accessibilityValue = host
        accessibilityHint = String(localized: "Copies the link.")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(page:)")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    /// The badge is the tint, thinned; before iOS 26 that is the text's own
    /// colour (`AppAccent`).
    override func tintColorDidChange() {
        super.tintColorDidChange()
        badge.backgroundColor = tintColor.withAlphaComponent(0.12)
        glyph.tintColor = tintColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }
        badge.snp.updateConstraints { $0.size.equalTo(badgeSide) }
        badge.layer.cornerRadius = badgeSide / 2
    }

    /// The badge grows with the text, up to half as large again.
    @objc private dynamic var badgeSide: CGFloat {
        min(UIFontMetrics(forTextStyle: .headline).scaledValue(for: 36), 54)
    }

    /// The tick, then the copy glyph again a moment later.
    @objc private dynamic func flashCopied() {
        restoration?.cancel()
        show(copied: true, animated: true)
        let restoration = DispatchWorkItem { [weak self] in self?.show(copied: false, animated: true) }
        self.restoration = restoration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: restoration)
    }

    @objc private dynamic func show(copied: Bool, animated: Bool = false) {
        let change = { [statusView] in
            statusView.image = UIImage(
                systemName: copied ? "checkmark" : "doc.on.doc",
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
                    .applying(UIImage.SymbolConfiguration(weight: copied ? .semibold : .regular)),
            )
            statusView.tintColor = copied ? .systemGreen : .secondaryLabel
        }
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            change()
            return
        }
        UIView.transition(
            with: statusView,
            duration: 0.2,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
            animations: change,
        )
    }
}
