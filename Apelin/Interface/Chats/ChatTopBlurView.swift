import UIKit

/// VariableBlur's alpha-mask CAFilter approach, on a backdrop UIKit does not reconfigure.
/// Reference: https://github.com/nikstar/VariableBlur
final class ChatTopBlurView: UIView {
    override class var layerClass: AnyClass {
        NSClassFromString("CABackdropLayer") ?? CALayer.self
    }

    private let frost = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        frost.locations = [0, 1]
        layer.addSublayer(frost)
        updateFrost()
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let filter = filterClass.perform(
                  NSSelectorFromString("filterWithType:"),
                  with: "variableBlur",
              )?.takeUnretainedValue() as? NSObject
        else { return }

        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: 0, y: 0, width: 2, height: 128)
        gradient.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        gradient.locations = frost.locations
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let mask = UIGraphicsImageRenderer(size: gradient.bounds.size, format: format)
            .image { gradient.render(in: $0.cgContext) }
        filter.setValue(1.0, forKey: "inputRadius")
        filter.setValue(mask.cgImage, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        layer.filters = [filter]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frost.frame = bounds
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFrost()
    }

    @objc dynamic private func updateFrost() {
        let color = UIColor.pageBackground.resolvedColor(with: traitCollection)
        frost.colors = [color.withAlphaComponent(1).cgColor, color.withAlphaComponent(0).cgColor]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window, layer.isKind(of: NSClassFromString("CABackdropLayer") ?? CALayer.self) else { return }
        layer.setValue(window.traitCollection.displayScale, forKey: "scale")
    }
}
