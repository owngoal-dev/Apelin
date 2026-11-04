import ApelinCore
import ApelinProtocol
import UIKit

/// The first step of distributing a project. The release packages builds
/// already made of its current version, roothide and rootless, come first
/// (`DistributionPackages`), each Built, Shared or Published: the selected
/// ones are published together in one commit, and any one is shared from
/// its row, as its build made it, so a version already packaged needs no
/// second build. Below them, pick a target, see what the package should not
/// carry yet, then build on its own page (`DistributionBuildController`).
/// What the check finds is advice: Build still goes ahead after a
/// confirmation, which a version packaged before does not ask for when its
/// package is listed above, and Ask Agent to Prepare hands the work to the
/// project's conversation. What stops the build — an error the check
/// finds, such as a workspace script that is not in the project — is listed
/// and Build waits for it to be fixed. A workspace is built by its own
/// script, whose package is checked once it is written, and its newest
/// release packages are listed whatever their version. A project with no
/// build description or script (`ProjectBuildMethod`) has nothing to
/// package: the page says so and offers no target.
@MainActor
final class ProjectDistributionController: TableController {
    private enum Section: Hashable {
        case project, packages, target, readiness
    }

    private enum Row: Hashable {
        case project, package(BuildBootstrap), publish, target(BuildBootstrap), checking, ready, blocker(Int), issue(Int), prepare, unavailable
    }

    private struct RowContent: Equatable {
        var row: Row
        var text: String?
        var secondaryText: String?
        /// What VoiceOver reads for the row when it is not the two texts.
        var spokenText: String?
        var spokenValue: String?
        var selected = false
        var enabled = true
    }

    private let projectName: String
    /// Asks the project's conversation to prepare the package; nil where
    /// the page was not opened from one.
    private let onPrepare: ((String) -> Void)?
    @objc private dynamic var displayName: String?
    private var selectedTarget: BuildBootstrap? = .roothide
    /// Nil until the manifest is read; one that cannot build takes the
    /// targets away.
    private var method: ProjectBuildMethod?
    /// The check's errors: the build would stop at them.
    private var blockers: [ProjectDiagnostic] = []
    private var issues: [ProjectDiagnostic] = []
    @objc private dynamic var checking = true
    @objc private dynamic var showsChecking = false
    @objc private dynamic var hasCheckResult = false
    private var loadingDelay: Task<Void, Never>?
    @objc private dynamic var checkFailure: String?
    private var check: Task<Void, Never>?
    /// The release packages builds left, per target, read again each time
    /// the page appears; the ones picked to publish, by artifact.
    private var packages: [BuildBootstrap: DistributionPackage] = [:]
    @objc private dynamic var selectedPackages: Set<String> = []
    private var packageReader: Task<Void, Never>?
    /// While a package is read back to be shared or published.
    @objc private dynamic var isPreparingPackage = false
    @objc private dynamic var hasAppeared = false
    private var dataSource: TableDataSource<Section, Row, RowContent>!

    init(projectName: String, onPrepare: ((String) -> Void)? = nil) {
        self.projectName = projectName
        self.onPrepare = onPrepare
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(projectName:onPrepare:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Distribute Project")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Build"),
            primaryAction: UIAction { [weak self] _ in self?.build() },
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Distribution")
        dataSource = TableDataSource(
            tableView: tableView,
            identifier: { $0.row },
        ) { [weak self] tableView, indexPath, content in
            let cell = tableView.dequeueReusableCell(withIdentifier: "Distribution", for: indexPath)
            self?.configure(cell, value: content)
            return cell
        }
        dataSource.headerTitle = { section in
            switch section {
            case .project: nil
            case .packages: String(localized: "Packages")
            case .target: String(localized: "Target")
            case .readiness: String(localized: "Before Distributing")
            }
        }
        dataSource.footerTitle = { [weak self] section in
            switch section {
            case .packages:
                String(localized: "Publish the selected packages to your package repository together, or share one. Each is the file its build made, unchanged.")
            case .target: String(localized: "Choose one target, then tap “Build”. To build the other target, come back and build again.")
            case .readiness:
                self?.blockers.isEmpty == false
                    ? String(localized: "Fix these before building.")
                    : self?.issues.isEmpty == false
                    ? String(localized: "These are suggestions. You can still build the package.")
                    : nil
            case .project: nil
            }
        }
        updateRows()
        refreshCheck()
        Task { [weak self] in
            guard let self else { return }
            displayName = await (try? ProjectSummary.load())?.first { $0.name == self.projectName }?.displayTitle
            updateRows()
        }
    }

