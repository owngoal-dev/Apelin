import Litext
import Then
import UIKit

/// The root, laid out as ChatGPT and FlowDown lay out theirs. Wide (a
/// regular width with room for the sidebar beside an iPhone-wide page: an
/// iPad full screen, an iPhone Duo's inner display held sideways), the
/// sidebar sits beside the detail column, and the button first on the detail
/// bar hides it or brings it back. Narrow (a compact width, or a regular one
/// without that room: an iPhone, an iPhone Duo's outer display or its inner
/// one held upright), the detail column is the screen and the sidebar a
/// drawer under it: the same button, or a pan toward the trailing side on a
/// page at the root of the column, slides the page aside to show it; a tap
/// or a pan back on what is left of the page, or picking a conversation,
/// slides it back. A drawer always has a conversation behind it, never the
/// icon. While the sidebar is out of sight, a new conversation is the last
/// item on the detail bar. Right to left, all of it is mirrored: the sidebar
/// is on the right and the drawer comes out from there.
final class RootInterfaceController: UIViewController {
    /// The detail column's stack.
    let navigator = DetailNavigator()
    private let sidebar = SidebarController()
    private let chatRuntime = ChatRuntime()
    private var restoredChat = false
    private var opensChatAfterWelcome = false
    /// An `apelin://` link that came before the conversations were read,
    /// or an import that came during the welcome.
    private var pendingLink: ApelinLink?
    /// A link is being looked up: the launch's own restore waits for it.
    private var isResolvingLink = false
    private lazy var sidebarNavigation = UINavigationController(rootViewController: sidebar)
    /// The conversation page, made once and handed each conversation picked.
    /// Its Delete Conversation… goes through the sidebar's Delete, which
    /// leaves the page to what is picked next.
    private lazy var chatController: ChatController = {
        let page = ChatController()
        page.runtime = chatRuntime
        page.onDelete = { [weak self, weak page] id in
            self?.sidebar.delete(id, from: .moreMenu, presenter: page)
        }
        return page
    }()

    /// Beside the page, the sidebar is always this wide.
    private static let sidebarWidth: CGFloat = 340
    /// The narrowest page the sidebar goes beside: an iPhone's width.
    private static let minimumPageWidth: CGFloat = 402
    /// What an open drawer leaves of the page, to tap or pan it back.
    private static let drawerMargin: CGFloat = 64
    /// The widest a drawer gets, in an iPhone's landscape.
    private static let maximumDrawerWidth: CGFloat = 400

    /// The page covers the shade, and the shade takes the tap and the pan
    /// that close an open drawer.
    private let shade = DrawerShade()

    /// Wide, the sidebar's button hides it.
    private var isSidebarHidden = false
    /// Narrow, how far the drawer is out: 0 closed, 1 open, between while a
    /// pan moves it.
    private var drawerProgress: CGFloat = 0
    /// The progress a pan started from.
    private var panStart: CGFloat = 0
    /// The layout last applied, to notice the window crossing between the two.
    private var laidOutAsDrawer: Bool?

    /// Narrow: a compact width, or a regular one without the room for the
    /// sidebar beside a page an iPhone's width. A regular width is not
    /// always an iPad's: an iPhone Duo's inner display held upright is
    /// 669 pt wide, and beside the sidebar its page was 329. There the
    /// sidebar comes out over the page, as a split view's does in an iPad's
    /// portrait. Read on every layout: the window changes width under the
    /// running app.
    private var isDrawer: Bool {
        let width = viewIfLoaded?.bounds.width ?? 0
        return traitCollection.horizontalSizeClass == .compact
            || (width > 0 && width < Self.sidebarWidth + Self.minimumPageWidth)
    }

    private var drawerWidth: CGFloat {
        min(view.bounds.width - Self.drawerMargin, Self.maximumDrawerWidth)
    }

