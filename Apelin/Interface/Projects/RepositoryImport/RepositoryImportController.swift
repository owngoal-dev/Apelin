import ApelinCore
import ApelinProtocol
import SPIndicator
import Then
import UIKit

/// Open in Apelin for a Git repository (`apelin://import`), asked before
/// anything is made: the address and branch the link names, any project
/// that already has that repository as its `origin`, to open instead, and
/// the name of the new project. Import runs `RepositoryImporter` on the
/// progress card and opens the project on a new conversation, sending
/// nothing; closing the sheet makes nothing. A name a project already has
/// is refused here, so importing again takes another name.
final class RepositoryImportController: TableController, UITextFieldDelegate {
    /// Opens a project: one already on the device (`imported` false), or
    /// the one just imported.
    var onOpen: ((ProjectSummary, _ imported: Bool) -> Void)?

    let request: RepositoryImportPlan.Request

    /// The request while its sheet is shown or its import runs; nil once
    /// the sheet has closed.
    var openRequest: RepositoryImportPlan.Request? {
        isClosed ? nil : request
    }

    private enum Section: Hashable {
        case repository
        case existing
        case name
    }

    private enum Row: Equatable {
        case address(String)
        case branch(String?)
        case existing(ProjectSummary)
        case name

        var id: String {
            switch self {
            case .address: "address"
            case .branch: "branch"
            case let .existing(project): "existing:" + project.name
            case .name: "name"
            }
        }
    }

    private var isClosed = false
    private var isImporting = false
    /// The projects are read: the names they take and which have this
    /// repository.
    private var isLoaded = false
    private var takenNames: [String] = []
    private var existing: [ProjectSummary] = []
    /// The user typed a name: the one suggested no longer replaces it.
    private var nameEdited = false