    /// A project changed while the build page was open is checked again
    /// on the way back, and its packages are read again each time: a build
    /// or a publish may have changed them.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasAppeared {
            refreshCheck()
        }
        refreshPackages()
        hasAppeared = true
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .package(target):
            guard let package = packages[target] else { return }
            if selectedPackages.remove(package.artifactID) == nil {
                selectedPackages.insert(package.artifactID)
            }
            updateRows()
        case .publish:
            publish()
        case let .target(target) where target != selectedTarget:
            selectedTarget = target
            refreshCheck()
        case .prepare:
            prepare()
        default:
            break
        }
    }

    // MARK: - Rows

    private func configure(_ cell: UITableViewCell, value: RowContent) {
        var content: UIListContentConfiguration = switch value.row {
        case .project: .valueCell()
        case .ready, .issue: .explanatoryCell()
        default: .stackedValueCell()
        }
        content.text = value.text
        content.secondaryText = value.secondaryText
        content.secondaryTextProperties.color = .secondaryLabel
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .none
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .staticText
        cell.accessibilityCustomActions = nil
        switch value.row {
        case .project:
            break
        case let .package(target):
            content.image = UIImage(systemName: value.selected ? "checkmark.circle.fill" : "circle")
            content.imageProperties.tintColor = value.selected ? .tintColor : .tertiaryLabel
            cell.selectionStyle = .default
            cell.accessibilityTraits = value.selected ? [.button, .selected] : .button
            cell.accessoryView = shareButton(for: target)
            // the row is the element, so its Share button is reached as an action
            cell.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "Share Package")) { [weak self, weak cell] _ in
                    guard let self, let cell else { return false }
                    share(target, from: cell)
                    return true
                },
            ]
        case .publish:
            content.textProperties.color = value.enabled ? .tintColor : .tertiaryLabel
            cell.selectionStyle = value.enabled ? .default : .none
            cell.accessibilityTraits = value.enabled ? .button : [.button, .notEnabled]
        case .target:
            cell.accessoryType = value.selected ? .checkmark : .none
            cell.selectionStyle = .default
            cell.accessibilityTraits = value.selected ? [.button, .selected] : .button
        case .checking:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        case .ready:
            content.image = UIImage(systemName: "checkmark.seal.fill")
            content.imageProperties.tintColor = .systemGreen
        case .blocker:
            content.image = UIImage(systemName: "xmark.octagon.fill")
            content.imageProperties.tintColor = .systemRed
            content.textProperties.numberOfLines = 0
        case .issue:
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
        case .prepare:
            content.textProperties.color = .tintColor
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
        case .unavailable:
            content.textProperties.numberOfLines = 0
            content.textProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = content
        cell.accessibilityLabel = value.spokenText
            ?? [value.text, value.secondaryText].compactMap(\.self).joined(separator: ", ")
        cell.accessibilityValue = value.spokenValue
    }

    /// The Share button at a package row's trailing edge.
    private func shareButton(for target: BuildBootstrap) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        button.accessibilityLabel = String(localized: "Share Package")
        button.sizeToFit()
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let button else { return }
            share(target, from: button)
        }, for: .touchUpInside)
        return button
    }

    @objc private dynamic func updateRows() {
        let canBuild = method?.canBuild ?? true
        var readiness: [RowContent]
        if let blocker = method?.blocker {
            readiness = [RowContent(row: .unavailable, text: blocker)]
        } else if showsChecking {
            readiness = [RowContent(row: .checking, text: String(localized: "Checking…"))]
        } else if !hasCheckResult {
            readiness = []
        } else if let checkFailure {
            readiness = [RowContent(row: .unavailable, text: checkFailure)]
        } else if blockers.isEmpty, issues.isEmpty {
            readiness = [RowContent(
                row: .ready,
                text: String(localized: "Ready to distribute"),
                secondaryText: method == .script
                    ? String(localized: "The package is checked after the build script writes it.")
                    : nil,
            )]
        } else {
            readiness = blockers.indices.map { index in
                RowContent(row: .blocker(index), text: blockers[index].message)
            }
            readiness += issues.indices.map { index in
                RowContent(
                    row: .issue(index),
                    text: DistributionAdvice.title(of: issues[index]),
                    secondaryText: DistributionAdvice.advice(for: issues[index]),
                )
            }
            if onPrepare != nil {
                readiness.append(RowContent(row: .prepare, text: String(localized: "Ask Agent to Prepare")))
            }
        }
        var sections: [(Section, [RowContent])] = [
            (.project, [RowContent(row: .project, text: String(localized: "Project"), secondaryText: displayName ?? projectName)]),
        ]
        let listed = BuildBootstrap.allCases.compactMap { packages[$0] }
        if !listed.isEmpty {
            let rows = listed.map { package in
                let state = package.state.title
                return RowContent(
                    row: .package(package.bootstrap),
                    text: package.bootstrap.rawValue,
                    secondaryText: "\(package.version) · \(state)",
                    spokenText: "\(package.bootstrap.rawValue), \(package.version)",
                    spokenValue: state,
                    selected: selectedPackages.contains(package.artifactID),
                )
            }
            let canPublish = !isPreparingPackage && listed.contains { selectedPackages.contains($0.artifactID) }
            let publish = RowContent(row: .publish, text: String(localized: "Publish to Repository"), enabled: canPublish)
            sections.append((.packages, rows + [publish]))
        }
        if canBuild {
            sections.append((.target, BuildBootstrap.allCases.map { target in
                RowContent(row: .target(target), text: target.rawValue, selected: target == selectedTarget)
            }))
        }
        if !readiness.isEmpty {
            sections.append((.readiness, readiness))
        }
        dataSource.update(sections, reconfigure: true)
        navigationItem.rightBarButtonItem?.isEnabled = canBuild && blockers.isEmpty && !checking
            && checkFailure == nil && selectedTarget != nil
    }

    // MARK: - The check

    /// The distribution check for the chosen target (any, before one is
    /// chosen); a newer one replaces a check still running.
    @objc private dynamic func refreshCheck() {
        check?.cancel()
        loadingDelay?.cancel()
        checking = true
        showsChecking = false
        updateRows()
        loadingDelay = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard let self, !Task.isCancelled, checking else { return }
            showsChecking = true
            updateRows()
        }
        let target = selectedTarget
        check = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled {
                    loadingDelay?.cancel()
                    checking = false
                    showsChecking = false
                    hasCheckResult = true
                    updateRows()
                }
            }
            do {
                let project = try await DistributionProject.resolve(named: projectName)
                guard !Task.isCancelled else { return }
                method = project.method
                guard project.method.canBuild else {
                    blockers = []
                    issues = []
                    checkFailure = nil
                    return
                }
                let response = try await ApelinService.app.projectCheck(
                    projectID: project.id,
                    purpose: .distribution,
                    bootstrap: target,
                )
                guard !Task.isCancelled else { return }
                checkFailure = nil
                blockers = response.diagnostics.filter { $0.severity == .error }
                issues = response.diagnostics.filter { $0.code.hasPrefix("distribution.") && $0.severity != .error }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                blockers = []
                issues = []
                checkFailure = error.readableMessage
            }
        }
    }

    // MARK: - Packages

    /// The release packages of the version the manifest names now, and
    /// whether the linked repository holds each.
    @objc private dynamic func refreshPackages() {
        packageReader?.cancel()
        dataSource.beginLoad()
        packageReader = Task { [weak self] in
            guard let self else { return }
            var found: [BuildBootstrap: DistributionPackage] = [:]
            if let project = try? await DistributionProject.resolve(named: projectName), project.method.canBuild {
                // the link needs no network; a failure leaves every package unpublished
                let linked = try? await ApelinService.app.distributionRepositoryList(repositories: false).linked
                found = await DistributionPackages.newest(
                    projectID: project.id,
                    package: project.package,
                    isWorkspace: project.method == .script,
                    repository: linked,
                )
            }
            guard !Task.isCancelled else { return }
            show(found)
        }
    }

    /// A package seen for the first time is picked unless it is published
    /// already; one seen before keeps the reader's choice until it becomes
    /// published.
    private func show(_ found: [BuildBootstrap: DistributionPackage]) {
        let before = Dictionary(packages.values.map { ($0.artifactID, $0) }) { first, _ in first }
        selectedPackages = Set(found.values.filter { package in
            guard let earlier = before[package.artifactID] else { return !package.isPublished }
            return selectedPackages.contains(package.artifactID) && (earlier.isPublished || !package.isPublished)
        }.map(\.artifactID))
        packages = found
        updateRows()
    }

    private func share(_ target: BuildBootstrap, from anchor: UIView) {
        guard let package = packages[target], !isPreparingPackage, presentedViewController == nil else { return }
        isPreparingPackage = true
        Task { [weak self] in
            guard let self else { return }
            await DistributionPublishing.share(package.item, from: self, anchor: anchor) { [weak self] in
                self?.updateRows()
            }
            isPreparingPackage = false
        }
    }

    /// The selected packages, roothide's first, in one publish.
    @objc private dynamic func publish() {
        let chosen = BuildBootstrap.allCases.compactMap { packages[$0] }.filter { selectedPackages.contains($0.artifactID) }
        guard !chosen.isEmpty, !isPreparingPackage else { return }
        isPreparingPackage = true
        updateRows()
        Task { [weak self] in
            guard let self else { return }
            await DistributionPublishing.publish(chosen.map(\.item), from: self)
            isPreparingPackage = false
            updateRows()
        }
    }

    // MARK: - Actions

    @objc private dynamic func build() {
        guard !checking, checkFailure == nil, let target = selectedTarget, let method, method.canBuild, blockers.isEmpty else { return }
        let open = { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(
                DistributionBuildController(projectName: projectName, target: target, method: method),
                animated: true,
            )
        }
        // a version packaged before needs no question when its package is listed above
        let asked = issues.filter { $0.code != DistributionAdvice.versionPackaged || packages[target] == nil }
        guard !asked.isEmpty else {
            open()
            return
        }
        presentConfirmation(
            title: "Build Anyway?",
            message: "Some details still need attention before other people install this package.",
            confirmTitle: "Build",
            onConfirm: open,
        )
    }

    @objc private dynamic func prepare() {
        guard !checking, let onPrepare else { return }
        let prompt = if method == .script {
            String(localized: "Prepare this workspace for distribution: run apelin_project_check_distribution and fix everything it lists, and make sure its build script writes a release package for each target when APELIN_CONFIGURATION is release, with the package’s real name, identifier, author and a new version. Then tell me what you changed. Do not build yet.")
        } else if let target = selectedTarget {
            String(localized: "Prepare this project for distribution to \(target.rawValue): run apelin_project_check_distribution, fix everything it lists (the package’s name, description, author and version, its identifiers, and the app’s icon if it has one), then tell me what you changed. Do not build yet.")
        } else {
            String(localized: "Prepare this project for distribution: run apelin_project_check_distribution, fix everything it lists (the package’s name, description, author and version, its identifiers, and the app’s icon if it has one), then tell me what you changed. Do not build yet.")
        }
        dismiss(animated: true) { onPrepare(prompt) }
    }
}

