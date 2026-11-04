// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

/// FlowDown's square icon tile with its caption underneath.
final class ComposerGiantButton: UIButton {
    private let iconView = UIImageView()
    private let backgroundView = UIView()
    private let labelView = UILabel()
    @objc dynamic var actionBlock: () -> Void = {}

    init(title: String, icon: String) {
        super.init(frame: .zero)
        backgroundView.backgroundColor = .label.withAlphaComponent(0.05)
        backgroundView.layer.cornerRadius = 16
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.isUserInteractionEnabled = false
        addSubview(backgroundView)
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .label.withAlphaComponent(0.75)
        iconView.image = UIImage(named: icon)?.withRenderingMode(.alwaysTemplate)
        backgroundView.addSubview(iconView)
        labelView.text = title
        labelView.textAlignment = .center
        labelView.font = .preferredFont(forTextStyle: .footnote)
        labelView.adjustsFontForContentSizeCategory = true
        labelView.adjustsFontSizeToFitWidth = true
        labelView.minimumScaleFactor = 0.7
        labelView.textColor = .secondaryLabel
        addSubview(labelView)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        addTarget(self, action: #selector(onTapped), for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:icon:)")
    }

    @objc dynamic private func onTapped() {
        actionBlock()
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundView.alpha = isHighlighted ? 0.4 : 1
            labelView.alpha = isHighlighted ? 0.4 : 1
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let labelHeight = max(32, labelView.font.lineHeight + 12)
        backgroundView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - labelHeight)
        iconView.frame = CGRect(
            x: (backgroundView.bounds.width - 28) / 2,
            y: (backgroundView.bounds.height - 28) / 2,
            width: 28,
            height: 28,
        )
        labelView.frame = CGRect(x: 0, y: backgroundView.frame.maxY, width: bounds.width, height: labelHeight)
    }
}
