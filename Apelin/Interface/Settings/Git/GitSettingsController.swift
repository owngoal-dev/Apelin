import ApelinProtocol
import SPIndicator
import Then
import UIKit

/// Settings ▸ Git: the author the agent's commits carry, saved from the bar;
/// the GitHub account, signed in with a code as gh does
/// (`GitHubLoginController`), whose token goes to apelin-environment's
/// keychain and never comes back; the package repository it publishes to
/// (`DistributionRepositoryFlow`) and its card (`RepositoryCardController`); and the credentials of other hosts an
/// agent saved, each removed with a trailing swipe after a confirmation.
final class GitSettingsController: TableController {
    private enum Section: Hashable {
        case author
        case gitHub
        /// No package repository yet; its footer says what one is.
        case publishing
        /// The linked one; its footer says what to do with the address.
        case published
        case credentials
    }

    private enum Row: Hashable {
        case name
        case email
        case loading
        case unavailable(String)
        case gitHubAccount(String)
        case gitHubSignIn
        case repository(DistributionRepository)
        /// The card a camera scans to add the source in Irisin.
        case repositoryCard(DistributionRepository)
        /// Apelin's current template over the files it maintains.
        case updateRepository(DistributionRepository)
        /// Publishing needs the GitHub account first.
        case createRepository
        case linkRepository
        case credential(GitCredentialSummary)
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    /// What apelin-environment last answered; nil until it has.
    private var settings: GitSettingsResponse?
    private var linked: DistributionRepository?
    @objc private dynamic var failure: Error?
    private var loader: Task<Void, Never>?
    @objc private dynamic var isSaving = false

    private let nameField = UITextField()
    private let emailField = UITextField()
    @objc private dynamic lazy var nameCell = Self.cell(containing: nameField)
    @objc private dynamic lazy var emailCell = Self.cell(containing: emailField)
    private lazy var flow = DistributionRepositoryFlow(presenter: self) { [weak self] in self?.load() }

    @objc private dynamic lazy var saveItem = UIBarButtonItem(
        title: String(localized: "Save"),
        primaryAction: UIAction { [weak self] _ in self?.saveAuthor() },
    )

    private var gitHubAccount: GitCredentialSummary? {
        settings?.credentials.first { $0.host == GitHubDeviceFlow.host }
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    deinit {
        loader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Git")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = saveItem
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        configure(nameField, label: String(localized: "Name"), placeholder: String(localized: "Name"))
        nameField.textContentType = .name
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .next
        nameField.addAction(
            UIAction { [weak self] _ in self?.emailField.becomeFirstResponder() },
            for: .editingDidEndOnExit,
        )
        configure(emailField, label: String(localized: "Email"), placeholder: String(localized: "Email"))
        emailField.textContentType = .emailAddress
        emailField.keyboardType = .emailAddress
        emailField.autocapitalizationType = .none
        emailField.returnKeyType = .done
        emailField.addAction(UIAction { [weak self] _ in self?.saveAuthor() }, for: .editingDidEndOnExit)
        dataSource.allowsEditing = true
        dataSource.headerTitle = { section in
            switch section {
            case .author: String(localized: "Author")
            case .gitHub: String(localized: "GitHub")
            case .publishing, .published: String(localized: "Publishing")
            case .credentials: String(localized: "Other Hosts")
            }
        }
        dataSource.footerTitle = { section in
            switch section {
            case .author:
                String(localized: "Commits in your projects carry this name and email.")
            case .gitHub:
                String(localized: "Clones, pulls and pushes to github.com use this account. Its token is kept only in this device’s keychain and never synced.")
            case .publishing:
                String(localized: "A package repository is an APT source on GitHub Pages: “Distribute…” publishes a project’s release builds to it.")
            case .published:
                String(localized: "Add this address in Irisin. Tap to copy it.")
            case .credentials:
                String(localized: "Credentials an agent saved for other hosts.")
            }
        }
        updateControls()
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    // MARK: - Loading

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let answer = try await ApelinService.app.gitSettings()
                // the link needs no network; a failure leaves it unknown
                let link = try? await ApelinService.app.distributionRepositoryList(repositories: false).linked
                guard !Task.isCancelled, let self else { return }
                showAuthor(of: answer)
                settings = answer
                linked = link
                failure = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                failure = error
            }
            guard let self else { return }
            updateControls()
            updateRows()
        }
    }

    /// The saved author in the fields, unless the user has typed over the
    /// last one shown.
    private func showAuthor(of answer: GitSettingsResponse) {
        if nameField.text ?? "" == settings?.authorName ?? "" {
            nameField.text = answer.authorName
        }
        if emailField.text ?? "" == settings?.authorEmail ?? "" {
            emailField.text = answer.authorEmail
        }
    }

