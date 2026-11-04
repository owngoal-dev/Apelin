import ApelinCore
import ApelinProtocol
import Then
import UIKit

/// Creates a project through the same template API the agent host uses: its
/// name first, then every template the installed extensions offer, one
/// section per kind, the chosen one ticked. With the empty workspace ticked,
/// a Git repository's address may go under it: the project is made empty as
/// ever, and its first message asks the agent to import the repository and
/// work out how it builds.
final class NewProjectController: TableController, UITextFieldDelegate {
    /// The project made, and the message its first conversation sends, if any.
    var onCreate: ((ProjectSummary, _ firstPrompt: String?) -> Void)?
    @objc dynamic var onCanCreateChange: ((Bool) -> Void)?
    private let dismissesOnCreate: Bool
    private let preferredTemplateID: String?

    private struct Choice: Equatable {
        let template: TemplateSummary
        let kind: DevelopmentExtensionKind
    }

    private enum Section: Hashable {
        case name
        case kind(DevelopmentExtensionKind)
        case repository
    }

    private enum Row: Equatable {
        case name
        case template(Choice, selected: Bool)
        case repository

        var id: String {
            switch self {
            case .name: "name"
            case let .template(choice, _): "template:" + choice.template.id
            case .repository: "repository"
            }
        }
    }

    /// What the page offers until the catalog is read, or when it cannot be:
    /// the build worker's built-in workspace, which needs no SDK or toolchain.
    /// Its words are the worker's, looked up in the catalogue when drawn.
    private static let emptyWorkspace = Choice(
        template: TemplateSummary(
            id: "wiki.qaq.apelin.workspace/empty",
            displayName: "Empty",
            summary: "An empty workspace. No SDK or toolchain is required.",
        ),
        kind: .workspace,
    )

    private var choices = [NewProjectController.emptyWorkspace]
    @objc private dynamic var selectedID = NewProjectController.emptyWorkspace.template.id
    private var draft = ProjectCreationDraft()
    @objc private dynamic var loading = false

    private let nameField = UITextField()
    @objc private dynamic lazy var nameCell = Self.cell(containing: nameField)
    private let repositoryField = UITextField()
    @objc private dynamic lazy var repositoryCell = Self.cell(containing: repositoryField)

