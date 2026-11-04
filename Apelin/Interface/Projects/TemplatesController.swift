import ApelinProtocol
import UIKit

/// The installed template catalog, shared by Settings and project creation.
final class TemplatesController: TableController {
    private struct CatalogSection {
        let id: String
        let extensionInfo: DevelopmentExtension
        let rows: [Row]
    }

    private struct Row: Equatable {
        let id: String
        let template: TemplateSummary
    }

    private var sections: [CatalogSection] = []
    private var loader: Task<Void, Never>?

    private lazy var dataSource = TableDataSource<String, String, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] table, _, row in
        self?.cell(in: table, template: row.template)
    }

    @objc private dynamic func updateRows() {
        dataSource.headerTitle = { [weak self] id in self?.sections.first { $0.id == id }?.extensionInfo.displayName }
        dataSource.footerTitle = { [weak self] id in self?.footer(for: id) }
        dataSource.update(sections.map { ($0.id, $0.rows) })
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
        title = String(localized: "Templates")
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(load), for: .valueChanged)
        updateRows()
        load()
    }

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            guard let self else { return }
            defer { refreshControl?.endRefreshing() }
            do {
                let catalog = try await ApelinService.app.extensionList()
                guard !Task.isCancelled else { return }
                // Quarantined duplicate extensions remain visible in the catalog.
                var occurrences: [String: Int] = [:]
                sections = catalog.extensions.map { item in
                    let occurrence = occurrences[item.id, default: 0]
                    occurrences[item.id] = occurrence + 1
                    let id = item.id + "\u{1f}" + String(occurrence)
                    var rowOccurrences: [String: Int] = [:]
                    let rows = item.templates.map { template in
                        let occurrence = rowOccurrences[template.id, default: 0]
                        rowOccurrences[template.id] = occurrence + 1
                        return Row(id: id + "\u{1f}" + template.id + "\u{1f}" + String(occurrence), template: template)
                    }
                    return CatalogSection(id: id, extensionInfo: item, rows: rows)
                }
                updateRows()
            } catch { presentNotice(title: "Templates Unavailable", message: error.readableMessage) }
        }
    }

    @objc private dynamic func footer(for id: String) -> String? {
        guard let item = sections.first(where: { $0.id == id })?.extensionInfo else { return nil }
        let description = switch item.kind {
        case .workspace: String(localized: "Start with an empty workspace. No SDK or toolchain is required.")
        case .app: String(localized: "Create UIKit apps with Objective-C or Swift.")
        case .commandLineTool: String(localized: "Build tools that run in a terminal.")
        case .tweak: String(localized: "Customize apps and SpringBoard.")
        case .preferenceBundle: String(localized: "Add settings pages for your tweaks.")
        }
        return ([description] + item.problems).joined(separator: "\n")
    }

    private func cell(in _: UITableView, template: TemplateSummary) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        content.text = template.displayName
        content.secondaryText = template.byteCount
            .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        content.textProperties.numberOfLines = 1
        content.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.accessoryType = .none
        cell.selectionStyle = .none
        return cell
    }
}
