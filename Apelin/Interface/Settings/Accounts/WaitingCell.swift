import UIKit

/// A spinner and what it is waiting for.
final class WaitingCell: UITableViewCell {
    private let spinner = UIActivityIndicatorView(style: .medium)

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        spinner.startAnimating()
        accessoryView = spinner
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    @objc dynamic func show(_ text: String) {
        var content = UIListContentConfiguration.cell()
        content.text = text
        content.textProperties.color = .secondaryLabel
        contentConfiguration = content
        spinner.startAnimating()
        accessibilityLabel = text
    }
}
