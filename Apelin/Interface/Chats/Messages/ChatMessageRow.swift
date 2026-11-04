import ListViewKit
import Litext
import MarkdownView
import UIKit

/// User messages use FlowDown's trailing, accent-tinted bubble geometry.
/// Assistant text uses MarkdownView, with received images in an album below it.
/// Laid out left to right and mirrored right to left, where the bubble
/// and its attachments sit on the left.
final class ChatMessageRow: ListRowView {
    static let horizontalPadding: CGFloat = 20
    /// The widest a row's content gets: the composer's card at its widest
    /// (750 pt less its 10 pt gap each side), so text lines up with it. The
    /// list spans the page's safe area side to side, so the margins beside
    /// the content still scroll.
    static let readableWidth: CGFloat = 730

    /// A row's insets at `width`: the padding, or more to centre the content
    /// in the readable width.
    @objc dynamic static func insets(for width: CGFloat) -> UIEdgeInsets {
        let side = max(horizontalPadding, ((width - readableWidth) / 2).rounded(.down))
        return UIEdgeInsets(
            top: ChatMarkdownView.blockSpacing / 2,
            left: side,
            bottom: ChatMarkdownView.blockSpacing / 2,
            right: side,
        )
    }

    private static let userContentPadding: CGFloat = 20
    private static let textPadding: CGFloat = 12
    /// Between the sender line and what it is over.
    private static let senderSpacing: CGFloat = 4

    private let bubble = MessageAccentGradientView()
    /// Over a message another conversation's agent sent: which one. A
    /// label, so VoiceOver reads it before the message.
    private let senderLabel = UILabel()
    /// The message this row shows: only a change to it animates, never the
    /// row taking another message out of the pool.
    @objc dynamic private var shownID: UUID?
    private let label = TextLabelView()
    private let markdownView = ChatMarkdownView()
    @objc dynamic private var markdownText: String?
    /// The reply has finished, but its last text is still fading in.
    @objc dynamic private var finishesStreamWhenStill = false
    @objc dynamic private var revealObservation: NSKeyValueObservation?
    private let attachmentsView = MessageAttachmentsView()
    @objc dynamic var attachmentHeightLimit: CGFloat = 0 {
        didSet {
            if attachmentHeightLimit != oldValue {
                setNeedsLayout()
            }
        }
    }

    /// The screen's, the one `height(for:…)` was given, rather than the
    /// row's own traits, which a row not yet in its window may not have:
    /// the row lays its images out at the height it was measured at.
    @objc dynamic var displayScale: CGFloat = 0 {
        didSet {
            if displayScale != oldValue {
                setNeedsLayout()
            }
        }
    }

