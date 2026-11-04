import ApelinCore
import ApelinProtocol
import Then
import UIKit
import UniformTypeIdentifiers

/// SDKs ▸ plus: the iOS versions the enabled sources offer, newest first,
/// laid out as the Command Line Tools page is — a Version heading, one line
/// each, a tick on installed versions — and one picked downloads. The other ways in (the
/// inbox, a link, a file) are in the menu at the top. An import is a task
/// the session host runs; this page starts it and hands over to
/// `EnvironmentTaskController`.
final class SDKCatalogController: TableController {
    private struct Entry: Equatable {
        let sourceID: String
        let source: SDKSourceStatus
        let branch: String
        /// "14.5", from `sdk/iPhoneOS14.5`.
        let version: String
        let installed: Bool
    }

    private struct Section {
        let id: String
        let source: SDKSourceStatus
        let entries: [Entry]
    }

    private lazy var dataSource = TableDataSource<String, String, Entry>(
        tableView: tableView,
        identifier: { $0.sourceID + "\u{1f}" + $0.branch },
    ) { [weak self] table, indexPath, entry in
        self?.cell(in: table, at: indexPath, entry: entry)
    }

    @objc private dynamic func updateRows(changedItems: Set<String> = []) {
        dataSource.headerTitle = { [weak self] id in
            guard let self else { return nil }
            return sections.count > 1 ? sections.first { $0.id == id }?.source.name : String(localized: "Version")
        }
        dataSource.footerTitle = { [weak self] id in
            guard let self else { return nil }
            return sections.first { $0.id == id }?.source.problem
        }
        dataSource.update(sections.map { ($0.id, $0.entries) }, reconfigure: true, changedItems: changedItems)
    }

    private var sections: [Section] = []
    private var loader: Task<Void, Never>?

    /// No figures beside the version; only the trailing mark.
    private var cachedMetrics: (UIContentSizeCategory, ColumnTableMetrics)?

    private var metrics: ColumnTableMetrics {
        let category = traitCollection.preferredContentSizeCategory
        if let cachedMetrics, cachedMetrics.0 == category {
            return cachedMetrics.1
        }
        let metrics = ColumnTableMetrics(columns: [], category: category, trailingSymbol: true)
        cachedMetrics = (category, metrics)
        return metrics
    }

    /// Told once an import ends, so the list behind reads itself again.
    @objc dynamic var onImport: (() -> Void)?

