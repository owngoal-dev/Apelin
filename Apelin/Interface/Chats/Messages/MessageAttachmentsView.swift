import UIKit

/// Both message roles share the same album and document cards, aligned by the
/// row: to the trailing edge for the reader's messages, the leading one for
/// the agent's, each mirrored right to left.
final class MessageAttachmentsView: UIView {
    var onPreview: ((ComposerAttachment) -> Void)?
    var onPreviewImages: (([ComposerAttachment], UUID) -> Void)?
    @objc dynamic var onSizeChange: (() -> Void)?
    @objc dynamic var documentWidthLimit: CGFloat = 350 {
        didSet {
            if documentWidthLimit != oldValue {
                setNeedsLayout()
            }
        }
    }

    @objc dynamic var previewHeightLimit: CGFloat = 0 {
        didSet {
            if previewHeightLimit != oldValue {
                setNeedsLayout()
            }
        }
    }

    /// The screen's, as `height(for:…)` was given it.
    @objc dynamic var displayScale: CGFloat = 0 {
        didSet {
            if displayScale != oldValue {
                setNeedsLayout()
            }
        }
    }

    private let grid = MessageImageGrid()
    @objc dynamic private var cards: [MessageDocumentCard] = []
    private var attachments: [ComposerAttachment] = []
    @objc dynamic private var requested: Set<UUID> = []
    @objc dynamic private var trailing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(grid)
        grid.onPreview = { [weak self] item in
            guard let self else { return }
            onPreviewImages?(Self.images(in: attachments), item.id)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// `animated` is the row's to say: a message gaining attachments
    /// cross-fades, a row taking another message out of the pool does not.
    func show(_ attachments: [ComposerAttachment], trailing: Bool, animated: Bool) {
        guard self.attachments != attachments || self.trailing != trailing else { return }
        if self.attachments.map(\.id) != attachments.map(\.id) {
            requested.removeAll()
        }
        self.attachments = attachments
        self.trailing = trailing
        refresh(animated: animated)
        for item in attachments where requested.insert(item.id).inserted {
            MessageAttachmentPreviews.shared.prepare(item) { [weak self] in
                guard let self, self.attachments.contains(where: { $0.id == item.id }) else { return }
                refresh(animated: true)
                onSizeChange?()
            }
        }
    }

    @objc dynamic private func refresh(animated: Bool) {
        if animated, window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: self, duration: 0.18, options: [.transitionCrossDissolve, .allowAnimatedContent]) {
                // Only the cross-fade: new tiles and cards start at their
                // places rather than growing out of the corner.
                UIView.performWithoutAnimation {
                    self.updateContent()
                    self.layoutIfNeeded()
                }
            }
        } else {
            UIView.performWithoutAnimation(updateContent)
        }
    }

    @objc dynamic private func updateContent() {
        grid.show(Self.images(in: attachments))
        cards.forEach { $0.removeFromSuperview() }
        cards = Self.files(in: attachments).map { item in
            let card = MessageDocumentCard(item: item)
            card.addAction(UIAction { [weak self] _ in self?.onPreview?(item) }, for: .touchUpInside)
            addSubview(card)
            return card
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let images = Self.images(in: attachments)
        grid.maximumSize = CGSize(width: bounds.width, height: previewHeightLimit)
        grid.displayScale = displayScale
        let size = MessageImageGrid.size(
            for: images,
            width: bounds.width,
            maximumHeight: previewHeightLimit,
            displayScale: displayScale,
        )
        grid.frame = directionalFrame(
            CGRect(x: trailing ? bounds.width - size.width : 0, y: 0, width: size.width, height: size.height),
        )
        var y = size.height
        for card in cards {
            if y > 0 {
                y += ChatMarkdownView.blockSpacing
            }
            let width = MessageDocumentCard.width(for: card.item, maximum: min(bounds.width, documentWidthLimit))
            let height = min(previewHeightLimit, MessageDocumentCard.height(for: card.item, width: width))
            card.frame = directionalFrame(
                CGRect(x: trailing ? bounds.width - width : 0, y: y, width: width, height: height),
            )
            y += height
        }
    }

    static func height(
        for attachments: [ComposerAttachment],
        width: CGFloat,
        documentWidthLimit: CGFloat,
        maximumPreviewHeight: CGFloat,
        displayScale: CGFloat,
    ) -> CGFloat {
        var height = MessageImageGrid.size(
            for: images(in: attachments),
            width: width,
            maximumHeight: maximumPreviewHeight,
            displayScale: displayScale,
        ).height
        for item in files(in: attachments) {
            if height > 0 {
                height += ChatMarkdownView.blockSpacing
            }
            let cardWidth = MessageDocumentCard.width(for: item, maximum: min(width, documentWidthLimit))
            height += min(maximumPreviewHeight, MessageDocumentCard.height(for: item, width: cardWidth))
        }
        return height
    }

    private static func images(in items: [ComposerAttachment]) -> [ComposerAttachment] {
        items.filter { MessageAttachmentPreviews.shared.image(for: $0) != nil }
    }

    private static func files(in items: [ComposerAttachment]) -> [ComposerAttachment] {
        items.filter { MessageAttachmentPreviews.shared.image(for: $0) == nil }
    }
}

