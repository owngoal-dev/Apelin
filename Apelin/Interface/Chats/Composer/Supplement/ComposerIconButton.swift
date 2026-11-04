// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

/// One of the composer's round icons: a symbol and a tap. It has no text,
/// so it carries the name VoiceOver reads, set with the symbol and changed
/// with it.
class ComposerIconButton: UIButton {
    let iconView = UIImageView()

    @objc dynamic var tapAction: () -> Void = {}

    required init() {
        super.init(frame: .zero)
        addSubview(iconView)
        iconView.tintColor = .label
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit

        addTarget(self, action: #selector(buttonAction), for: .primaryActionTriggered)

        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(iconName:label:)")
    }

    required convenience init(iconName: String, label: String) {
        self.init()
        iconView.image = UIImage(named: iconName)?.withRenderingMode(.alwaysTemplate)
        accessibilityLabel = label
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        iconView.frame = bounds.insetBy(dx: 2, dy: 2)
    }

    /// Hidden or faded out, it is not there: the composer keeps its unused
    /// icons laid out but invisible.
    @objc dynamic private var isShown: Bool {
        !isHidden && alpha > 0
    }

    @objc dynamic private func buttonAction() {
        guard isShown else { return }
        tapAction()
    }

    override var isHighlighted: Bool {
        didSet { iconView.alpha = isHighlighted ? 0.4 : 1 }
    }

    @objc dynamic func change(iconName: String) {
        UIView.transition(with: iconView, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {
            self.iconView.image = UIImage(named: iconName)?.withRenderingMode(.alwaysTemplate)
        }
    }
}
