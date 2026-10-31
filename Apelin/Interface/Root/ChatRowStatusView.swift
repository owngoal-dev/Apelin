import UIKit

/// What a sidebar row shows at its trailing edge: the system's spinner
/// while the conversation works, a yellow dot while a reply waits unread
/// (`ChatSummary.showsUnread`). One view the spinner's size, the dot
/// centred in it, so the two share a centre and the title keeps its width
/// whichever shows. Drawn only: the row's `accessibilityValue` says it.
final class ChatRowStatusView: UIView {
    enum Status {
        case working
        case unread
    }

    /// An even size, so the dot sits on whole pixels in the spinner's
    /// 20-point square at every scale.
    private static let dotDiameter: CGFloat = 10

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let dot = UIView()

    init() {
        super.init(frame: .zero)
        spinner.sizeToFit()
        frame.size = spinner.bounds.size
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        spinner.frame = bounds
        addSubview(spinner)
        dot.backgroundColor = .systemYellow
        dot.bounds.size = CGSize(width: Self.dotDiameter, height: Self.dotDiameter)
        dot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        dot.layer.cornerRadius = Self.dotDiameter / 2
        addSubview(dot)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    /// Shows `status`; nil shows neither.
    func show(_ status: Status?) {
        if status == .working {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        dot.isHidden = status != .unread
    }
}