    /// Whether the sidebar is on screen, beside the page or over it.
    private var isSidebarShown: Bool {
        isDrawer ? drawerProgress > 0 : !isSidebarHidden
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        sidebar.runtime = chatRuntime
        sidebar.onSelect = { [weak self] chat, picked in self?.open(chat, picked: picked) }
        sidebar.onProjectsLoaded = { [weak self] in self?.restoreChatIfReady() }
        // startNewChat has just put that conversation on the page
        sidebar.onSendPrompt = { [weak self] text in self?.chatController.sendPrompt(text) }
        chatRuntime.onChange = { [weak self] in
            guard let self else { return }
            sidebar.refresh()
            restoreChatIfReady()
            chatController.refreshRuntime()
            ChatWidgetPublisher.shared.chatsChanged()
        }
        ChatWidgetPublisher.shared.attach(chatRuntime)
        ChatRuntime.active = chatRuntime
        chatRuntime.onDraftRestored = { [weak self] id in self?.chatController.restoreDraft(for: id) }
        chatRuntime.onUnsentReturned = { [weak self] id, returned in
            self?.chatController.unsentReturned(returned, to: id)
        }
        chatRuntime.onError = { [weak self] error in
            self?.presentNotice(title: "Unable to Load Chats", message: error.readableMessage)
        }
        chatRuntime.onSaveFailure = { [weak self] error in
            guard let self else { return }
            StorageWarning.saveFailed(error, from: self)
        }
        chatRuntime.onSaveRecovered = { StorageWarning.saveRecovered() }
        chatRuntime.onBuildsCompleted = { [weak self] count in
            guard let self else { return }
            StarPrompt.buildsCompleted(count, from: self)
        }
    }

    /// A restored chat already names its project. A fresh phone chat must
    /// wait for the sidebar's saved project, rather than racing it into General.
    private func restoreChatIfReady() {
        guard !WelcomeFlow.shouldPresent, chatRuntime.isLoaded, !isResolvingLink else { return }
        if let link = pendingLink {
            pendingLink = nil
            open(link)
            // an import's sheet goes over the page the launch still restores
            guard Self.isImport(link) else { return }
        }
        guard !restoredChat else { return }
        if let saved = Self.savedChatID, let summary = chatRuntime.records[saved]?.summary {
            restoredChat = true
            sidebar.select(summary)
        } else if sidebar.hasLoadedProjects {
            restoredChat = true
            if isDrawer || traitCollection.userInterfaceIdiom == .phone || opensChatAfterWelcome {
                sidebar.startNewChat(picked: false)
            }
        }
    }

