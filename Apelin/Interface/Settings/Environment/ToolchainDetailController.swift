import ApelinCore
import ApelinProtocol
import SnapKit
import Then
import UIKit

/// Toolchain details: version, self-tests, supported languages and architectures.
final class ToolchainDetailController: TableController {
    /// Refresh the list when its default or installed toolchains change.
    @objc dynamic var onChange: (() -> Void)?

    private enum Section: Hashable {
        case overview, selfTests, languages, architectures, metadata
    }

    private enum Field: Hashable {
        case version, swiftVersion, minimumOS, isDefault, files, appleProduct, selfTests
        case language(String), architecture(String)
    }

    private enum Row: Equatable {
        case value(Field, String, String)
        case item(Field, String)
        case selfTests([ToolchainSelfTestResult])
        var id: Field {
            switch self {
            case let .value(id, _, _), let .item(id, _): id
            case .selfTests: .selfTests
            }
        }
    }

    private lazy var dataSource = TableDataSource<Section, Field, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private let record: ToolchainRecord
    @objc private dynamic var isDefault: Bool
    @objc private dynamic var isSettingDefault = false

    /// `…` in the bar: Export, anchoring the share sheet that follows.
    @objc private dynamic lazy var moreItem: UIBarButtonItem = .init(
        image: UIImage(systemName: "ellipsis"),
        menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuItems() ?? [])
        }]),
    ).then { $0.accessibilityLabel = String(localized: "More") }

    @objc private dynamic func menuItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = [
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
        ]
        if !isDefault {
            items.insert(UIAction(
                title: String(localized: "Set as Default…"),
                image: UIImage(systemName: "checkmark.circle"),
            ) { [weak self] _ in self?.confirmSetDefault() }, at: 0)
        }
        return items
    }

    init(record: ToolchainRecord, isDefault: Bool) {
        self.record = record
        self.isDefault = isDefault
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(record:isDefault:)")
    }

    static func name(of record: ToolchainRecord) -> String {
        String(localized: "Command Line Tools \(record.version)")
    }

    /// "C, C++, Objective-C, Swift": what its components compile.
    static func languages(of record: ToolchainRecord) -> String {
        record.components.compactMap { component -> String? in
            switch component.kind {
            case .c: String(localized: "C, C++, Objective-C")
            case .swift: String(localized: "Swift")
            case .auxiliary: nil
            }
        }.joined(separator: ", ")
    }

    /// `<productID> <url>`: the product is what Apple calls it.
    static func product(of record: ToolchainRecord) -> String? {
        record.origin?.split(separator: " ").first.map(String.init)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.name(of: record)
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = moreItem
        dataSource.headerTitle = { section in
            switch section {
            case .languages: String(localized: "Languages")
            case .architectures: String(localized: "Architectures")
            default: nil
            }
        }
        updateRows()
    }

    @objc private dynamic func updateRows() {
        var overview: [Row] = [
            .value(.version, String(localized: "Version"), record.version),
            .value(.isDefault, String(localized: "Default"), isDefault ? String(localized: "Yes") : String(localized: "No")),
        ]
        if let swift = record.swiftRequirements, record.components.contains(where: { $0.kind == .swift }) {
            overview.append(.value(.swiftVersion, String(localized: "Swift Version"), swift.version))
            overview.append(.value(.minimumOS, String(localized: "Minimum iOS Version"), swift.minimumHost))
        }
        var sections: [(Section, [Row])] = [(.overview, overview)]
        if let tests = record.selfTests, !tests.isEmpty {
            sections.append((.selfTests, [.selfTests(tests)]))
        }
        var languages: [String] = []
        if record.components.contains(where: { $0.kind == .c }) {
            languages += ["C", "C++", "Objective-C"]
        }
        if record.components.contains(where: { $0.kind == .swift }) {
            languages.append("Swift")
        }
        if !languages.isEmpty {
            sections.append((.languages, languages.map { .item(.language($0), $0) }))
        }
        let architectures = Array(Set((record.selfTests ?? []).map(\.architecture))).sorted()
        if !architectures.isEmpty {
            sections.append((.architectures, architectures.map { .item(.architecture($0), $0) }))
        }
        var metadata: [Row] = []
        if let count = record.fileCount {
            metadata.append(.value(.files, String(localized: "Files"), count.formatted()))
        }
        if let product = Self.product(of: record) {
            metadata.append(.value(.appleProduct, String(localized: "Apple Product ID"), product))
        }
        if !metadata.isEmpty {
            sections.append((.metadata, metadata))
        }
        dataSource.update(sections)
    }

    // MARK: - Table

    private func cell(for row: Row) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        cell.selectionStyle = .none
        switch row {
        case let .value(_, name, value):
            content.text = name
            content.secondaryText = value
        case let .item(_, name):
            content = .cell()
            content.text = name
        case let .selfTests(tests):
            let passed = tests.filter(\.passed).count
            content.text = String(localized: "Self-Tests")
            content.secondaryText = String(localized: "\(passed) of \(tests.count) Passed")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if case .selfTests? = dataSource.value(at: indexPath) {
            return true
        }
        return false
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case let .selfTests(tests):
            navigationController?.pushViewController(SelfTestsController(record: record, tests: tests), animated: true)
        case .value, .item:
            break
        }
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        let text: String
        guard let row = dataSource.value(at: indexPath) else { return nil }
        switch row {
        case let .value(_, _, value), let .item(_, value): text = value
        default: return nil
        }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc"),
            ) { _ in
                UIPasteboard.general.string = text
            }])
        })
    }

    @objc private dynamic func confirmSetDefault() {
        presentConfirmation(
            title: "Set as Default?",
            message: "New projects will use this toolchain. To switch an existing project’s toolchain, ask the model in that project.",
            confirmTitle: "Set as Default",
        ) { [weak self] in self?.setDefault() }
    }

    @objc private dynamic func setDefault() {
        guard !isDefault, !isSettingDefault else { return }
        isSettingDefault = true
        moreItem.isEnabled = false
        Task { [weak self, record] in
            guard let self else { return }
            defer {
                isSettingDefault = false
                moreItem.isEnabled = true
            }
            do {
                try await ApelinService.app.toolchainSetDefault(id: record.id)
                isDefault = true
                updateRows()
                onChange?()
            } catch {
                presentNotice(title: "Unable to Set Default", message: error.readableMessage)
            }
        }
    }

    @objc private dynamic func confirmRemoval() {
        presentConfirmation(
            title: "Remove the Toolchain?",
            message: "Projects using this toolchain cannot build until you download and set it up again.",
            confirmTitle: "Remove",
            destructive: true,
        ) { [weak self] in
            self?.remove()
        }
    }

    /// A `.apetc` of this toolchain, for the user's other devices.
    @objc private dynamic func export() {
        TransferExporter.confirmAndExport(
            kind: .toolchain,
            id: record.id,
            name: Self.name(of: record),
            from: self,
            anchor: moreItem,
        )
    }

    /// Removal is quick: Fila's progress card, not the setup page.
    @objc private dynamic func remove() {
        Task { [weak self, record] in
            guard let self else { return }
            do {
                let outcome = try await ProgressCard.run(
                    title: String(localized: "Removing Toolchain"),
                    message: Self.name(of: record),
                    cancellable: false,
                    from: self,
                ) { update in
                    let handle = try await ApelinService.app.toolchainRemove(id: record.id)
                    var progress = EnvironmentTaskProgress(work: .toolchainRemoval)
                    for try await event in ApelinService.app.events(of: handle) {
                        progress.apply(event)
                        if let detail = progress.detail, !detail.isEmpty {
                            update(ProgressCard.Status(subtitle: detail))
                        }
                    }
                    return progress
                }
                onChange?()
                if outcome.state == .succeeded {
                    navigationController?.popViewController(animated: true)
                } else {
                    presentNotice(title: "Unable to Remove", message: outcome.outcomeMessage)
                }
            } catch {
                presentNotice(title: "Unable to Remove", message: error.readableMessage)
            }
        }
    }
}

