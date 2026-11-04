import ApelinProtocol
import UIKit

/// The outstanding decision replaces the input. Only its result enters history.
final class ComposerApprovalSection: ComposerSectionView {
    /// The request and the decision; Approve on a request as root waits on
    /// the device owner's check there before anything is sent.
    var onDecision: ((ChatMessage, ApprovalDecision) -> Void)?
    private var request: ChatMessage?
    @objc dynamic var isPresentingRequest: Bool {
        request != nil
    }

    private let titleLabel = UILabel()
    /// Shown only for a command that runs as root, between the title and
    /// the detail, so it is read before the command.
    private let rootLabel = UILabel()
    @objc dynamic private var detailViews: [UIView] = []
    /// The title and detail: a request taller than half the window scrolls
    /// from its start, under buttons that stay in place.
    private let textScroll = UIScrollView()
    private let approveButton = UIButton(type: .system)
    private let denyButton = UIButton(type: .system)

    @objc override dynamic func initializeViews() {
        super.initializeViews()
        clipsToBounds = true
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        // Drawn at the final size and pinned to the top, not stretched, while a frame animates.
        titleLabel.contentMode = .topLeft
        titleLabel.accessibilityTraits.insert(.header)
        let subheadline = UIFont.preferredFont(forTextStyle: .subheadline)
        rootLabel.font = subheadline.fontDescriptor.withSymbolicTraits(.traitBold)
            .map { UIFont(descriptor: $0, size: 0) } ?? subheadline
        rootLabel.adjustsFontForContentSizeCategory = true
        rootLabel.textColor = .systemRed
        rootLabel.numberOfLines = 0
        rootLabel.contentMode = .topLeft
        rootLabel.text = String(localized: "Runs as root, with full control of this device")
        var approveStyle = UIButton.Configuration.filled()
        approveStyle.baseBackgroundColor = .label
        approveStyle.baseForegroundColor = .systemBackground
        approveStyle.cornerStyle = .medium
        approveStyle.titleLineBreakMode = .byTruncatingTail
        approveStyle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .headline)
            return attributes
        }
        approveButton.configuration = approveStyle
        approveButton.setTitle(String(localized: "Approve"), for: .normal)
        var denyStyle = UIButton.Configuration.gray()
        denyStyle.baseForegroundColor = .label
        denyStyle.cornerStyle = .medium
        denyStyle.titleTextAttributesTransformer = approveStyle.titleTextAttributesTransformer
        denyStyle.titleLineBreakMode = .byTruncatingTail
        denyButton.configuration = denyStyle
        denyButton.setTitle(String(localized: "Deny"), for: .normal)
        approveButton.addAction(UIAction { [weak self] _ in self?.decide(.approve) }, for: .touchUpInside)
        denyButton.addAction(UIAction { [weak self] _ in self?.decide(.deny) }, for: .touchUpInside)
        textScroll.contentInsetAdjustmentBehavior = .never
        for view in [titleLabel, rootLabel] {
            textScroll.addSubview(view)
        }
        for view in [textScroll, denyButton, approveButton] {
            addSubview(view)
        }
        alpha = 0
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    func show(_ message: ChatMessage?) {
        guard request != message else { return }
        let replacing = request != nil
        if let message, !replacing {
            // Placed while still hidden, so the content is revealed by the
            // card rather than growing out of a zero frame.
            UIView.performWithoutAnimation {
                setText(of: message)
                layoutContent()
            }
        }
        let update = { [self] in
            request = message
            if let message, replacing {
                for label in [titleLabel, rootLabel] {
                    UIView.transition(
                        with: label,
                        duration: 0.25,
                        options: [.transitionCrossDissolve, .allowUserInteraction],
                    ) {}
                }
                setText(of: message)
            }
            let visible = message != nil
            alpha = visible ? 1 : 0
            isUserInteractionEnabled = visible
            accessibilityElementsHidden = !visible
            heightPublisher.send(visible ? layoutContent() : 0)
            // The composer's layout follows whether a request is shown, not only this band's height.
            superview?.setNeedsLayout()
        }
        if window != nil, !UIAccessibility.isReduceMotionEnabled {
            (superview ?? self).doWithAnimation(update)
        } else {
            UIView.performWithoutAnimation(update)
        }
    }

    private func setText(of message: ChatMessage) {
        titleLabel.text = message.approvalTitle
        rootLabel.isHidden = !message.runsAsRoot
        detailViews.forEach { $0.removeFromSuperview() }
        detailViews = []
        let sections = message.approvalSections.isEmpty
            ? [ApprovalCardText.Section(text: message.approvalDetail)] : message.approvalSections
        for section in sections where !section.text.isEmpty {
            if let title = section.title, !section.isCode {
                let label = UILabel()
                label.text = title
                label.font = .preferredFont(forTextStyle: .callout)
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .secondaryLabel
                label.numberOfLines = 0
                label.accessibilityTraits.insert(.header)
                detailViews.append(label)
            }
            if section.isCode {
                let code = UITextView()
                code.text = section.text
                code.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular))
                code.adjustsFontForContentSizeCategory = true
                code.textColor = .label
                code.backgroundColor = .clear
                code.isEditable = false
                code.isSelectable = true
                code.isScrollEnabled = false
                code.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
                code.textContainer.lineFragmentPadding = 0
                code.textContainer.lineBreakMode = .byCharWrapping
                code.accessibilityLabel = section.title
                detailViews.append(ApprovalCodeBlock(title: section.title, code: code))
            } else {
                let label = UILabel()
                label.text = section.text
                label.font = .preferredFont(forTextStyle: .callout)
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .secondaryLabel
                label.numberOfLines = 0
                detailViews.append(label)
            }
        }
        detailViews.forEach { textScroll.addSubview($0) }
        textScroll.contentOffset = .zero
    }

    private func decide(_ decision: ApprovalDecision) {
        guard let request else { return }
        onDecision?(request, decision)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard request != nil else { return }
        heightPublisher.send(layoutContent())
    }

    /// Places the content for the current width and answers the height it needs.
    @discardableResult
    @objc dynamic private func layoutContent() -> CGFloat {
        let contentWidth = max(1, bounds.width)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height,
        )
        titleLabel.frame = CGRect(x: 0, y: ChatMarkdownView.blockSpacing, width: contentWidth, height: titleHeight)
        var textBottom = titleLabel.frame.maxY
        if !rootLabel.isHidden {
            let rootHeight = ceil(
                rootLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height,
            )
            rootLabel.frame = CGRect(x: 0, y: textBottom + ChatMarkdownView.blockSpacing / 2, width: contentWidth, height: rootHeight)
            textBottom = rootLabel.frame.maxY
        }
        for (index, detail) in detailViews.enumerated() {
            let gap: CGFloat = index > 0 && (detailViews[index - 1] as? UILabel)?.accessibilityTraits.contains(.header) == true ? 6 : 14
            let height = ceil(detail.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
            detail.frame = CGRect(x: 0, y: textBottom + gap, width: contentWidth, height: height)
            textBottom = detail.frame.maxY
        }
        let textHeight = textBottom
        textScroll.contentSize = CGSize(width: contentWidth, height: textHeight)
        textScroll.frame = CGRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: min(textHeight, (window?.bounds.height ?? .greatestFiniteMagnitude) / 2),
        )
        let buttonWidth = (contentWidth - ChatMarkdownView.blockSpacing) / 2
        let actionY = textScroll.frame.maxY + ChatMarkdownView.blockSpacing
        // Deny then Approve in reading order: right to left, Deny on the right
        let buttonHeight = max(44, ceil(UIFont.preferredFont(forTextStyle: .headline).lineHeight + 22))
        let row = CGRect(x: 0, y: actionY, width: contentWidth, height: buttonHeight)
        let deny = CGRect(x: 0, y: actionY, width: buttonWidth, height: buttonHeight)
        denyButton.frame = directionalFrame(deny, across: row)
        approveButton.frame = directionalFrame(
            CGRect(x: deny.maxX + ChatMarkdownView.blockSpacing, y: actionY, width: buttonWidth, height: buttonHeight),
            across: row,
        )
        return approveButton.frame.maxY + ChatMarkdownView.blockSpacing
    }
}

/// The caption decorates the block; selecting or copying still takes only code.
private final class ApprovalCodeBlock: UIView {
    private let caption = UILabel()
    private let code: UITextView

    init(title: String?, code: UITextView) {
        self.code = code
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        clipsToBounds = true
        caption.text = title?.uppercased(with: .current)
        caption.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel
        caption.numberOfLines = 0
        caption.isHidden = title == nil
        caption.accessibilityTraits.insert(.header)
        addSubview(caption)
        addSubview(code)
        code.textContainerInset = UIEdgeInsets(top: title == nil ? 14 : 8, left: 12, bottom: 14, right: 12)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:code:)")
    }

    @objc dynamic private func captionHeight(for width: CGFloat) -> CGFloat {
        caption.isHidden ? 0 : ceil(caption.sizeThatFits(CGSize(width: max(1, width - 24), height: .greatestFiniteMagnitude)).height) + 12
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: captionHeight(for: size.width)
            + ceil(code.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude)).height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let headerHeight = captionHeight(for: bounds.width)
        caption.frame = CGRect(x: 12, y: 12, width: max(0, bounds.width - 24), height: max(0, headerHeight - 12))
        code.frame = CGRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
    }
}