    private let nameField = UITextField()
    private lazy var nameCell = UITableViewCell(style: .default, reuseIdentifier: nil).then { cell in
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(nameField)
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            nameField.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            nameField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
        ])
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: \.id,
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private lazy var importButton = UIBarButtonItem(
        title: String(localized: "Import"),
        primaryAction: UIAction { [weak self] _ in self?.startImport() },
    ).then { $0.style = .done }

    private lazy var importingIndicator = UIBarButtonItem(customView: UIActivityIndicatorView(style: .medium).then {
        $0.startAnimating()
        $0.isAccessibilityElement = true
        $0.accessibilityLabel = String(localized: "Importing Project…")
    })

    init(request: RepositoryImportPlan.Request) {
        self.request = request
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(request:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Import Repository")
        navigationItem.rightBarButtonItem = importButton
        tableView.keyboardDismissMode = .onDrag
        nameField.delegate = self
        nameField.text = RepositoryImportPlan.suggestedName(for: request.address, taken: [])
        nameField.placeholder = String(localized: "Project Name")
        nameField.accessibilityLabel = String(localized: "Project Name")
        nameField.font = .preferredFont(forTextStyle: .body)
        nameField.adjustsFontForContentSizeCategory = true
        nameField.autocapitalizationType = .none
        nameField.autocorrectionType = .no
        nameField.spellCheckingType = .no
        nameField.clearButtonMode = .whileEditing
        nameField.returnKeyType = .done
        nameField.addAction(UIAction { [weak self] _ in
            self?.nameEdited = true
            self?.updateImportButton()
        }, for: .editingChanged)
        dataSource.headerTitle = { section in
            switch section {
            case .repository: String(localized: "Git Repository")
            case .existing: String(localized: "Already Imported")
            case .name: String(localized: "Name on This Device")
            }
        }
        dataSource.footerTitle = { section in
            switch section {
            case .repository:
                String(localized: "Apelin downloads the repository into a new project and opens it. Nothing in it runs, and nothing is sent to your agent.")
            case .existing:
                String(localized: "This repository is already a project on this device. Open it, or import it again as a new project with another name.")
            case .name: nil
            }
        }
        updateRows()
        updateImportButton()
        dataSource.beginLoad()
        Task { [weak self] in
            guard let self else { return }
            let projects = await (try? ProjectSummary.load()) ?? []
            let existing = await Self.projects(in: projects, withOrigin: request.address)
            guard !isClosed else { return }
            takenNames = projects.map(\.name)
            self.existing = existing
            if !nameEdited {
                nameField.text = RepositoryImportPlan.suggestedName(for: request.address, taken: takenNames)
            }
            isLoaded = true
            updateRows()
            updateImportButton()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed ?? isBeingDismissed {
            isClosed = true
        }
    }

    /// The projects whose repository's `origin` is `address`, read from
    /// each one's `.git/config` without following a link.
    private static func projects(
        in projects: [ProjectSummary],
        withOrigin address: String,
    ) async -> [ProjectSummary] {
        guard let wanted = RepositoryImportPlan.comparable(address) else { return [] }
        let folder = DataFolder.app
        return await Task.detached {
            projects.filter { project in
                guard let url = folder.project(named: project.name), let root = CanonicalPath.resolve(url.path),
                      let data = BoundedFile.read(root + "/.git/config", inside: root, limit: 64 << 10),
                      let origin = RepositoryImportPlan.origin(inGitConfig: String(decoding: data, as: UTF8.self))
                else { return false }
                return RepositoryImportPlan.comparable(origin) == wanted
            }
        }.value
    }

    private func updateRows() {
        var sections: [(Section, [Row])] = [(.repository, [.address(request.address), .branch(request.branch)])]
        if !existing.isEmpty {
            sections.append((.existing, existing.map(Row.existing)))
        }
        sections.append((.name, [.name]))
        dataSource.update(sections, reconfigure: true)
    }

    private var trimmedName: String {
        (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canImport: Bool {
        isLoaded && !isImporting && ProjectName.validate(trimmedName) == nil
    }

    private func updateImportButton() {
        importButton.isEnabled = canImport
    }

    private func cell(for row: Row) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content: UIListContentConfiguration
        switch row {
        case .name:
            return nameCell
        case let .address(address):
            content = .cell()
            content.text = address
            content.textProperties.lineBreakMode = .byCharWrapping
        case let .branch(branch):
            content = .valueCell()
            content.text = String(localized: "Branch")
            content.secondaryText = branch ?? String(localized: "Default Branch")
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
            content.secondaryTextProperties.numberOfLines = 0
        case let .existing(project):
            content = .cell()
            content.image = ProjectIcon.image(for: project)
            content.imageProperties.maximumSize = CGSize(width: 29, height: 29)
            content.imageProperties.reservedLayoutSize = CGSize(width: 29, height: 29)
            content.text = String(localized: "Open “\(project.displayTitle)”")
            content.textProperties.color = .tintColor
            cell.selectionStyle = .default
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = content.text
            cell.accessibilityTraits = .button
        }
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard case .existing = dataSource.value(at: indexPath) else { return false }
        return !isImporting
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isImporting, case let .existing(project) = dataSource.value(at: indexPath) else { return }
        close { [onOpen] in onOpen?(project, false) }
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        let text: String
        switch dataSource.value(at: indexPath) {
        case let .address(address): text = address
        case let .branch(branch?): text = branch
        default: return nil
        }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc"),
            ) { _ in
                UIPasteboard.general.string = text
            }])
        })
    }

    func textFieldShouldReturn(_: UITextField) -> Bool {
        if canImport {
            startImport()
        }
        return false
    }

    // MARK: - Importing

    /// While it runs the sheet holds still: no edits, no close, the spinner
    /// where Import was. Cancel is the progress card's.
    private func setImporting(_ importing: Bool) {
        isImporting = importing
        navigationItem.rightBarButtonItem = importing ? importingIndicator : importButton
        navigationItem.leftBarButtonItem?.isEnabled = !importing
        navigationController?.isModalInPresentation = importing
        tableView.isUserInteractionEnabled = !importing
        updateImportButton()
    }

    private func startImport() {
        guard canImport else { return }
        let name = trimmedName
        if takenNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            presentNotice(
                title: "Name Already Used",
                message: "Another project is already named “\(name)”. Choose another name.",
            ) { [weak self] in
                self?.nameField.becomeFirstResponder()
            }
            return
        }
        view.endEditing(true)
        setImporting(true)
        Task { [weak self, request] in
            guard let self else { return }
            do {
                let project = try await ProgressCard.run(
                    title: String(localized: "Importing Project…"),
                    message: request.address,
                    cancellable: true,
                    from: self,
                ) { update in
                    try await RepositoryImporter.run(request, name: name, update: update)
                }
                NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
                SPIndicator.present(title: String(localized: "Project Imported"), preset: .done, haptic: .success)
                close { [onOpen] in onOpen?(project, true) }
            } catch is CancellationError {
                // the card's Cancel: the project it made is gone again
                setImporting(false)
            } catch {
                setImporting(false)
                report(error)
            }
        }
    }

    /// Why nothing was imported. A repository that wants a sign-in names
    /// the one Apelin takes for its host: Sign In with GitHub for
    /// github.com, a token the user gives the agent anywhere else.
    private func report(_ error: Error) {
        if (error as? ApelinError)?.code == .conflict {
            // the name, taken since the projects were read; nothing was made
            presentNotice(title: "Name Already Used", message: error.readableMessage) { [weak self] in
                self?.nameField.becomeFirstResponder()
            }
            return
        }
        guard let failure = error as? RepositoryImportFailure else {
            presentNotice(title: "Unable to Import", message: error.readableMessage)
            return
        }
        let host = URLComponents(string: request.address)?.host?.lowercased() ?? ""
        let needsSignIn = failure.reason == ApelinError.Reason.authenticationRequired.rawValue
        if needsSignIn, host == "github.com", failure.leftProject == nil {
            presentConfirmation(
                title: "Sign In with GitHub",
                message: "This repository needs a GitHub sign-in. Sign In with GitHub in Settings ▸ Git, then import again.",
                confirmTitle: "Open Settings",
            ) { [weak self] in
                guard let self else { return }
                SettingsViewController.presentGit(from: self)
            }
            return
        }
        var message = if needsSignIn, host == "github.com" {
            String(localized: "This repository needs a GitHub sign-in. Sign In with GitHub in Settings ▸ Git, then import again.")
        } else if needsSignIn {
            String(localized: "\(host) asks for a sign-in. Give your agent a token for it in a chat, which it saves for Apelin, then import again.")
        } else {
            failure.message
        }
        if let left = failure.leftProject {
            message += "\n\n" + String(localized: "Apelin could not remove the project “\(left)”. Delete it in All Projects.")
        }
        presentNotice(title: "Unable to Import", message: message)
    }

    /// The sheet goes, then `then` runs: what it opens shows behind it.
    private func close(then: @escaping () -> Void) {
        isClosed = true
        guard let navigation = navigationController, navigation.presentingViewController != nil else {
            then()
            return
        }
        navigation.dismiss(animated: true, completion: then)
    }
}
