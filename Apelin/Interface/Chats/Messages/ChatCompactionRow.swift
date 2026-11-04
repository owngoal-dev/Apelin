import ListViewKit
import UIKit

/// Where the reader's Compact… compacted the conversation: one quiet line,
/// like a summary's title, that opens the summary the conversation goes on
/// from (`ChatCompactionController`). A session that did not keep the
/// summary leaves only the line.
final class ChatCompactionRow: ListRowView {
    @objc dynamic var onOpen: (() -> Void)?
    private let label = UILabel()
    @objc dynamic private var opensSummary = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label.withAlphaComponent(0.5)
        label.numberOfLines = 0
        label.text = Self.title
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = Self.title
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(open)))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ message: ChatMessage) {
        opensSummary = !message.text.isEmpty
        accessibilityTraits = opensSummary ? .button : .staticText
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onOpen = nil
        opensSummary = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.inset(by: ChatMessageRow.insets(for: bounds.width))
    }

    override func accessibilityActivate() -> Bool {
        guard opensSummary else { return false }
        open()
        return true
    }

    @objc dynamic private func open() {
        guard opensSummary else { return }
        onOpen?()
    }

    @objc dynamic private static var title: String {
        String(localized: "Compacted")
    }

    static func height(for _: ChatMessage, width: CGFloat) -> CGFloat {
        let insets = ChatMessageRow.insets(for: width)
        let width = max(1, width - insets.left - insets.right)
        let rect = (title as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)],
            context: nil,
        )
        return insets.top + ceil(rect.height) + insets.bottom
    }
}
