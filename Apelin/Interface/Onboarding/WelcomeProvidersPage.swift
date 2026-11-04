// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
// Table/action-bar layout copied from Irisin's WelcomeRepositoriesController.
import ApelinProtocol
import UIKit

final class WelcomeProvidersPage: WelcomeListPage {
    private let entries: [(String, AgentProvider)] = [
        (String(localized: "Claude Code"), .anthropicOAuth),
        (String(localized: "Codex"), .openAICodex),
        (String(localized: "Cursor"), .cursor),
        (String(localized: "GitHub Copilot"), .githubCopilot),
    ]
    private enum Item: Hashable { case introduction, provider(AgentProvider) }
    private enum Row: Equatable {
        case introduction
        case provider(AgentProvider, name: String, connected: Bool)
        var id: Item {
            switch self {
            case .introduction: .introduction
            case let .provider(provider, _, _): .provider(provider)
            }
        }
    }

    private lazy var dataSource = TableDataSource<Int, Item, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    @objc private dynamic func updateRows() {
        dataSource.update([(0, [.introduction]), (1, entries.map { entry in
            Row.provider(
                entry.1,
                name: entry.0,
                connected: accounts.contains { $0.provider == entry.1 && $0.signedIn },
            )
        })])
    }

    private var accounts: [AgentAccount] = []
    private var loader: Task<Void, Never>?
    deinit { loader?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Add a Model Provider")
        next { [weak self] in self?.flow.showGitHub() }
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func cell(for row: Row) -> UITableViewCell {
        guard case let .provider(provider, name, connected) = row else {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Sign in to the account the agent uses to write, build and install your tweaks.")
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = name
        content.image = provider.icon
        content.imageProperties.maximumSize = CGSize(width: 40, height: 40)
        cell.contentConfiguration = content
        // a signed-in account is ticked; tapping it still picks its models
        cell.accessoryType = connected ? .checkmark : .disclosureIndicator
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = name
        cell.accessibilityValue = connected
            ? String(localized: "Connected") : nil
        return cell
    }

    @objc dynamic func tableView(_: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard dataSource.sectionIdentifier(for: section) == 1 else { return nil }
        return text(.groupedFooter(), String(localized: "You can add more providers later in Settings."))
    }

    @objc dynamic func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .provider(provider, _, _)? = dataSource.value(at: indexPath) else { return }
        signIn(provider)
    }

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let response = try await ApelinService.app.agentAccountList()
                guard !Task.isCancelled, let self else { return }
                accounts = response.accounts
                updateRows()
            } catch {}
        }
    }

    private func signIn(_ provider: AgentProvider) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let accounts = try await ApelinService.app.agentAccountList().accounts
                guard let account = accounts.first(where: { $0.provider == provider }) else {
                    throw ApelinError(
                        .unimplemented,
                        String(localized: "This provider is not available. You can add another provider in Settings."),
                    )
                }
                guard presentedViewController == nil, view.window != nil else { return }
                if account.signedIn {
                    presentPageAsFormSheet(ModelActivationController(account: account))
                } else {
                    let page = ProviderLoginController(account: account)
                    page.onFinish = { [weak self] in self?.load() }
                    presentPageAsFormSheet(page)
                }
            } catch { presentNotice(title: "Provider Unavailable", message: error.readableMessage) }
        }
    }
}