    @objc private dynamic var inbox: URL {
        DataFolder.app.root.appendingPathComponent("inbox", isDirectory: true)
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
        title = String(localized: "iOS SDK")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: importMenu(),
        ).then { $0.accessibilityLabel = String(localized: "Other Ways to Import") }
        tableView.register(ColumnTableCell.self, forCellReuseIdentifier: ColumnTableCell.reuseIdentifier)
        tableView.backgroundView = LoadingView()
        updateRows()
        load()
    }

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let list = try await ApelinService.app.sdkList(includeSources: true, readSources: true)
                guard !Task.isCancelled else { return }
                self?.show(list)
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(error)
            }
        }
    }

    private func show(_ list: SDKListResponse) {
        let installed = Set(list.sdks.map { $0.canonicalName.lowercased() })
        // A user can list the same repository twice; count only matching sources.
        var occurrences: [String: Int] = [:]
        sections = (list.sources ?? []).filter(\.enabled).map { source in
            let key = source.url + "\u{1f}" + source.branchPrefix
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            let id = key + "\u{1f}" + String(occurrence)
            let entries = (source.branches ?? []).map { branch in
                let name = branch.hasPrefix(source.branchPrefix)
                    ? String(branch.dropFirst(source.branchPrefix.count))
                    : branch
                let version = name.lowercased().hasPrefix("iphoneos") ? String(name.dropFirst(8)) : name
                return Entry(
                    sourceID: id,
                    source: source,
                    branch: branch,
                    version: version,
                    installed: installed.contains(name.lowercased()),
                )
            }
            return Section(id: id, source: source, entries: entries.sorted {
                $0.version.compare($1.version, options: .numeric) == .orderedDescending
            })
        }
        tableView.backgroundView = sections.contains { !$0.entries.isEmpty || $0.source.problem != nil }
            ? nil
            : EmptyStateView(
                symbolName: "tray",
                title: String(localized: "No SDKs Yet"),
                text: String(localized: "Use “From Link…” or “From Files…” in the menu to import an SDK."),
            )
        updateRows()
    }

    @objc private dynamic func show(_ error: Error) {
        sections = []
        tableView.backgroundView = EmptyStateView(
            symbolName: "exclamationmark.triangle",
            title: String(localized: "Error"),
            text: ToolchainController.unavailableText(error),
        )
        updateRows()
    }

    // MARK: - Table

    override func tableView(_: UITableView, heightForRowAt _: IndexPath) -> CGFloat {
        metrics.rowHeight
    }

    // Only why a source could not be read; its own note is not shown.

    private func cell(in tableView: UITableView, at indexPath: IndexPath, entry: Entry) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ColumnTableCell.reuseIdentifier, for: indexPath)
        guard let cell = cell as? ColumnTableCell else { return cell }
        // The installed mark is also included in the spoken name.
        let spoken = entry.installed
            ? String(localized: "iOS \(entry.version), Installed")
            : String(localized: "iOS \(entry.version)")
        cell.configure(
            name: NSAttributedString(string: entry.version),
            accessibilityName: spoken,
            values: [],
            columns: [],
            metrics: metrics,
            symbol: entry.installed ? UIImage(systemName: "checkmark") : nil,
            symbolTint: .secondaryLabel,
        )
        cell.accessibilityTraits = entry.installed ? .staticText : .button
        return cell
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateRows(changedItems: Set(dataSource.snapshot().itemIdentifiers))
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        dataSource.value(at: indexPath)?.installed == false
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let entry = dataSource.value(at: indexPath), !entry.installed else { return }
        importSDK(.repository(url: entry.source.url, branch: entry.branch))
    }

    // MARK: - Import

    @objc private dynamic func importMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.importMenuItems() ?? [])
            },
        ])
    }

    @objc private dynamic func importMenuItems() -> [UIMenuElement] {
        let otherSources: [UIMenuElement] = [
            UIAction(title: String(localized: "From Link…"), image: UIImage(systemName: "link")) { [weak self] _ in
                self?.askForLink()
            },
            UIAction(title: String(localized: "From Files…"), image: UIImage(systemName: "folder")) { [weak self] _ in
                self?.pickFile()
            },
        ]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path))?
            .filter { !$0.hasPrefix(".") }
            .sorted() ?? []
        guard !names.isEmpty else {
            // Explanatory copy belongs in the section header; action titles truncate.
            let folder = "Documents/wiki.qaq.apelin/inbox"
            return [UIMenu(
                title: String(localized: "Put an SDK in \(folder), then reopen this menu."),
                options: .displayInline,
                children: otherSources,
            )]
        }
        let items = names.map { name in
            UIAction(title: name, image: UIImage(systemName: "tray")) { [weak self] _ in
                self?.importSDK(.inbox(path: name))
            }
        }
        return [
            UIMenu(title: String(localized: "From Inbox"), options: .displayInline, children: items),
            UIMenu(options: .displayInline, children: otherSources),
        ]
    }

    @objc private dynamic func askForLink() {
        presentTextInput(
            title: "Import from Link",
            message: "Enter an HTTPS link to a zip, tar.xz or tar.zst archive containing one iPhoneOS SDK.",
            placeholder: "https://",
            doneTitle: "Import",
        ) { [weak self] text in
            let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.isEmpty else { return }
            self?.importSDK(.url(link))
        }
    }

    @objc private dynamic func pickFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func importSDK(_ source: SDKSource, descriptors: [OwnedDescriptor] = []) {
        view.isUserInteractionEnabled = false
        Task { [weak self] in
            do {
                let handle = try await ApelinService.app.sdkImport(source, descriptors: descriptors)
                self?.view.isUserInteractionEnabled = true
                self?.openTask(handle)
            } catch {
                self?.view.isUserInteractionEnabled = true
                self?.presentNotice(title: "Unable to Start Import", message: error.readableMessage)
            }
        }
    }

    private func openTask(_ handle: TaskHandle) {
        let page = EnvironmentTaskController(
            handle: handle,
            work: .sdkImport,
            title: String(localized: "Importing SDK"),
            doneTitle: String(localized: "SDK Imported"),
        )
        page.onFinish = { [weak self] in
            self?.onImport?()
            self?.load()
        }
        navigationController?.pushViewController(page, animated: true)
    }
}

extension SDKCatalogController: UIDocumentPickerDelegate {
    /// An archive goes to the host as a descriptor; a folder cannot, so it
    /// is copied into the inbox first and imported from there.
    @objc dynamic func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // an SDK exported by Apelin is a transfer file, not an archive to unpack
        if TransferKind(fileName: url.lastPathComponent) != nil {
            TransferOpener.open(url, from: self, pushingOnto: navigationController)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let target = inbox.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            do {
                try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.copyItem(at: url, to: target)
                }
                importSDK(.inbox(path: url.lastPathComponent))
            } catch {
                presentNotice(title: "Unable to Import", message: error.readableMessage)
            }
            return
        }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let reason = String(cString: strerror(errno))
            presentNotice(title: "Unable to Import", message: String(localized: "Unable to read the file: \(reason)"))
            return
        }
        importSDK(.file(DescriptorSlot(index: 0)), descriptors: [OwnedDescriptor(adopting: descriptor)])
    }
}