    @objc private dynamic var isPreparingCreation = false

    private func updateRows(changedItems: Set<Row> = []) {
        guard let settings else {
            let state: Row = failure.map { .unavailable($0.readableMessage) } ?? .loading
            dataSource.update([(.author, [.name, .email]), (.gitHub, [state])])
            return
        }
        let signedIn = gitHubAccount != nil
        var sections: [(Section, [Row])] = [
            (.author, [.name, .email]),
            (.gitHub, [gitHubAccount.map { .gitHubAccount($0.username) } ?? .gitHubSignIn]),
        ]
        if let linked {
            sections.append((.published, [.repository(linked), .repositoryCard(linked), .updateRepository(linked)]))
        } else if signedIn {
            sections.append((.publishing, [.createRepository, .linkRepository]))
        }
        let others = settings.credentials.filter { $0.host != GitHubDeviceFlow.host }
        if !others.isEmpty {
            sections.append((.credentials, others.map(Row.credential)))
        }
        dataSource.update(sections, changedItems: changedItems)
    }

    // MARK: - The author

    @objc private dynamic static func trimmed(_ field: UITextField) -> String {
        (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private dynamic var authorChanged: Bool {
        guard let settings else { return false }
        return Self.trimmed(nameField) != settings.authorName ?? ""
            || Self.trimmed(emailField) != settings.authorEmail ?? ""
    }

    @objc private dynamic func updateControls() {
        let editable = settings != nil && !isSaving
        nameField.isEnabled = editable
        emailField.isEnabled = editable
        saveItem.isEnabled = editable && authorChanged
    }

    @objc private dynamic func saveAuthor() {
        guard saveItem.isEnabled else { return }
        view.endEditing(true)
        let name = Self.trimmed(nameField)
        let email = Self.trimmed(emailField)
        isSaving = true
        updateControls()
        Task { [weak self] in
            do {
                try await ApelinService.app.gitAuthorSet(
                    name: name.isEmpty ? nil : name,
                    email: email.isEmpty ? nil : email,
                )
                guard let self else { return }
                settings?.authorName = name.isEmpty ? nil : name
                settings?.authorEmail = email.isEmpty ? nil : email
                nameField.text = name
                emailField.text = email
                SPIndicator.present(title: String(localized: "Saved"), preset: .done, haptic: .success)
            } catch {
                self?.presentNotice(title: "Unable to Save Author", message: error.readableMessage)
            }
            self?.isSaving = false
            self?.updateControls()
        }
    }

    // MARK: - GitHub and other hosts

    @objc private dynamic func signInToGitHub() {
        navigationController?.pushViewController(GitHubLoginController(), animated: true)
    }

    @objc private dynamic func confirmSignOut() {
        presentConfirmation(
            title: "Sign Out of GitHub?",
            message: "Clones, pulls and pushes to github.com stop working until you sign in again. The package repository stays linked.",
            confirmTitle: "Sign Out",
            destructive: true,
        ) { [weak self] in
            self?.remove(host: GitHubDeviceFlow.host)
        }
    }

    private func confirmRemoval(_ credential: GitCredentialSummary) {
        presentConfirmation(
            title: "Remove Credential for \(credential.host)?",
            message: "Git can no longer sign in to this host until you add a credential for it again.",
            confirmTitle: "Remove",
            destructive: true,
        ) { [weak self] in
            self?.remove(host: credential.host)
        }
    }

    @objc private dynamic func remove(host: String) {
        Task { [weak self] in
            do {
                try await ApelinService.app.gitCredentialRemove(host: host)
                SPIndicator.present(title: String(localized: "Removed"), preset: .done, haptic: .success)
            } catch {
                self?.presentNotice(title: "Unable to Remove Credential", message: error.readableMessage)
            }
            self?.load()
        }
    }

    private func showCard(of repository: DistributionRepository) {
        navigationController?.pushViewController(RepositoryCardController(repository: repository), animated: true)
    }

    private func open(_ repository: DistributionRepository) {
        guard let url = URL(string: repository.url) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Table

    @objc private dynamic func configure(_ field: UITextField, label: String, placeholder: String) {
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = label
        field.placeholder = placeholder
        field.addAction(UIAction { [weak self] _ in self?.updateControls() }, for: .editingChanged)
    }

    /// A field filling the row's margins; the field is the element, not the row.
    @objc dynamic static func cell(containing field: UITextField) -> UITableViewCell {
        UITableViewCell(style: .default, reuseIdentifier: nil).then { cell in
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(field)
            let margins = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
                field.topAnchor.constraint(equalTo: margins.topAnchor),
                field.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
                cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            ])
        }
    }

    private func cell(for row: Row) -> UITableViewCell? {
        switch row {
        case .name:
            return nameCell
        case .email:
            return emailCell
        case .loading:
            return WaitingCell().then { $0.show(String(localized: "Loading…")) }
        case let .unavailable(message):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.stackedValueCell()
            content.text = String(localized: "Git Settings Unavailable")
            content.secondaryText = message
            content.secondaryTextProperties.color = .secondaryLabel

            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case let .gitHubAccount(login):
            return valueCell(String(localized: "Signed In"), login)
        case let .repository(repository):
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            var content = UIListContentConfiguration.stackedValueCell()
            content.text = repository.fullName
            content.secondaryText = repository.sourceURL
            content.secondaryTextProperties.color = .secondaryLabel

            cell.contentConfiguration = content
            cell.accessibilityHint = String(localized: "Copies the source address.")
            cell.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "Open on GitHub")) { [weak self] _ in
                    self?.open(repository); return true
                },
                UIAccessibilityCustomAction(name: String(localized: "Unlink")) { [weak self] _ in
                    self?.flow.confirmUnlink(repository); return true
                },
            ]
            return cell
        case let .credential(credential):
            return valueCell(credential.host, credential.username)
        case .gitHubSignIn, .createRepository, .linkRepository, .repositoryCard, .updateRepository:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = switch row {
            case .gitHubSignIn: String(localized: "Sign In…")
            case .createRepository: String(localized: "Create Repository…")
            case .repositoryCard: String(localized: "Repository Card…")
            case .updateRepository: String(localized: "Update Repository…")
            default: String(localized: "Link Repository…")
            }
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessibilityTraits.insert(.button)
            if case .createRepository = row, isPreparingCreation {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
                cell.accessibilityTraits.insert(.notEnabled)
                cell.accessibilityValue = String(localized: "Loading…")
            }
            return cell
        }
    }

    @objc private dynamic func valueCell(_ text: String, _ value: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        content.text = text
        content.secondaryText = value
        content.textProperties.numberOfLines = 1
        content.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.value(at: indexPath) {
        case .createRepository?: !isPreparingCreation
        case .gitHubSignIn?, .repository?, .repositoryCard?, .updateRepository?, .linkRepository?: true
        default: false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.value(at: indexPath) {
        case .gitHubSignIn?:
            signInToGitHub()
        case let .repository(repository)?:
            UIPasteboard.general.string = repository.sourceURL
            SPIndicator.present(title: String(localized: "Copied"), preset: .done, haptic: .success)
        case let .repositoryCard(repository)?:
            showCard(of: repository)
        case let .updateRepository(repository)?:
            flow.confirmUpdate(repository)
        case .createRepository?:
            flow.create { [weak self] loading in
                self?.isPreparingCreation = loading
                self?.updateRows(changedItems: [.createRepository])
            }
        case .linkRepository?:
            flow.pick()
        default:
            break
        }
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard case let .repository(repository)? = dataSource.value(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Copy Source Address"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = repository.sourceURL
                },
                UIAction(title: String(localized: "Open on GitHub"), image: UIImage(systemName: "safari")) { _ in
                    self?.open(repository)
                },
                UIAction(title: String(localized: "Repository Card…"), image: UIImage(systemName: "qrcode")) { _ in
                    self?.showCard(of: repository)
                },
                UIAction(title: String(localized: "Update Repository…"), image: UIImage(systemName: "arrow.triangle.2.circlepath")) { _ in
                    self?.flow.confirmUpdate(repository)
                },
                UIAction(
                    title: String(localized: "Unlink"),
                    image: UIImage(systemName: "link"),
                    attributes: .destructive,
                ) { _ in
                    self?.flow.confirmUnlink(repository)
                },
            ])
        })
    }

    override func tableView(_: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        switch dataSource.value(at: indexPath) {
        case .credential?, .gitHubAccount?, .repository?: .delete
        default: .none
        }
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        let action: UIContextualAction
        switch dataSource.value(at: indexPath) {
        case let .credential(credential)?:
            action = UIContextualAction(style: .destructive, title: String(localized: "Remove")) { [weak self] _, _, completion in
                // the row goes when the host says it has
                completion(false)
                self?.confirmRemoval(credential)
            }
            action.image = UIImage(systemName: "trash")
        case .gitHubAccount?:
            action = UIContextualAction(style: .destructive, title: String(localized: "Sign Out")) { [weak self] _, _, completion in
                completion(false)
                self?.confirmSignOut()
            }
        case let .repository(repository)?:
            action = UIContextualAction(style: .destructive, title: String(localized: "Unlink")) { [weak self] _, _, completion in
                completion(false)
                self?.flow.confirmUnlink(repository)
            }
        default:
            return nil
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
}
