import SnapKit
import UIKit

/// One journal read back as rows — a launch's, or the one the agent writes
/// for a conversation: Irisin's log page, given a file (`JournalFile`) in
/// place of Dog's current one. The search field keeps the entries whose
/// text has what is typed, so a tool call is found by its ID.
///
/// The file is parsed once into `parsed` and filtered from there, so a filter
/// change costs a filter rather than a re-parse. The running launch's file,
/// and a conversation's, which its agent may be writing, are followed while
/// the screen is up: the poll compares the file's size, and only a file that
/// changed is read again, a conversation's with the file it rotated into. An
/// earlier launch's file no longer changes and is read once.
final class LogViewerController: UIViewController, UITableViewDelegate, UISearchResultsUpdating {
    let tableView = FirstFillTableView(frame: .zero, style: .plain)
    let file: JournalFile
    /// The running launch's: followed, and Clear hides what it holds so far.
    let isCurrent: Bool
    let pacing = ListPacing()
    /// The page's name: when the launch began, or the conversation's.
    private let pageTitle: String

    /// Every line in the file, filters not yet applied.
    var parsed: [JournalLine] = []
    /// What the table is showing.
    var shown: [JournalLine] = []

    var selectedLevels = Set(JournalLevel.allCases)
    var selectedCategories: Set<String> = []
    /// What the search field holds; empty keeps every entry.
    private var searchText = ""
    var allCategories: Set<String> {
        Set(parsed.map(\.category))
    }

    /// Characters Clear hid from the top of the file.
    var hiddenPrefixCount = 0

    /// Size of the file at the last parse, so the poll can skip a file that
    /// has not moved.
    var lastReadLength = -1
    private var tail: Timer?
    /// The first parse, off the main actor from init; nil once the rows are
    /// in `parsed`.
    var work: Task<Void, Never>?

    init(file: JournalFile, isCurrent: Bool, title: String) {
        self.file = file
        self.isCurrent = isCurrent
        pageTitle = title
        super.init(nibName: nil, bundle: nil)
        lastReadLength = fileLength
        work = Task { [weak self] in
            let lines = await Task.detached {
                JournalLines.parse(LogViewerController.text(of: file, hiding: 0))
            }.value
            guard let self, !Task.isCancelled else { return }
            work = nil
            parsed = lines
            if isViewLoaded {
                applyFilters(stickToBottom: true)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(file:isCurrent:title:)")
    }

    /// A line's place in the log is its identity: the same text can be
    /// written twice and both rows have to exist.
    struct Row: Hashable, Sendable {
        let index: Int
        let line: JournalLine
    }

    lazy var dataSource = UITableViewDiffableDataSource<Int, Row>(tableView: tableView) { tableView, _, row in
        let id = "LogCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)
        Self.configure(cell, with: row.line)
        return cell
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = pageTitle
        view.backgroundColor = .pageBackground
        navigationItem.largeTitleDisplayMode = .never

        setupNavigationItems()
        setupSearch()
        setupTableView()
        // rows already parsed go up with the view; otherwise the first
        // parse applies them when it lands
        if work == nil {
            applyFilters(stickToBottom: true)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard isCurrent || file.sessionID != nil else { return }
        // The running launch writes while it is being read, and so may a
        // conversation's agent. A sheet
        // dismissed over this screen appears it again without ever
        // disappearing it: the previous timer goes first.
        tail?.invalidate()
        tail = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfFileGrew() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        tail?.invalidate()
        tail = nil
    }

    private func setupTableView() {
        tableView.dataSource = dataSource
        tableView.delegate = self
        tableView.estimatedRowHeight = 60
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .singleLine
        tableView.backgroundColor = .pageBackground
        tableView.keyboardDismissMode = .onDrag
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func setupSearch() {
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = String(localized: "Search")
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard text != searchText else { return }
        searchText = text
        applyFilters(stickToBottom: false)
    }

    /// `growing` for new lines from the file, which may animate in a list
    /// that sat still (`ListPacing`); a filter, a search or Clear shows
    /// other rows and never does.
    func applyFilters(stickToBottom: Bool, growing: Bool = false) {
        shown = parsed.filter { line in
            selectedLevels.contains(line.level)
                && (selectedCategories.isEmpty || selectedCategories.contains(line.category))
                && (searchText.isEmpty || line.fullText.localizedCaseInsensitiveContains(searchText))
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(shown.enumerated().map { Row(index: $0.offset, line: $0.element) })
        guard tableView.isFilled else {
            pacing.begin()
            dataSource.applyFirst(snapshot, to: tableView) { [weak self] in
                if stickToBottom {
                    self?.scrollToBottom(animated: false)
                }
            }
            return
        }
        if !growing {
            pacing.begin()
        }
        let animated = pacing.animatesChange(in: tableView)
        dataSource.applyChange(snapshot, to: tableView, animated: animated) { [weak self] in
            if stickToBottom {
                self?.scrollToBottom(animated: animated)
            }
        }
    }

    /// Following the file must not fight someone reading further up, so new
    /// lines only pull the view down when it was already at the end.
    var isNearBottom: Bool {
        guard tableView.contentSize.height > tableView.bounds.height else { return true }
        let distance = tableView.contentSize.height
            - tableView.contentOffset.y
            - tableView.bounds.height
            + tableView.adjustedContentInset.bottom
        return distance < 60
    }

    private func scrollToBottom(animated: Bool) {
        guard !shown.isEmpty, !tableView.isTracking, !tableView.isDecelerating else { return }
        tableView.scrollToRow(at: IndexPath(row: shown.count - 1, section: 0), at: .bottom, animated: animated)
    }

    private static func configure(_ cell: UITableViewCell, with logLine: JournalLine) {
        var content = UIListContentConfiguration.subtitleCell()
        let font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular,
        )
        content.text = logLine.message
        content.textProperties.font = font
        content.textProperties.numberOfLines = 0
        content.secondaryText = logLine.timestamp.isEmpty
            ? logLine.category
            : "\(logLine.timestamp) • \(logLine.category)"
        content.secondaryTextProperties.font = font
        content.secondaryTextProperties.numberOfLines = 1

        switch logLine.level {
        case .verbose:
            content.textProperties.color = .logVerbose
            content.secondaryTextProperties.color = .logVerboseDetail
            cell.backgroundColor = .pageBackground
        case .info:
            content.textProperties.color = .label
            content.secondaryTextProperties.color = .secondaryLabel
            cell.backgroundColor = .pageBackground
        case .warning:
            content.textProperties.color = .logProblem
            content.secondaryTextProperties.color = .logProblemDetail
            cell.backgroundColor = .pageBackground
        case .error:
            content.textProperties.color = .logProblem
            content.secondaryTextProperties.color = .logProblemDetail
            cell.backgroundColor = .logErrorBackground
        case .critical:
            content.textProperties.color = .logProblem
            content.secondaryTextProperties.color = .logProblemDetail
            cell.backgroundColor = .logCriticalBackground
        }

        cell.contentConfiguration = content
        cell.selectionStyle = .none
        // the level is drawn only in colour: spoken first in the value,
        // before when and where the line was written
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = logLine.message
        cell.accessibilityValue = [name(of: logLine.level), content.secondaryText ?? ""].joined(separator: ", ")
    }
}
