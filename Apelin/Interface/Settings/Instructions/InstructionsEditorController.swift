import ApelinCore
import UIKit

/// Edits one scope of the user's custom instructions (issue #74;
/// `CustomInstructionsStore`): those for every conversation, from Settings ▸
/// Agent, or a project's, from its chat's More menu. A session takes them
/// when it opens, and an open one hears of a change with its next message.
///
/// The text is saved only while the file still holds what this page
/// loaded, so a second window cannot undo a newer save or a Clear; Clear
/// asks first. A count under the text says how much of the limit is used,
/// and Save waits while the text is over it rather than cutting what was
/// typed or pasted.
final class InstructionsEditorController: TableController, UITextViewDelegate {
    private enum Row: Hashable { case text, clear }

    private final class DataSource: UITableViewDiffableDataSource<Int, Row> {
        @objc dynamic var footer: String?

        override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
            section == 0 ? footer : nil
        }
    }

    private let scope: InstructionsScope
    private let store = CustomInstructionsStore(root: DataFolder.app.root)
    /// What the file held when this page read it; nil until then, or when it
    /// could not be read.
    @objc private dynamic var loaded: String?
    @objc private dynamic var saving = false
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let counter = UILabel()
    private var dataSource: DataSource!
    @objc private dynamic lazy var saveItem = UIBarButtonItem(
        title: String(localized: "Save"),
        primaryAction: UIAction { [weak self] _ in self?.save() },
    )

    init(scope: InstructionsScope) {
        self.scope = scope
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(scope:)")
    }

    @objc private dynamic var isProject: Bool {
        if case .project = scope {
            return true
        }
        return false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isProject ? String(localized: "Project Instructions") : String(localized: "Custom Instructions")
        navigationItem.rightBarButtonItem = saveItem
        tableView.keyboardDismissMode = .interactive
        tableView.selfSizingInvalidation = .enabledIncludingConstraints
        textView.accessibilityLabel = title
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isEditable = false
        textView.delegate = self
        placeholder.text = isProject
            ? String(localized: "How should your agent work in this project?")
            : String(localized: "How should your agent work in every chat?")
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 0
        placeholder.isAccessibilityElement = false
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: textView.frameLayoutGuide.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: textView.frameLayoutGuide.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: textView.frameLayoutGuide.topAnchor),
        ])
        counter.font = .preferredFont(forTextStyle: .footnote)
        counter.adjustsFontForContentSizeCategory = true
        counter.textAlignment = .natural
        let textCell = editorCell()
        dataSource = DataSource(tableView: tableView) { _, _, row in
            switch row {
            case .text: return textCell
            case .clear:
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                var content = cell.defaultContentConfiguration()
                content.text = String(localized: "Clear Instructions")
                content.textProperties.color = .systemRed
                cell.contentConfiguration = content
                cell.accessibilityTraits = .button
                return cell
            }
        }
        dataSource.footer = isProject
            ? String(localized: "Your agent follows these in every chat in this project, ahead of your custom instructions for all chats. They can’t change approvals or Apelin’s rules.")
            : String(localized: "Your agent follows these in every chat, such as checking your assumptions before it starts. They can’t change approvals or Apelin’s rules.")
        apply(clearable: false)
        updateControls()
        load()
    }

    /// The text and its count under it, the count at the trailing edge.
    @objc private dynamic func editorCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        let stack = UIStackView(arrangedSubviews: [textView, counter])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .trailing
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: margins.topAnchor),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            textView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        return cell
    }

    @objc private dynamic func apply(clearable: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems([.text], toSection: 0)
        if clearable {
            snapshot.appendSections([1])
            snapshot.appendItems([.clear], toSection: 1)
        }
        if dataSource.snapshot().sectionIdentifiers.isEmpty {
            dataSource.applyFirst(snapshot, to: tableView)
        } else {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    @objc(apelin_load) private dynamic func load() {
        let store = store
        let scope = scope
        Task { [weak self] in
            do {
                let loaded = try await Task.detached { try store.load(scope) }.value
                guard let self else { return }
                self.loaded = loaded.text
                textView.text = loaded.text
                textView.isEditable = true
                apply(clearable: !loaded.text.isEmpty)
                updateControls()
                if loaded.setAside != nil {
                    presentNotice(
                        title: "Instructions Couldn’t Be Read",
                        message: "The previous copy was kept aside, so you can write your instructions again here.",
                    )
                }
            } catch {
                self?.presentNotice(title: "Unable to Load Instructions", message: "Go back and try again.")
            }
        }
    }

    @objc dynamic func textViewDidChange(_: UITextView) {
        updateControls()
    }

    /// The count, Save and the placeholder, as the text and the load stand.
    @objc private dynamic func updateControls() {
        let text = textView.text ?? ""
        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        let limit = CustomInstructionsStore.maximumCharacters
        counter.text = "\(count.formatted())/\(limit.formatted())"
        counter.textColor = count > limit ? .systemRed : .secondaryLabel
        counter.accessibilityLabel = String(localized: "\(count) of \(limit) characters")
        counter.isHidden = loaded == nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        saveItem.isEnabled = !saving && loaded.map { $0 != trimmed } == true && count <= limit
        placeholder.isHidden = !text.isEmpty
        textView.accessibilityHint = placeholder.isHidden ? nil : placeholder.text
    }

    @objc private dynamic func save() {
        guard saveItem.isEnabled, let loaded else { return }
        write(textView.text ?? "", replacing: loaded)
    }

    /// Saves `text` over `previous`, what the page loaded, and goes back.
    @objc private dynamic func write(_ text: String, replacing previous: String) {
        guard !saving else { return }
        saving = true
        updateControls()
        view.endEditing(true)
        let store = store
        let scope = scope
        Task { [weak self] in
            do {
                try await Task.detached { try store.save(text, for: scope, replacing: previous) }.value
                self?.navigationController?.popViewController(animated: true)
            } catch {
                guard let self else { return }
                saving = false
                updateControls()
                presentInstructionsError(error)
            }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard dataSource.itemIdentifier(for: indexPath) == .clear, let loaded, !saving else { return }
        confirmClearingInstructions(project: isProject) { [weak self] in
            self?.write("", replacing: loaded)
        }
    }
}

extension UIViewController {
    /// Asks before custom instructions are cleared.
    func confirmClearingInstructions(project: Bool, onConfirm: @escaping () -> Void) {
        presentConfirmation(
            title: "Clear Instructions?",
            message: project
                ? "Your agent will no longer follow these in this project."
                : "Your agent will no longer follow these in any chat.",
            confirmTitle: "Clear",
            destructive: true,
            onConfirm: onConfirm,
        )
    }

    func presentInstructionsError(_ error: Error) {
        switch error as? CustomInstructionsError {
        case .changed:
            presentNotice(
                title: "Instructions Changed",
                message: "These instructions were changed in another window. Reopen them to review the latest version before editing.",
            )
        default:
            presentNotice(title: "Unable to Save Instructions", message: "Your changes weren’t saved. Try again.")
        }
    }
}
