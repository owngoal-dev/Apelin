import ApelinCore
import UIKit

/// What a conversation loads besides Apelin's own prompt (issue #74), from
/// its More menu: the user's custom instructions for every chat, then, in a
/// project's chat, the project's, and the project's `AGENTS.md` or
/// `CLAUDE.md`, read as the agent reads it (`ProjectInstructionsFile`). The
/// user's open in their editor and are cleared with a trailing swipe, after
/// a confirmation; the project's file is shown, never changed here. Read
/// again whenever the page appears, so an edit shows on the way back.
final class ConversationInstructionsController: TableController {
    private enum Section: Hashable { case allChats, project, file }
    private enum Row: Hashable { case allChats, project, file }

    private struct Content: Equatable {
        let row: Row
        /// The saved text, or the file's; nil when there is none.
        let text: String?
        /// The file's name, for the file's row.
        var fileName: String?
    }

    /// The project's ID, which keys its instructions; nil in General Chat,
    /// or for a project whose description names none.
    private let projectID: String?
    /// The project's folder, where its file is read; nil in General Chat.
    private let projectFolder: String?
    private let store = CustomInstructionsStore(root: DataFolder.app.root)
    private var loader: Task<Void, Never>?

    private lazy var dataSource = TableDataSource<Section, Row, Content>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] table, _, content in
        self?.cell(in: table, content: content)
    }

    /// The More menu's item that opens this page for a conversation: in
    /// General Chat, with no project, `projectFolder` is nil.
    @objc dynamic static func menuAction(
        projectID: String?,
        projectFolder: String?,
        from presenter: UIViewController,
    ) -> UIAction {
        UIAction(
            title: String(localized: "Custom Instructions…"),
            image: UIImage(systemName: "text.badge.checkmark"),
        ) { [weak presenter] _ in
            presenter?.presentPageAsFormSheet(
                ConversationInstructionsController(projectID: projectID, projectFolder: projectFolder),
            )
        }
    }

    init(projectID: String?, projectFolder: String?) {
        self.projectID = projectID.flatMap { CustomInstructionsStore.isProjectKey($0) ? $0 : nil }
        self.projectFolder = projectFolder
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(projectID:projectFolder:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Custom Instructions")
        navigationItem.backButtonDisplayMode = .minimal
        // the user's rows clear with a trailing swipe; the file's has none
        dataSource.allowsEditing = true
        dataSource.headerTitle = { section in
            switch section {
            case .allChats: String(localized: "All Chats")
            case .project: String(localized: "This Project")
            case .file: String(localized: "Project Folder")
            }
        }
        dataSource.footerTitle = { [weak self] section in
            guard let self, section == lastSection else { return nil }
            return projectFolder == nil
                ? String(localized: "Your agent reads these when a chat starts, and an open chat picks up changes with your next message. They can’t change approvals or Apelin’s rules.")
                : String(localized: "Your agent reads these when a chat starts, and an open chat picks up changes with your next message. This project’s instructions come before those for all chats, and both before AGENTS.md or CLAUDE.md. None of them can change approvals or Apelin’s rules.")
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private var lastSection: Section {
        projectFolder == nil ? .allChats : .file
    }

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        dataSource.beginLoad()
        let store = store
        let projectID = projectID
        // the folder's canonical path, or none when it is gone
        let projectRoot = projectFolder.flatMap { try? ProjectActions.directory(named: $0) }
        loader = Task { [weak self] in
            let read = await Task.detached { () -> Result<Reading, Error> in
                Result {
                    var reading = try Reading(allChats: store.load(.allChats))
                    if let projectID {
                        reading.project = try store.load(.project(projectID))
                    }
                    if let projectRoot {
                        reading.file = ProjectInstructionsFile.read(projectRoot: projectRoot)
                    }
                    return reading
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            switch read {
            case let .success(reading):
                show(reading)
            case .failure:
                presentNotice(title: "Unable to Load Instructions", message: "Close this page and try again.")
            }
        }
    }

    private struct Reading: Sendable {
        var allChats: CustomInstructionsStore.Loaded
        var project: CustomInstructionsStore.Loaded?
        var file: (file: String, text: String)?
    }

    private func show(_ reading: Reading) {
        var sections: [(Section, [Content])] = [
            (.allChats, [Content(row: .allChats, text: Self.saved(reading.allChats))]),
        ]
        if projectFolder != nil {
            if let project = reading.project {
                sections.append((.project, [Content(row: .project, text: Self.saved(project))]))
            }
            sections.append((.file, [Content(row: .file, text: reading.file?.text, fileName: reading.file?.file)]))
        }
        dataSource.update(sections, reconfigure: true)
        if reading.allChats.setAside != nil || reading.project?.setAside != nil {
            presentNotice(
                title: "Instructions Couldn’t Be Read",
                message: "The previous copy was kept aside, so you can write your instructions again here.",
            )
        }
    }

    private static func saved(_ loaded: CustomInstructionsStore.Loaded) -> String? {
        loaded.text.isEmpty ? nil : loaded.text
    }

    private func cell(in tableView: UITableView, content: Content) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "instructions")
            ?? UITableViewCell(style: .default, reuseIdentifier: "instructions")
        var configuration = UIListContentConfiguration.subtitleCell()
        switch (content.row, content.text) {
        case let (.file, text?):
            configuration.text = content.fileName
            configuration.secondaryText = text
            configuration.secondaryTextProperties.numberOfLines = 4
            configuration.secondaryTextProperties.color = .secondaryLabel
        case let (_, text?):
            configuration.text = text
            configuration.textProperties.numberOfLines = 4
        case (.file, nil):
            configuration.text = String(localized: "No AGENTS.md or CLAUDE.md")
            configuration.textProperties.color = .secondaryLabel
        case (_, nil):
            configuration.text = String(localized: "None")
            configuration.textProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = configuration
        let opens = content.row != .file || content.text != nil
        cell.accessoryType = opens ? .disclosureIndicator : .none
        cell.selectionStyle = opens ? .default : .none
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let content = dataSource.value(at: indexPath) else { return false }
        return content.row != .file || content.text != nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let content = dataSource.value(at: indexPath) else { return }
        let page: UIViewController
        switch content.row {
        case .allChats:
            page = InstructionsEditorController(scope: .allChats)
        case .project:
            guard let projectID else { return }
            page = InstructionsEditorController(scope: .project(projectID))
        case .file:
            guard let text = content.text, let name = content.fileName else { return }
            page = ChatCompactionController(summary: text, title: name)
        }
        navigationController?.pushViewController(page, animated: true)
    }

    /// The user's instructions a row shows, which Clear takes: none for the
    /// project's file, or for a scope with nothing saved.
    private func clearable(at indexPath: IndexPath) -> (scope: InstructionsScope, text: String)? {
        guard let content = dataSource.value(at: indexPath), let text = content.text else { return nil }
        switch content.row {
        case .allChats: return (.allChats, text)
        case .project: return projectID.map { (.project($0), text) }
        case .file: return nil
        }
    }

    override func tableView(_: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        clearable(at: indexPath) == nil ? .none : .delete
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let target = clearable(at: indexPath) else { return UISwipeActionsConfiguration(actions: []) }
        let clear = UIContextualAction(style: .destructive, title: String(localized: "Clear")) { [weak self] _, _, complete in
            // the row changes when the page is read again
            complete(false)
            self?.confirmClearingInstructions(project: target.scope != .allChats) { [weak self] in
                self?.clear(target.scope, replacing: target.text)
            }
        }
        return UISwipeActionsConfiguration(actions: [clear])
    }

    private func clear(_ scope: InstructionsScope, replacing text: String) {
        let store = store
        Task { [weak self] in
            do {
                try await Task.detached { try store.save("", for: scope, replacing: text) }.value
            } catch {
                self?.presentInstructionsError(error)
            }
            self?.load()
        }
    }
}
