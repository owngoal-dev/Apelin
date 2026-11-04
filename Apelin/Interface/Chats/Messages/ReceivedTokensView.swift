import LitextAnimation
import UIKit

/// At the trailing end of a summary's title line: the output tokens the run
/// has received so far, then a downward arrow, "653 ↓"; right to left, the
/// arrow is at the edge and the figure on its right, still after it. The
/// figure climbs to each count rather than jumping (`TokenClimb`), drawn
/// again at most ten times a second with its digits rolling
/// (`LTXNumericTransitionAnimator`), all of them one width. A count shown at
/// once — another summary's, off screen or under Reduce Motion — neither
/// climbs nor rolls. VoiceOver reads the count as the title's value, so the
/// view itself is hidden.
///
/// The view spans the whole line and draws at its trailing end: the figure
/// grows away from the arrow inside a label whose frame holds still, so the
/// roll's glyphs stay where they are. `contentWidth` is how much of the
/// line the count covers once the figure has arrived.
final class ReceivedTokensView: UIView {
    private let symbol = UIImageView(image: UIImage(systemName: "arrow.down"))
    private let label = LTXAnimatableLabel()
    private var climb = TokenClimb(at: 0)
    private var shownFigure: Int?
    @objc dynamic private var timer: Timer?
    private static let spacing: CGFloat = 3
    /// How often a climbing figure is drawn again.
    private static let step: TimeInterval = 0.1
    /// As the title is drawn when it is finished.
    private static let color = UIColor.label.withAlphaComponent(0.5)

    @objc dynamic var font = UIFont.preferredFont(forTextStyle: .body) {
        didSet { applyFont() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        symbol.tintColor = Self.color
        symbol.contentMode = .center
        label.animator = LTXNumericTransitionAnimator()
        label.animationPolicy = LTXNumericTransitionAnimator.policy
        label.isSelectable = false
        addSubview(label)
        addSubview(symbol)
        applyFont()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// Shows `tokens` at once.
    @objc dynamic func show(_ tokens: Int) {
        stopClimbing()
        climb = TokenClimb(at: tokens)
        draw(tokens, rolls: false)
    }

    /// Climbs from the figure to `tokens`, to arrive `duration` from now;
    /// off screen or under Reduce Motion it is there at once.
    @objc dynamic func climb(to tokens: Int, within duration: TimeInterval) {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            show(tokens)
            return
        }
        climb.aim(at: tokens, within: duration, at: CACurrentMediaTime())
        tick()
    }

    @objc dynamic private func tick() {
        let now = CACurrentMediaTime()
        draw(climb.figure(at: now), rolls: true)
        if climb.hasArrived(at: now) {
            stopClimbing()
        } else if timer == nil {
            let timer = Timer(timeInterval: Self.step, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { return timer.invalidate() }
                    self.tick()
                }
            }
            // and while the list scrolls
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    @objc dynamic private func stopClimbing() {
        timer?.invalidate()
        timer = nil
    }

    /// A view leaving the screen is at its count when it comes back.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, timer != nil {
            show(climb.target)
        }
    }

    /// The count as it is drawn, grouped in the reader's locale: 1,234.
    @objc dynamic static func figure(_ tokens: Int) -> String {
        tokens.formatted(.number)
    }

    /// What VoiceOver reads as the title's value.
    @objc dynamic static func spoken(_ tokens: Int) -> String {
        tokens == 1
            ? String(localized: "1 token received")
            : String(localized: "\(figure(tokens)) tokens received")
    }

    /// The figure the climb arrives at, the space and the arrow.
    @objc dynamic var contentWidth: CGFloat {
        let figure = NSAttributedString(string: Self.figure(climb.target), attributes: [.font: figureFont])
        return ceil(figure.size().width + Self.spacing + symbol.intrinsicContentSize.width)
    }

    @objc dynamic var lineHeight: CGFloat {
        ceil(max(symbol.intrinsicContentSize.height, figureFont.lineHeight))
    }

    /// The arrow at the trailing edge, the label filling the rest of the
    /// line with its figure set against the arrow.
    override func layoutSubviews() {
        super.layoutSubviews()
        let symbolWidth = symbol.intrinsicContentSize.width
        symbol.frame = directionalFrame(CGRect(
            x: bounds.width - symbolWidth,
            y: 0,
            width: symbolWidth,
            height: bounds.height,
        ))
        label.frame = directionalFrame(CGRect(
            x: 0,
            y: ((bounds.height - ceil(figureFont.lineHeight)) / 2).rounded(),
            width: max(0, bounds.width - symbolWidth - Self.spacing),
            height: ceil(figureFont.lineHeight),
        ))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        font = .preferredFont(forTextStyle: .body)
    }

    @objc dynamic private var figureFont: UIFont {
        .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
    }

    /// The arrow is drawn at the figure's font, so the two keep their sizes
    /// to each other at every text size.
    @objc dynamic private func applyFont() {
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: figureFont)
        if let shownFigure {
            draw(shownFigure, rolls: false, force: true)
        }
        setNeedsLayout()
    }

    @objc dynamic private func draw(_ figure: Int, rolls: Bool, force: Bool = false) {
        guard force || figure != shownFigure else { return }
        shownFigure = figure
        let paragraph = NSMutableParagraphStyle()
        // against the arrow, which is at the trailing edge
        paragraph.alignment = laysOutRightToLeft ? .left : .right
        paragraph.lineBreakMode = .byClipping
        let text = NSAttributedString(string: Self.figure(figure), attributes: [
            .font: figureFont,
            .foregroundColor: Self.color,
            .paragraphStyle: paragraph,
        ])
        label.setAttributedText(text, animated: rolls && window != nil && !UIAccessibility.isReduceMotionEnabled)
    }
}
