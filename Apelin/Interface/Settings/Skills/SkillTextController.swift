import ApelinProtocol
import UIKit

/// One skill from Settings ▸ Skills: its description, the instructions the
/// agent reads with `apelin_skill_read`, and the other files its folder serves.
/// From GitHub previews a skill before it is imported the same way: its
/// `SKILL.md` as it is, the files that come with it and what stays behind.
/// Selectable, wrapping text, as a license's page is.
final class SkillTextController: UIViewController {
    private let name: String
    private let summary: String
    private let text: String
    private let files: [String]
    private let leftBehind: [String]

    init(name: String, summary: String, text: String, files: [String], leftBehind: [String] = []) {
        self.name = name
        self.summary = summary
        self.text = text
        self.files = files
        self.leftBehind = leftBehind
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(skill: AgentSkill) {
        self.init(name: skill.name, summary: skill.description, text: skill.body, files: skill.files)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = name
        view.backgroundColor = .systemGroupedBackground
        let body = UIFont.preferredFont(forTextStyle: .body)
        let footnote = UIFont.preferredFont(forTextStyle: .footnote)
        let monospaced = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: footnote.pointSize, weight: .regular),
        )
        let page = NSMutableAttributedString(string: summary + "\n\n", attributes: [
            .font: body, .foregroundColor: UIColor.secondaryLabel,
        ])
        page.append(NSAttributedString(string: text, attributes: [
            .font: monospaced, .foregroundColor: UIColor.label,
        ]))
        let lists = [(String(localized: "Files"), files), (String(localized: "Left Behind"), leftBehind)]
        for (heading, paths) in lists where !paths.isEmpty {
            page.append(NSAttributedString(
                string: "\n\n" + heading + "\n",
                attributes: [.font: UIFont.preferredFont(forTextStyle: .headline), .foregroundColor: UIColor.label],
            ))
            page.append(NSAttributedString(string: paths.joined(separator: "\n"), attributes: [
                .font: monospaced, .foregroundColor: UIColor.secondaryLabel,
            ]))
        }

        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.attributedText = page
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
    }
}
