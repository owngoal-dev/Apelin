import ApelinCore
import ApelinProtocol
import Then
import UIKit

/// SDKs ▸ one SDK: its version, architectures and Swift interfaces.
/// Removing it is in the menu at the top.
final class SDKDetailController: TableController {
    /// Told once the SDK is removed, so the list reads itself again.
    @objc dynamic var onRemove: (() -> Void)?

    private enum Field: Hashable { case version, name, architecture(String), swiftInterfaces }
    private struct Row: Equatable {
        let id: Field
        let name: String
        let value: String
    }

    private lazy var dataSource = TableDataSource<Int, Field, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private let record: SDKRecord

    /// `…` in the bar: Export, anchoring the share sheet that follows.
    @objc private dynamic lazy var moreItem: UIBarButtonItem = .init(
        image: UIImage(systemName: "ellipsis"),
        menu: UIMenu(children: [
            UIAction(title: String(localized: "Show in Fila"), image: UIImage(systemName: "folder")) { [weak self] _ in
                self?.revealInFila(path: self?.record.path ?? "")
            },
            UIAction(
                title: String(localized: "Export…"),
                image: UIImage(systemName: "square.and.arrow.up"),
            ) { [weak self] _ in
                self?.export()
            },
            UIAction(
                title: String(localized: "Remove"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive,
            ) { [weak self] _ in self?.confirmRemoval() },
        ]),
    ).then { $0.accessibilityLabel = String(localized: "More") }

    init(record: SDKRecord) {
        self.record = record
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(record:)")
    }

    /// `iphoneos27.0` → `iOS 27.0`.
    static func displayName(of record: SDKRecord) -> String {
        let platform = record.canonicalName.lowercased().hasPrefix("iphoneos") ? "iOS" : record.canonicalName
        return "\(platform) \(record.version)"
    }

    /// `arm64e-ios`, `arm64e.x1-ios` → `arm64e`, `arm64e.x1`.
    static func architectures(of record: SDKRecord) -> [String] {
        record.targets.map { target in
            target.hasSuffix("-ios") ? String(target.dropLast(4)) : target
        }
    }

    /// "Apple Swift version 6.4 effective-5.10 (…)" → "6.4".
    static func swiftVersion(of record: SDKRecord) -> String? {
        guard let swift = record.swiftCompilerVersion else { return nil }
        let words = swift.split(separator: " ")
        guard let index = words.firstIndex(of: "version"), words.indices.contains(index + 1) else { return swift }
        return String(words[index + 1])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.displayName(of: record)
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = moreItem

        var about: [Row] = [
            Row(id: .version, name: String(localized: "Version"), value: record.version),
        ]
        if let swift = Self.swiftVersion(of: record) {
            about.append(Row(id: .swiftInterfaces, name: String(localized: "Swift Interfaces"), value: swift))
        }
        // the check's warnings stay in the record; none of them stops a build
        dataSource.headerTitle = { section in
            section == 1 ? String(localized: "Architectures") : nil
        }
        var sections = [(0, about)]
        let architectures = Self.architectures(of: record).reduce(into: [String]()) { result, architecture in
            if !result.contains(architecture) {
                result.append(architecture)
            }
        }
        if !architectures.isEmpty {
            sections.append((1, architectures.map {
                Row(id: .architecture($0), name: $0, value: "")
            }))
        }
        sections.append((2, [Row(id: .name, name: String(localized: "Name"), value: record.canonicalName)]))
        dataSource.update(sections)
    }

    private func cell(for row: Row) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = row.value.isEmpty ? UIListContentConfiguration.cell() : .valueCell()
        content.text = row.name
        content.secondaryText = row.value.isEmpty ? nil : row.value
        cell.selectionStyle = .none
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt _: IndexPath) -> Bool {
        false
    }

    @objc private dynamic func confirmRemoval() {
        presentConfirmation(
            title: "Remove the SDK?",
            message: "This deletes the SDK files. SDKs used by a project cannot be removed.",
            confirmTitle: "Remove",
            destructive: true,
        ) { [weak self] in
            self?.remove()
        }
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let row = dataSource.value(at: indexPath) else { return nil }
        let text = row.value.isEmpty ? row.name : row.value
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc"),
            ) { _ in
                UIPasteboard.general.string = text
            }])
        })
    }

    /// A `.apesdk` of this SDK, for the user's other devices.
    @objc private dynamic func export() {
        TransferExporter.confirmAndExport(
            kind: .sdk,
            id: record.id,
            name: Self.displayName(of: record),
            from: self,
            anchor: moreItem,
        )
    }

    @objc private dynamic func remove() {
        Task { [weak self, record] in
            guard let self else { return }
            do {
                try await ProgressCard.run(
                    title: String(localized: "Removing SDK"),
                    message: Self.displayName(of: record),
                    cancellable: false,
                    from: self,
                ) { _ in
                    try await ApelinService.app.sdkRemove(id: record.id)
                }
                onRemove?()
                navigationController?.popViewController(animated: true)
            } catch {
                presentNotice(title: "Unable to Remove", message: error.readableMessage)
            }
        }
    }
}