private final class MessageDocumentCard: UIControl {
    let item: ComposerAttachment
    private let name = UILabel()
    private let excerpt = UILabel()
    private static let padding: CGFloat = 12
    private static let previewLines = 3
    private static let sizingExcerpt = UILabel()
    @objc dynamic private static var nameFont: UIFont {
        UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
    }

    @objc dynamic private static var excerptFont: UIFont {
        .preferredFont(forTextStyle: .subheadline)
    }

    init(item: ComposerAttachment) {
        self.item = item
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        name.font = Self.nameFont
        name.text = item.name
        name.lineBreakMode = .byTruncatingMiddle
        excerpt.font = Self.excerptFont
        excerpt.textColor = .secondaryLabel
        excerpt.numberOfLines = Self.previewLines
        excerpt.text = Self.previewText(item)
        for label in [name, excerpt] {
            label.isUserInteractionEnabled = false
            addSubview(label)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = item.name
        accessibilityHint = String(localized: "Opens the attachment preview.")
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(item:)")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        let headerHeight = ceil(name.font.lineHeight)
        name.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: headerHeight)
        excerpt.frame = CGRect(
            x: content.minX,
            y: content.minY + headerHeight + 8,
            width: content.width,
            height: max(0, content.height - headerHeight - 8),
        )
    }

    static func height(for item: ComposerAttachment, width: CGFloat) -> CGFloat {
        let header = ceil(nameFont.lineHeight)
        guard let text = previewText(item), !text.isEmpty else { return padding * 2 + header }
        sizingExcerpt.font = excerptFont
        sizingExcerpt.numberOfLines = previewLines
        sizingExcerpt.text = text
        let size = sizingExcerpt.sizeThatFits(
            CGSize(width: max(1, width - padding * 2), height: .greatestFiniteMagnitude),
        )
        return padding * 2 + header + 8 + ceil(size.height)
    }

    static func width(for item: ComposerAttachment, maximum: CGFloat) -> CGFloat {
        let nameWidth = (item.name as NSString).size(withAttributes: [.font: nameFont]).width
        let textWidth = ((previewText(item) ?? "") as NSString).size(withAttributes: [.font: excerptFont]).width
        let naturalWidth = ceil(max(nameWidth, textWidth)) + padding * 2
        return max(1, min(350, maximum, naturalWidth))
    }

    private static func previewText(_ item: ComposerAttachment) -> String? {
        guard let text = item.text else { return nil }
        var preview = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
        // Eight passes collapse even a run spanning the entire 220-character preview.
        for _ in 0 ..< 8 {
            guard preview.contains("\n\n") else { break }
            preview = preview.replacingOccurrences(of: "\n\n", with: "\n")
        }
        return preview
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBorder()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateBorder()
    }

    @objc dynamic private func updateBorder() {
        layer.borderColor = tintColor.resolvedColor(with: traitCollection).withAlphaComponent(0.15).cgColor
    }
}
