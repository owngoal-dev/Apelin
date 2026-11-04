import ApelinCore
import ApelinProtocol
import Then
import UIKit
import UniformTypeIdentifiers

/// Settings ▸ Toolchains: the Command Line Tools releases adapted to this
/// device, several side by side, each with its languages; any setup or
/// removal still running above them; the plus in the bar sets another one
/// up from Apple's catalog. A row opens its toolchain.
final class ToolchainController: TableController {
    private enum Row: Equatable {
        case task(TaskHandle)
        case toolchain(ToolchainRecord, isDefault: Bool)
    }

    private struct Section {
        var id: String
        var header: String?
        var rows: [Row]
    }

    private lazy var dataSource = TableDataSource<String, String, Row>(tableView: tableView, identifier: { row in
        switch row {
        case let .task(handle): "task:" + handle.taskID.rawValue
        case let .toolchain(record, _): "toolchain:" + record.id
        }
    }) { [weak self] table, _, row in self?.cell(in: table, row: row) }
    @objc private dynamic func updateRows() {
        dataSource.headerTitle = { [weak self] id in self?.sections.first { $0.id == id }?.header }
        dataSource.update(sections.map { ($0.id, $0.rows) })
    }

    /// Retain the selected release when the user leaves the task or relaunches the app.
    private static let taskVersionsKey = "toolchainTaskVersions"

    static func remember(version: String, for handle: TaskHandle) {
        var versions = UserDefaults.standard.dictionary(forKey: taskVersionsKey) as? [String: String] ?? [:]
        versions[handle.taskID.rawValue] = version
        UserDefaults.standard.set(versions, forKey: taskVersionsKey)
    }

    private static func taskTitle(_ handle: TaskHandle) -> String {
        if let version = UserDefaults.standard.dictionary(forKey: taskVersionsKey)?[handle.taskID.rawValue] as? String {
            return String(localized: "Command Line Tools \(version)")
        }
        return String(localized: "Toolchain Task")
    }

    private var sections: [Section] = []
    private var status = ToolchainStatusResponse()
    private var loader: Task<Void, Never>?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Toolchains")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            menu: UIMenu(children: [
                UIAction(
                    title: String(localized: "From Apple…"),
                    image: UIImage(systemName: "arrow.down.circle"),
                ) { [weak self] _ in self?.setUp() },
                UIAction(
                    title: String(localized: "From File…"),
                    image: UIImage(systemName: "doc"),
                ) { [weak self] _ in self?.pickFile() },
            ]),
        ).then { $0.accessibilityLabel = String(localized: "Add Toolchain") }
        tableView.backgroundView = LoadingView()
        updateRows()
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(transferImported),
            name: TransferOpener.environmentChanged,
            object: nil,
        )
    }

    @objc private dynamic func transferImported() {
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    @objc private dynamic func reload() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let status = try await ApelinService.app.toolchainStatus()
                guard !Task.isCancelled else { return }
                self?.show(status)
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(error)
            }
        }
    }

    private func show(_ status: ToolchainStatusResponse) {
        refreshControl?.endRefreshing()
        self.status = status
        var sections: [Section] = []
        if !status.activeTasks.isEmpty {
            sections.append(Section(
                id: "tasks",
                header: String(localized: "In Progress"),
                rows: status.activeTasks.map(Row.task),
            ))
        }
        if !status.toolchains.isEmpty {
            let toolchains = status.toolchains.sorted {
                let order = $0.version.compare($1.version, options: .numeric)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedDescending
            }
            sections.append(Section(
                id: "installed",
                header: String(localized: "Installed"),
                rows: toolchains.map { .toolchain($0, isDefault: $0.id == status.defaultID) },
            ))
        }
        self.sections = sections
        tableView.backgroundView = sections.isEmpty
            ? EmptyStateView(
                symbolName: "hammer",
                title: String(localized: "No Toolchains Yet"),
                text: String(localized: "Tap “+” to download Apple’s Command Line Tools or import a toolchain from a file."),
            )
            : nil
        updateRows()
    }

    @objc private dynamic func show(_ error: Error) {
        refreshControl?.endRefreshing()
        sections = []
        tableView.backgroundView = EmptyStateView(
            symbolName: "exclamationmark.triangle",
            title: String(localized: "Error"),
            text: Self.unavailableText(error),
        )
        updateRows()
    }

    @objc dynamic static func unavailableText(_ error: Error) -> String {
        if let error = error as? ApelinError, error.code == .backendUnavailable {
            return String(localized: """
            Apelin’s background service is unavailable. Reinstall Apelin with your preferred package \
            manager to restore it.
            """)
        }
        return error.readableMessage
    }

    // MARK: - Table

    private func cell(in _: UITableView, row: Row) -> UITableViewCell {
        switch row {
        case let .task(handle):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.cell()
            content.text = Self.taskTitle(handle)
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        case let .toolchain(record, isDefault):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = isDefault ? UIListContentConfiguration.stackedValueCell() : .cell()
            content.text = ToolchainDetailController.name(of: record)
            content.secondaryText = isDefault ? String(localized: "Default") : nil
            content.secondaryTextProperties.color = .secondaryLabel

            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case let .task(handle):
            navigationController?.pushViewController(taskPage(handle), animated: true)
        case let .toolchain(record, isDefault):
            let page = ToolchainDetailController(record: record, isDefault: isDefault)
            page.onChange = { [weak self] in self?.reload() }
            navigationController?.pushViewController(page, animated: true)
        }
    }

    // MARK: - Setup

    /// The release first; the catalog page starts the setup, and the setup
    /// page takes its place in the stack.
    @objc private dynamic func setUp() {
        let catalog = ToolchainCatalogController(installedToolchains: status.toolchains)
        catalog.onStart = { [weak self, weak catalog] handle in
            guard let self, let navigation = navigationController else { return }
            var stack = navigation.viewControllers
            if let catalog, let index = stack.firstIndex(of: catalog) {
                stack.removeSubrange(index...)
            }
            navigation.setViewControllers(stack + [taskPage(handle)], animated: true)
        }
        navigationController?.pushViewController(catalog, animated: true)
    }

    /// A `.apetc` from Files: read and confirmed before anything is installed.
    @objc private dynamic func pickFile() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [TransferOpener.contentType(.toolchain)],
            asCopy: false,
        )
        picker.delegate = self
        present(picker, animated: true)
    }

    private func taskPage(_ handle: TaskHandle) -> EnvironmentTaskController {
        let page = EnvironmentTaskController(
            handle: handle,
            work: .toolchainSetup,
            title: Self.taskTitle(handle),
            doneTitle: String(localized: "Toolchain Ready"),
        )
        page.onFinish = { [weak self] in self?.reload() }
        return page
    }
}

extension ToolchainController: UIDocumentPickerDelegate {
    @objc dynamic func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        TransferOpener.open(url, from: self, pushingOnto: navigationController)
    }
}
