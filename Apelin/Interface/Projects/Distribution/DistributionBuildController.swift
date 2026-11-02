import ApelinCore
import ApelinProtocol
import Then
import UIKit

/// One release build for one distribution target, started as the page
/// opens: its stages while it runs, then Distribute for the one `.deb` it
/// made, or Retry. Distribute is the page's prominent action, and its menu
/// keeps the two ways out apart: Share Package hands the file to the share
/// sheet, Publish to Repository adds it to the linked package repository
/// and pushes it, or, with none linked, opens Settings ▸ Git, where
/// Publishing creates or links one. A workspace's build runs its own
/// script, and what the build finds in the package it wrote (a placeholder
/// identifier, a version packaged before, another package for the other
/// target) is listed under the outcome. The `…` menu holds the build's
/// whole log and, once the package is ready, the same two choices.
@MainActor
final class DistributionBuildController: TableController {
    private enum Stage: Int {
        case preparing, compiling, running, packaging, verifying, readyToDistribute

        /// apelin-build's own stages, or a workspace's script's
        /// (`ExternalBuild`: `script`, then `verify`).
        static func stages(for method: ProjectBuildMethod) -> [Stage] {
            method == .script ? [.preparing, .running, .verifying, .readyToDistribute] : [.preparing, .compiling, .packaging, .verifying, .readyToDistribute]
        }

        var title: String {
            switch self {
            case .preparing: String(localized: "Preparing")
            case .compiling: String(localized: "Compiling")
            case .running: String(localized: "Running Build Script")
            case .packaging: String(localized: "Packaging")
            case .verifying: String(localized: "Verifying Package")
            case .readyToDistribute: String(localized: "Ready to Distribute")
            }
        }

        init(event: String) {
            switch event {
            case "check": self = .preparing
            case "script": self = .running
            case "package": self = .packaging
            case "verify": self = .verifying
            default: self = .compiling
            }
        }
    }

    private enum Section: Hashable {
        case progress, outcome
    }

    private enum Row: Hashable {
        case stage(Stage), outcome, finding(Int)
    }

    private struct RowContent: Equatable {
        var row: Row
        var text: String?
        var secondaryText: String?
    }

    private let projectName: String
    private let target: BuildBootstrap
    private let method: ProjectBuildMethod
    private var stage = Stage.preparing
    private var artifact: BuildArtifact?
    /// The build's `distribution.*` warnings about the package it wrote.
    private var findings: [ProjectDiagnostic] = []
    private var work: Task<Void, Never>?
    private var outcome: String?
    private var finishedState: TaskState?
    private lazy var stepCells = Dictionary(uniqueKeysWithValues: Stage.stages(for: method).map { ($0, TaskStepCell(stage: String($0.rawValue))) })
    private var logLines: [String] = []
    private weak var logPage: TaskLogController?
    private var dataSource: TableDataSource<Section, Row, RowContent>!
    /// While the package is read back for Share Package or Publish to
    /// Repository: neither starts again until it is done.
    private var isPreparingPackage = false {
        didSet { distributeButton.isEnabled = !isPreparingPackage }
    }

