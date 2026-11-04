import ApelinCore
import ApelinProtocol
import Then
import UIKit

/// Settings ▸ SDKs: the iPhoneOS SDKs registered on this device and any
/// import still running. The plus opens `SDKCatalogController`, where an
/// iOS version is picked to download.
final class SDKListController: TableController {
    private enum Row: Equatable {
        case task(TaskHandle)
        case sdk(SDKRecord)
    }

    private struct Section {
        var id: String
        var header: String?
        var footer: String?
        var rows: [Row]
    }

    private lazy var dataSource = TableDataSource<String, String, Row>(tableView: tableView, identifier: { row in
        switch row {
        case let .task(handle): "task:" + handle.taskID.rawValue
        case let .sdk(record): "sdk:" + record.id
        }
    }) { [weak self] table, _, row in self?.cell(in: table, row: row) }
    @objc private dynamic func updateRows() {
        dataSource.headerTitle = { [weak self] id in self?.sections.first { $0.id == id }?.header }
        dataSource.footerTitle = { [weak self] id in self?.sections.first { $0.id == id }?.footer }
        dataSource.update(sections.map { ($0.id, $0.rows) })
    }

    private var sections: [Section] = []
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
        title = String(localized: "SDKs")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in
                let page = SDKCatalogController()
                page.onImport = { self?.reload() }
                self?.navigationController?.pushViewController(page, animated: true)
            },
        ).then { $0.accessibilityLabel = String(localized: "Add SDK") }
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
                let local = try await ApelinService.app.sdkList()
                guard !Task.isCancelled else { return }
                self?.show(local)
            } catch {
                guard !Task.isCancelled, let self else { return }
                if sections.isEmpty {
                    show(error)
                }
            }
        }
    }

    private func show(_ list: SDKListResponse) {
        refreshControl?.endRefreshing()
        var sections: [Section] = []
        if !list.activeTasks.isEmpty {
            sections.append(Section(
                id: "tasks",
                header: String(localized: "In Progress"),
                rows: list.activeTasks.map(Row.task),
            ))
        }
        if !list.sdks.isEmpty {
            let sdks = list.sdks.sorted {
                let order = $0.version.compare($1.version, options: .numeric)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedDescending
            }
            sections.append(Section(
                id: "installed",
                header: String(localized: "Installed"),
                rows: sdks.map(Row.sdk),
            ))
        }
        self.sections = sections
        tableView.backgroundView = sections.isEmpty
            ? EmptyStateView(
                symbolName: "shippingbox",
                title: String(localized: "No SDKs Yet"),
                text: String(localized: "Tap “+” to download an iOS SDK."),
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
            text: ToolchainController.unavailableText(error),
        )
        updateRows()
    }

    // MARK: - Table

    private func cell(in _: UITableView, row: Row) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.stackedValueCell()
        content.secondaryTextProperties.color = .secondaryLabel

        switch row {
        case .task:
            content.text = String(localized: "SDK Import")
            content.secondaryText = String(localized: "In progress. Tap to view.")
            cell.accessoryType = .disclosureIndicator
        case let .sdk(record):
            content.text = SDKDetailController.displayName(of: record)
            if let swift = SDKDetailController.swiftVersion(of: record) {
                content.secondaryText = String(localized: "Swift \(swift)")
            }
        }
        cell.accessoryType = .disclosureIndicator
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case let .task(handle):
            openTask(handle)
        case let .sdk(record):
            let page = SDKDetailController(record: record)
            page.onRemove = { [weak self] in self?.reload() }
            navigationController?.pushViewController(page, animated: true)
        }
    }

    private func openTask(_ handle: TaskHandle) {
        let page = EnvironmentTaskController(
            handle: handle,
            work: .sdkImport,
            title: String(localized: "Importing SDK"),
            doneTitle: String(localized: "SDK Imported"),
        )
        page.onFinish = { [weak self] in self?.reload() }
        navigationController?.pushViewController(page, animated: true)
    }
}
