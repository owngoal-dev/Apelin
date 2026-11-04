import ApelinCore
import ApelinProtocol
import Then
import UIKit

/// Toolchain ▸ Set Up: the Command Line Tools releases Apple's software
/// update catalog offers, newest first, as Inspector's table: the newest SDK
/// each one's tools read, those already set up marked, those Apelin cannot
/// set up dimmed with the reason. Picking one sets it up — with Swift where
/// the release and this device take it, which the app always asks for then
/// — and hands over to the setup page.
final class ToolchainCatalogController: TableController {
    /// Told with the setup's task, in place of this page.
    var onStart: ((TaskHandle) -> Void)?

    private lazy var dataSource = TableDataSource<Int, String, ToolchainCatalogProduct>(
        tableView: tableView,
        identifier: { $0.productID },
    ) { [weak self] table, indexPath, product in
        self?.cell(in: table, at: indexPath, product: product)
    }

    @objc private dynamic func updateRows(changedItems: Set<String> = []) {
        dataSource.footerTitle = { [weak self] _ in self?.footer() }
        dataSource.update(products.isEmpty ? [] : [(0, products)], reconfigure: true, changedItems: changedItems)
    }

    private var products: [ToolchainCatalogProduct] = []
    private let installedToolchains: [ToolchainRecord]
    private func isInstalled(_ product: ToolchainCatalogProduct) -> Bool {
        installedToolchains.contains { record in
            ToolchainDetailController.product(of: record) == product.productID
                && (product.supportsSwift != true
                    || record.components.contains { $0.kind == .swift && $0.selfCheckPassed == true })
        }
    }

    private var loader: Task<Void, Never>?

    private let columns = [
        TableColumn(title: String(localized: "Swift"), samples: ["5.7.2", "6.4", "—"]),
        // "SDK" is the English word, an acronym, not a key: spelled as a
        // LocalizationValue so the all-capitals check does not take it for one
        TableColumn(title: String(localized: String.LocalizationValue("SDK")), samples: ["88.8", "88.x", "—"]),
        TableColumn(title: String(localized: "Size"), samples: ["888.8M", "8.8G"]),
    ]
    private var metrics: ColumnTableMetrics {
        ColumnTableMetrics(
            columns: columns,
            category: traitCollection.preferredContentSizeCategory,
            trailingSymbol: !installedToolchains.isEmpty,
            availableWidth: tableView.bounds.width > 0 ? tableView.bounds.width - 72 : nil,
        )
    }

    init(installedToolchains: [ToolchainRecord]) {
        self.installedToolchains = installedToolchains
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(installedToolchains:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Command Line Tools")
        navigationItem.backButtonDisplayMode = .minimal
        tableView.register(
            ColumnTableHeaderView.self,
            forHeaderFooterViewReuseIdentifier: ColumnTableHeaderView.reuseIdentifier,
        )
        tableView.register(ColumnTableCell.self, forCellReuseIdentifier: ColumnTableCell.reuseIdentifier)
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        }
        if let saved = Self.savedProducts(), !saved.isEmpty {
            products = saved
        } else {
            tableView.backgroundView = LoadingView()
        }
        updateRows()
        reload()
    }

    // MARK: - The saved list

    /// Reading Apple's catalog takes seconds; the last list read is shown at
    /// once and read again behind it. Per viewer and only a convenience: a
    /// release that moved is refused by setup with its reason either way.
    private static let savedKey = "ToolchainCatalog.products.v2"

    private static func savedProducts() -> [ToolchainCatalogProduct]? {
        guard let data = UserDefaults.standard.data(forKey: savedKey) else { return nil }
        return try? JSONDecoder().decode([ToolchainCatalogProduct].self, from: data)
    }

    private static func save(_ products: [ToolchainCatalogProduct]) {
        guard let data = try? JSONEncoder().encode(products) else { return }
        UserDefaults.standard.set(data, forKey: savedKey)
    }

