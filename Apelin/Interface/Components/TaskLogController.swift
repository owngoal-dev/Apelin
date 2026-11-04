import SnapKit
import Then
import UIKit

/// Every line a task said, in order: the page behind a task's menu, for
/// whoever wants the whole account. Irisin's operation log: a number and a
/// monospaced line each, following the end while the task runs and reading
/// the same once it is over. The share button hands the text on.
final class TaskLogController: UIViewController {
    private let tableView = FirstFillTableView(frame: .zero, style: .plain)
    @objc private dynamic var lines: [String]
    /// A refresh asked for while one is waiting is folded into it: lines
    /// arrive in bursts while a download counts.
    @objc private dynamic var refreshPending = false
    @objc private dynamic var displayedLines: [String] = []
    private let pacing = ListPacing()

    private lazy var dataSource = UITableViewDiffableDataSource<Int, Int>(
        tableView: tableView,
    ) { [weak self] table, indexPath, line in
        let cell = table.dequeueReusableCell(withIdentifier: TaskLogCell.reuseIdentifier, for: indexPath)
        (cell as? TaskLogCell)?.configure(
            number: line + 1,
            message: self.flatMap { $0.lines.indices.contains(line) ? $0.lines[line] : nil } ?? "",
        )
        return cell
    }

    init(lines: [String]) {
        self.lines = lines
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(lines:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Full Log")
        view.backgroundColor = .pageBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .action,
            primaryAction: UIAction { [weak self] _ in self?.share() },
        ).then { $0.accessibilityLabel = String(localized: "Share Log") }

        tableView.backgroundColor = .pageBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 28
        tableView.separatorStyle = .none
        tableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 20, right: 0)
        tableView.allowsSelection = false
        tableView.register(TaskLogCell.self, forCellReuseIdentifier: TaskLogCell.reuseIdentifier)
        view.addSubview(tableView)
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        apply()
    }

    /// The task's lines so far; the table catches up at most ten times a
    /// second and always ends on the latest.
    @objc dynamic func update(_ lines: [String]) {
        self.lines = lines
        guard isViewLoaded, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshPending = false
            self?.apply()
        }
    }

    @objc private dynamic func share() {
        let share = UIActivityViewController(activityItems: [lines.joined(separator: "\n")], applicationActivities: nil)
        share.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(share, animated: true)
    }

    /// Follows the end only while the end is in sight and nobody is
    /// scrolling: reading back up is not interrupted.
    @objc private dynamic func apply() {
        let previous = dataSource.snapshot()
        let lastVisible = previous.itemIdentifiers.last.map {
            tableView.indexPathsForVisibleRows?.contains(IndexPath(row: $0, section: 0)) == true
        } ?? true
        let follow = lastVisible && !tableView.isTracking && !tableView.isDecelerating
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        // a row is its position: the same line can be said twice
        snapshot.appendItems(Array(lines.indices))
        let changed = lines.indices.filter { displayedLines.indices.contains($0) && displayedLines[$0] != lines[$0] }
        guard !tableView.isFilled || displayedLines != lines else { return }
        snapshot.reconfigureItems(changed)
        displayedLines = lines
        let animated = tableView.isFilled && pacing.animatesChange(in: tableView)
        let last = snapshot.itemIdentifiers.last
        let scroll = { [weak self] in
            guard let self, follow, !tableView.isTracking, !tableView.isDecelerating,
                  let last, let indexPath = dataSource.indexPath(for: last) else { return }
            tableView.scrollToRow(at: indexPath, at: .bottom, animated: animated)
        }
        if tableView.isFilled {
            dataSource.applyChange(snapshot, to: tableView, animated: animated, completion: scroll)
        } else {
            pacing.begin()
            dataSource.applyFirst(snapshot, to: tableView, completion: scroll)
        }
    }
}

/// A log line: its number in a narrow column, the text beside it.
private final class TaskLogCell: UITableViewCell {
    static let reuseIdentifier = "log"

    private let numberLabel = UILabel()
    private let messageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .pageBackground
        selectionStyle = .none
        numberLabel.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular,
        )
        numberLabel.textColor = .secondaryLabel
        numberLabel.textAlignment = .right
        messageLabel.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular,
        )
        messageLabel.textColor = .label
        messageLabel.numberOfLines = 0
        contentView.addSubview(numberLabel)
        contentView.addSubview(messageLabel)
        numberLabel.snp.makeConstraints { x in
            x.leading.equalToSuperview().inset(12)
            x.width.equalTo(32)
            x.firstBaseline.equalTo(messageLabel)
        }
        messageLabel.snp.makeConstraints { x in
            x.leading.equalTo(numberLabel.snp.trailing).offset(12)
            x.trailing.equalToSuperview().inset(20)
            x.top.bottom.equalToSuperview().inset(5)
        }
        // the line is the row; its number is only drawn
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(style:reuseIdentifier:)")
    }

    @objc dynamic func configure(number: Int, message: String) {
        numberLabel.text = String(number)
        messageLabel.text = message
        accessibilityLabel = message
    }

    /// The number stands against the line it numbers: on its right left
    /// to right, on its left right to left.
    override func layoutSubviews() {
        super.layoutSubviews()
        numberLabel.textAlignment = laysOutRightToLeft ? .left : .right
    }
}
