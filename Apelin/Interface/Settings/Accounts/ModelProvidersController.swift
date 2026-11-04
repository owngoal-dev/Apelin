import ApelinProtocol
import Then
import UIKit

/// Settings ▸ Model Providers: every provider apelin-agent can sign in to,
/// in Apelin's display order. Signed-in ones first, each with who
/// it is signed in as under its name and a `…` menu (Edit Configuration or Sign In Again, Sign
/// Out); then the rest, those signed in to with an account apart from those
/// that take a typed key. A search field narrows the list by name.
final class ModelProvidersController: TableController, UISearchResultsUpdating {
    private enum Group: Hashable {
        case signedIn
        case accounts
        case keys

        var title: String {
            switch self {
            case .signedIn: String(localized: "Signed In")
            case .accounts: String(localized: "Sign In with an Account")
            case .keys: String(localized: "API Keys")
            }
        }
    }

    private enum Status: Equatable {
        case loading
        case unavailable(String)
        case noResults
    }

    private enum Section: Hashable {
        case group(Group)
        case status
    }

    private enum Row: Equatable {
        case account(AgentAccount)
        case status(Status)
        var id: String {
            switch self {
            case let .account(account): account.provider.rawValue
            case .status: "status"
            }
        }
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        guard let self else { return nil }
        switch row {
        case let .account(account): return accountCell(account)
        case let .status(status): return statusCell(status)
        }
    }

