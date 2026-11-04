// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
// Table/action-bar layout copied from Irisin's WelcomeRepositoriesController.
import ApelinCore
import ApelinProtocol
import UIKit

/// Lists templates grouped by kind, as Settings ▸ Templates does. Picking one
/// creates the project at once under a generated name the agent may replace.
final class WelcomeProjectPage: WelcomeListPage {
    private enum Section: Hashable { case introduction, kind(String) }
    private struct Row: Equatable {
        let template: TemplateSummary
        let kind: DevelopmentExtensionKind
        let created: Bool
    }

    private enum Item: Equatable {
        case introduction
        case template(Row)
        var id: String {
            switch self {
            case .introduction: "introduction"
            case let .template(row): "template:" + row.template.id
            }
        }
    }

    private var extensions: [DevelopmentExtension] = [.emptyWorkspace]
    @objc private dynamic var creating = false
    private var loader: Task<Void, Never>?
    private lazy var dataSource = TableDataSource<Section, String, Item>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        switch row {
        case .introduction:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Pick a template to start your first project. You can also create one later from the sidebar.")
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case let .template(row): return self?.cell(for: row)
        }
    }

    deinit { loader?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "First Project")
        next { [weak self] in self?.flow.showNotifications() }
        dataSource.headerTitle = { [weak self] section in
            guard case let .kind(id) = section else { return nil }
            return self?.extensions.first { $0.id == id }?.displayName
        }
        dataSource.footerTitle = { [weak self] section in
            guard case let .kind(id) = section else { return nil }
            return self?.extensions.first { $0.id == id }?.kind.templateDescription
        }
        updateRows()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            guard let catalog = try? await ApelinService.app.extensionList(),
                  !Task.isCancelled, let self
            else { return }
            let usable = catalog.extensions.filter { $0.problems.isEmpty && !$0.templates.isEmpty }
            guard !usable.isEmpty else { return }
            extensions = usable
            updateRows()
        }
    }

    @objc private dynamic func updateRows() {
        let createdID = flow.project == nil ? nil : flow.projectTemplateID
        dataSource.update([(.introduction, [.introduction])] + extensions.map { item in
            (.kind(item.id), item.templates.map { Item.template(Row(template: $0, kind: item.kind, created: $0.id == createdID)) })
        })
    }

    private func cell(for row: Row) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.cell()
        content.text = row.template.displayName
        content.textProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.accessoryType = row.created ? .checkmark : .disclosureIndicator
        if row.created {
            cell.accessibilityTraits.insert(.selected)
        }
        return cell
    }

    @objc dynamic func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .template(row)? = dataSource.value(at: indexPath) else { return }
        if flow.project != nil {
            flow.showNotifications()
        } else {
            create(row)
        }
    }

    private func create(_ row: Row) {
        guard !creating else { return }
        creating = true
        tableView.isUserInteractionEnabled = false
        Task { [weak self] in
            guard let self else { return }
            defer {
                creating = false
                tableView.isUserInteractionEnabled = true
            }
            do {
                let existing = await (try? ProjectSummary.load()) ?? []
                let draft = ProjectCreationDraft(avoiding: existing.map(\.name))
                let created = try await ApelinService.app.projectCreate(ProjectCreateRequest(
                    templateID: row.template.id,
                    name: draft.trimmedName,
                    automaticallyName: true,
                ))
                NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
                flow.project = ProjectSummary(
                    name: created.name,
                    kind: row.kind,
                    displayName: created.name,
                    projectID: created.projectID,
                    automaticallyNamed: true,
                )
                flow.projectTemplateID = row.template.id
                updateRows()
                presentNotice(
                    title: "Project Ready",
                    message: String(localized: "Your new project “\(created.name)” is ready. Your agent will give it a better name later."),
                    dismissTitle: "Continue",
                ) { [weak self] in self?.flow.showNotifications() }
            } catch { presentNotice(title: "Unable to Create Project", message: error.readableMessage) }
        }
    }
}

private extension DevelopmentExtension {
    /// What the page offers until the catalog is read, or when it cannot be:
    /// the build worker's built-in workspace, which needs no SDK or toolchain.
    static let emptyWorkspace = DevelopmentExtension(
        id: "wiki.qaq.apelin.workspace",
        version: "1",
        kind: .workspace,
        displayName: String(localized: "Workspace"),
        templates: [TemplateSummary(id: "wiki.qaq.apelin.workspace/empty", displayName: String(localized: "Empty"))],
    )
}

private extension DevelopmentExtensionKind {
    /// The same wording as Settings ▸ Templates.
    var templateDescription: String {
        switch self {
        case .workspace: String(localized: "Start with an empty workspace. No SDK or toolchain is required.")
        case .app: String(localized: "Create UIKit apps with Objective-C or Swift.")
        case .commandLineTool: String(localized: "Build tools that run in a terminal.")
        case .tweak: String(localized: "Customize apps and SpringBoard.")
        case .preferenceBundle: String(localized: "Add settings pages for your tweaks.")
        }
    }
}