    /// The menus read the page as they open, so neither is rebuilt when the
    /// build ends or a package is being read back.
    private lazy var distributeButton: UIBarButtonItem = .init(
        title: String(localized: "Distribute"),
        menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            completion(distributionActions(anchor: distributeButton))
        }]),
    ).then {
        // iOS 26's prominent style (the same value), a bold title before it
        $0.style = .done
    }

    private lazy var moreButton = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis"),
        menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreMenuElements() ?? [])
        }]),
    ).then { $0.accessibilityLabel = String(localized: "More") }

    /// Distribute's choices once there is a package, then the log.
    private func moreMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        if artifact != nil, work == nil {
            elements.append(UIMenu(options: .displayInline, children: distributionActions(anchor: moreButton)))
        }
        elements.append(UIAction(title: String(localized: "Build Log"), image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in
            self?.openLog()
        })
        return elements
    }

    /// Share Package and Publish to Repository; the share sheet points at
    /// `anchor`, the item whose menu they were chosen from.
    private func distributionActions(anchor: UIBarButtonItem) -> [UIMenuElement] {
        let attributes: UIMenuElement.Attributes = isPreparingPackage ? .disabled : []
        return [
            UIAction(
                title: String(localized: "Share Package"),
                image: UIImage(systemName: "square.and.arrow.up"),
                attributes: attributes,
            ) { [weak self, weak anchor] _ in
                guard let anchor else { return }
                self?.sharePackage(from: anchor)
            },
            UIAction(
                title: String(localized: "Publish to Repository"),
                image: UIImage(systemName: "shippingbox"),
                attributes: attributes,
            ) { [weak self] _ in
                self?.publish()
            },
        ]
    }

    init(projectName: String, target: BuildBootstrap, method: ProjectBuildMethod) {
        self.projectName = projectName
        self.target = target
        self.method = method
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(projectName:target:method:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = target.rawValue
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Build")
        dataSource = TableDataSource(
            tableView: tableView,
            identifier: { $0.row },
        ) { [weak self] tableView, indexPath, content in
            if case let .stage(stage) = content.row {
                return self?.stepCells[stage]
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "Build", for: indexPath)
            self?.configure(cell, value: content)
            return cell
        }
        dataSource.headerTitle = { section in
            section == .progress ? String(localized: "Steps") : nil
        }
        start()
    }

    // MARK: - Rows

    private func configure(_ cell: UITableViewCell, value: RowContent) {
        var content: UIListContentConfiguration = switch value.row {
        case .finding: .explanatoryCell()
        default: .stackedValueCell()
        }
        content.text = value.text
        content.secondaryText = value.secondaryText
        content.secondaryTextProperties.color = .secondaryLabel
        cell.accessoryView = nil
        cell.selectionStyle = .none
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .staticText
        cell.accessibilityValue = nil
        switch value.row {
        case .stage:
            break
        case .outcome:
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
            if finishedState == .failed || finishedState == .cancelled {
                content.image = UIImage(systemName: finishedState == .cancelled ? "stop.circle.fill" : "exclamationmark.triangle.fill")
                content.imageProperties.tintColor = finishedState == .cancelled ? .secondaryLabel : .systemRed
            }
        case .finding:
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
        }
        cell.contentConfiguration = content
        cell.accessibilityLabel = [value.text, value.secondaryText].compactMap(\.self).joined(separator: ", ")
    }

    private func updateRows() {
        for item in Stage.stages(for: method) {
            let state: EnvironmentTaskProgress.StageState = if finishedState == .succeeded || item.rawValue < stage.rawValue {
                .done
            } else if item == stage {
                finishedState == nil ? .running(nil) : .failed
            } else {
                .pending
            }
            let status: String = switch state {
            case .done: String(localized: "Completed")
            case .running: String(localized: "In Progress")
            case .failed: finishedState == .cancelled ? String(localized: "Stopped") : String(localized: "Failed")
            default: finishedState == nil ? String(localized: "Waiting") : String(localized: "Not Started")
            }
            stepCells[item]?.show(state, status: status, animated: tableView.window != nil && !UIAccessibility.isReduceMotionEnabled, title: item.title)
        }
        var sections: [(Section, [RowContent])] = [
            (.progress, Stage.stages(for: method).map { item in
                RowContent(
                    row: .stage(item),
                    text: item.title,
                )
            }),
        ]
        if let outcome {
            let title = switch finishedState {
            case .succeeded: String(localized: "Completed")
            case .cancelled: String(localized: "Stopped")
            default: String(localized: "Failed")
            }
            var rows: [RowContent] = finishedState == .succeeded ? [] : [RowContent(row: .outcome, text: title, secondaryText: EnvironmentTaskProgress.readableDetail(outcome))]
            rows += findings.indices.map { index in
                RowContent(
                    row: .finding(index),
                    text: DistributionAdvice.title(of: findings[index]),
                    secondaryText: DistributionAdvice.advice(for: findings[index]),
                )
            }
            if !rows.isEmpty {
                sections.append((.outcome, rows))
            }
        }
        dataSource.update(sections, reconfigure: true)
    }

    private func updateNavigation() {
        let running = work != nil
        navigationController?.isModalInPresentation = running
        navigationItem.hidesBackButton = running
        let primary: UIBarButtonItem = if running {
            UIBarButtonItem(
                title: String(localized: "Stop"),
                primaryAction: UIAction { [weak self] _ in self?.work?.cancel() },
            )
        } else if artifact != nil {
            distributeButton
        } else {
            UIBarButtonItem(
                title: String(localized: "Retry"),
                primaryAction: UIAction { [weak self] _ in self?.start() },
            )
        }
        // the right bar's items run from the trailing edge in
        navigationItem.rightBarButtonItems = [primary, moreButton]
    }

    // MARK: - The build

    private func start() {
        guard work == nil else { return }
        artifact = nil
        outcome = nil
        finishedState = nil
        findings = []
        stage = .preparing
        logLines = []
        logPage?.update(logLines)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await DistributionProject.id(named: projectName)
                try Task.checkCancellation()
                artifact = try await build(projectID: id)
                finishedState = .succeeded
                outcome = String(localized: "The package is ready to export.")
                StarPrompt.buildsCompleted(1, from: self)
            } catch is CancellationError {
                finishedState = .cancelled
                outcome = String(localized: "Distribution stopped. You can try again.")
            } catch {
                finishedState = .failed
                outcome = error.readableMessage
            }
            work = nil
            updateNavigation()
            updateRows()
        }
        updateNavigation()
        updateRows()
    }

    private func build(projectID: String) async throws -> BuildArtifact {
        let handle = try await ApelinService.app.buildStart(
            projectID: projectID,
            configuration: .release,
            bootstrap: target,
        )
        return try await withTaskCancellationHandler {
            var artifact: BuildArtifact?
            var succeeded = false
            var failure: String?
            for try await event in ApelinService.app.events(of: handle) {
                try Task.checkCancellation()
                record(event)
                if event.kind == "stage", let name = event.payload?["stage"]?.stringValue {
                    let next = Stage(event: name)
                    if next != stage {
                        stage = next
                        updateRows()
                    }
                } else if event.kind == "artifact" {
                    // persisted-read: a live task event, not saved data
                    artifact = try event.payload?.decode(BuildArtifact.self)
                } else if event.kind == "diagnostic",
                          let finding = try? event.payload?.decode(ProjectDiagnostic.self),
                          finding.code.hasPrefix("distribution.")
                {
                    findings.append(finding)
                } else if event.kind == TaskEvent.stateKind {
                    succeeded = event.payload?["state"]?.stringValue == TaskState.succeeded.rawValue
                    failure = event.payload?["message"]?.stringValue
                }
            }
            try Task.checkCancellation()
            guard succeeded, let artifact, artifact.bootstrap == target.rawValue else {
                throw ApelinError(
                    .internal,
                    failure ?? (method == .script
                        ? String(localized: "The package could not be built. Check the build script’s log and try again.")
                        : String(localized: "The package could not be built. Check the project’s build description and try again.")),
                )
            }
            return artifact
        } onCancel: {
            Task { try? await ApelinService.app.buildCancel(taskID: handle.taskID) }
        }
    }

    /// The build's own words for the log: its stages, log lines and
    /// diagnostics, and how it ended.
    private func record(_ event: TaskEvent) {
        let line: String? = switch event.kind {
        case "stage": event.payload?["stage"]?.stringValue.map { "▸ " + $0 }
        case "log": event.payload?["line"]?.stringValue
        case "diagnostic": event.payload?["message"]?.stringValue
        case TaskEvent.stateKind:
            [event.payload?["state"]?.stringValue, event.payload?["message"]?.stringValue]
                .compactMap(\.self).joined(separator: ": ")
        default: nil
        }
        guard let line else { return }
        logLines.append(line)
        logPage?.update(logLines)
    }

    private func openLog() {
        let page = TaskLogController(lines: logLines)
        logPage = page
        navigationController?.pushViewController(page, animated: true)
    }

    /// The package this build made, as sharing and publishing take it.
    private var item: DistributionPublishing.Item? {
        guard let artifact, artifact.bootstrap == target.rawValue else { return nil }
        return DistributionPublishing.Item(
            path: artifact.path,
            digest: artifact.digest,
            packageID: artifact.packageID,
            version: artifact.version,
            bootstrap: target,
        )
    }

    private func sharePackage(from anchor: UIBarButtonItem) {
        guard let item, work == nil, !isPreparingPackage else { return }
        isPreparingPackage = true
        Task { [weak self] in
            guard let self else { return }
            await DistributionPublishing.share(item, from: self, anchor: anchor)
            isPreparingPackage = false
        }
    }

    private func publish() {
        guard let item, work == nil, !isPreparingPackage else { return }
        isPreparingPackage = true
        Task { [weak self] in
            guard let self else { return }
            await DistributionPublishing.publish([item], from: self)
            isPreparingPackage = false
        }
    }
}