    /// The accounts as apelin-agent last listed them.
    private var accounts: [AgentAccount] = []
    @objc private dynamic var loaded = false
    @objc private dynamic var failure: Error?
    @objc private dynamic var query = ""
    private var sections: [(Section, [Row])] = [(.status, [.status(.loading)])]
    private var loader: Task<Void, Never>?
    private let search = UISearchController(searchResultsController: nil)

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        loader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Model Providers")
        navigationItem.backButtonDisplayMode = .minimal
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        dataSource.headerTitle = { section in
            if case let .group(group) = section {
                return group.title
            }
            return nil
        }
        dataSource.footerTitle = { [weak self] section in
            guard let self, section == sections.last?.0, case .group = section else { return nil }
            return String(localized: "Credentials stay in this device’s keychain.")
        }
        dataSource.update(sections)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let list = try await ApelinService.app.agentAccountList()
                guard !Task.isCancelled, let self else { return }
                accounts = list.accounts
                failure = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                failure = error
            }
            guard let self else { return }
            loaded = true
            regroup()
        }
    }

    @objc dynamic func updateSearchResults(for searchController: UISearchController) {
        let text = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        guard text != query else { return }
        query = text
        regroup()
    }

    @objc private dynamic func regroup() {
        if !loaded {
            sections = [(.status, [.status(.loading)])]
        } else if let failure, accounts.isEmpty {
            sections = [(.status, [.status(.unavailable(ProviderLoginController.unavailableText(failure)))])]
        } else {
            let shown = query.isEmpty
                ? accounts
                : accounts.filter { $0.provider.displayName.localizedStandardContains(query) }
            let groups: [(Group, [AgentAccount])] = [
                (.signedIn, shown.filter(\.signedIn)),
                (.accounts, shown.filter { !$0.signedIn && $0.method != .apiKey }),
                (.keys, shown.filter { !$0.signedIn && $0.method == .apiKey }),
            ]
            sections = groups.filter { !$0.1.isEmpty }.map { (.group($0.0), $0.1.map(Row.account)) }
            if sections.isEmpty {
                sections = [(.status, [.status(.noResults)])]
            }
        }
        dataSource.update(sections)
    }

    // MARK: - Table

    private func account(at indexPath: IndexPath) -> AgentAccount? {
        guard case let .account(account)? = dataSource.value(at: indexPath) else { return nil }
        return account
    }

    private func statusCell(_ status: Status) -> UITableViewCell {
        switch status {
        case .loading:
            return WaitingCell().then { $0.show(String(localized: "Loading…")) }
        case let .unavailable(message):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.stackedValueCell()
            content.text = String(localized: "Model Providers Unavailable")
            content.secondaryText = message
            content.secondaryTextProperties.color = .secondaryLabel

            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case .noResults:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "No Results")
            content.textProperties.color = .secondaryLabel
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
    }

    /// The provider's mark and name on one line; signed in, who as under the
    /// name and a `…` menu at the end.
    private func accountCell(_ account: AgentAccount) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content: UIListContentConfiguration
        if account.signedIn {
            content = .stackedValueCell()
            content.secondaryText = Self.signedInLine(account)
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 1

            cell.accessoryView = menuButton(account)
            cell.selectionStyle = .none
        } else {
            content = .cell()
            cell.accessoryType = .disclosureIndicator
        }
        content.text = account.provider.displayName
        content.textProperties.numberOfLines = 1
        content.image = account.provider.icon
        content.imageProperties.maximumSize = CGSize(width: 29, height: 29)
        content.imageProperties.reservedLayoutSize = CGSize(width: 29, height: 29)
        cell.contentConfiguration = content
        return cell
    }

    private static func signedInLine(_ account: AgentAccount) -> String {
        var parts = [account.account ?? String(localized: "Signed In")]
        if let expiresAt = account.expiresAt {
            let date = expiresAt.formatted(date: .abbreviated, time: .shortened)
            parts.append(expiresAt < Date() ? String(localized: "Expired \(date)") : String(localized: "Until \(date)"))
        }
        return parts.joined(separator: " · ")
    }

    /// `…` with no circle, its menu read each time it opens.
    private func menuButton(_ account: AgentAccount) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.accountActions(account) ?? [])
        }])
        button.frame = CGRect(x: 0, y: 0, width: 32, height: 44)
        button.accessibilityLabel = String(localized: "\(account.provider.displayName) Options")
        return button
    }

    private func accountActions(_ account: AgentAccount) -> [UIMenuElement] {
        [
            UIAction(
                title: String(localized: "Edit"),
                image: UIImage(systemName: account.isAPIKeyAccount ? "pencil" : "arrow.clockwise"),
            ) { [weak self] _ in
                self?.signIn(account)
            },
            UIAction(
                title: String(localized: "Models"),
                image: UIImage(systemName: "checklist"),
            ) { [weak self] _ in
                self?.presentPageAsFormSheet(ModelActivationController(account: account))
            },
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Sign Out"),
                    image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                    attributes: .destructive,
                ) { [weak self] _ in
                    self?.confirmSignOut(account.provider)
                },
            ]),
        ]
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        account(at: indexPath).map { !$0.signedIn } ?? false
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let account = account(at: indexPath), account.signedIn else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: self?.accountActions(account) ?? [])
        })
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let account = account(at: indexPath), !account.signedIn else { return }
        signIn(account)
    }

    // MARK: - Acting

    private func signIn(_ account: AgentAccount) {
        let page = ProviderLoginController(account: account)
        page.onFinish = { [weak self] in self?.load() }
        // a sheet of its own over Settings, kept up until it is closed: a
        // stray swipe would end a sign-in waiting on Safari
        page.isModalInPresentation = true
        presentPageAsFormSheet(page)
    }

    private func confirmSignOut(_ provider: AgentProvider) {
        presentConfirmation(
            title: "Sign Out of \(provider.displayName)?",
            message: "Agent sessions that use it stop working until you sign in again.",
            confirmTitle: "Sign Out",
            destructive: true,
        ) { [weak self] in
            self?.signOut(provider)
        }
    }

    private func signOut(_ provider: AgentProvider) {
        Task { [weak self] in
            do {
                try await ApelinService.app.agentSignOut(provider: provider)
                EnabledModels.remove(for: provider)
                self?.load()
            } catch {
                self?.presentNotice(title: "Unable to Sign Out", message: error.readableMessage)
            }
        }
    }
}