    private var attachments: [ComposerAttachment] = []
    @objc dynamic private var isUser = false
    private static let sizingMarkdown = ChatMarkdownView()
    private static let sizingLabel = TextLabelView()
    @objc dynamic var onAttachmentLayoutChanged: (() -> Void)?
    var onPreview: ((ComposerAttachment) -> Void)?
    var onPreviewImages: (([ComposerAttachment], UUID) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Selection handles extend beyond a transcript row.
        clipsToBounds = false
        bubble.layer.cornerRadius = 12
        bubble.layer.cornerCurve = .continuous
        bubble.clipsToBounds = true
        bubble.isHidden = true
        addSubview(bubble)
        senderLabel.font = Self.senderFont
        senderLabel.adjustsFontForContentSizeCategory = true
        senderLabel.textColor = .secondaryLabel
        senderLabel.textAlignment = .right
        senderLabel.lineBreakMode = .byTruncatingTail
        senderLabel.isHidden = true
        addSubview(senderLabel)
        label.isSelectable = true
        label.delegate = self
        label.isAccessibilityElement = true
        addSubview(label)
        addSubview(markdownView)
        markdownView.linkHandler = { [weak self] link, _, _ in
            let url: URL? = switch link {
            case let .url(value): value
            case let .string(value): URL(string: value)
            }
            guard let url else { return }
            // an apelin:// link opens its conversation in place
            if ApelinLinkRouter.open(url, in: self?.window?.windowScene) {
                return
            }
            if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
        }
        attachmentsView.onPreview = { [weak self] item in self?.onPreview?(item) }
        attachmentsView.onPreviewImages = { [weak self] items, selectedID in self?.onPreviewImages?(items, selectedID) }
        attachmentsView.onSizeChange = { [weak self] in self?.onAttachmentLayoutChanged?() }
        addSubview(attachmentsView)
        revealObservation = markdownView.streamLabel.observe(\.isAnimating) { [weak self] _, _ in
            // Called while the label is still taking its animation down.
            DispatchQueue.main.async { [weak self] in
                guard let self, finishesStreamWhenStill, !markdownView.streamLabel.isAnimating else { return }
                finishStream()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.clearSelection()
        label.attributedText = NSAttributedString()
        label.accessibilityLabel = nil
        bubble.isHidden = true
        senderLabel.text = nil
        senderLabel.isHidden = true
        shownID = nil
        finishesStreamWhenStill = false
        markdownView.reset()
        markdownView.isStreaming = false
        markdownView.streamIdentity = nil
        markdownText = nil
        attachments = []
        attachmentsView.show([], trailing: false, animated: false)
        onAttachmentLayoutChanged = nil
        onPreview = nil
        onPreviewImages = nil
    }

    func show(_ message: ChatMessage, isStreaming: Bool = false) {
        let isSameMessage = shownID == message.id
        isUser = message.role == .user
        label.attributedText = Self.attributedText(message.text)
        label.accessibilityLabel = message.text
        // A message the run has not taken yet waits faded, and settles in
        // place once it does.
        let waiting = isUser && message.isQueued
        let alpha: CGFloat = waiting ? 0.5 : 1
        if bubble.alpha != alpha {
            let fade = { [self] in
                bubble.alpha = alpha
                label.alpha = alpha
            }
            if isSameMessage, window != nil, !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.25, animations: fade)
            } else {
                fade()
            }
        }
        shownID = message.id
        label.accessibilityValue = waiting ? String(localized: "Waiting to Send") : nil
        bubble.isHidden = !isUser || message.text.isEmpty
        senderLabel.text = isUser ? message.sender : nil
        senderLabel.isHidden = senderLabel.text == nil
        senderLabel.alpha = alpha
        label.isHidden = message.role != .user
        markdownView.isHidden = message.role == .user
        if message.role == .assistant {
            let firstFill = markdownView.streamIdentity != AnyHashable(message.id)
            if firstFill {
                finishesStreamWhenStill = false
            }
            markdownView.streamIdentity = message.id
            let animates = !UIAccessibility.isReduceMotionEnabled
            // The update that ends a reply often brings its last chunk too.
            // Turning streaming off now would show that chunk and the text
            // still fading at once, so it stays on until the label is still.
            if !isStreaming, animates, !firstFill, markdownView.isStreaming {
                finishesStreamWhenStill = true
            } else {
                finishesStreamWhenStill = false
                markdownView.isStreaming = isStreaming && animates
            }
            if firstFill || markdownText != message.text {
                if firstFill || !markdownView.isStreaming {
                    markdownView.setMarkdown(message.text)
                } else {
                    markdownView.setContent(MarkdownContent(markdown: message.text, theme: markdownView.theme))
                }
                markdownText = message.text
            }
            if finishesStreamWhenStill, !markdownView.streamLabel.isAnimating {
                finishStream()
            }
        }
        attachments = message.attachments
        attachmentsView.show(attachments, trailing: isUser, animated: isSameMessage)
        setNeedsLayout()
    }