/// Toolchain ▸ Self-Tests: each language and architecture the installed
/// tools were checked with, and what the check found.
private final class SelfTestsController: TableController {
    private enum Section: Hashable {
        case explanation
        case language(String)
    }

    private enum Row: Equatable {
        case explanation
        case result(ToolchainSelfTestResult)

        var id: String {
            switch self {
            case .explanation: "explanation"
            case let .result(test): test.language + "\u{1f}" + test.architecture
            }
        }
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        switch row {
        case .explanation: self?.explanationCell()
        case let .result(test): self?.cell(for: test)
        }
    }

    @objc private dynamic func updateRows() {
        dataSource.headerTitle = { section in
            if case let .language(name) = section {
                return name
            }
            return nil
        }
        var languages: [String] = []
        for test in tests where !languages.contains(test.language) {
            languages.append(test.language)
        }
        var sections: [(Section, [Row])] = [(.explanation, [.explanation])]
        for language in languages {
            sections.append((.language(language), tests.filter { $0.language == language }.map(Row.result)))
        }
        dataSource.update(sections)
    }

    private let record: ToolchainRecord
    private var tests: [ToolchainSelfTestResult]

    init(record: ToolchainRecord, tests: [ToolchainSelfTestResult]) {
        self.record = record
        self.tests = tests
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(record:tests:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Self-Tests")
        tableView.allowsSelection = false
        updateRows()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIAction(
                    title: String(localized: "Run Again"),
                    image: UIImage(systemName: "arrow.clockwise"),
                ) { [weak self] _ in self?.runAgain() },
            ]),
        ).then { $0.accessibilityLabel = String(localized: "More") }
    }

    /// The installed tools tested once more, on the task page; back here the
    /// list shows what the registry now keeps.
    @objc private dynamic func runAgain() {
        Task { [weak self, record] in
            do {
                let handle = try await ApelinService.app.toolchainSelfTest(id: record.id)
                guard let self else { return }
                let page = EnvironmentTaskController(
                    handle: handle,
                    work: .toolchainSelfTest,
                    title: String(localized: "Running Self-Tests"),
                    doneTitle: String(localized: "Self-Tests Done"),
                )
                page.onFinish = { [weak self] in self?.reload() }
                navigationController?.pushViewController(page, animated: true)
            } catch {
                self?.presentNotice(title: "Unable to Start Self-Tests", message: error.readableMessage)
            }
        }
    }

    @objc private dynamic func reload() {
        dataSource.beginLoad()
        Task { [weak self, record] in
            guard let status = try? await ApelinService.app.toolchainStatus(),
                  let fresh = status.toolchains.first(where: { $0.id == record.id })?.selfTests,
                  let self
            else { return }
            tests = fresh
            updateRows()
        }
    }

    @objc private dynamic func explanationCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.cell()
        content.text = String(localized: """
        Checked after installation by compiling, linking, signing and running a program \
        for each language and architecture.
        """)
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    private func cell(for test: ToolchainSelfTestResult) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let seconds = String(localized: "\(test.seconds.formatted(.number.precision(.fractionLength(2)))) s")
        let architecture = UILabel()
        architecture.text = test.architecture
        architecture.font = .preferredFont(forTextStyle: .body)
        architecture.adjustsFontForContentSizeCategory = true
        architecture.numberOfLines = 0

        let duration = UILabel()
        duration.text = seconds
        duration.font = .preferredFont(forTextStyle: .body)
        duration.adjustsFontForContentSizeCategory = true
        duration.textColor = .secondaryLabel
        duration.setContentHuggingPriority(.required, for: .horizontal)
        duration.setContentCompressionResistancePriority(.required, for: .horizontal)

        let result = UIImageView(image: UIImage(systemName: test.passed ? "checkmark.circle.fill" : "xmark.circle.fill"))
        result.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        result.tintColor = test.passed ? .systemGreen : .systemRed
        result.contentMode = .scaleAspectFit
        result.setContentHuggingPriority(.required, for: .horizontal)
        result.setContentCompressionResistancePriority(.required, for: .horizontal)
        let summary = UIStackView(arrangedSubviews: [architecture, duration, result])
        summary.axis = .horizontal
        summary.alignment = .center
        summary.spacing = 12

        let stack = UIStackView(arrangedSubviews: [summary])
        stack.axis = .vertical
        stack.spacing = 8
        if !test.passed, !test.detail.isEmpty {
            let detail = UILabel()
            detail.text = test.detail
            detail.font = .preferredFont(forTextStyle: .body)
            detail.adjustsFontForContentSizeCategory = true
            detail.textColor = .systemRed
            detail.numberOfLines = 0
            stack.addArrangedSubview(detail)
        }
        cell.contentView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalTo(cell.contentView.layoutMarginsGuide)
        }
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .staticText
        cell.accessibilityLabel = test.architecture
        var spoken = [test.passed ? String(localized: "Passed") : String(localized: "Failed"), seconds]
        if !test.passed, !test.detail.isEmpty {
            spoken.append(test.detail)
        }
        cell.accessibilityValue = spoken.joined(separator: "\n")
        return cell
    }
}
