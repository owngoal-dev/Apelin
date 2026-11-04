import ApelinCore
import ApelinProtocol
import SnapKit
import Then
import UIKit

/// An environment task with stable step names and status values. Transfer
/// figures have their own rows; technical details remain in the full log.
///
/// The session host owns the task, not this page: leaving it, or the app,
/// stops nothing, and the page opened again replays the task from its first
/// event. Stop, in the menu, is what ends it.
final class EnvironmentTaskController: TableController {
    /// Told once, when the task has ended, so the page beneath reads its
    /// list again.
    @objc dynamic var onFinish: (() -> Void)?

    private enum Section: Hashable {
        case summary
        case transfer
        case stages
        case outcome
        case warnings
    }

    private enum Row: Equatable {
        case value(id: String, title: String, value: String)
        case stage(String)
        case outcome(String?, String?, TaskState)
        case warning(String, occurrence: Int)
        var id: String {
            switch self {
            case let .value(id, _, _): id
            case let .stage(stage): "stage:" + stage
            case .outcome: "outcome"
            case let .warning(text, occurrence): "warning:\(occurrence):" + text
            }
        }
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private let handle: TaskHandle
    private let runningTitle: String
    private let doneTitle: String
    private let showsDownload: Bool
    private let showsStatusSummary: Bool
    private var progress: EnvironmentTaskProgress
    private var follower: Task<Void, Never>?
    @objc private dynamic var cancelRequested = false

    /// One cell per stage, kept rather than dequeued, so a ring goes on
    /// turning from one event to the next.
    @objc private dynamic var stageCells: [TaskStepCell] = []

    /// Every event as a line, for the full log; a download's progress is
    /// one line said again with new figures, not a line per sample.
    private var logLines: [String] = []
    @objc private dynamic var lastLogKey: String?
    @objc private dynamic weak var logPage: TaskLogController?

    private static let logTime = DateFormatter().then {
        $0.dateFormat = "HH:mm:ss"
    }

    /// `doneTitle` is the page's title once the task succeeded:
    /// "Toolchain Ready", "SDK Imported".
    init(handle: TaskHandle, work: EnvironmentTaskProgress.Work, title: String, doneTitle: String) {
        self.handle = handle
        runningTitle = title
        self.doneTitle = doneTitle
        showsDownload = work.includesDownload
        showsStatusSummary = work != .toolchainSetup && work != .transferImport(.toolchain)
        progress = EnvironmentTaskProgress(work: work)
        super.init(style: .insetGrouped)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(handle:work:title:doneTitle:)")
    }

    deinit {
        follower?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
        tableView.allowsSelection = false
        logLines = ["Task ID: \(handle.taskID.rawValue)"]
        dataSource.headerTitle = { [weak self] in
            switch $0 {
            case .stages: String(localized: "Steps")
            case .transfer: self?.showsStatusSummary == false ? nil : String(localized: "Download")
            case .warnings: String(localized: "Warnings")
            default: nil
            }
        }
        render()
        follow()
    }

    // MARK: - Following

