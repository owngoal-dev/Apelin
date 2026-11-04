import UIKit

/// One line under a running summary, at the reading width, between
/// hairlines on a faint grey ground that runs the row's whole width: the
/// summary's newest call (`ToolCallBanner`). A file edit leads with the
/// file's name and the lines added in green and removed in red, so
/// truncation takes the end of the reason, never the numbers. A new call,
/// or a call's counts coming in, fades in, at once under Reduce Motion.
/// The full record stays in the trace the summary opens.
final class ToolCallBannerView: UIView {
    static let height: CGFloat = 32

    private let label = UILabel()
    /// The grey ground and its hairlines, drawn past the view's own edges
    /// to the row's: the line keeps the reading width, its ground does not.
    private let ground = UIView()
    private let topRule = UIView()
    private let bottomRule = UIView()
    private var shown: ToolCallBanner?

    /// How far the ground reaches past each side, set by the row.
    @objc dynamic var groundBleed = UIEdgeInsets.zero {
        didSet {
            if groundBleed != oldValue {
                setNeedsLayout()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        ground.backgroundColor = UIColor.systemGray.withAlphaComponent(0.05)
        addSubview(ground)
        for rule in [topRule, bottomRule] {
            rule.backgroundColor = .separator
            ground.addSubview(rule)
        }
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// `animated`: the same summary showing its next call, or its counts.
    func show(_ banner: ToolCallBanner, animated: Bool) {
        guard banner != shown else { return }
        let previous = shown
        shown = banner
        label.layer.removeAllAnimations()
        label.attributedText = Self.line(banner)
        accessibilityLabel = banner.reason
        accessibilityValue = Self.spokenFile(banner)
        if animated, previous != nil, window != nil, !UIAccessibility.isReduceMotionEnabled {
            let fadeIn = CATransition()
            fadeIn.type = .fade
            fadeIn.duration = 0.2
            label.layer.add(fadeIn, forKey: "content")
        }
    }

    @objc dynamic func reset() {
        shown = nil
        label.layer.removeAllAnimations()
        label.attributedText = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rule = 1 / max(traitCollection.displayScale, 1)
        ground.frame = bounds.inset(
            by: UIEdgeInsets(top: 0, left: -groundBleed.left, bottom: 0, right: -groundBleed.right),
        )
        topRule.frame = CGRect(x: 0, y: 0, width: ground.bounds.width, height: rule)
        bottomRule.frame = CGRect(x: 0, y: ground.bounds.height - rule, width: ground.bounds.width, height: rule)
        label.frame = bounds.insetBy(dx: ChatMessageRow.horizontalPadding, dy: 0)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory,
           let shown
        {
            label.attributedText = Self.line(shown)
        }
    }

    /// "Tweak.x  +12 −3  Hook the lock screen".
    private static func line(_ banner: ToolCallBanner) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let figures = UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .medium)
        let result = NSMutableAttributedString()
        func append(_ text: String, _ font: UIFont, _ color: UIColor) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        if let file = banner.file {
            append(file, UIFont.systemFont(ofSize: font.pointSize, weight: .medium), .label)
            if let change = banner.change {
                append("  +\(change.added)", figures, .systemGreen)
                append(" −\(change.removed)", figures, .systemRed)
            }
            append("  ", font, .secondaryLabel)
        }
        let reason = banner.reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        append(reason, font, .secondaryLabel)
        return result
    }

    /// The file and its counts in words: "Tweak.x, 12 lines added and 3
    /// lines removed".
    private static func spokenFile(_ banner: ToolCallBanner) -> String? {
        guard let file = banner.file else { return nil }
        var parts = [file]
        if let change = banner.change {
            parts.append(change.added == 1
                ? String(localized: "1 line added")
                : String(localized: "\(change.added) lines added"))
            parts.append(change.removed == 1
                ? String(localized: "1 line removed")
                : String(localized: "\(change.removed) lines removed"))
        }
        return ListFormatter.localizedString(byJoining: parts)
    }
}
