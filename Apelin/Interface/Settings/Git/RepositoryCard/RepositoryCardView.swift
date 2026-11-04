import UIKit

/// The card, drawn on a fixed 400 × 570 pt canvas scaled to the view, so
/// what the page shows and the image Save writes (`image(of:)`) are one
/// drawing. It is a printed thing: always light, whatever the system is.
/// Every line of text is the body size in SF Rounded, told apart only by
/// weight and by half opacity; the badge's slot is cut out of the card.
final class RepositoryCardView: UIView {
    static let canvas = CGSize(width: 400, height: 570)

    var card: RepositoryCard? {
        didSet {
            setNeedsDisplay()
            updateAccessibility()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func draw(_: CGRect) {
        guard let card, let context = UIGraphicsGetCurrentContext() else { return }
        context.scaleBy(x: bounds.width / Self.canvas.width, y: bounds.height / Self.canvas.height)
        Self.draw(card)
    }

    @objc private dynamic func updateAccessibility() {
        guard let card else { return }
        accessibilityLabel = [
            String(localized: "Repository Card"),
            card.title,
            card.address,
            String(localized: "Scan with Camera to add in Irisin"),
            "@" + card.owner,
        ].joined(separator: ", ")
    }

    /// The card as Save writes it, at three pixels a point: on the page's
    /// grey with a margin and a soft shadow, so that alone in Photos it
    /// still reads as a card, its slot showing the grey through.
    static func image(of card: RepositoryCard) -> UIImage {
        let margin: CGFloat = 40
        let size = CGSize(width: canvas.width + margin * 2, height: canvas.height + margin * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            page.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: margin, y: margin)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 4), blur: 24, color: UIColor.black.withAlphaComponent(0.08).cgColor)
            UIColor.white.setFill()
            shape.fill()
            cg.restoreGState()
            draw(card)
        }
    }

    // MARK: - Drawing

    private static let ink = UIColor(red: 0.12, green: 0.14, blue: 0.17, alpha: 1)
    /// The grey a saved card sits on, the light grouped background's.
    private static let page = UIColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255, alpha: 1)

    @objc private dynamic static func font(_ weight: UIFont.Weight) -> UIFont {
        let system = UIFont.systemFont(ofSize: 17, weight: weight)
        guard let rounded = system.fontDescriptor.withDesign(.rounded) else { return system }
        return UIFont(descriptor: rounded, size: 17)
    }

    /// The card's outline with the badge's slot cut out of it.
    @objc private dynamic static var shape: UIBezierPath {
        let bounds = CGRect(origin: .zero, size: canvas)
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: 24)
        path.append(UIBezierPath(roundedRect: CGRect(x: bounds.midX - 30, y: 20, width: 60, height: 11), cornerRadius: 5.5))
        path.usesEvenOddFillRule = true
        return path
    }

    private static func draw(_ card: RepositoryCard) {
        let bounds = CGRect(origin: .zero, size: canvas)
        UIColor.white.setFill()
        shape.fill()

        let iconRect = CGRect(x: bounds.midX - 32, y: 65, width: 64, height: 64)
        UIGraphicsGetCurrentContext()?.saveGState()
        UIBezierPath(roundedRect: iconRect, cornerRadius: 15).addClip()
        card.icon.draw(in: iconRect)
        UIGraphicsGetCurrentContext()?.restoreGState()

        line(card.title, font(.bold), ink, y: 145)
        line(card.address, font(.regular), ink.withAlphaComponent(0.5), y: 170)
        let qrBottom = drawModules(card.modules, top: 210, side: 248)
        line(String(localized: "Scan with Camera to add in Irisin"), font(.regular), ink.withAlphaComponent(0.5), y: qrBottom + 30)
        line("@" + card.owner, font(.regular), ink.withAlphaComponent(0.5), y: qrBottom + 54)
    }

    @objc private dynamic static func line(_ text: String, _ font: UIFont, _ color: UIColor, y: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            with: CGRect(x: 32, y: y, width: canvas.width - 64, height: font.lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph],
            context: nil,
        )
    }

    /// Square modules filled as one path, so no seam shows between
    /// neighbours at any scale; the three finder patterns rounded. Answers
    /// the code's bottom edge.
    @objc private dynamic static func drawModules(_ modules: [[Bool]], top: CGFloat, side: CGFloat) -> CGFloat {
        let count = modules.count
        guard count > 0 else { return top }
        let cell = side / CGFloat(count)
        let origin = CGPoint(x: (canvas.width - side) / 2, y: top)
        let finders = [(0, 0), (count - 7, 0), (0, count - 7)]
        func inFinder(_ x: Int, _ y: Int) -> Bool {
            finders.contains { x >= $0.0 && x < $0.0 + 7 && y >= $0.1 && y < $0.1 + 7 }
        }
        let path = UIBezierPath()
        for (y, row) in modules.enumerated() {
            for (x, dark) in row.enumerated() where dark && !inFinder(x, y) {
                path.append(UIBezierPath(rect: CGRect(
                    x: origin.x + CGFloat(x) * cell,
                    y: origin.y + CGFloat(y) * cell,
                    width: cell,
                    height: cell,
                )))
            }
        }
        for (fx, fy) in finders {
            let outer = CGRect(x: origin.x + CGFloat(fx) * cell, y: origin.y + CGFloat(fy) * cell, width: cell * 7, height: cell * 7)
            let ring = UIBezierPath(roundedRect: outer, cornerRadius: cell * 2)
            ring.append(UIBezierPath(roundedRect: outer.insetBy(dx: cell, dy: cell), cornerRadius: cell * 1.2).reversing())
            path.append(ring)
            path.append(UIBezierPath(roundedRect: outer.insetBy(dx: cell * 2, dy: cell * 2), cornerRadius: cell * 0.9))
        }
        ink.setFill()
        path.fill()
        return top + side
    }
}