    @objc dynamic private func finishStream() {
        finishesStreamWhenStill = false
        markdownView.isStreaming = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = bounds.inset(by: Self.insets(for: bounds.width))
        let hasText = label.attributedText.length > 0
        let available = Self.textWidth(for: bounds.width, user: true)
        // The label measures itself as `height(for:)` measures it.
        let textSize = isUser && hasText ? label.sizeThatFits(CGSize(width: available, height: 0)) : nil
        let documentWidth = isUser ? Self.bubbleWidth(textSize: textSize, available: available) : 350
        let attachmentWidth = isUser ? available + Self.textPadding * 2 : content.width
        attachmentsView.documentWidthLimit = documentWidth
        attachmentsView.previewHeightLimit = attachmentHeightLimit
        attachmentsView.displayScale = displayScale
        let attachmentHeight = MessageAttachmentsView.height(
            for: attachments,
            width: attachmentWidth,
            documentWidthLimit: documentWidth,
            maximumPreviewHeight: attachmentHeightLimit,
            displayScale: displayScale,
        )
        let gap = hasText && attachmentHeight > 0 ? ChatMarkdownView.blockSpacing : 0
        if isUser {
            let textHeight = textSize.map { ceil($0.height) + Self.textPadding * 2 } ?? 0
            let width = documentWidth
            let senderHeight = senderLabel.isHidden ? 0 : Self.senderHeight
            // over the bubble, at its trailing edge
            senderLabel.textAlignment = laysOutRightToLeft ? .left : .right
            senderLabel.frame = CGRect(
                x: content.minX,
                y: content.minY,
                width: content.width,
                height: ceil(Self.senderFont.lineHeight),
            )
            let top = content.minY + senderHeight
            attachmentsView.frame = directionalFrame(CGRect(
                x: content.maxX - attachmentWidth,
                y: top,
                width: attachmentWidth,
                height: attachmentHeight,
            ))
            bubble.frame = directionalFrame(CGRect(
                x: content.maxX - width,
                y: top + attachmentHeight + gap,
                width: width,
                height: textHeight,
            ))
            label.frame = bubble.frame.insetBy(dx: Self.textPadding, dy: Self.textPadding)
        } else {
            let textHeight = hasText ? max(0, content.height - attachmentHeight - gap) : 0
            markdownView.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: textHeight)
            markdownView.trackedScrollView = superview as? UIScrollView
            attachmentsView.frame = CGRect(
                x: content.minX,
                y: content.minY + textHeight + gap,
                width: content.width,
                height: attachmentHeight,
            )
        }
    }

    static func height(
        for message: ChatMessage,
        width: CGFloat,
        maximumAttachmentHeight: CGFloat,
        displayScale: CGFloat,
    ) -> CGFloat {
        let user = message.role == .user
        let available = textWidth(for: width, user: user)
        let userTextSize = user && !message.text.isEmpty ? textSize(message.text, width: available) : nil
        let textHeight: CGFloat
        if message.text.isEmpty {
            textHeight = 0
        } else if let userTextSize {
            textHeight = ceil(userTextSize.height) + textPadding * 2
        } else {
            sizingMarkdown.setMarkdown(message.text)
            textHeight = ceil(sizingMarkdown.boundingSize(for: available).height)
        }
        let insets = Self.insets(for: width)
        let contentWidth = max(1, width - insets.left - insets.right)
        let attachmentWidth = user ? available + textPadding * 2 : contentWidth
        let documentWidth = user ? bubbleWidth(textSize: userTextSize, available: available) : 350
        let attachmentHeight = MessageAttachmentsView.height(
            for: message.attachments,
            width: attachmentWidth,
            documentWidthLimit: documentWidth,
            maximumPreviewHeight: maximumAttachmentHeight,
            displayScale: displayScale,
        )
        let gap = textHeight > 0 && attachmentHeight > 0 ? ChatMarkdownView.blockSpacing : 0
        let senderHeight = user && message.sender != nil ? Self.senderHeight : 0
        return senderHeight + textHeight + attachmentHeight + gap + insets.top + insets.bottom
    }

    @objc dynamic private static var senderFont: UIFont {
        .preferredFont(forTextStyle: .footnote)
    }

    /// The sender line and the space under it.
    @objc dynamic private static var senderHeight: CGFloat {
        ceil(senderFont.lineHeight) + senderSpacing
    }

    /// A bubble fits its text; one with no text leaves its attachments the full width.
    private static func bubbleWidth(textSize: CGSize?, available: CGFloat) -> CGFloat {
        (textSize.map { ceil($0.width) } ?? available) + textPadding * 2
    }

    @objc dynamic private static func textWidth(for width: CGFloat, user: Bool) -> CGFloat {
        let insets = Self.insets(for: width)
        let available = width - insets.left - insets.right
        return max(user ? min(800, available - userContentPadding * 2) - textPadding * 2 : available, 1)
    }

    /// Measured by Litext, which draws the text with CoreText and pins its first
    /// line to the top of the label. TextKit's `boundingRect` gives shorter
    /// lines wherever a fallback font brings a taller ascent and descent, as
    /// PingFang does for Chinese, and the text then sat low in its bubble.
    @objc dynamic private static func textSize(_ text: String, width: CGFloat) -> CGSize {
        sizingLabel.attributedText = attributedText(text)
        return sizingLabel.sizeThatFits(CGSize(width: width, height: 0))
    }

    @objc dynamic private static func attributedText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.label])
    }

    @objc dynamic private static var font: UIFont {
        .preferredFont(forTextStyle: .body)
    }
}

extension ChatMessageRow: TextLabelViewDelegate {
    @objc dynamic func textLabelView(
        _ label: TextLabelView,
        editMenuForSelection selection: NSRange,
        suggestedActions: [UIMenuElement],
    ) -> UIMenu? {
        ChatSelectionMenu.menu(for: label, selection: selection, suggestedActions: suggestedActions)
    }
}