    @objc private dynamic func reload() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let catalog = try await ApelinService.app.toolchainCatalog()
                guard !Task.isCancelled, let self else { return }
                refreshControl?.endRefreshing()
                products = catalog.products
                Self.save(products)
                tableView.backgroundView = products.isEmpty
                    ? EmptyStateView(symbolName: "tray", title: String(localized: "No Toolchains Yet"), text: String(localized: """
                    Apple’s catalog lists no Command Line Tools. Check your internet connection, then \
                    pull down to try again.
                    """))
                    : nil
                updateRows()
            } catch {
                guard !Task.isCancelled, let self else { return }
                refreshControl?.endRefreshing()
                // a saved list stays up; the read is tried again on the next visit
                guard products.isEmpty else { return }
                tableView.backgroundView = EmptyStateView(
                    symbolName: "exclamationmark.triangle",
                    title: String(localized: "Error"),
                    text: ToolchainController.unavailableText(error),
                )
                updateRows()
            }
        }
    }

    private static func name(of product: ToolchainCatalogProduct) -> String {
        product.version == "unknown"
            ? String(localized: "Unknown Version")
            : String(localized: "Command Line Tools \(product.version)")
    }

    /// What a row shows: the version alone, since the page's title already
    /// says Command Line Tools and a row on a phone has no room for both.
    private static func shortName(of product: ToolchainCatalogProduct) -> String {
        product.version == "unknown" ? String(localized: "Unknown Version") : product.version
    }

    @objc private dynamic static func compactSize(_ bytes: Int64) -> String {
        let units: [(Int64, String)] = [(1_000_000_000, "G"), (1_000_000, "M"), (1000, "K")]
        for (divisor, suffix) in units {
            if bytes >= divisor {
                return (Double(bytes) / Double(divisor)).formatted(.number.precision(.fractionLength(0 ... 1))) + suffix
            }
        }
        return bytes.formatted() + "B"
    }

    // MARK: - Table

    @objc private dynamic func footer() -> String? {
        String(localized: """
        Downloaded from Apple. No Apple ID needed.

        Includes C, C++ and Objective-C. “—” in the Swift column means Swift is unavailable.

        SDK shows the highest supported version. A compatible iOS SDK downloads automatically.
        """)
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection _: Int) -> UIView? {
        guard !metrics.isStacked,
              let header = tableView.dequeueReusableHeaderFooterView(
                  withIdentifier: ColumnTableHeaderView.reuseIdentifier,
              ) as? ColumnTableHeaderView
        else { return nil }
        header.configure(columns: columns, metrics: metrics, nameTitle: String(localized: "Version"))
        return header
    }

    override func tableView(_: UITableView, heightForHeaderInSection _: Int) -> CGFloat {
        metrics.isStacked ? .leastNormalMagnitude : ceil(metrics.titleFont.lineHeight) + 24
    }

    override func tableView(_: UITableView, heightForRowAt _: IndexPath) -> CGFloat {
        metrics.rowHeight
    }

    private func cell(
        in tableView: UITableView,
        at indexPath: IndexPath,
        product: ToolchainCatalogProduct,
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ColumnTableCell.reuseIdentifier, for: indexPath)
        guard let cell = cell as? ColumnTableCell else { return cell }
        let name = Self.name(of: product)
        let supported = product.unsupportedReason == nil
        let installed = isInstalled(product)
        let swiftName = product.swiftRequirements.map { String(localized: "Swift \($0.version)") }
            ?? String(localized: "Swift")
        // a release Apelin cannot set up is struck through; the reason is a tap away
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: supported ? UIColor.label : UIColor.tertiaryLabel,
        ]
        if !supported {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        let text = NSAttributedString(string: Self.shortName(of: product), attributes: attributes)
        // drawn only (strike, check, plus): the spoken name says it
        var spoken = [name]
        if product.supportsSwift == true {
            spoken.append(swiftName)
        }
        if installed {
            spoken.append(String(localized: "Installed"))
        }
        if !supported {
            spoken.append(String(localized: "Not Supported"))
        }
        let spokenName = spoken.joined(separator: ", ")
        let symbol = installed ? UIImage(systemName: "checkmark") : nil
        cell.configure(
            name: text,
            accessibilityName: spokenName,
            values: [
                product.supportsSwift == true ? product.swiftRequirements?.version ?? "—" : "—",
                product.newestSDK.map { $0.contains(".") ? $0 : $0 + ".x" } ?? "—",
                Self.compactSize(product.size),
            ],
            columns: columns,
            metrics: metrics,
            symbol: symbol,
            symbolTint: installed ? .secondaryLabel : .tintColor,
        )
        cell.accessibilityTraits = .button
        return cell
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateRows(changedItems: Set(dataSource.snapshot().itemIdentifiers))
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let product = dataSource.value(at: indexPath) else { return }
        // an installed release has nothing to do; the tick says so
        guard !isInstalled(product) else { return }
        confirmSetup(product, from: self)
    }

    /// Only the capabilities that affect this installation decision.
    static func details(of product: ToolchainCatalogProduct) -> String {
        var notes = [product.supportsSwift == true
            ? String(localized: "Swift is included on this device.")
            : String(localized: "Swift is not included on this device.")]
        if !(product.clangModuleCPUFeatures ?? ["FEAT_SHA3"]).allSatisfy(HostCPU.has) {
            notes.append(String(localized: "Clang modules are unavailable with this release on this device."))
        }
        return notes.joined(separator: "\n")
    }

    private func confirmSetup(_ product: ToolchainCatalogProduct, from presenter: UIViewController) {
        if let reason = product.unsupportedReason {
            presenter.presentNotice(title: "Not Supported", message: reason)
            return
        }
        let size = ByteCountFormatter.string(fromByteCount: product.size, countStyle: .file)
        presenter.presentConfirmation(
            title: "Install Command Line Tools \(product.version)?",
            message: String.LocalizationValue("\(Self.details(of: product))\n\nDownload: \(size)\nA compatible iOS SDK is downloaded automatically when needed."),
            confirmTitle: "Install",
        ) { [weak self] in
            self?.setUp(product, from: presenter)
        }
    }

    private func setUp(_ product: ToolchainCatalogProduct, from presenter: UIViewController) {
        presenter.view.isUserInteractionEnabled = false
        Task { [weak self] in
            do {
                let handle = try await ApelinService.app.toolchainSetup(ToolchainSetupRequest(
                    source: .appleCatalog(productID: product.productID),
                    components: product.supportsSwift == true ? [.c, .swift] : [.c],
                ))
                presenter.view.isUserInteractionEnabled = true
                ToolchainController.remember(version: product.version, for: handle)
                self?.onStart?(handle)
            } catch {
                presenter.view.isUserInteractionEnabled = true
                presenter.presentNotice(title: "Unable to Start Setup", message: error.readableMessage)
            }
        }
    }
}
