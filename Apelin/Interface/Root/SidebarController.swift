import SnapKit
import Then
import UIKit

/// The sidebar: beside the detail column when the window is wide, a
/// drawer under it when narrow (`RootInterfaceController`). Its bar: the open project's name as a plain title,
/// a folder menu that switches projects or opens the picker, and
/// a plus whose menu starts a conversation or makes a new project,
/// with a search field under it that a
/// pull on the list brings out; the button that hides the sidebar is on
/// the detail column's bar. With no project open the title is Apelin's,
/// with no menu, and a new conversation is a temporary one, kept apart from
/// every project's. Below it the project's conversations, a plain inset
/// grouped table: the pinned ones, then the rest under the day the reader
/// last started or wrote in each (`SidebarOrder`). At the bottom a new
/// conversation on the left, and Projects beside Settings on the right:
/// glass on iOS 26, the toolbar's blur before it.
final class SidebarController: UIViewController {
    private enum Section: Hashable {
        case pinned
        case day(Date)
    }

    /// The conversation to show, as it is picked, made or deleted: nil when
    /// none is left picked. `picked` when the reader chose it, by its row or
    /// New Chat, which puts a drawer away; a conversation that follows a
    /// project switch, a deletion or the launch changes behind it.
    var onSelect: ((ChatSummary?, _ picked: Bool) -> Void)?
    var onProjectsLoaded: (() -> Void)?
    /// A message to send in the conversation just picked, as if typed.
    var onSendPrompt: ((String) -> Void)?
    private(set) var hasLoadedProjects = false
    var runtime: ChatRuntime!

    func select(_ summary: ChatSummary) {
        if project?.name != summary.projectName {
            project = summary.projectName.map { name in
                projects.first { $0.name == name } ?? ProjectSummary(name: name, kind: .workspace)
            }
        }
        UserDefaults.standard.set(summary.projectName, forKey: "chat.selectedProject")
        selectedID = summary.id
        applySnapshot()
        onSelect?(summary, false)
    }

    func refresh() {
        let previous = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        chats = runtime.summaries.filter { $0.projectName == project?.name }
        let pinChanged = chats.contains { chat in
            previous[chat.id].map { $0.isPinned != chat.isPinned } ?? false
        }
        let changedRows = chats.compactMap { chat -> UUID? in
            guard let old = previous[chat.id],
                  old.title != chat.title || old.isWorking != chat.isWorking || old.showsUnread != chat.showsUnread
            else { return nil }
            return chat.id
        }
        if isViewLoaded {
            applySnapshot(changedRows: changedRows, restoreSelection: false, animateMove: pinChanged)
        }
    }

    /// The projects in `Projects/`, once the host lists them; none until then.
    private var projects: [ProjectSummary] = []
    private let projectMonitor = ProjectCatalogMonitor()
    private let pacing = ListPacing()

    /// The open project's conversations; what is picked among them is
    /// `switchProject(to:)`'s, or the launch's to restore.
    private var project: ProjectSummary? {
        didSet {
            UserDefaults.standard.set(project?.name, forKey: "chat.selectedProject")
            showProject()
            guard oldValue?.name != project?.name else { return }
            // another project's list replaces this one; it is not a change
            pacing.begin()
            refresh()
        }
    }

    /// Opens `candidate` on its most recent conversation, or none when it
    /// has none yet.
    private func switchProject(to candidate: ProjectSummary?) {
        guard candidate?.name != project?.name else {
            project = candidate
            return
        }
        project = candidate
        selectedID = SidebarOrder.newest(chats)?.id
        applySnapshot()
        onSelect?(selectedID.flatMap(chat), false)
    }

    /// The open project's conversations, as the runtime lists them.
    private var chats: [ChatSummary] = []

    /// What the search field holds; the list shows the conversations whose
    /// title has it, ignoring case and diacritics.
    private var query = ""

    private lazy var searchController = UISearchController(searchResultsController: nil).then {
        $0.searchResultsUpdater = self
        $0.obscuresBackgroundDuringPresentation = false
        $0.searchBar.placeholder = String(localized: "Search chats")
    }

