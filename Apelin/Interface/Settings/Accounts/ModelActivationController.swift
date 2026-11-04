import AlertController
import ApelinProtocol
import UIKit

/// Saves one provider's enabled models only when the user confirms.
final class ModelActivationController: TableController, UISearchResultsUpdating {
    private let account: AgentAccount
    @objc private dynamic var selected: Set<String>
    @objc private dynamic var shown: [String]
    @objc private dynamic var models: [String]
    @objc private dynamic var custom: Set<String>
    @objc private dynamic var hidden: Set<String>
    private var loader: Task<Void, Never>?
    @objc private dynamic var saving = false
    private var verification: TaskHandle?
    private let search = UISearchController(searchResultsController: nil)

    init(account: AgentAccount) {
        self.account = account
        let available = account.models ?? []
        let enabled = EnabledModels.ids(for: account.provider)
        custom = Set(EnabledModels.customIDs(for: account.provider))
        hidden = account.isAPIKeyAccount ? EnabledModels.hiddenIDs(for: account.provider) : []
        selected = account.isAPIKeyAccount ? enabled.subtracting(hidden) : enabled.intersection(available)
        models = account.isAPIKeyAccount
            ? Array(Set(available).union(custom).union(selected).subtracting(hidden)).sorted()
            : available
        shown = models
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(account:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Enable Models")
        navigationItem.largeTitleDisplayMode = .never
        let menu = usesAPIKey
            ? UIMenu(children: [UIAction(title: String(localized: "Save Without Verification")) { [weak self] _ in
                self?.save(verify: false)
            }])
            : nil
        let save = UIBarButtonItem(
            title: String(localized: "Save"),
            primaryAction: UIAction { [weak self] _ in self?.save() },
            menu: menu,
        )
        if usesAPIKey {
            let add = UIBarButtonItem(
                image: UIImage(systemName: "plus"),
                primaryAction: UIAction { [weak self] _ in self?.addCustomModel() },
            )
            add.accessibilityLabel = String(localized: "Add Custom Model")
            navigationItem.rightBarButtonItems = [save, add]
        } else {
            navigationItem.rightBarButtonItem = save
        }
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Models")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        definesPresentationContext = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "model")
        updateRows()
    }

    private struct ModelRow: Equatable {
        let id: String
        let selected: Bool
    }

    private lazy var dataSource = TableDataSource<Int, String, ModelRow>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] table, indexPath, row in
        self?.cell(in: table, at: indexPath, row: row)
    }

    @objc private dynamic func updateRows() {
        dataSource.headerTitle = { [weak self] _ in self.map { $0.account.account ?? $0.account.provider.displayName } }
        dataSource.footerTitle = { _ in String(localized: "Choose the models to show in the chat model picker. You can change this later in Model Providers.") }
        dataSource.allowsEditing = usesAPIKey
        dataSource.update([(0, shown.map { ModelRow(id: $0, selected: selected.contains($0)) })], reconfigure: true)
    }

    @objc private dynamic var usesAPIKey: Bool {
        account.isAPIKeyAccount
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard usesAPIKey, loader == nil else { return }
        dataSource.beginLoad()
        loader = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await ProviderProgress.run(title: "Fetching Models", from: self) {
                    try await ApelinService.app.agentModelList(provider: self.account.provider).models
                }
                models = Array(Set(fetched).union(custom).union(selected).subtracting(hidden)).sorted()
                updateSearchResults(for: search)
            } catch {
                presentNotice(title: "Unable to Fetch Models", message: error.readableMessage)
            }
        }
    }

    @objc dynamic func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        shown = models.filter { query.isEmpty || $0.localizedStandardContains(query) }
        updateRows()
    }

    private func cell(in tableView: UITableView, at indexPath: IndexPath, row: ModelRow) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "model", for: indexPath)
        let model = row.id
        var content = cell.defaultContentConfiguration()
        content.text = model
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = row.selected ? .checkmark : .none
        cell.accessibilityTraits = row.selected ? [.button, .selected] : [.button]
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !saving, let model = dataSource.itemIdentifier(for: indexPath) else { return }
        if !selected.insert(model).inserted {
            selected.remove(model)
        }
        updateRows()
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard usesAPIKey, !saving, let model = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, completion in
            guard let self, !saving, let row = shown.firstIndex(of: model) else { completion(false); return }
            selected.remove(model)
            custom.remove(model)
            hidden.insert(model)
            models.removeAll { $0 == model }
            shown.remove(at: row)
            completion(true)
            updateRows()
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    @objc private dynamic func addCustomModel() {
        let alert = AlertInputViewController(
            title: "Add Custom Model",
            message: "Enter the model ID accepted by this provider.",
            placeholder: "Model ID",
            text: "",
            doneButtonText: "Add",
        ) { [weak self] value in
            guard let self else { return }
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= 256, !id.contains(where: \.isWhitespace) else {
                presentNotice(
                    title: "Invalid Model ID",
                    message: String(localized: "Enter a model ID without spaces or line breaks."),
                )
                return
            }
            custom.insert(id)
            hidden.remove(id)
            models = Array(Set(models + [id])).sorted()
            selected.insert(id)
            updateSearchResults(for: search)
        }
        present(alert, animated: true)
    }

    @objc private dynamic func save(verify: Bool = true) {
        guard !saving else { return }
        guard usesAPIKey && verify || account.provider == .githubCopilot,
              !selected.isEmpty
        else { finishSaving(); return }
        saving = true
        navigationController?.isModalInPresentation = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = false }
        Task { [weak self] in
            guard let self else { return }
            defer {
                saving = false
                verification = nil
                navigationController?.isModalInPresentation = false
                navigationItem.leftBarButtonItem?.isEnabled = true
                navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = true }
            }
            do {
                try await ProviderProgress.run(
                    title: usesAPIKey ? "Verifying Models" : "Enabling Models",
                    message: "Waiting for a response from each selected model…",
                    from: self,
                    cancel: { [weak self] in
                        if let handle = self?.verification {
                            try? await ApelinService.app.agentSignInCancel(taskID: handle.taskID)
                        }
                    },
                ) {
                    let handle = try await ApelinService.app.agentModelActivate(
                        provider: self.account.provider,
                        models: self.selected.sorted(),
                    )
                    self.verification = handle
                    if Task.isCancelled {
                        try? await ApelinService.app.agentSignInCancel(taskID: handle.taskID)
                        throw CancellationError()
                    }
                    for try await event in ApelinService.app.events(of: handle) {
                        guard event.kind == TaskEvent.stateKind,
                              let state = event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)),
                              state.isTerminal
                        else { continue }
                        if state == .cancelled {
                            throw CancellationError()
                        }
                        guard state == .succeeded else {
                            throw ApelinError(
                                .unavailable,
                                event.payload?["message"]?.stringValue
                                    ?? String(localized: "Model verification failed."),
                            )
                        }
                        return
                    }
                    throw ApelinError(.unavailable, String(localized: "Model verification did not finish."))
                }
                finishSaving()
            } catch {
                if !(error is CancellationError) {
                    presentNotice(title: "Unable to Verify Models", message: error.readableMessage)
                }
            }
        }
    }

    @objc private dynamic func finishSaving() {
        EnabledModels.save(selected, custom: custom, hidden: hidden, for: account.provider)
        dismiss(animated: true)
    }
}