/// The project folder's identity, read from its own manifest after the
/// folder is resolved inside `Projects/`.
enum DistributionProject {
    /// The project's ID; throws for one with nothing to build its package
    /// from, saying what it needs.
    static func id(named name: String) async throws -> String {
        let project = try await resolve(named: name)
        if let blocker = project.method.blocker {
            throw ApelinError(.badRequest, blocker)
        }
        return project.id
    }

    /// What the distribution pages read from a project's manifest.
    struct Manifest {
        var id: String
        /// How its package is built.
        var method: ProjectBuildMethod
        /// The package its description builds, and the version; nil for a
        /// workspace, whose script decides both, and a description that
        /// names neither.
        var package: (id: String, version: String)?
    }

    static func resolve(named name: String) async throws -> Manifest {
        try await Task.detached { () throws -> Manifest in
            guard let root = DataFolder.app.project(named: name), let canonical = CanonicalPath.resolve(root.path),
                  let projects = CanonicalPath.resolve(DataFolder.app.projects.path),
                  canonical == projects + "/" + name,
                  let manifest = CanonicalPath.resolve(root.appendingPathComponent("apelin-project.json").path),
                  manifest == canonical + "/apelin-project.json"
            else {
                throw ApelinError(.notFound, String(localized: "This project is no longer available."))
            }
            let value = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
            guard let id = value["projectID"]?.stringValue else {
                throw ApelinError(.notFound, String(localized: "This project is no longer available."))
            }
            let method = ProjectBuildMethod(manifest: value)
            var package: (id: String, version: String)?
            if method == .description, let packageID = value["package"]?["id"]?.stringValue,
               let version = value["package"]?["version"]?.stringValue
            {
                package = (packageID, version)
            }
            return Manifest(id: id, method: method, package: package)
        }.value
    }
}
