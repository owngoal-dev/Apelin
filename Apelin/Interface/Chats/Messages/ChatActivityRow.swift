import ListViewKit
import UIKit

/// A summary in the transcript, which opens its trace (`TraceController`).
/// The turn's latest summary carries the output the run has received so far
/// at the trailing end of its title line, the title's first line fading out
/// before it; a running summary's newest call is the line under it.
final class ChatActivityRow: ListRowView {
    @objc dynamic var onToggle: (() -> Void)?
    private let header = ThinkingStatusLabel()
    /// Holds the title, and while the count shows fades its first line out
    /// before it (`titleMask`), so a long title runs under the count rather
    /// than into it. The title's own mask is its shimmer.
    private let titleView = UIView()
    private let titleMask = CALayer()
    private let titleFade = CAGradientLayer()
    private let titleRest = CALayer()
    private let received = ReceivedTokensView()
    private let bannerView = ToolCallBannerView()
    /// The message this row shows: only a change to it animates, never the
    /// row taking another message out of the pool.
    @objc dynamic private var shownID: UUID?
    /// Whether the count is meant to be on screen, while it fades too.
    @objc dynamic private var showsReceived = false
    private static let sizingHeader = ThinkingStatusLabel()
    /// Between the title's fade and the count.
    private static let receivedSpacing: CGFloat = 6
    /// How far the title fades out before the count.
    private static let titleFadeWidth: CGFloat = 20
    /// Between the title and the line under it.
    private static let bannerSpacing: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleView.addSubview(header)
        addSubview(titleView)
        titleFade.colors = Self.opaqueFade
        titleRest.backgroundColor = UIColor.black.cgColor
        titleMask.addSublayer(titleFade)
        titleMask.addSublayer(titleRest)
        received.isHidden = true
        addSubview(received)
        bannerView.isHidden = true
        addSubview(bannerView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
        header.onShownTextChange = { [weak self] _ in
            self?.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ message: ChatMessage) {
        let isSameMessage = shownID == message.id
        shownID = message.id
        header.animationIdentity = message.id
        header.text = message.activityTitle
        isAccessibilityElement = false
        header.accessibilityLabel = message.activityTitle
        let opensTrace = Self.isReasoning(message)
        header.accessibilityTraits = opensTrace ? .button : .staticText
        header.accessibilityCustomActions = opensTrace
            ? [UIAccessibilityCustomAction(name: String(localized: "View Thoughts")) { [weak self] _ in
                self?.onToggle?(); return true
            }]
            : nil
        let tokens = message.receivedTokens
        header.accessibilityValue = tokens.map(ReceivedTokensView.spoken)
        showReceived(tokens, settles: message.receivedSettles, animated: isSameMessage)
        if let call = Self.banner(of: message) {
            bannerView.show(call, animated: isSameMessage)
            bannerView.isHidden = false
        } else {
            bannerView.reset()
            bannerView.isHidden = true
        }
        header.isThinking = message.role.isThinking
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        shownID = nil
        header.isThinking = false
        header.animationIdentity = nil
        header.text = nil
        header.accessibilityValue = nil
        showsReceived = false
        received.layer.removeAllAnimations()
        received.isHidden = true
        received.alpha = 1
        setTitleFade(false, animated: false)
        titleView.layer.mask = nil
        bannerView.reset()
        bannerView.isHidden = true
        onToggle = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = bounds.inset(by: ChatMessageRow.insets(for: bounds.width))
        let textWidth = max(1, content.width)
        let scale = max(traitCollection.displayScale, 1)
        func pixel(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        let height = ceil(header.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        titleView.frame = CGRect(
            x: pixel(content.minX),
            y: pixel(content.minY),
            width: pixel(textWidth),
            height: pixel(height),
        )
        header.frame = titleView.bounds
        layoutReceived(in: content)
        if !bannerView.isHidden {
            // the line keeps the reading width, padding included; its
            // ground is drawn out to the row's edges
            let padding = ChatMessageRow.horizontalPadding
            bannerView.frame = CGRect(
                x: content.minX - padding,
                y: titleView.frame.maxY + Self.bannerSpacing,
                width: content.width + padding * 2,
                height: ToolCallBannerView.height,
            )
            bannerView.groundBleed = UIEdgeInsets(
                top: 0,
                left: max(0, bannerView.frame.minX),
                bottom: 0,
                right: max(0, bounds.width - bannerView.frame.maxX),
            )
        }
    }

    /// Across the title's first line, drawn at its trailing end; the title
    /// fades out before it, however long the title is.
    @objc dynamic private func layoutReceived(in content: CGRect) {
        guard !received.isHidden else { return }
        let line = ceil(header.font.lineHeight)
        let height = received.lineHeight
        received.frame = CGRect(
            x: content.minX,
            y: titleView.frame.minY + ((line - height) / 2).rounded(),
            width: content.width,
            height: height,
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = titleView.bounds
        titleMask.frame = bounds
        titleFade.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(line, bounds.height))
        titleRest.frame = CGRect(x: 0, y: titleFade.frame.maxY, width: bounds.width,
                                 height: max(0, bounds.height - titleFade.frame.maxY))
        // measured from the title's leading edge, whichever side that is
        let width = max(bounds.width, 1)
        let end = min(max((bounds.width - received.contentWidth - Self.receivedSpacing) / width, 0), 1)
        titleFade.locations = [NSNumber(value: Double(max(end - Self.titleFadeWidth / width, 0))), NSNumber(value: Double(end))]
        titleFade.startPoint = CGPoint(x: laysOutRightToLeft ? 1 : 0, y: 0.5)
        titleFade.endPoint = CGPoint(x: laysOutRightToLeft ? 0 : 1, y: 0.5)
        CATransaction.commit()
    }

    private static let opaqueFade = [UIColor.black.cgColor, UIColor.black.cgColor]
    private static let clearingFade = [UIColor.black.cgColor, UIColor.clear.cgColor]

    /// The title's first line fading before the count, or whole.
    @objc dynamic private func setTitleFade(_ fades: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        titleFade.colors = fades ? Self.clearingFade : Self.opaqueFade
        CATransaction.commit()
    }

    /// On the same summary the count climbs to each figure — from nothing
    /// when it appears — in five seconds while the summary runs and half a
    /// second once the reply after it has begun, and fades in and out. On
    /// another summary, off screen or under Reduce Motion it is there, or
    /// gone, at once.
    private func showReceived(_ tokens: Int?, settles: Bool, animated: Bool) {
        let moves = animated && window != nil && !UIAccessibility.isReduceMotionEnabled
        if let tokens {
            if !moves {
                received.show(tokens)
            } else {
                if !showsReceived {
                    received.show(0)
                }
                received.climb(to: tokens, within: settles ? TokenClimb.settling : TokenClimb.running)
            }
        }
        let shows = tokens != nil
        guard shows != showsReceived else { return }
        showsReceived = shows
        received.layer.removeAllAnimations()
        if shows {
            received.isHidden = false
            titleView.layer.mask = titleMask
            // in place before it fades in, not moving in from elsewhere
            setNeedsLayout()
            layoutIfNeeded()
            received.alpha = moves ? 0 : 1
            setTitleFade(true, animated: moves)
            if moves {
                UIView.animate(withDuration: 0.2) { self.received.alpha = 1 }
            }
        } else if moves {
            setTitleFade(false, animated: true)
            UIView.animate(withDuration: 0.2) {
                self.received.alpha = 0
            } completion: { _ in
                guard !self.showsReceived else { return }
                self.received.isHidden = true
                self.received.alpha = 1
                self.titleView.layer.mask = nil
            }
        } else {
            received.isHidden = true
            received.alpha = 1
            setTitleFade(false, animated: false)
            titleView.layer.mask = nil
        }
    }

    static func height(for message: ChatMessage, width: CGFloat) -> CGFloat {
        let insets = ChatMessageRow.insets(for: width)
        let width = max(1, width - insets.left - insets.right)
        sizingHeader.font = .preferredFont(forTextStyle: .body)
        sizingHeader.text = message.activityTitle
        let headerHeight = ceil(
            sizingHeader.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height,
        )
        var height = headerHeight + insets.top + insets.bottom
        if banner(of: message) != nil {
            height += bannerSpacing + ToolCallBannerView.height
        }
        return height
    }

    /// Only a running summary has the line under it; the trace lists every
    /// call whole.
    private static func banner(of message: ChatMessage) -> ToolCallBanner? {
        message.role.isThinking ? message.banner : nil
    }

    private static func isReasoning(_ message: ChatMessage) -> Bool {
        if case .thinking = message.role {
            return true
        }
        return false
    }

    @objc dynamic private func toggle() {
        onToggle?()
    }
}
