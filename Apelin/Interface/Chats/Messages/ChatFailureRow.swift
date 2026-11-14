import ListViewKit
import Litext
import UIKit

/// An error in the transcript (`ChatFailure`): what went wrong in one line,
/// in red, and under it what to do or what the provider said. Plain,
/// selectable text at the reading width, so it never reads as a reply.
final class ChatFailureRow: ListRowView {
    private let label = TextLabelView()
    private static let sizing = TextLabelView()
    /// Between the title and the line under it.
    private static let lineSpacing: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Selection handles extend beyond a transcript row.
        clipsToBounds = false
        label.isSelectable = true
        label.delegate = self
        label.isAccessibilityElement = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ message: ChatMessage) {
        guard let failure = message.failure else { return }
        label.attributedText = Self.text(of: failure)
        label.accessibilityLabel = failure.spoken
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.clearSelection()
        label.attributedText = NSAttributedString()
        label.accessibilityLabel = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.inset(by: ChatMessageRow.insets(for: bounds.width))
    }

    static func height(for message: ChatMessage, width: CGFloat) -> CGFloat {
        guard let failure = message.failure else { return 0 }
        let insets = ChatMessageRow.insets(for: width)
        sizing.attributedText = text(of: failure)
        let size = sizing.sizeThatFits(CGSize(width: max(1, width - insets.left - insets.right), height: 0))
        return insets.top + ceil(size.height) + insets.bottom
    }

    /// The title, semibold and red, over the detail in the secondary colour.
    private static func text(of failure: ChatFailure) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = lineSpacing
        let text = NSMutableAttributedString(string: failure.title, attributes: [
            .font: UIFont.systemFont(ofSize: body.pointSize, weight: .semibold),
            .foregroundColor: UIColor.systemRed,
            .paragraphStyle: paragraph,
        ])
        if !failure.detail.isEmpty {
            text.append(NSAttributedString(string: "\n" + failure.detail, attributes: [
                .font: body,
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraph,
            ]))
        }
        return text
    }
}

extension ChatFailureRow: TextLabelViewDelegate {
    @objc dynamic func textLabelView(
        _ label: TextLabelView,
        editMenuForSelection selection: NSRange,
        suggestedActions: [UIMenuElement],
    ) -> UIMenu? {
        ChatSelectionMenu.menu(for: label, selection: selection, suggestedActions: suggestedActions)
    }
}