    /// Replays the task from its first event and reads on until it ends.
    /// A dropped connection is the same call again from the last event: the
    /// stream ends with an error, and the next attach picks up after it. A
    /// task the host does not have, or will not show, ends the page.
    @objc private dynamic func follow() {
        follower = Task { [weak self, handle] in
            var cursor = EventSeq.start
            while !Task.isCancelled {
                do {
                    for try await event in ApelinService.app.events(of: handle, afterSeq: cursor) {
                        cursor = event.seq
                        self?.receive(event)
                    }
                    return
                } catch {
                    if Task.isCancelled {
                        return
                    }
                    if let error = error as? ApelinError, error.code.endsTaskFollowing {
                        self?.lose(error)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func receive(_ event: TaskEvent) {
        let wasFinished = progress.isFinished
        log(event)
        progress.apply(event)
        render()
        if progress.isFinished, !wasFinished {
            finished()
        }
    }

    /// `12:04:31  progress  {"completed":…}`: the time, the kind and what
    /// it carried, as the host wrote it.
    private func log(_ event: TaskEvent) {
        var line = Self.logTime.string(from: event.time) + "  " + event.kind
        if let payload = event.payload,
           let data = try? JSONEncoder().then({
               $0.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
           }).encode(payload),
           let text = String(data: data, encoding: .utf8)
        {
            line += "  " + text
        }
        let key = event.kind == "progress"
            ? "progress " + (event.payload?["stage"]?.stringValue ?? "")
            + " " + (event.payload?["phase"]?.stringValue ?? "")
            : nil
        if let key, key == lastLogKey, !logLines.isEmpty {
            logLines[logLines.count - 1] = line
        } else {
            logLines.append(line)
        }
        lastLogKey = key
        logPage?.update(logLines)
    }

    @objc private dynamic func openLog() {
        let page = TaskLogController(lines: logLines)
        logPage = page
        navigationController?.pushViewController(page, animated: true)
    }

    @objc private dynamic func lose(_ error: Error) {
        guard !progress.isFinished else { return }
        progress.lost(error.readableMessage)
        render()
        finished()
    }

    @objc private dynamic func finished() {
        onFinish?()
        onFinish = nil
        UIAccessibility.post(notification: .announcement, argument: progress.state == .succeeded ? doneTitle : statusTitle)
    }

    // MARK: - Drawing

    @objc private dynamic func render() {
        let finished = progress.isFinished
        title = runningTitle
        // the items are made once and swapped only when the task ends: a
        // menu whose item is replaced under it closes, or never opens
        if navigationItem.rightBarButtonItems == nil || barShowsFinished != finished {
            barShowsFinished = finished
            let running = isSheetRoot ? backgroundBarItem : spinnerBarItem
            if finished {
                navigationItem.rightBarButtonItems = progress.state == .succeeded
                    ? [doneBarItem, menuBarItem] : [menuBarItem]
            } else {
                navigationItem.rightBarButtonItems = [running, menuBarItem]
            }
        }

        let stages = progress.shownStages
        let structureChanged = stageCells.map(\.stage) != stages
        let existing = Dictionary(uniqueKeysWithValues: stageCells.map { ($0.stage, $0) })
        stageCells = stages.map { existing[$0] ?? TaskStepCell(stage: $0) }
        for cell in stageCells {
            cell.show(
                progress.state(of: cell.stage),
                status: status(of: cell.stage),
                animated: !structureChanged && !UIAccessibility.isReduceMotionEnabled,
            )
        }
        var sections: [(Section, [Row])] = []
        if showsStatusSummary {
            sections.append((.summary, [
                .value(id: "status", title: String(localized: "Status"), value: statusTitle),
            ]))
        }
        if showsDownload {
            let amount: String
            if let bytes = progress.downloadedBytes {
                let completed = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                amount = progress.downloadTotalBytes.map {
                    String(localized: "\(completed) of \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))")
                } ?? completed
            } else {
                amount = "—"
            }
            let speed = !finished && progress.isDownloading ? progress.bytesPerSecond.map {
                String(localized: "\(ByteCountFormatter.string(fromByteCount: Int64(max(0, $0)), countStyle: .file))/s")
            } ?? "—" : "—"
            sections.append((.transfer, [
                .value(id: "downloaded", title: String(localized: "Downloaded"), value: amount),
                .value(id: "speed", title: String(localized: "Speed"), value: speed),
            ]))
        }
        sections.append((.stages, stages.map(Row.stage)))
        if finished, progress.state != .succeeded {
            sections.append((.outcome, [.outcome(statusTitle, EnvironmentTaskProgress.readableDetail(progress.outcomeMessage), progress.state)]))
        }
        if !progress.warnings.isEmpty {
            var occurrences: [String: Int] = [:]
            let rows = progress.warnings.map { warning in
                let text = EnvironmentTaskProgress.readableDetail(warning)
                let occurrence = occurrences[text, default: 0]
                occurrences[text] = occurrence + 1
                return Row.warning(text, occurrence: occurrence)
            }
            sections.append((.warnings, rows))
        }
        // Value rows create cells on demand; reconfiguration requires returning the same cell.
        // Reload changed rows instead. Stage cells keep their existing progress rings.
        dataSource.update(sections, animatingDifferences: false)
    }

    @objc private dynamic var statusTitle: String {
        switch progress.state {
        case .queued: String(localized: "Waiting")
        case .running: String(localized: "In Progress")
        case .waitingForApproval: String(localized: "Waiting for Approval")
        case .succeeded: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Stopped")
        case .interrupted: String(localized: "Interrupted")
        }
    }

    /// A step value always describes its state, never its transfer figures.
    @objc private dynamic func status(of stage: String) -> String {
        switch progress.state(of: stage) {
        case .pending: progress.isFinished ? String(localized: "Not Started") : String(localized: "Waiting")
        case .skipped: String(localized: "Skipped")
        case .done: String(localized: "Completed")
        case .failed:
            progress.state == .cancelled ? String(localized: "Stopped") : String(localized: "Failed")
        case .running: String(localized: "In Progress")
        }
    }

    /// Whether the bar holds the finished task's items.
    @objc private dynamic var barShowsFinished = false
    @objc private dynamic lazy var spinnerBarItem = spinnerItem()
    @objc private dynamic lazy var doneBarItem = doneItem()
    /// Closes the sheet; the task is the host's and goes on.
    @objc private dynamic lazy var backgroundBarItem = UIBarButtonItem(
        title: String(localized: "Continue in Background"),
        primaryAction: UIAction { [weak self] _ in self?.leave() },
    )

    @objc private dynamic var isSheetRoot: Bool {
        navigationController?.viewControllers.first === self
    }

    @objc private dynamic lazy var menuBarItem = menuItem()

    @objc private dynamic func spinnerItem() -> UIBarButtonItem {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.isAccessibilityElement = true
        spinner.accessibilityLabel = String(localized: "In Progress")
        spinner.startAnimating()
        return UIBarButtonItem(customView: spinner)
    }

    @objc private dynamic func doneItem() -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            primaryAction: UIAction { [weak self] _ in self?.leave() },
        ).then {
            $0.style = .done
            $0.accessibilityLabel = String(localized: "Done")
        }
    }

    @objc private dynamic func menuItem() -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuElements() ?? [])
            }]),
        ).then { $0.accessibilityLabel = String(localized: "More") }
    }

    @objc private dynamic func menuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = [
            UIAction(
                title: String(localized: "View Full Log"),
                image: UIImage(systemName: "text.alignleft"),
            ) { [weak self] _ in
                self?.openLog()
            },
        ]
        if !progress.isFinished {
            elements.append(UIMenu(options: .displayInline, children: [UIAction(
                title: String(localized: "Stop"),
                image: UIImage(systemName: "stop.circle"),
                attributes: cancelRequested ? [.destructive, .disabled] : .destructive,
            ) { [weak self] _ in self?.confirmStop() }]))
        }
        return elements
    }

    // MARK: - Table

    private func cell(for row: Row) -> UITableViewCell? {
        switch row {
        case let .value(_, title, value):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            var content = UIListContentConfiguration.valueCell()
            content.text = title
            content.secondaryText = value
            cell.contentConfiguration = content
            return cell
        case let .stage(stage):
            return stageCells.first { $0.stage == stage }
        case let .outcome(title, message, state):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.stackedValueCell()
            content.text = title
            content.secondaryText = message

            content.secondaryTextProperties.color = .secondaryLabel

            content.image = UIImage(
                systemName: state == .cancelled ? "stop.circle.fill" : "exclamationmark.triangle.fill",
            )
            content.imageProperties.tintColor = state == .cancelled ? .secondaryLabel : .systemRed
            cell.contentConfiguration = content
            return cell
        case let .warning(text, _):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.cell()
            content.text = text
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemOrange
            cell.contentConfiguration = content
            return cell
        }
    }

    /// Done: back to the page beneath, or — the root of a sheet of its own,
    /// as an import opened from another app is — the sheet closes.
    @objc private dynamic func leave() {
        guard let navigation = navigationController else { return }
        if navigation.viewControllers.first === self {
            navigation.dismiss(animated: true)
        } else {
            navigation.popViewController(animated: true)
        }
    }

    // MARK: - Stopping

    @objc private dynamic func confirmStop() {
        presentConfirmation(
            title: "Stop This Task?",
            message: "Progress so far is discarded. Starting again begins from scratch.",
            confirmTitle: "Stop",
            destructive: true,
        ) { [weak self] in
            self?.stop()
        }
    }

    @objc private dynamic func stop() {
        cancelRequested = true
        Task { [weak self, handle] in
            do {
                try await ApelinService.app.environmentCancel(taskID: handle.taskID)
            } catch {
                guard let self else { return }
                cancelRequested = false
                presentNotice(title: "Unable to Stop", message: error.readableMessage)
            }
        }
    }
}

