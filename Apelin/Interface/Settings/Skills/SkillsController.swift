import ApelinCore
import ApelinProtocol
import SPIndicator
import Then
import UIKit
import UniformTypeIdentifiers

/// Settings ▸ Agent ▸ Skills: every skill a chat is offered — Apelin's own,
/// then those in the skills folder — and what in that folder is not offered
/// as it stands. The list is the agent worker's (`agentSkillList`), read as
/// a session reads it. A skill opens its instructions; the plus copies one
/// in from Files (`SkillFolder`); a skill of the folder, or a problem, is
/// removed with a trailing swipe after a confirmation.
final class SkillsController: TableController {
    private enum Section: Hashable {
        case builtIn
        case user
        case problems
    }

    private enum Row: Equatable {
        case skill(AgentSkill)
        case problem(AgentSkillProblem)
        case empty
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: { row in
            switch row {
            case let .skill(skill): "skill:" + skill.name
            case let .problem(problem): "problem:" + (problem.location ?? "") + "\u{1f}" + problem.message
            case .empty: "empty"
            }
        },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private let folder = SkillFolder(root: DataFolder.app.root.appendingPathComponent("skills", isDirectory: true))
    private var listing: AgentSkillListResponse?
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
        title = String(localized: "Skills")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in self?.pickSkill() },
        ).then { $0.accessibilityLabel = String(localized: "Import Skill") }
        dataSource.allowsEditing = true
        dataSource.headerTitle = { section in
            switch section {
            case .builtIn: String(localized: "Built-in")
            case .user: String(localized: "Your Skills")
            case .problems: String(localized: "Problems")
            }
        }
        dataSource.footerTitle = { section in
            switch section {
            case .user:
                String(localized: """
                Import a folder that holds a SKILL.md, or a Markdown file. Every chat is offered these skills, and \
                the agent reads one when a task matches its description.
                """)
            case .builtIn, .problems: nil
            }
        }
        tableView.backgroundView = LoadingView()
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    @objc private dynamic func load(then check: String? = nil) {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let listing = try await ApelinService.app.agentSkillList()
                guard !Task.isCancelled, let self else { return }
                show(listing)
                if let check, let problem = listing.problems.first(where: { $0.location == check }) {
                    presentNotice(title: "Check This Skill", message: problem.message)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                refreshControl?.endRefreshing()
                if listing == nil {
                    tableView.backgroundView = EmptyStateView(
                        symbolName: "exclamationmark.triangle",
                        title: String(localized: "Error"),
                        text: ToolchainController.unavailableText(error),
                    )
                }
            }
        }
    }

    private func show(_ listing: AgentSkillListResponse) {
        self.listing = listing
        refreshControl?.endRefreshing()
        tableView.backgroundView = nil
        let user = listing.skills.filter { $0.source == .user }.map(Row.skill)
        var sections: [(Section, [Row])] = [
            (.builtIn, listing.skills.filter { $0.source == .builtIn }.map(Row.skill)),
            (.user, user.isEmpty ? [.empty] : user),
        ]
        if !listing.problems.isEmpty {
            sections.append((.problems, listing.problems.map(Row.problem)))
        }
        dataSource.update(sections, reconfigure: true)
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "skill")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "skill")
        var content = UIListContentConfiguration.stackedValueCell()
        switch row {
        case let .skill(skill):
            content = .explanatoryCell()
            content.text = skill.name
            content.textProperties.numberOfLines = 1
            content.secondaryText = skill.description
            content.secondaryTextProperties.numberOfLines = 2
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case let .problem(problem):
            content.text = problem.location ?? String(localized: "Skills Folder")
            content.secondaryText = problem.message
            content.secondaryTextProperties.numberOfLines = 0
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case .empty:
            content.text = String(localized: "No skills yet")
            content.textProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if case .skill = dataSource.value(at: indexPath) {
            return true
        }
        return false
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .skill(skill)? = dataSource.value(at: indexPath) else { return }
        navigationController?.pushViewController(SkillTextController(skill: skill), animated: true)
    }

    /// What a swipe at `indexPath` removes: a skill of the folder, or a
    /// problem's place in it; nil for a built-in.
    private func removable(at indexPath: IndexPath) -> (location: String, name: String)? {
        switch dataSource.value(at: indexPath) {
        case let .skill(skill): skill.location.map { ($0, skill.name) }
        case let .problem(problem): problem.location.map { ($0, $0) }
        default: nil
        }
    }

    override func tableView(_: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        removable(at: indexPath) == nil ? .none : .delete
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let target = removable(at: indexPath) else { return nil }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Remove"),
        ) { [weak self] _, _, completion in
            // the row goes when the list is read again
            completion(false)
            self?.confirmRemoval(of: target.location, named: target.name)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    // MARK: - Changes

    @objc private dynamic func confirmRemoval(of location: String, named name: String) {
        presentConfirmation(
            title: "Remove \(name)?",
            message: "Its files are removed from the skills folder, and chats are no longer offered it.",
            confirmTitle: "Remove",
            destructive: true,
        ) { [weak self] in
            self?.remove(location)
        }
    }

    @objc private dynamic func remove(_ location: String) {
        let folder = folder
        Task { [weak self] in
            do {
                try await Task.detached { try folder.remove(location) }.value
                SPIndicator.present(title: String(localized: "Removed"), preset: .done, haptic: .success)
            } catch {
                self?.presentNotice(title: "Unable to Remove Skill", message: error.readableMessage)
            }
            self?.load()
        }
    }

    @objc private dynamic func pickSkill() {
        let markdown = UTType(filenameExtension: "md", conformingTo: .text) ?? .plainText
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, markdown], asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Copies the pick in, asking first before it replaces a skill of the
    /// same place; afterwards a problem the agent finds with it is shown.
    @objc private dynamic func add(_ url: URL, replacing: Bool) {
        let folder = folder
        Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                try DataFolder.app.makeLevels(to: folder.root)
                let location = try await Task.detached { try folder.add(url, replacing: replacing) }.value
                SPIndicator.present(title: String(localized: "Imported"), preset: .done, haptic: .success)
                self?.load(then: location)
            } catch let SkillFolder.Failure.exists(location) {
                self?.presentConfirmation(
                    title: "Replace \(location)?",
                    message: "The skills folder already has a skill here. Replacing it removes its files.",
                    confirmTitle: "Replace",
                    destructive: true,
                ) { [weak self] in
                    self?.add(url, replacing: true)
                }
            } catch let failure as SkillFolder.Failure {
                switch failure {
                case .tooLarge:
                    self?.presentNotice(
                        title: "Unable to Import Skill",
                        message: "A skill can hold up to 2,000 files and 32 MB.",
                    )
                default:
                    self?.presentNotice(
                        title: "Unable to Import Skill",
                        message: "Choose a folder that holds a SKILL.md, or a Markdown file.",
                    )
                }
            } catch {
                self?.presentNotice(title: "Unable to Import Skill", message: error.readableMessage)
            }
        }
    }
}

extension SkillsController: UIDocumentPickerDelegate {
    @objc dynamic func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        add(url, replacing: false)
    }
}