    @objc private dynamic static func cell(containing field: UITextField) -> UITableViewCell {
        UITableViewCell(style: .default, reuseIdentifier: nil).then { cell in
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
            ])
        }
    }

    private static let templateCellID = "template"

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: \.id,
    ) { [weak self] table, indexPath, row in
        guard let self else { return nil }
        switch row {
        case .name:
            return nameCell
        case .repository:
            return repositoryCell
        case let .template(choice, selected):
            let cell = table.dequeueReusableCell(withIdentifier: Self.templateCellID, for: indexPath)
            configure(cell, choice: choice, selected: selected)
            return cell
        }
    }

    @objc dynamic var canCreate: Bool {
        !loading && draft.isValid
    }

    init(templateID: String? = nil, dismissesOnCreate: Bool = true) {
        preferredTemplateID = templateID
        self.dismissesOnCreate = dismissesOnCreate
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "New Project")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.templateCellID)
        tableView.keyboardDismissMode = .onDrag
        nameField.delegate = self
        // empty until typed in: the generated name is the placeholder, and
        // the one the project starts with when nothing is typed
        nameField.placeholder = draft.suggestion
        nameField.accessibilityLabel = String(localized: "Project Name")
        nameField.font = .preferredFont(forTextStyle: .body)
        nameField.adjustsFontForContentSizeCategory = true
        nameField.autocorrectionType = .no
        nameField.clearButtonMode = .whileEditing
        nameField.returnKeyType = .done
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        repositoryField.delegate = self
        repositoryField.placeholder = String(localized: "https://github.com/owner/repository")
        repositoryField.accessibilityLabel = String(localized: "Git Repository")
        repositoryField.font = .preferredFont(forTextStyle: .body)
        repositoryField.adjustsFontForContentSizeCategory = true
        repositoryField.keyboardType = .URL
        repositoryField.textContentType = .URL
        repositoryField.autocapitalizationType = .none
        repositoryField.autocorrectionType = .no
        repositoryField.spellCheckingType = .no
        repositoryField.clearButtonMode = .whileEditing
        repositoryField.returnKeyType = .done
        navigationItem.rightBarButtonItem = createButton
        dataSource.headerTitle = { section in
            switch section {
            case .name: String(localized: "Name")
            case let .kind(kind): kind.displayName
            case .repository: String(localized: "Git Repository")
            }
        }
        dataSource.footerTitle = { section in
            switch section {
            case .name:
                String(localized: "Leave it empty to use the name shown for now. Your agent will name the project once it knows what you’re making.")
            case .repository:
                String(localized: "Optional. Your agent imports the repository into the new project and works out how to build it.")
            case .kind: nil
            }
        }
        updateCreate()
        updateRows()
        dataSource.beginLoad()
        Task { [weak self] in
            guard let self else { return }
            let existing = await (try? ProjectSummary.load()) ?? []
            guard !Task.isCancelled else { return }
            draft.avoidExisting(existing.map(\.name))
            nameField.placeholder = draft.suggestion
            updateCreate()
            do {
                let catalog = try await ApelinService.app.extensionList()
                guard !Task.isCancelled else { return }
                var seen = Set<String>()
                let available = catalog.extensions.filter(\.problems.isEmpty).flatMap { item in
                    item.templates.map { Choice(template: $0, kind: item.kind) }
                }.filter { seen.insert($0.template.id).inserted }
                guard !available.isEmpty else { return }
                choices = available
                selectedID = initialSelection(in: available)
                updateRows()
            } catch { presentNotice(title: "Templates Unavailable", message: error.readableMessage) }
        }
    }

    /// The template asked for, else the one already ticked, else the
    /// workspace, else the first.
    private func initialSelection(in available: [Choice]) -> String {
        let wanted = [preferredTemplateID, selectedID].compactMap(\.self)
        if let id = wanted.first(where: { id in available.contains { $0.template.id == id } }) {
            return id
        }
        return (available.first { $0.kind == .workspace } ?? available[0]).template.id
    }

    @objc private dynamic lazy var createButton = UIBarButtonItem(
        title: String(localized: "Create"),
        primaryAction: UIAction { [weak self] _ in self?.createProject() },
    )

    @objc private dynamic lazy var creatingIndicator = UIBarButtonItem(customView: UIActivityIndicatorView(style: .medium).then {
        $0.startAnimating()
        $0.isAccessibilityElement = true
        $0.accessibilityLabel = String(localized: "Creating Project…")
    })

    /// The repository field shows above the workspace section while the
    /// empty workspace is ticked.
    @objc private dynamic func updateRows() {
        var sections: [(Section, [Row])] = [(.name, [.name])]
        for kind in DevelopmentExtensionKind.displayOrder {
            let rows = choices.filter { $0.kind == kind }
                .map { Row.template($0, selected: $0.template.id == selectedID) }
            guard !rows.isEmpty else { continue }
            if kind == .workspace, importsRepository {
                sections.append((.repository, [.repository]))
            }
            sections.append((.kind(kind), rows))
        }
        dataSource.update(sections, reconfigure: true)
    }

    @objc private dynamic var importsRepository: Bool {
        selectedID == Self.emptyWorkspace.template.id
    }

    /// The address typed, when the empty workspace takes one; nil when
    /// nothing is typed.
    @objc private dynamic var repositoryAddress: String? {
        guard importsRepository else { return nil }
        let address = (repositoryField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? nil : address
    }

    /// Only the basics: HTTPS, a host, and no user or token written into it,
    /// which would go into the conversation. The agent reports the rest.
    @objc private dynamic static func isImportable(_ address: String) -> Bool {
        guard let url = URLComponents(string: address), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    private func configure(_ cell: UITableViewCell, choice: Choice, selected: Bool) {
        var content = UIListContentConfiguration.explanatoryCell()
        content.image = ProjectIcon.image(for: choice.kind)
        content.imageProperties.maximumSize = CGSize(width: 36, height: 36)
        content.imageProperties.reservedLayoutSize = CGSize(width: 36, height: 36)
        content.text = Self.catalogText(choice.template.displayName)
        content.secondaryText = choice.template.summary.map(Self.catalogText)
        content.secondaryTextProperties.color = .secondaryLabel

        cell.contentConfiguration = content
        cell.accessoryType = selected ? .checkmark : .none
        // the tick is drawn; the trait says it
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = [content.text, content.secondaryText].compactMap(\.self).joined(separator: ", ")
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
    }

    /// A template's name and summary are its extension's English; the
    /// catalogue has the shipped ones, and anything else stays as written.
    @objc private dynamic static func catalogText(_ text: String) -> String {
        String(localized: String.LocalizationValue(text))
    }

    override func tableView(_: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        switch dataSource.value(at: indexPath) {
        case .template:
            break
        case .repository:
            repositoryField.becomeFirstResponder()
            return nil
        default:
            // a tap beside the field still means the field
            nameField.becomeFirstResponder()
            return nil
        }
        return indexPath
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .template(choice, _) = dataSource.value(at: indexPath) else { return }
        selectedID = choice.template.id
        updateRows()
    }

    @objc private dynamic func nameChanged() {
        draft.edit(nameField.text ?? "")
        updateCreate()
    }

    @objc private dynamic func updateCreate() {
        createButton.isEnabled = canCreate
        onCanCreateChange?(canCreate)
    }

    /// While the request is out the page holds still: no edits, no other
    /// template, no close, and the spinner where Create was.
    @objc private dynamic func setCreating(_ creating: Bool) {
        loading = creating
        navigationItem.rightBarButtonItem = creating ? creatingIndicator : createButton
        navigationItem.leftBarButtonItem?.isEnabled = !creating
        navigationItem.hidesBackButton = creating
        navigationController?.isModalInPresentation = creating
        tableView.isUserInteractionEnabled = !creating
        updateCreate()
    }

    @objc dynamic func textFieldShouldReturn(_: UITextField) -> Bool {
        if canCreate {
            createProject()
        }
        return false
    }

    @objc dynamic func createProject() {
        guard canCreate, let entry = choices.first(where: { $0.template.id == selectedID }) else { return }
        let address = repositoryAddress
        if let address, !Self.isImportable(address) {
            presentNotice(title: "Check the Repository Address", message: "Enter an HTTPS address, such as https://github.com/owner/repository, with no username or token in it. Save a token in Settings ▸ Git instead.")
            return
        }
        let firstPrompt = address.map { address in
            String(localized: "Import the Git repository \(address) into this workspace with git_clone, then work out how to build it and tell me what you find.")
        }
        view.endEditing(true)
        let name = draft.trimmedName
        let automaticallyName = draft.automaticallyName
        setCreating(true)
        Task {
            defer { setCreating(false) }
            do {
                let created = try await ApelinService.app.projectCreate(ProjectCreateRequest(
                    templateID: entry.template.id,
                    name: name,
                    automaticallyName: automaticallyName,
                ))
                NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
                let project = ProjectSummary(
                    name: created.name,
                    kind: entry.kind,
                    displayName: created.name,
                    projectID: created.projectID,
                    automaticallyNamed: automaticallyName,
                )
                if dismissesOnCreate {
                    dismiss(animated: true) { [onCreate] in onCreate?(project, firstPrompt) }
                } else {
                    onCreate?(project, firstPrompt)
                }
            } catch { presentNotice(title: "Unable to Create Project", message: error.readableMessage) }
        }
    }
}

extension Notification.Name {
    static let apelinProjectsChanged = Notification.Name("wiki.qaq.apelin.projectsChanged")
}