/// A stage's name and status ring on one line.
final class TaskStepCell: UITableViewCell {
    let stage: String
    private let ring = ProgressRing()

    init(stage: String) {
        self.stage = stage
        super.init(style: .default, reuseIdentifier: nil)
        ring.frame = CGRect(origin: .zero, size: ring.intrinsicContentSize)
        accessoryView = ring
        selectionStyle = .none
        // one stop a row: the name, then what it is doing as the value
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(stage:)")
    }

    func show(_ state: EnvironmentTaskProgress.StageState, status: String, animated: Bool, title: String? = nil) {
        var content = UIListContentConfiguration.cell()
        content.text = title ?? EnvironmentTaskProgress.title(of: stage)
        content.textProperties.color = state == .pending || state == .skipped ? .secondaryLabel : .label
        content.textProperties.numberOfLines = 1
        contentConfiguration = content

        let appearance: ProgressRing.Appearance
        switch state {
        case .pending:
            appearance = .waiting
        case .skipped:
            appearance = .skipped
        case let .running(fraction):
            ring.tintColor = .tintColor
            appearance = fraction.map { .progress($0) } ?? .working(0)
        case .done:
            ring.tintColor = .systemGreen
            appearance = .glyph("checkmark.circle.fill")
        case .failed:
            ring.tintColor = .systemRed
            appearance = .glyph("info.circle.fill")
        }
        ring.set(appearance, animated: animated)
        accessibilityLabel = content.text
        accessibilityValue = status
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