    /// The picked conversation, kept across a change to the list, which
    /// moves rows between sections and would drop the table's selection.
    private var selectedID: UUID?

    /// "Today" and "Yesterday" in the reader's language, capitalised as a
    /// heading starts: French, Italian and Spanish write them in lower case
    /// mid-sentence.
    private static let relativeDayFormatter = DateFormatter().then {
        $0.dateStyle = .medium
        $0.timeStyle = .none
        $0.doesRelativeDateFormatting = true
        $0.formattingContext = .beginningOfSentence
    }

    /// The other days' headings, capitalised the same way ("Lundi").
    private static let dayHeading = Date.FormatStyle(capitalizationContext: .beginningOfSentence)

    private lazy var newChatButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "New Chat")
        configuration.image = UIImage(systemName: "square.and.pencil")
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .label
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }
        return UIButton(
            configuration: configuration,
            primaryAction: UIAction { [weak self] _ in self?.startNewChat() },
        )
    }()

    private lazy var projectMenuButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "folder"),
            menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.projectMenu().children ?? [])
            }]),
        )
        item.preferredMenuElementOrder = .fixed
        item.accessibilityLabel = String(localized: "Projects")
        return item
    }()

    /// The plus: a new conversation, as the toolbar's New Chat starts one,
    /// or a new project.
    private lazy var newMenuButton: UIBarButtonItem = {
        let newChat = UIAction(
            title: String(localized: "New Chat"),
            image: UIImage(systemName: "square.and.pencil"),
        ) { [weak self] _ in self?.startNewChat() }
        let newProject = UIAction(
            title: String(localized: "New Project"),
            image: UIImage(systemName: "folder.badge.plus"),
        ) { [weak self] _ in self?.openNewProject() }
        let item = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: UIMenu(children: [newChat, newProject]))
        item.preferredMenuElementOrder = .fixed
        item.accessibilityLabel = String(localized: "New")
        return item
    }()

    /// The system's inset grouped list, cells, headers and selection as
    /// they come.
    private let tableView = FirstFillTableView(frame: .zero, style: .insetGrouped).then {
        $0.backgroundColor = .panelBackground
        $0.register(UITableViewCell.self, forCellReuseIdentifier: "chat")
        // The first conversation is picked at launch, and after that a tap
        // picks: in a primary column the selection would otherwise follow
        // a keyboard's focus.
        $0.selectionFollowsFocus = false
        // the symbol alone; the words are for VoiceOver
        $0.backgroundView = EmptyStateView(
            symbolName: "bubble.left.and.bubble.right.fill",
            text: String(localized: "No chats yet. Tap “New Chat” to start one."),
            showsText: false,
        )
    }

    /// A picked row's ground, lighter than the system's: black at 0.1 in
    /// the light, white at 0.1 in the dark (owner, 2026-10-21).
    private static let selectionColor = UIColor(
        light: UIColor.black.withAlphaComponent(0.1),
        dark: UIColor.white.withAlphaComponent(0.1),
    )

    /// The rows are conversation IDs.
    private lazy var dataSource = SwipeableTableDataSource<Section, UUID>(
        tableView: tableView,
    ) { [unowned self] tableView, indexPath, id in
        let cell = tableView.dequeueReusableCell(withIdentifier: "chat", for: indexPath)
        let summary = chat(id)
        var content = UIListContentConfiguration.cell()
        content.text = summary?.displayTitle
        content.textProperties.numberOfLines = 1
        cell.contentConfiguration = content
        // working wins; the dot shows once it is at rest
        let status: ChatRowStatusView.Status? = if summary?.isWorking == true {
            .working
        } else if summary?.showsUnread == true {
            .unread
        } else {
            nil
        }
        if let status {
            let view = cell.accessoryView as? ChatRowStatusView ?? ChatRowStatusView()
            view.show(status)
            cell.accessoryView = view
        } else {
            (cell.accessoryView as? ChatRowStatusView)?.show(nil)
            cell.accessoryView = nil
        }
        cell.isAccessibilityElement = true
        cell.accessibilityValue = switch status {
        case .working: String(localized: "Working")
        case .unread: String(localized: "Unread")
        case nil: nil
        }
        cell.configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
            if state.isSelected || state.isHighlighted {
                background.backgroundColor = Self.selectionColor
            }
            cell.backgroundConfiguration = background
        }
        return cell
    }.then {
        $0.sectionTitle = { Self.title(for: $0) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        projectMonitor.start()
        view.backgroundColor = .panelBackground

        // The project name stays at the leading edge; the folder owns switching.
        navigationItem.style = .editor
        // under the bar, hidden until the list is pulled down
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = true
        // Making things stays in the top bar; project switching lives below.
        navigationItem.rightBarButtonItems = [newMenuButton]
        showProject()
        refresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(projectsChanged),
            name: .apelinProjectsChanged,
            object: nil,
        )
        Task { await refreshProjects() }
        toolbarItems = [
            UIBarButtonItem(customView: newChatButton),
            .flexibleSpace(),
            projectMenuButton,
            UIBarButtonItem(
                image: UIImage(systemName: "gearshape"),
                primaryAction: UIAction { [weak self] _ in self?.presentSettings() },
            ).then { $0.accessibilityLabel = String(localized: "Settings") },
        ]

        tableView.delegate = self
        // a row that arrives fades in where it belongs, rather than sliding
        dataSource.defaultRowAnimation = .fade
        view.addSubview(tableView)
        // the list the bar watches, for the pull that brings out the search;
        // an empty or short one still gives way to the pull
        setContentScrollView(tableView)
        tableView.alwaysBounceVertical = true
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        applySnapshot()
    }

    /// A search controller given before the bar is first shown is shown
    /// with it, whatever `hidesSearchBarWhenScrolling` says; given after,
    /// it starts tucked away.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if navigationItem.searchController == nil {
            navigationItem.searchController = searchController
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    // MARK: - The list

    private func chat(_ id: UUID) -> ChatSummary? {
        chats.first { $0.id == id }
    }

    private func applySnapshot(changedRows: [UUID] = [], restoreSelection: Bool = true, animateMove: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
        let shown = query.isEmpty ? chats : chats.filter {
            $0.displayTitle.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let order = SidebarOrder.sections(of: shown)
        // Pinning moves a row between existing sections. Inserting or deleting
        // its section in the same diff turns that move into a section fade.
        snapshot.appendSections([.pinned])
        snapshot.appendItems(order.pinned)
        for day in order.days {
            snapshot.appendSections([.day(day.start)])
            snapshot.appendItems(day.chats)
        }
        let current = dataSource.snapshot()
        let old = Set(current.itemIdentifiers)
        let reconfigured = changedRows.filter { old.contains($0) && snapshot.indexOfItem($0) != nil }
        snapshot.reconfigureItems(reconfigured)
        let hasChanges = !reconfigured.isEmpty || current.sectionIdentifiers != snapshot.sectionIdentifiers
            || current.itemIdentifiers != snapshot.itemIdentifiers
            || snapshot.itemIdentifiers.contains { current.sectionIdentifier(containingItem: $0) != snapshot.sectionIdentifier(containingItem: $0) }
        // Streamed text changes nothing here, and an unchanged row is never
        // rebuilt: its open swipe actions would close.
        tableView.backgroundView?.isHidden = !shown.isEmpty
        guard tableView.isFilled else {
            pacing.begin()
            dataSource.applyFirst(snapshot, to: tableView) { [weak self] in self?.selectPicked() }
            return
        }
        if hasChanges {
            let pacedAnimation = pacing.animatesChange(in: tableView)
            let animated = animateMove
                ? tableView.window != nil && !UIAccessibility.isReduceMotionEnabled
                : pacedAnimation
            dataSource.applyChange(snapshot, to: tableView, animated: animated) { [weak self] in
                self?.selectPicked()
            }
        }
        if !hasChanges, restoreSelection {
            selectPicked()
        }
    }

    private func selectPicked() {
        if let selectedID, let indexPath = dataSource.indexPath(for: selectedID) {
            tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        }
    }

    /// An empty conversation at the top of today, picked and shown: the
    /// project's untouched one if it has one, so empty rows never pile up.
    func startNewChat(picked: Bool = true) {
        let chat = runtime.newChat(project: project?.name, preferring: selectedID)
        refresh()
        selectedID = chat.id
        applySnapshot()
        onSelect?(chat, picked)
        // only when it is out of sight: scrolling the list moves the bar's
        // hidden search field too, and left it half drawn
        if let indexPath = dataSource.indexPath(for: chat.id),
           tableView.indexPathsForVisibleRows?.contains(indexPath) != true
        {
            tableView.scrollToRow(at: indexPath, at: .none, animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    private func togglePin(_ id: UUID) {
        runtime.togglePin(id)
        refresh()
    }

    private func stop(_ id: UUID) {
        Task {
            do { try await runtime.stop(id) }
            catch { presentNotice(title: "Unable to Stop", message: error.readableMessage) }
        }
    }

    /// Deletes a conversation, from its row or the chat's More menu
    /// (`origin`), asking first as `ChatDeletion` says; `presenter` asks,
    /// the sidebar when it is nil. One still working is stopped first.
    func delete(_ id: UUID, from origin: ChatDeletion.Origin, presenter: UIViewController? = nil) {
        guard let chat = runtime.records[id]?.summary else { return }
        guard let confirmation = ChatDeletion.confirmation(for: chat, from: origin) else {
            delete(id)
            return
        }
        let onConfirm: () -> Void = { [weak self] in self?.delete(id) }
        let presenter = presenter ?? self
        let name = chat.displayTitle
        switch confirmation {
        case .delete:
            presenter.presentConfirmation(
                title: "Delete Conversation?",
                message: "“\(name)” and its messages will be deleted. This cannot be undone.",
                confirmTitle: "Delete",
                destructive: true,
                onConfirm: onConfirm,
            )
        case .stopAndDelete:
            presenter.presentConfirmation(
                title: "Delete Conversation?",
                message: "“\(name)” is still working. It will be stopped, then deleted with its messages. This cannot be undone.",
                confirmTitle: "Stop and Delete",
                destructive: true,
                onConfirm: onConfirm,
            )
        }
    }

    /// Stops it if it is working by then, as Stop does, closes its session,
    /// removes its history and leaves the page to what is picked next. A
    /// stop that fails leaves the run to the close, which ends it too.
    private func delete(_ id: UUID) {
        Task {
            if runtime.records[id]?.summary.isWorking == true {
                try? await runtime.stop(id)
            }
            do {
                try await runtime.delete(id)
                if selectedID == id {
                    selectedID = nil; onSelect?(nil, false)
                }
                refresh()
            } catch { presentNotice(title: "Unable to Delete Chat", message: error.readableMessage) }
        }
    }

    /// Pinned, then Today, Yesterday, the weekday within the week, then the date.
    private static func title(for section: Section) -> String {
        let now = Date()
        guard case let .day(day) = section else { return String(localized: "Pinned") }
        let calendar = Calendar.current
        if calendar.isDateInToday(day) || calendar.isDateInYesterday(day) {
            return relativeDayFormatter.string(from: day)
        }
        let age = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? .max
        if age < 7 {
            return day.formatted(dayHeading.weekday(.wide))
        }
        if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            return day.formatted(dayHeading.month(.abbreviated).day())
        }
        return day.formatted(dayHeading.year().month(.abbreviated).day())
    }

    // MARK: - The project

    private func showProject() {
        title = project?.displayTitle ?? String(localized: "Apelin")
        projectMenuButton.image = project.flatMap { ProjectIcon.menuImage(for: $0) } ?? UIImage(systemName: "folder")
        projectMenuButton.accessibilityValue = project?.displayTitle ?? String(localized: "General Chat")
    }

    /// The projects to switch to, the open one ticked: the newest at the
    /// top and the rest under More Projects (`ProjectMenuOrder`), then
    /// the picker, which also makes a new one. Each says how many of its
    /// conversations wait unread, as General Chat and More Projects do for
    /// theirs (`ChatUnread`); the menu is built again each time it opens.
    private func projectMenu() -> UIMenu {
        let open = project?.name
        let byName = Dictionary(projects.map { ($0.name, $0) }) { first, _ in first }
        let chats = runtime.summaries
        let order = ProjectMenuOrder.split(
            projects.map(\.name),
            created: byName.compactMapValues(\.created),
            chats: chats,
            open: open,
        )
        let unread = ChatUnread.Counts(chats)
        let switchAction = { [weak self] (name: String) -> UIAction? in
            guard let candidate = byName[name] else { return nil }
            return UIAction(
                title: ChatUnread.menuTitle(candidate.displayTitle, unread: unread.projects[name] ?? 0),
                state: name == open ? .on : .off,
            ) { [weak self] _ in
                self?.switchProject(to: candidate)
            }
        }
        var switches: [UIMenuElement] = order.top.compactMap(switchAction)
        if !order.more.isEmpty {
            switches.append(UIMenu(
                title: ChatUnread.menuTitle(String(localized: "More Projects"), unread: unread.total(of: order.more)),
                children: order.more.compactMap(switchAction),
            ))
        }
        let general = UIAction(
            title: ChatUnread.menuTitle(String(localized: "General Chat"), unread: unread.general),
            state: project == nil ? .on : .off,
        ) { [weak self] _ in self?.switchProject(to: nil) }
        let allProjects = UIAction(title: String(localized: "All Projects…")) { [weak self] _ in
            self?.openProjectPicker()
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [general]),
            UIMenu(options: .displayInline, children: switches),
            UIMenu(options: .displayInline, children: [allProjects]),
        ])
    }

    @objc private func projectsChanged() {
        Task { await refreshProjects() }
    }

    private func refreshProjects() async {
        do {
            projects = try await ProjectSummary.load()
            // A project whose folder went takes its conversations, and the
            // sidebar leaves it for General Chat, as Delete in All Projects does.
            let deleted = await runtime.forgetDeletedProjects()
            if let name = project?.name, deleted.contains(name) {
                switchProject(to: nil)
            } else if let name = project?.name, let resolved = projects.first(where: { $0.name == name }),
                      resolved != project
            {
                project = resolved
            } else if let name = UserDefaults.standard.string(forKey: "chat.selectedProject"),
                      let saved = projects.first(where: { $0.name == name }), project == nil
            {
                project = saved
            }
            showProject()
            if !hasLoadedProjects {
                hasLoadedProjects = true
                onProjectsLoaded?()
            }
        } catch { presentNotice(title: "Projects Unavailable", message: error.readableMessage) }
    }

    /// Settings, whose Logs names each conversation's journal by the
    /// conversation the runtime has for its session.
    private func presentSettings() {
        let settings = SettingsViewController()
        settings.conversationTitle = { [weak self] session in self?.runtime.title(ofSession: session) }
        presentPageAsFormSheet(settings)
    }

    private func openNewProject() {
        let page = NewProjectController()
        page.onCreate = { [weak self] project, firstPrompt in
            self?.openCreatedProject(project, firstPrompt: firstPrompt)
        }
        presentPageAsFormSheet(page)
    }

    /// Opens a project just made on a new conversation, which sends
    /// `firstPrompt` when there is one.
    func openCreatedProject(_ project: ProjectSummary, firstPrompt: String? = nil) {
        projects.removeAll { $0.name == project.name }
        projects.append(project)
        self.project = project
        startNewChat()
        if let firstPrompt {
            onSendPrompt?(firstPrompt)
        }
    }

    private func openProjectPicker() {
        let picker = ProjectPickerController(projects: projects, current: project?.name)
        picker.onPick = { [weak self] project in self?.switchProject(to: project) }
        picker.onCreate = { [weak self] project, firstPrompt in
            self?.openCreatedProject(project, firstPrompt: firstPrompt)
        }
        picker.onDelete = { [weak self] project in
            guard let self else { return }
            try await runtime.deleteProject(project.name)
            projects.removeAll { $0.name == project.name }
            if self.project?.name == project.name {
                switchProject(to: nil)
            }
            showProject()
            NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
        }
        presentPageAsFormSheet(picker)
    }
}

