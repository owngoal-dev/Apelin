import CoreText
import Litext
import LitextAnimation
import UIKit

/// A conversation's name on the bar, drawn as the bar draws its own title
/// and rolled to the next one by Litext's numeric transition when another
/// conversation is picked.
///
/// It asks the bar for all the room it has, so its frame holds still while
/// one name rolls into the next, and places the text itself: centred on the
/// bar, as the bar's own title is, slid aside only as far as the items
/// beside it need, and cut short with an ellipsis when it does not fit.
final class ChatTitleView: UIView {
    private let label = LTXAnimatableLabel()
    @objc dynamic private(set) var title = ""
    /// Whether the change waiting for the next layout pass rolls in.
    @objc dynamic private var animatesNextChange = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // sized by the bar from `intrinsicContentSize`, not by its frame
        translatesAutoresizingMaskIntoConstraints = false
        label.animator = LTXNumericTransitionAnimator()
        label.animationPolicy = LTXNumericTransitionAnimator.policy
        label.isSelectable = false
        label.backgroundColor = .clear
        addSubview(label)

        isAccessibilityElement = true
        accessibilityTraits = .header
        // the bar's own title is shown larger on a long press at the
        // largest text sizes; so is this one
        showsLargeContentViewer = true
        addInteraction(UILargeContentViewerInteraction())
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// Shows `title`, rolling the old one out when `animated` and the label
    /// is on screen.
    @objc dynamic func setTitle(_ title: String, animated: Bool) {
        guard title != self.title else { return }
        self.title = title
        accessibilityLabel = title
        largeContentTitle = title
        animatesNextChange = animated
        setNeedsLayout()
    }

    /// The bar's inline title: headline at the default text size, which the
    /// bar keeps at every size.
    @objc dynamic private static var font: UIFont {
        UIFont.preferredFont(
            forTextStyle: .headline,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large),
        )
    }

    /// As tall as a line, as wide as the bar allows: the bar narrows it to
    /// the room between its items.
    override var intrinsicContentSize: CGSize {
        CGSize(width: 10000, height: ceil(Self.font.lineHeight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let lineHeight = ceil(Self.font.lineHeight)
        label.frame = CGRect(x: 0, y: floor((bounds.height - lineHeight) / 2), width: bounds.width, height: lineHeight)
        let text = fittedText(width: bounds.width)
        let indent = leadingIndent(forTextWidth: Self.width(of: text), in: bounds.width)
        let attributed = NSAttributedString(string: text, attributes: Self.attributes(indent: indent))
        let animated = animatesNextChange
        animatesNextChange = false
        guard !attributed.isEqual(to: label.attributedText) else { return }
        // a change of room alone moves or cuts the text at once
        label.setAttributedText(attributed, animated: animated)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    /// The title, or as much of it as fits with an ellipsis after it, set
    /// in its own direction (`isolated`).
    @objc dynamic private func fittedText(width: CGFloat) -> String {
        guard width > 0, Self.width(of: title) > width else { return Self.isolated(title) }
        let characters = Array(title)
        var low = 0
        var high = characters.count
        // the longest prefix that fits with its ellipsis
        while low < high {
            let middle = (low + high + 1) / 2
            if Self.width(of: Self.truncated(characters, to: middle)) <= width {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return Self.truncated(characters, to: low)
    }

    private static func truncated(_ characters: [Character], to count: Int) -> String {
        isolated(String(characters.prefix(count)).trimmingCharacters(in: .whitespaces) + "…")
    }

    /// `text` between a first-strong isolate and its end: laid out in the
    /// direction of its own first letter inside the left-to-right line the
    /// indent needs, so an Arabic name reads right to left as a whole and
    /// its ellipsis lands on its left. The marks take no room.
    @objc dynamic private static func isolated(_ text: String) -> String {
        "\u{2068}" + text + "\u{2069}"
    }

    /// Where the text starts so that it sits centred on the bar, kept
    /// inside this view.
    @objc dynamic private func leadingIndent(forTextWidth textWidth: CGFloat, in width: CGFloat) -> CGFloat {
        let room = max(width - textWidth, 0)
        guard let bar = enclosingNavigationBar else { return room / 2 }
        let barCentre = convert(CGPoint(x: bar.bounds.midX, y: 0), from: bar).x
        return floor(min(max(barCentre - textWidth / 2, 0), room))
    }

    @objc dynamic private var enclosingNavigationBar: UINavigationBar? {
        var view = superview
        while let current = view {
            if let bar = current as? UINavigationBar {
                return bar
            }
            view = current.superview
        }
        return nil
    }

    /// The width CoreText, which draws the label, gives `text` on one line.
    @objc dynamic private static func width(of text: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes(indent: 0)),
        )
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    @objc dynamic private static func attributes(indent: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        // placed from the left whatever the script: the indent is measured
        // from the left edge, and one line in either direction fits it
        paragraph.alignment = .left
        paragraph.baseWritingDirection = .leftToRight
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineBreakMode = .byClipping
        return [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
    }
}
