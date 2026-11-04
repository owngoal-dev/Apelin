// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

/// FlowDown's BlockButton geometry, shared by the composer's small controls.
final class ComposerBlockButton: UIButton {
    @objc dynamic var borderColor: UIColor = .label.withAlphaComponent(0.1) {
        didSet { applyAppearance() }
    }

    private let borderView = UIView()
    private let iconView = UIImageView()
    private let textLabel = UILabel()
    private let inset: CGFloat = 8
    private let spacing: CGFloat = 8
    private let iconSize: CGFloat = 16

    init(text: String, image: UIImage?) {
        super.init(frame: .zero)
        for view in [borderView, iconView, textLabel] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        borderView.backgroundColor = .clear
        borderView.layer.borderWidth = 1
        borderView.layer.cornerRadius = 8
        borderView.layer.cornerCurve = .continuous
        iconView.image = image?.withRenderingMode(.alwaysTemplate)
        iconView.contentMode = .scaleAspectFit
        textLabel.text = text
        textLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        textLabel.numberOfLines = 1
        textLabel.textAlignment = .center
        textLabel.lineBreakMode = .byTruncatingMiddle
        tintColor = .label
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(text:image:)")
    }

    @objc dynamic func setText(_ text: String) {
        textLabel.text = text
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var isHighlighted: Bool {
        didSet {
            let opacity: CGFloat = isHighlighted ? 0.4 : 1
            borderView.alpha = opacity
            iconView.alpha = opacity
            textLabel.alpha = opacity
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: ceil(inset + iconSize + spacing + textLabel.intrinsicContentSize.width + inset),
               height: ceil(max(iconSize, textLabel.intrinsicContentSize.height) + inset * 2))
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyAppearance()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    @objc dynamic private func applyAppearance() {
        borderView.layer.borderColor = borderColor.resolvedColor(with: traitCollection).cgColor
        iconView.tintColor = tintColor
        textLabel.textColor = tintColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        borderView.frame = bounds
        // the icon leads the text: right to left, on its right
        let icon = CGRect(x: inset, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        iconView.frame = directionalFrame(icon)
        textLabel.frame = directionalFrame(CGRect(
            x: icon.maxX + spacing,
            y: inset,
            width: max(0, bounds.width - icon.maxX - spacing - inset),
            height: bounds.height - inset * 2,
        ))
    }
}
