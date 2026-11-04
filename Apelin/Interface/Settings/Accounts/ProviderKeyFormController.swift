import ApelinProtocol
import UIKit

/// The editable part of an API-key sign-in. The parent owns the sign-in
/// task; this native grouped form owns only the user's unsent field values.
final class ProviderKeyFormController: TableController {
    var onSubmit: (([AgentSignInField: String]) -> Void)?
    var onSwitchMethod: ((AgentSignInMethod) -> Void)?

    @objc dynamic var isSubmitting = false {
        didSet {
            if isViewLoaded {
                updateSubmit()
            }
        }
    }

    private let keys: [SignInProgress.KeyField]
    private let alternatives: [AgentSignInMethod]
    private let initialValues: [String: String]
    private var fields: [AgentSignInField: UITextField] = [:]
    private var cells: [AgentSignInField: UITableViewCell] = [:]
    private enum Row: Hashable {
        case field(AgentSignInField)
        case method(AgentSignInMethod)
    }

    private enum Section: Hashable {
        case field(AgentSignInField)
        case methods
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    @objc dynamic lazy var submitItem = UIBarButtonItem(
        title: String(localized: "Fetch Models"),
        primaryAction: UIAction { [weak self] _ in self?.submit() },
    )

    init(keys: [SignInProgress.KeyField], alternatives: [AgentSignInMethod], initialValues: [String: String] = [:]) {
        self.keys = keys.filter { $0.field != .defaultModel }
        self.alternatives = alternatives
        self.initialValues = initialValues
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(keys:alternatives:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        for (index, key) in keys.enumerated() {
            let field = UITextField()
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartDashesType = .no
            field.smartQuotesType = .no
            field.clearButtonMode = .whileEditing
            field.isSecureTextEntry = key.secure
            field.textContentType = key.field == .baseURL ? .URL : nil
            field.keyboardType = key.field == .baseURL ? .URL : .asciiCapable
            field.returnKeyType = index == keys.count - 1 ? .go : .next
            field.accessibilityLabel = key.field.title
            field.text = initialValues[key.field.rawValue] ?? key.defaultValue
            field.placeholder = key.placeholder
                ?? (key.required ? key.field.title : String(localized: "\(key.field.title) (Optional)"))
            field.addAction(UIAction { [weak self] _ in self?.updateSubmit() }, for: .editingChanged)
            field.addAction(UIAction { [weak self] _ in self?.advance(from: index) }, for: .editingDidEndOnExit)
            fields[key.field] = field
            cells[key.field] = cell(containing: field)
        }
        submitItem.tintColor = .tintColor
        submitItem.accessibilityLabel = String(localized: "Fetch Models")
        updateSubmit()
        dataSource.headerTitle = { section in
            if case let .field(field) = section {
                return field.title
            }
            return nil
        }
        var sections: [(Section, [Row])] = keys.map { (.field($0.field), [.field($0.field)]) }
        if !alternatives.isEmpty {
            sections.append((.methods, alternatives.map(Row.method)))
        }
        dataSource.update(sections)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isSubmitting, let first = keys.first {
            fields[first.field]?.becomeFirstResponder()
        }
    }

    @objc private dynamic func cell(containing input: UIView) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        input.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(input)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            input.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            input.topAnchor.constraint(equalTo: margins.topAnchor),
            input.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        return cell
    }

    private var values: [AgentSignInField: String] {
        // The model selector owns defaultModel; editing a key or endpoint
        // must preserve that saved field even though this form hides it.
        var result: [AgentSignInField: String] = [:]
        if let defaultModel = initialValues[AgentSignInField.defaultModel.rawValue] {
            result[.defaultModel] = defaultModel
        }
        return result.merging(fields.mapValues { $0.text ?? "" }) { _, edited in edited }
    }

    @objc private dynamic var isReady: Bool {
        keys.allSatisfy {
            !$0.required || !(fields[$0.field]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @objc private dynamic func updateSubmit() {
        submitItem.isEnabled = isReady && !isSubmitting
        fields.values.forEach { $0.isEnabled = !isSubmitting }
    }

    @objc private dynamic func advance(from index: Int) {
        if index + 1 < keys.count {
            fields[keys[index + 1].field]?.becomeFirstResponder()
        } else {
            submit()
        }
    }

    @objc private dynamic func submit() {
        guard isReady, !isSubmitting else { return }
        view.endEditing(true)
        onSubmit?(values)
    }

    private func cell(for row: Row) -> UITableViewCell? {
        if case let .field(field) = row {
            return cells[field]
        }
        guard case let .method(method) = row else { return nil }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = method.switchTitle
        content.textProperties.color = .tintColor
        cell.contentConfiguration = content
        cell.accessibilityTraits.insert(.button)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case let .field(field): fields[field]?.becomeFirstResponder()
        case let .method(method):
            if !isSubmitting {
                onSwitchMethod?(method)
            }
        }
    }
}
