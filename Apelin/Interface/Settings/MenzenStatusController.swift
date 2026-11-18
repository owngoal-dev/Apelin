import ApelinCore
import UIKit

/// What the Discord status shows while an agent works. The session host
/// sends it through Menzen (`MenzenStatus`) and reads these switches from
/// `MenzenStatus.json`.
final class MenzenStatusController: TableController {
    private enum Section: Hashable {
        case shown
    }

    private enum RowID: Hashable, CaseIterable {
        case project
        case activity
        case elapsedTime
    }

    private struct Row: Equatable {
        let id: RowID
        let isOn: Bool
    }

    private var options = MenzenStatusOptions()

    private lazy var dataSource = TableDataSource<Section, RowID, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    @objc private dynamic func updateRows() {
        dataSource.footerTitle = { _ in
            String(localized: "While an agent works, your Discord profile shows it through Menzen. Turn on Apelin in Settings › Menzen › Connected Apps first.")
        }
        dataSource.update([
            (.shown, RowID.allCases.map { Row(id: $0, isOn: isOn($0)) }),
        ], reconfigure: true)
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
        title = String(localized: "Discord Status")
        options = MenzenStatusOptions.read(from: DataFolder.app)
        updateRows()
    }

    private func isOn(_ id: RowID) -> Bool {
        switch id {
        case .project: options.showsProject
        case .activity: options.showsActivity
        case .elapsedTime: options.showsElapsedTime
        }
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        // The switch says on or off itself; the row's text names it.
        let cell = tableView.dequeueReusableCell(withIdentifier: "option")
            ?? UITableViewCell(style: .default, reuseIdentifier: "option")
        var content = cell.defaultContentConfiguration()
        content.text = switch row.id {
        case .project: String(localized: "Show Project")
        case .activity: String(localized: "Show What the Agent Is Doing")
        case .elapsedTime: String(localized: "Show Elapsed Time")
        }
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        let toggle = (cell.accessoryView as? UISwitch) ?? UISwitch()
        toggle.isOn = row.isOn
        toggle.tag = RowID.allCases.firstIndex(of: row.id) ?? 0
        toggle.removeTarget(nil, action: nil, for: .valueChanged)
        toggle.addTarget(self, action: #selector(optionChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt _: IndexPath) -> Bool {
        false
    }

    @objc private dynamic func optionChanged(_ toggle: UISwitch) {
        guard RowID.allCases.indices.contains(toggle.tag) else { return }
        switch RowID.allCases[toggle.tag] {
        case .project: options.showsProject = toggle.isOn
        case .activity: options.showsActivity = toggle.isOn
        case .elapsedTime: options.showsElapsedTime = toggle.isOn
        }
        try? options.write(to: DataFolder.app)
        updateRows()
    }
}
