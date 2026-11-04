import ApelinCore
import UIKit

final class MemoriesController: TableController {
    private enum Section: Hashable { case allChats, project(String) }
    private enum Row: Hashable { case memory(String), empty }

    private final class DataSource: UITableViewDiffableDataSource<Section, Row> {
        @objc dynamic var projectNames: [String: String] = [:]
        @objc dynamic func name(for id: String) -> String {
            projectNames[id] ?? (id.hasPrefix("temporary:")
                ? String(localized: "Temporary Chat")
                : String(localized: "Unavailable Project"))
        }

        override func tableView(_: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
            if case .memory? = itemIdentifier(for: indexPath) {
                return true
            }
            return false
        }

        override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
            guard snapshot().sectionIdentifiers.indices.contains(section) else { return nil }
            switch snapshot().sectionIdentifiers[section] {
            case .allChats: return String(localized: "All Chats")
            case let .project(id): return name(for: id)
            }
        }

        override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
            guard section == 0 else { return nil }
            return String(localized: "The agent remembers useful preferences and project facts. You can review or correct them here.")
        }
    }

    private let store = MemoryStore(root: DataFolder.app.root)
    private var memories: MemorySnapshot?
    private var dataSource: DataSource!
    private var loader: Task<Void, Never>?
    private let pacing = ListPacing()

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Memories")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in self?.open(nil) },
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Add Memory")
        navigationItem.rightBarButtonItem?.isEnabled = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Memory")
        dataSource = DataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: "Memory", for: indexPath)
            var content = UIListContentConfiguration.stackedValueCell()
            if case let .memory(id) = row, let record = self?.memories?.records.first(where: { $0.id == id }) {
                content.text = record.title
                content.secondaryText = record.body
                content.secondaryTextProperties.numberOfLines = 2
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            } else {
                content.text = String(localized: "No memories yet")
                content.textProperties.color = .secondaryLabel
                cell.accessoryType = .none
                cell.selectionStyle = .none
            }
            cell.contentConfiguration = content
            return cell
        }
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        pacing.beginLoad()
        let store = store
        loader = Task { [weak self] in
            do {
                let snapshot = try await Task.detached { try store.read() }.value
                let projects = await (try? ProjectSummary.load()) ?? []
                guard !Task.isCancelled, let self else { return }
                let names = Dictionary(
                    projects.compactMap { project in project.projectID.map { ($0, project.displayTitle) } },
                    uniquingKeysWith: { first, _ in first },
                )
                let renamed = Set(names.keys.filter { dataSource.projectNames[$0] != names[$0] })
                    .union(dataSource.projectNames.keys.filter { names[$0] == nil })
                dataSource.projectNames = names
                apply(snapshot, renamedProjects: renamed)
                refreshControl?.endRefreshing()
                navigationItem.rightBarButtonItem?.isEnabled = true
            } catch {
                guard !Task.isCancelled, let self else { return }
                refreshControl?.endRefreshing()
                presentNotice(title: "Unable to Load Memories", message: "Pull down to try again.")
            }
        }
    }

    private func apply(_ value: MemorySnapshot, renamedProjects: Set<String> = []) {
        let previous = dataSource.snapshot()
        let oldRecords = Dictionary(uniqueKeysWithValues: (memories?.records ?? []).map { ($0.id, $0) })
        let changedIDs = Set(
            value.records.filter { oldRecords[$0.id] != $0 && !renamedProjects.contains($0.projectID ?? "") }
                .map(\.id),
        )
        let changed = memories?.records != value.records || !renamedProjects.isEmpty
        memories = value
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.allChats])
        let global = value.records.filter { $0.projectID == nil }
        snapshot.appendItems(global.map { .memory($0.id) }, toSection: .allChats)
        let projectIDs = Set(value.records.compactMap(\.projectID)).sorted {
            (dataSource.projectNames[$0] ?? $0)
                .localizedStandardCompare(dataSource.projectNames[$1] ?? $1) == .orderedAscending
        }
        for id in projectIDs {
            snapshot.appendSections([.project(id)])
            snapshot.appendItems(
                value.records.filter { $0.projectID == id }.map { .memory($0.id) },
                toSection: .project(id),
            )
        }
        if value.records.isEmpty {
            snapshot.deleteAllItems()
        }
        tableView.backgroundView = value.records.isEmpty ? EmptyStateView(
            symbolName: "brain",
            title: String(localized: "No Memories Yet"),
            text: String(localized: "Tap “+” to add a memory."),
        ) : nil
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter {
            guard case let .memory(id) = $0 else { return false }
            return changedIDs.contains(id) && previous.indexOfItem($0) != nil
        })
        snapshot.reloadSections(snapshot.sectionIdentifiers.filter {
            guard case let .project(id) = $0 else { return false }
            return renamedProjects.contains(id) && previous.indexOfSection($0) != nil
        })
        if previous.sectionIdentifiers.isEmpty {
            pacing.begin()
            dataSource.applyFirst(snapshot, to: tableView)
        } else {
            dataSource.applyChange(snapshot, to: tableView, animated: changed && pacing.animatesChange(in: tableView))
        }
    }

    private func open(_ record: MemoryRecord?) {
        guard let memories else { return }
        navigationController?.pushViewController(
            MemoryEditorController(store: store, record: record, revision: memories.revision),
            animated: true,
        )
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .memory(id)? = dataSource.itemIdentifier(for: indexPath),
              let record = memories?.records.first(where: { $0.id == id })
        else { return }
        open(record)
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard case let .memory(id)? = dataSource.itemIdentifier(for: indexPath), let memories else { return nil }
        let action = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, complete in
            guard let self else { complete(false); return }
            let store = store
            Task { [weak self] in
                do {
                    let value = try await Task.detached { try store.delete(id: id, revision: memories.revision) }.value
                    self?.apply(value)
                    complete(true)
                } catch {
                    complete(false)
                    self?.presentMemoryError(error)
                    self?.load()
                }
            }
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
}

extension UIViewController {
    func presentMemoryError(_ error: Error) {
        switch error as? MemoryStoreError {
        case .changed:
            presentNotice(title: "Memory Changed", message: "A chat or another window changed these memories. Reopen the memory to review the latest version before editing.")
        case .invalidContent:
            presentNotice(title: "Check This Memory", message: "Enter a title and memory text. The title must be a single line.")
        case .full:
            presentNotice(title: "Memory Is Full", message: "Shorten or delete an older memory before adding more.")
        default:
            presentNotice(title: "Unable to Save Memory", message: "Your changes weren’t saved. Try again.")
        }
    }
}
