import Dog
import UIKit

/// Settings ▸ Logs: Dog's journal, one file a launch (`JournalFiles`), the
/// running launch's first; then the agent's, one a conversation, written
/// last first; then the earlier launches, newest first. A row opens that
/// journal (`LogViewerController`, Irisin's log page); any but the running
/// launch's can be deleted. Irisin's page reads only the running launch;
/// this one lists every launch Dog keeps, since the launch that went wrong
/// is usually an earlier one, and every conversation the agent journaled,
/// where its tool calls and compactions are.
final class LogsController: TableController {
    private enum Section: Hashable {
        case current
        case conversations
        case earlier
    }

    private struct Row: Equatable {
        let file: JournalFile
        let isCurrent: Bool
        /// The conversation's name, where the app has the conversation.
        let conversation: String?
    }

    private lazy var dataSource = TableDataSource<Section, URL, Row>(
        tableView: tableView,
        identifier: { $0.file.url },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private var loader: Task<Void, Never>?

    /// Where Dog writes: its own answer once it is open, else the data
    /// folder's `Journal/` (`AppJournal`).
    private static var directory: URL {
        Dog.shared.currentLogFileDirLocation ?? AppJournal.directory
    }

    /// A launch as its row and its page name it: when it began, else the
    /// file's name; a conversation's journal when it was last written.
    static func title(of file: JournalFile) -> String {
        (file.started ?? file.modified)?.formatted(date: .numeric, time: .shortened) ?? file.name
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Logs")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.allowsEditing = true
        dataSource.headerTitle = { section in
            switch section {
            case .current: String(localized: "This Launch")
            case .conversations: String(localized: "Chats")
            case .earlier: String(localized: "Earlier Launches")
            }
        }
        dataSource.footerTitle = { section in
            switch section {
            case .current: nil
            case .conversations: String(localized: "Apelin keeps the logs of its last 100 chats.")
            case .earlier: String(localized: "Apelin keeps the logs of its last 100 launches.")
            }
        }
    }

    /// Read on every appearance: the running launch's file grows, and so do
    /// the journals of conversations that run.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        loader?.cancel()
        dataSource.beginLoad()
        let directory = Self.directory
        let conversationsDirectory = AppJournal.agentDirectory
        let current = Dog.shared.currentLogFileLocation?.lastPathComponent
        loader = Task { [weak self] in
            let (launches, conversations) = await Task.detached {
                (JournalFiles.list(in: directory), JournalFiles.conversations(in: conversationsDirectory))
            }.value
            guard let self, !Task.isCancelled else { return }
            let rows = launches.map { Row(file: $0, isCurrent: $0.name == current, conversation: nil) }
            let earlier = rows.filter { !$0.isCurrent }
            let chats = conversations.map { file in
                // named by the window's runtime, however Settings was opened
                Row(file: file, isCurrent: false, conversation: file.sessionID.flatMap { ChatRuntime.active?.title(ofSession: $0) })
            }
            var sections: [(Section, [Row])] = []
            if let running = rows.first(where: \.isCurrent) {
                sections.append((.current, [running]))
            }
            if !chats.isEmpty {
                sections.append((.conversations, chats))
            }
            if !earlier.isEmpty {
                sections.append((.earlier, earlier))
            }
            dataSource.update(sections, reconfigure: true)
            tableView.backgroundView = rows.isEmpty && chats.isEmpty ? EmptyStateView(
                symbolName: "doc.text",
                title: String(localized: "No Logs"),
                text: String(localized: "Logs appear here when Apelin starts."),
            ) : nil
        }
    }

    /// A conversation's row is its name, with when its journal was last
    /// written beside it; one the app no longer has is named by that time.
    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "journal")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "journal")
        var content = UIListContentConfiguration.valueCell()
        content.text = row.conversation ?? Self.title(of: row.file)
        content.secondaryText = row.conversation == nil ? nil : Self.title(of: row.file)
        content.textProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        navigationController?.pushViewController(
            LogViewerController(
                file: row.file,
                isCurrent: row.isCurrent,
                title: row.conversation ?? Self.title(of: row.file),
            ),
            animated: true,
        )
    }

    /// Dog is still writing the running launch's file, so only an earlier
    /// one is deleted. A conversation's agent starts a new file when the
    /// one it wrote is gone.
    override func tableView(_: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        dataSource.value(at: indexPath)?.isCurrent == false ? .delete : .none
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let row = dataSource.value(at: indexPath), !row.isCurrent else { return nil }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, complete in
            let file = row.file
            Task { [weak self] in
                do {
                    try await Task.detached {
                        try FileManager.default.removeItem(at: file.url)
                        // the file it rotated into, as it is now
                        if let previous = file.previous {
                            try FileManager.default.removeItem(at: previous)
                        }
                    }.value
                    complete(true)
                } catch {
                    complete(false)
                    self?.presentNotice(title: "Unable to Delete Log", message: error.readableMessage)
                }
                self?.load()
            }
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }
}