extension SidebarController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        guard text != query else { return }
        query = text
        pacing.begin()
        applySnapshot()
    }
}

extension SidebarController: UITableViewDelegate {
    /// Keep empty groups available as move destinations without showing a
    /// heading or leaving a gap in the list.
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        tableView.numberOfRows(inSection: section) == 0 ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        tableView.numberOfRows(inSection: section) == 0 ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    /// Again on the row already picked, which puts a drawer away.
    func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedID = dataSource.itemIdentifier(for: indexPath)
        onSelect?(selectedID.flatMap(chat), true)
    }

    // MARK: Pin, stop and delete

    func tableView(
        _: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let chat = chat(id) else { return nil }
        return UISwipeActionsConfiguration(actions: ChatRowAction.leadingSwipe(for: chat).map { swipeAction($0, for: id) })
    }

    /// Never nil, which would put UIKit's default Delete on the row, one
    /// that does nothing here.
    func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let chat = chat(id) else {
            return UISwipeActionsConfiguration(actions: [])
        }
        let actions = UISwipeActionsConfiguration(
            actions: ChatRowAction.trailingSwipe(for: chat).map { swipeAction($0, for: id) },
        )
        // a full swipe deletes one at rest; one that works keeps Stop beside Delete
        actions.performsFirstActionWithFullSwipe = !chat.isWorking
        return actions
    }

    private func swipeAction(_ action: ChatRowAction, for id: UUID) -> UIContextualAction {
        switch action {
        case .pin, .unpin:
            let pin = UIContextualAction(
                style: .normal,
                title: action == .unpin ? String(localized: "Unpin") : String(localized: "Pin"),
            ) { [weak self] _, _, completion in
                // the swipe's own transaction has to end for the row to settle
                completion(true)
                DispatchQueue.main.async { [weak self] in self?.togglePin(id) }
            }
            pin.image = UIImage(systemName: action == .unpin ? "pin.slash.fill" : "pin.fill")
            pin.backgroundColor = .systemOrange
            return pin
        case .stop:
            let stop = UIContextualAction(
                style: .normal,
                title: String(localized: "Stop"),
            ) { [weak self] _, _, completion in
                completion(true)
                self?.stop(id)
            }
            stop.image = UIImage(systemName: "stop.fill")
            stop.backgroundColor = .darkGray
            return stop
        case .delete:
            let delete = UIContextualAction(
                style: .destructive,
                title: String(localized: "Delete"),
            ) { [weak self] _, _, completion in
                // The snapshot removes the row only after deletion succeeds.
                completion(false)
                self?.delete(id, from: .sidebarRow)
            }
            delete.image = UIImage(systemName: "trash.fill")
            return delete
        }
    }

    /// A swipe that ends after the list changed under it, as deleting the
    /// picked conversation does, leaves no row highlighted.
    func tableView(_: UITableView, didEndEditingRowAt _: IndexPath?) {
        applySnapshot()
    }

    /// The swipes' actions, for a long press and a pointer.
    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let chat = chat(id) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: ChatRowAction.menu(for: chat).compactMap { self?.menuAction($0, for: id) })
        }
    }

    private func menuAction(_ action: ChatRowAction, for id: UUID) -> UIAction {
        switch action {
        case .pin, .unpin:
            UIAction(
                title: action == .unpin ? String(localized: "Unpin") : String(localized: "Pin"),
                image: UIImage(systemName: action == .unpin ? "pin.slash" : "pin"),
            ) { [weak self] _ in self?.togglePin(id) }
        case .stop:
            UIAction(
                title: String(localized: "Stop"),
                image: UIImage(systemName: "stop.fill"),
            ) { [weak self] _ in self?.stop(id) }
        case .delete:
            UIAction(
                title: String(localized: "Delete"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive,
            ) { [weak self] _ in self?.delete(id, from: .sidebarRow) }
        }
    }
}

/// A diffable table data source whose rows can be swiped: UIKit offers a
/// row's swipe actions only when its data source calls it editable, and a
/// diffable one says no unless it is told otherwise. Xrash's, with each
/// section's header title from `sectionTitle`.
final class SwipeableTableDataSource<Section: Hashable, Item: Hashable>:
    UITableViewDiffableDataSource<Section, Item>
{
    var sectionTitle: ((Section) -> String?)?

    override func tableView(_: UITableView, canEditRowAt _: IndexPath) -> Bool {
        true
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section).flatMap { sectionTitle?($0) }
    }
}
