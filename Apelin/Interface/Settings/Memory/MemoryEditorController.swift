import ApelinCore
import UIKit

final class MemoryEditorController: TableController, UITextViewDelegate {
    private enum Row: Hashable { case title, body, delete }
    private final class DataSource: UITableViewDiffableDataSource<Int, Row> {
        override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
            switch section {
            case 0: String(localized: "Title")
            case 1: String(localized: "Memory")
            default: nil
            }
        }
    }

    private let store: MemoryStore
    private let record: MemoryRecord?
    private let revision: String
    private let titleField = UITextField()
    private let bodyField = UITextView()
    private let bodyPlaceholder = UILabel()
    private var dataSource: DataSource!
    @objc private dynamic var saving = false
    @objc private dynamic lazy var saveItem = UIBarButtonItem(
        title: String(localized: "Save"),
        primaryAction: UIAction { [weak self] _ in self?.save() },
    )

    init(store: MemoryStore, record: MemoryRecord?, revision: String) {
        self.store = store
        self.record = record
        self.revision = revision
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(store:record:revision:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = record == nil ? String(localized: "Add Memory") : String(localized: "Edit Memory")
        navigationItem.rightBarButtonItem = saveItem
        tableView.keyboardDismissMode = .interactive
        titleField.text = record?.title
        titleField.placeholder = String(localized: "A short title")
        titleField.accessibilityLabel = String(localized: "Title")
        titleField.font = .preferredFont(forTextStyle: .body)
        titleField.adjustsFontForContentSizeCategory = true
        titleField.clearButtonMode = .whileEditing
        titleField.addAction(UIAction { [weak self] _ in self?.updateSave() }, for: .editingChanged)
        bodyField.text = record?.body
        bodyField.accessibilityLabel = String(localized: "Memory")
        bodyField.font = .preferredFont(forTextStyle: .body)
        bodyField.adjustsFontForContentSizeCategory = true
        bodyField.backgroundColor = .clear
        bodyField.isScrollEnabled = false
        bodyField.textContainerInset = .zero
        bodyField.textContainer.lineFragmentPadding = 0
        bodyField.delegate = self
        bodyPlaceholder.text = String(localized: "What should the agent remember?")
        bodyPlaceholder.font = .preferredFont(forTextStyle: .body)
        bodyPlaceholder.adjustsFontForContentSizeCategory = true
        bodyPlaceholder.textColor = .placeholderText
        bodyPlaceholder.numberOfLines = 0
        bodyPlaceholder.isAccessibilityElement = false
        bodyPlaceholder.isUserInteractionEnabled = false
        bodyPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        bodyField.addSubview(bodyPlaceholder)
        NSLayoutConstraint.activate([
            bodyPlaceholder.leadingAnchor.constraint(equalTo: bodyField.frameLayoutGuide.leadingAnchor),
            bodyPlaceholder.trailingAnchor.constraint(equalTo: bodyField.frameLayoutGuide.trailingAnchor),
            bodyPlaceholder.topAnchor.constraint(equalTo: bodyField.frameLayoutGuide.topAnchor),
        ])
        let titleCell = fieldCell(titleField)
        let bodyCell = fieldCell(bodyField, minimumHeight: 180)
        dataSource = DataSource(tableView: tableView) { _, _, row in
            switch row {
            case .title: return titleCell
            case .body: return bodyCell
            case .delete:
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                var content = cell.defaultContentConfiguration()
                content.text = String(localized: "Delete Memory")
                content.textProperties.color = .systemRed
                cell.contentConfiguration = content
                cell.accessibilityTraits = .button
                return cell
            }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems([.title], toSection: 0)
        snapshot.appendItems([.body], toSection: 1)
        if record != nil {
            snapshot.appendSections([2])
            snapshot.appendItems([.delete], toSection: 2)
        }
        dataSource.applyFirst(snapshot, to: tableView)
        updateSave()
    }

    private func fieldCell(_ field: UIView, minimumHeight: CGFloat? = nil) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        let margins = cell.contentView.layoutMarginsGuide
        var constraints = [
            field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            field.topAnchor.constraint(equalTo: margins.topAnchor),
            field.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ]
        if let minimumHeight {
            constraints.append(field.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    @objc dynamic func textViewDidChange(_: UITextView) {
        updateSave()
    }

    @objc private dynamic func updateSave() {
        let title = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (bodyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        saveItem.isEnabled = !saving && !title.isEmpty && !body.isEmpty
        bodyPlaceholder.isHidden = !(bodyField.text ?? "").isEmpty
        bodyField.accessibilityHint = bodyPlaceholder.isHidden ? nil : bodyPlaceholder.text
    }

    @objc private dynamic func save() {
        guard saveItem.isEnabled else { return }
        let value = MemoryRecord(
            id: record?.id ?? UUID().uuidString.lowercased(),
            title: titleField.text ?? "",
            body: bodyField.text ?? "",
            projectID: record?.projectID,
        )
        perform { [store, record, revision] in try store.save(value, replacing: record?.id, revision: revision) }
    }

    private func perform(_ change: @escaping @Sendable () throws -> MemorySnapshot) {
        guard !saving else { return }
        saving = true
        updateSave()
        view.endEditing(true)
        Task { [weak self] in
            do {
                _ = try await Task.detached(operation: change).value
                self?.navigationController?.popViewController(animated: true)
            } catch {
                guard let self else { return }
                saving = false
                updateSave()
                presentMemoryError(error)
            }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard dataSource.itemIdentifier(for: indexPath) == .delete, let record, !saving else { return }
        presentConfirmation(
            title: "Delete Memory?",
            message: "This memory will no longer be used in future replies.",
            confirmTitle: "Delete",
            destructive: true,
        ) { [weak self] in
            guard let self else { return }
            perform { [store, revision] in try store.delete(id: record.id, revision: revision) }
        }
    }
}
