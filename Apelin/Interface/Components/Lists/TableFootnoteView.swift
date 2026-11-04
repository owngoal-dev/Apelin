import SnapKit
import Then
import UIKit

/// Small grey lines under a list, as Irisin ends its settings: the long
/// values a page keeps but nobody reads row by row — an identifier, a
/// digest, a path. A table's footer; `fit(in:)` sizes it from
/// `viewDidLayoutSubviews`.
final class TableFootnoteView: UIView {
    private let label = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .caption2)
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 0
        // a long path breaks anywhere rather than leaving a ragged gap
        $0.lineBreakMode = .byCharWrapping
    }

    init(lines: [String]) {
        super.init(frame: .zero)
        label.text = lines.joined(separator: "\n")
        addSubview(label)
        label.snp.makeConstraints { x in
            x.top.equalToSuperview().inset(12)
            x.leading.trailing.equalToSuperview().inset(32)
            // below required: the table holds the footer at its last frame
            // until it is measured again
            x.bottom.equalToSuperview().inset(24).priority(999)
        }
        // one stop for VoiceOver, every line in it
        isAccessibilityElement = true
        accessibilityLabel = label.text
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(lines:)")
    }

    /// Its text's height at the table's width and text size. Only a new
    /// size is set: setting a footer lays the table out again.
    @objc dynamic func fit(in tableView: UITableView) {
        let width = tableView.bounds.width
        guard width > 0, tableView.tableFooterView === self else { return }
        let height = systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        ).height
        guard frame.size != CGSize(width: width, height: height) else { return }
        frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableFooterView = self
    }
}
