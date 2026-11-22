import UIKit

/// The summary a compaction left, which the conversation goes on from, as
/// plain selectable text in a sheet; with `title`, another text shown the
/// same way (a project's AGENTS.md, `ConversationInstructionsController`).
final class ChatCompactionController: UIViewController {
    private let summary: String
    private let pageTitle: String?
    private let textView = UITextView()

    init(summary: String, title: String? = nil) {
        self.summary = summary
        pageTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(summary:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = pageTitle ?? String(localized: "Summary")
        view.backgroundColor = .pageBackground
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.alwaysBounceVertical = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.textContainer.lineFragmentPadding = 0
        let side = ChatMessageRow.horizontalPadding
        textView.textContainerInset = UIEdgeInsets(top: side, left: side, bottom: side, right: side)
        textView.text = summary
        view.addSubview(textView)
        setContentScrollView(textView)
        if #available(iOS 26, *) {
            textView.topEdgeEffect.style = .soft
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        textView.frame = view.bounds
    }
}