    /// The conversation shown last, to show again at launch.
    private static var savedChatID: UUID? {
        UserDefaults.standard.string(forKey: "chat.selectedID").flatMap(UUID.init(uuidString:))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .panelBackground
        Task { await chatRuntime.load(keeping: Self.savedChatID) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(enteredForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(enteredBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(syncViewedChat),
            name: UIApplication.didBecomeActiveNotification,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resignedActive),
            name: UIApplication.willResignActiveNotification,
            object: nil,
        )

        // the detail column sits a step above the sidebar: in the dark its
        // grounds resolve to their elevated shade, as a sheet's do
        if #available(iOS 17.0, *) {
            navigator.traitOverrides.userInterfaceLevel = .elevated
        } else {
            setOverrideTraitCollection(UITraitCollection(userInterfaceLevel: .elevated), forChild: navigator)
        }
        for child in [sidebarNavigation, navigator] {
            addChild(child)
            view.addSubview(child.view)
            child.didMove(toParent: self)
        }
        navigator.delegate = self
        navigator.view.layer.shadowColor = UIColor.black.cgColor
        navigator.view.layer.shadowRadius = 12

        shade.onClose = { [weak self] in self?.setDrawerOpen(false) }
        shade.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panDrawer)).then {
            $0.delegate = self
        })
        view.addSubview(shade)
        // the pan that brings the drawer out starts anywhere on the page
        navigator.view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panDrawer)).then {
            $0.delegate = self
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard WelcomeFlow.shouldPresent else {
            StorageWarning.checkFreeSpace(from: self)
            return
        }
        presentWelcome()
    }

    /// Space freed while the app was away lets the chats kept in memory
    /// be written; space still short is said again only after a save worked.
    @objc private func enteredForeground() {
        chatRuntime.retryUnsaved()
        StorageWarning.checkFreeSpace(from: self)
    }

    /// What streamed or was typed since the last write goes to disk before
    /// the app is suspended, rather than at the end of its interval.
    @objc private func enteredBackground() {
        let task = UIApplication.shared.beginBackgroundTask(withName: "Save Chats")
        chatRuntime.saveNow {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// Out of the reader's sight, the conversation on the page is no longer
    /// looked at: a reply that comes meanwhile leaves it unread, until the
    /// app is back in front with it.
    @objc private func resignedActive() {
        chatRuntime.viewedChat = nil
    }

    /// Tells the runtime which conversation the reader is looking at
    /// (`ChatRuntime.viewedChat`): the one on the conversation page, while
    /// that page is the column's, no drawer is out over it and the app is
    /// in front. A sheet over the page does not count: nothing tells the
    /// page when one goes, and its conversation is still the page under it.
    @objc private func syncViewedChat() {
        let page = navigator.topViewController as? ChatController
        let isLooking = UIApplication.shared.applicationState == .active && !(isDrawer && drawerProgress > 0)
        chatRuntime.viewedChat = isLooking ? page?.chat?.id : nil
    }

    func presentWelcome() {
        guard presentedViewController == nil else { return }
        WelcomeFlow.present(from: self) { [weak self] project in
            guard let self else { return }
            if let project {
                restoredChat = true
                sidebar.openCreatedProject(project)
                // only an import link held through the welcome is left
                restoreChatIfReady()
            } else {
                opensChatAfterWelcome = true
                restoreChatIfReady()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if laidOutAsDrawer != isDrawer {
            // a window narrowed with the sidebar beside the page, or widened
            // with the drawer out, starts the other layout closed and shown
            laidOutAsDrawer = isDrawer
            drawerProgress = 0
            isSidebarHidden = false
            syncBarItems()
            syncVisibility()
            if isDrawer, restoredChat, navigator.viewControllers.first is NothingSelectedController {
                // after this pass: showing a page lays the columns out again
                DispatchQueue.main.async { [weak self] in self?.sidebar.startNewChat(picked: false) }
            }
            // a drawer that was out is gone; after this pass, since reading
            // a conversation redraws the sidebar and the page
            DispatchQueue.main.async { [weak self] in self?.syncViewedChat() }
        }
        layoutColumns()
    }

    /// Places both columns for the current state; inside an animation
    /// block, it is what the animation moves to. Worked out left to right
    /// and mirrored right to left.
    private func layoutColumns() {
        let bounds = view.bounds
        if isDrawer {
            let width = drawerWidth
            let shift = view.directionalOffset(width * drawerProgress)
            // the drawer comes out from under the page, a little behind it
            place(
                sidebarNavigation.view,
                in: view.directionalFrame(CGRect(x: 0, y: 0, width: width, height: bounds.height)),
                shift: view.directionalOffset(-width * 0.25 * (1 - drawerProgress)),
            )
            place(navigator.view, in: bounds, shift: shift)
            place(shade, in: bounds, shift: shift)
            shade.alpha = drawerProgress
            navigator.view.layer.shadowOpacity = 0.15
        } else {
            let width = isSidebarHidden ? 0 : Self.sidebarWidth
            place(
                sidebarNavigation.view,
                in: view.directionalFrame(
                    CGRect(x: width - Self.sidebarWidth, y: 0, width: Self.sidebarWidth, height: bounds.height),
                ),
                shift: 0,
            )
            place(
                navigator.view,
                in: view.directionalFrame(CGRect(x: width, y: 0, width: bounds.width - width, height: bounds.height)),
                shift: 0,
            )
            place(shade, in: bounds, shift: 0)
            shade.alpha = 0
            navigator.view.layer.shadowOpacity = 0
        }
        navigator.view.layer.shadowPath = UIBezierPath(rect: navigator.view.bounds).cgPath
    }

    /// By bounds and center, which hold under a transform, then the
    /// transform: a pan moves only the transform.
    private func place(_ subview: UIView, in frame: CGRect, shift: CGFloat) {
        subview.bounds = CGRect(origin: .zero, size: frame.size)
        subview.center = CGPoint(x: frame.midX, y: frame.midY)
        subview.transform = CGAffineTransform(translationX: shift, y: 0)
    }

    /// What is out of sight is out of reach too: an offscreen sidebar is
    /// hidden, and a page under an open drawer is not read.
    private func syncVisibility() {
        sidebarNavigation.view.isHidden = !isSidebarShown
        shade.isHidden = !isDrawer || drawerProgress == 0
        navigator.view.accessibilityElementsHidden = isDrawer && drawerProgress > 0
    }

    private func animateLayout(velocity: CGFloat = 0, completion: (() -> Void)? = nil) {
        // shown before it moves in; hidden only once it is out
        sidebarNavigation.view.isHidden = false
        shade.isHidden = !isDrawer
        UIView.animate(
            withDuration: 0.4,
            delay: 0,
            usingSpringWithDamping: 1,
            initialSpringVelocity: velocity,
            options: [.allowUserInteraction, .beginFromCurrentState],
        ) {
            self.layoutColumns()
            self.navigator.view.layoutIfNeeded()
        } completion: { _ in
            self.syncVisibility()
            completion?()
        }
    }

    // MARK: - Showing and hiding the sidebar

    func setDrawerOpen(_ open: Bool, velocity: CGFloat = 0) {
        guard isDrawer else { return }
        // the keyboard goes with the column it typed into
        (open ? navigator.view : sidebarNavigation.view).endEditing(true)
        drawerProgress = open ? 1 : 0
        syncBarItems()
        animateLayout(velocity: velocity)
        // the page under an open drawer is not looked at
        syncViewedChat()
    }

    private func toggleSidebar() {
        if isDrawer {
            setDrawerOpen(drawerProgress == 0)
        } else {
            isSidebarHidden.toggle()
            syncBarItems()
            animateLayout()
        }
    }

    @objc private func panDrawer(_ pan: UIPanGestureRecognizer) {
        let width = drawerWidth
        guard width > 0 else { return }
        switch pan.state {
        case .began:
            panStart = drawerProgress
            navigator.view.endEditing(true)
            sidebarNavigation.view.isHidden = false
            shade.isHidden = false
        case .changed:
            let travel = view.directionalOffset(pan.translation(in: view).x)
            drawerProgress = min(max(panStart + travel / width, 0), 1)
            layoutColumns()
        case .ended:
            // positive toward the trailing side, the way the drawer comes out
            let velocity = view.directionalOffset(pan.velocity(in: view).x)
            let open = abs(velocity) > 300 ? velocity > 0 : drawerProgress > 0.5
            let distance = abs((open ? 1 : 0) - drawerProgress) * width
            setDrawerOpen(open, velocity: distance > 0 ? abs(velocity) / distance : 0)
        default:
            setDrawerOpen(drawerProgress > 0.5)
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isDrawer, drawerProgress > 0 else { return false }
        setDrawerOpen(false)
        return true
    }

    // MARK: - The detail column

    /// The picked conversation on the one conversation page. With none
    /// left picked, beside the sidebar the column shows the icon, and behind
    /// a drawer a new conversation. The page is put back at the root only
    /// when something else is there; otherwise it takes the conversation
    /// where it is. Only a conversation the reader picked puts the drawer
    /// away. What is shown is what the reader looks at, unless a drawer is
    /// out over it (`syncViewedChat`).
    private func open(_ chat: ChatSummary?, picked: Bool) {
        defer { syncViewedChat() }
        guard let chat else {
            if isDrawer {
                sidebar.startNewChat(picked: picked)
            } else if !(navigator.viewControllers.first is NothingSelectedController) {
                navigator.show(NothingSelectedController())
            }
            return
        }
        UserDefaults.standard.set(chat.id.uuidString, forKey: "chat.selectedID")
        chatController.use(chat)
        if navigator.viewControllers.first !== chatController {
            navigator.show(chatController)
        } else if navigator.topViewController !== chatController {
            navigator.popToRootViewController(animated: false)
        }
        if picked, drawerProgress > 0 {
            setDrawerOpen(false)
        }
    }

    /// Opens an `apelin://` link: its conversation, in its project, as if
    /// picked, which on an iPhone puts the drawer away. One that names
    /// nothing leaves the page as it was and says so. A link before the
    /// conversations are read waits for them, and the launch shows it
    /// instead of the conversation saved; during the welcome it is dropped.
    /// A prompt goes into a new General Chat's composer with the keyboard
    /// up, and waits there for the reader's Send. An import is a sheet over
    /// the page (`RepositoryImportFlow`); one that comes during the welcome
    /// waits for it to finish rather than being dropped, since a tap on
    /// Open in Apelin is what opened the app.
    func open(_ link: ApelinLink) {
        guard link != .app else { return }
        guard !WelcomeFlow.shouldPresent else {
            if Self.isImport(link) {
                pendingLink = link
            }
            return
        }
        guard chatRuntime.isLoaded else {
            pendingLink = link
            return
        }
        guard !Self.isImport(link) else {
            openImport(link)
            return
        }
        isResolvingLink = true
        Task { [weak self] in
            guard let self else { return }
            let destination = await ChatLinkTarget.resolve(link, in: chatRuntime)
            isResolvingLink = false
            guard let destination else {
                ChatLinkTarget.reportUnresolved(link)
                restoreChatIfReady()
                return
            }
            restoredChat = true
            switch destination {
            case let .chat(summary):
                sidebar.select(summary)
                setDrawerOpen(false)
            case let .newChat(project, draft):
                let summary = chatRuntime.newChat(project: project, preferring: nil)
                if let draft {
                    chatRuntime.saveDraft(ComposerDraft(text: draft), for: summary.id)
                }
                sidebar.select(summary)
                setDrawerOpen(false)
                guard draft != nil else { return }
                // the conversation may have been on the page already, untouched
                chatController.restoreDraft(for: summary.id)
                chatController.beginTyping()
            }
        }
    }

    private static func isImport(_ link: ApelinLink) -> Bool {
        switch link {
        case .importRepository, .invalidImport: true
        default: false
        }
    }

    /// The import's confirmation; the project it opens, an imported one on
    /// a new conversation that sends nothing, or one that had the
    /// repository already as its link would open it.
    private func openImport(_ link: ApelinLink) {
        guard case let .importRepository(address, branch) = link else {
            RepositoryImportFlow.reportUnreadableLink()
            return
        }
        let request = RepositoryImportPlan.Request(address: address, branch: branch)
        RepositoryImportFlow.open(request, from: self) { [weak self] project, imported in
            guard let self else { return }
            guard imported else {
                open(.project(project.projectID ?? project.name))
                return
            }
            restoredChat = true
            sidebar.openCreatedProject(project)
        }
    }

    /// The bar items the root owns on the top page: the sidebar's button
    /// first on the leading side, and a new conversation last on the
    /// trailing side while the sidebar, which has one, is out of sight.
    /// One item per screen: a bar button item has one view, and a push
    /// draws the departing and the arriving bar together.
    private func syncBarItems() {
        guard let top = navigator.topViewController else { return }
        syncBarItems(on: top)
    }

    private func syncBarItems(on controller: UIViewController) {
        let item = controller.navigationItem
        let isRoot = navigator.viewControllers.first === controller
        var leading = (item.leftBarButtonItems ?? []).filter { !($0 is RootBarItem) }
        var trailing = (item.rightBarButtonItems ?? []).filter { !($0 is RootBarItem) }
        // narrow, a page pushed above the root goes back to it with its back
        // button; the drawer opens from the root
        if !isDrawer || isRoot {
            if leading.isEmpty {
                item.leftItemsSupplementBackButton = true
            }
            let shown = isSidebarShown
            leading.insert(
                RootBarItem(
                    image: UIImage(systemName: isDrawer ? "line.3.horizontal" : "sidebar.leading"),
                    primaryAction: UIAction { [weak self] _ in self?.toggleSidebar() },
                ).then {
                    $0.accessibilityLabel = shown
                        ? String(localized: "Hide Sidebar")
                        : String(localized: "Show Sidebar")
                },
                at: 0,
            )
        }
        if isRoot, !isSidebarShown {
            // the right bar's items run from the trailing edge in
            trailing.insert(
                RootBarItem(
                    image: UIImage(systemName: "square.and.pencil"),
                    primaryAction: UIAction { [weak self] _ in self?.sidebar.startNewChat() },
                ).then {
                    $0.accessibilityLabel = String(localized: "New Chat")
                },
                at: 0,
            )
        }
        item.leftBarButtonItems = leading.isEmpty ? nil : leading
        item.rightBarButtonItems = trailing.isEmpty ? nil : trailing
    }

    override var childForStatusBarStyle: UIViewController? {
        navigator
    }

    override var childForStatusBarHidden: UIViewController? {
        navigator
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        navigator
    }
}

extension RootInterfaceController: UINavigationControllerDelegate {
    func navigationController(
        _: UINavigationController,
        willShow viewController: UIViewController,
        animated _: Bool,
    ) {
        syncBarItems(on: viewController)
    }
}

extension RootInterfaceController: UIGestureRecognizerDelegate {
    /// Narrow only, and sideways: toward the trailing side (right, or left
    /// right to left) on a root page with the drawer closed, back on the
    /// shade with it open. Anything else is the page's: its scrolling, a
    /// selection's handles, content scrolled sideways (a code block, a
    /// table, the attachments) that this pan would move, and the swipe back
    /// on a pushed page.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, isDrawer, presentedViewController == nil else {
            return false
        }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        let outward = view.directionalOffset(velocity.x)
        if pan.view === shade {
            return outward < 0
        }
        let rightward = !view.laysOutRightToLeft
        var touched = navigator.view.hitTest(pan.location(in: navigator.view), with: nil)
        while let view = touched {
            if let text = view as? TextLabelView, text.selectionRange != nil {
                return false
            }
            if let scroll = view as? UIScrollView, scroll.scrollsSideways(underPanRightward: rightward) {
                return false
            }
            touched = view.superview
        }
        return drawerProgress == 0 && outward > 0 && navigator.viewControllers.count == 1
    }
}

/// The bar items `RootInterfaceController` puts on a page and takes back.
private final class RootBarItem: UIBarButtonItem {}

private extension UIScrollView {
    /// Whether a pan to the right (or left) would scroll this sideways: to
    /// the right, content scrolled away from its left end comes back; to
    /// the left, content with more of it on the right goes on.
    func scrollsSideways(underPanRightward rightward: Bool) -> Bool {
        if rightward {
            return contentOffset.x > -adjustedContentInset.left + 0.5
        }
        return contentOffset.x < contentSize.width + adjustedContentInset.right - bounds.width - 0.5
    }
}

/// Over the page while the drawer is out: dims it, and a tap on it puts
/// the drawer away. VoiceOver reads it as that button.
private final class DrawerShade: UIView {
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.25)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Hide Sidebar")
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    @objc private func close() {
        onClose?()
    }

    override func accessibilityActivate() -> Bool {
        onClose?()
        return true
    }
}
