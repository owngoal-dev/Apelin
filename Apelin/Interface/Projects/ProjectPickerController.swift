import ApelinProtocol
import SnapKit
import Then
import UIKit

/// Which project the sidebar is about, in a sheet off its folder menu: one of
/// those in `Projects/`, the open one ticked, or a new one from the plus in
/// the bar.
final class ProjectPickerController: UIViewController {
    /// A project was picked, told once the sheet has gone, so the change
    /// it makes behind the sheet is seen.
    var onPick: ((ProjectSummary) -> Void)?
    /// A project made from the plus whose first conversation has a message
    /// to send (`NewProjectController`); without one it is picked.
    var onCreate: ((ProjectSummary, _ firstPrompt: String) -> Void)?
    var onDelete: ((ProjectSummary) async throws -> Void)?

    private var projects: [ProjectSummary]
    @objc private dynamic var current: String?

    @objc private dynamic lazy var collectionView = FirstFillCollectionView(
        frame: .zero,
        collectionViewLayout: makeLayout(),
    )

    @objc private dynamic func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let project = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let delete = UIContextualAction(
                style: .destructive,
                title: String(localized: "Delete"),
            ) { [weak self] _, _, completion in
                completion(false)
                self?.confirmDelete(project)
            }
            delete.image = UIImage(systemName: "trash")
            let actions = UISwipeActionsConfiguration(actions: [delete])
            actions.performsFirstActionWithFullSwipe = false
            return actions
        }
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private lazy var dataSource: UICollectionViewDiffableDataSource<String, ProjectSummary> = {
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, ProjectSummary> {
            [weak self] cell, _, project in
            var content = UIListContentConfiguration.cell()
            content.image = ProjectIcon.image(for: project)
            content.imageProperties.maximumSize = CGSize(width: 36, height: 36)
            content.imageProperties.reservedLayoutSize = CGSize(width: 36, height: 36)
            content.text = project.displayTitle
            content.textProperties.numberOfLines = 1
            content.textProperties.lineBreakMode = .byTruncatingTail
            cell.contentConfiguration = content
            let isOpen = project.name == self?.current
            cell.accessories = isOpen ? [.checkmark()] : []
            // the tick is drawn; the trait says it
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = project.displayTitle
            cell.accessibilityTraits = isOpen ? [.button, .selected] : .button
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader,
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            let kind = dataSource.snapshot().sectionIdentifiers[indexPath.section]
            let title = projects.first { $0.kind.rawValue == kind }?.kindName
            var content = UIListContentConfiguration.groupedHeader()
            content.text = title
            view.contentConfiguration = content
            view.isAccessibilityElement = true
            view.accessibilityLabel = title
            view.accessibilityTraits = .header
        }
        let source = UICollectionViewDiffableDataSource<String, ProjectSummary>(
            collectionView: collectionView,
        ) { collection, indexPath, project in
            collection.dequeueConfiguredReusableCell(using: row, for: indexPath, item: project)
        }
        source.supplementaryViewProvider = { collection, _, indexPath in
            collection.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        return source
    }()

    init(projects: [ProjectSummary], current: String?) {
        self.projects = projects
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(projects:current:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadProjects),
            name: .apelinProjectsChanged,
            object: nil,
        )
        title = String(localized: "Projects")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.openNewProject() },
        ).then { $0.accessibilityLabel = String(localized: "New Project") }
        collectionView.delegate = self
        collectionView.backgroundView = EmptyStateView(
            symbolName: "folder.fill",
            title: String(localized: "No Projects Yet"),
            text: String(localized: "Tap “+” to create a project."),
        )
        collectionView.backgroundView?.isHidden = !projects.isEmpty
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        applySnapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadProjects()
    }

    @objc private dynamic func reloadProjects() {
        Task { [weak self] in
            guard let self else { return }
            do {
                projects = try await ProjectSummary.load()
                applySnapshot()
            } catch { presentNotice(title: "Projects Unavailable", message: error.readableMessage) }
        }
    }

    @objc private dynamic func openNewProject() {
        let page = NewProjectController()
        page.onCreate = { [weak self] project, firstPrompt in
            if let firstPrompt, let onCreate = self?.onCreate {
                onCreate(project, firstPrompt)
            } else {
                self?.onPick?(project)
            }
        }
        navigationController?.pushViewController(page, animated: true)
    }

    @objc private dynamic func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<String, ProjectSummary>()
        let kinds: [DevelopmentExtensionKind] = [.workspace, .app, .tweak, .commandLineTool, .preferenceBundle]
        for kind in kinds {
            let matches = projects.filter { $0.kind == kind }
                .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
            guard !matches.isEmpty else { continue }
            snapshot.appendSections([kind.rawValue])
            snapshot.appendItems(matches, toSection: kind.rawValue)
        }
        collectionView.backgroundView?.isHidden = !projects.isEmpty
        if !collectionView.isFilled {
            dataSource.applyFirst(snapshot, to: collectionView)
        } else {
            let currentSnapshot = dataSource.snapshot()
            // Deleting also publishes a catalog notification. Its identical
            // result must not interrupt the removal animation already running.
            guard currentSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
                || currentSnapshot.itemIdentifiers != snapshot.itemIdentifiers
            else { return }
            let animated = collectionView.window != nil && !UIAccessibility.isReduceMotionEnabled
            dataSource.apply(snapshot, animatingDifferences: animated)
        }
    }

    private func confirmDelete(_ project: ProjectSummary) {
        presentConfirmation(
            title: "Delete Project?",
            message: "This permanently deletes “\(project.displayTitle)” and its files and chats from this device.",
            confirmTitle: "Delete",
            destructive: true,
        ) { [weak self] in
            guard let self, let onDelete else { return }
            navigationController?.isModalInPresentation = true
            collectionView.isUserInteractionEnabled = false
            navigationItem.leftBarButtonItem?.isEnabled = false
            navigationItem.rightBarButtonItem?.isEnabled = false
            Task {
                defer {
                    self.navigationController?.isModalInPresentation = false
                    self.collectionView.isUserInteractionEnabled = true
                    self.navigationItem.leftBarButtonItem?.isEnabled = true
                    self.navigationItem.rightBarButtonItem?.isEnabled = true
                }
                do {
                    try await onDelete(project)
                    self.projects.removeAll { $0.name == project.name }
                    if self.current == project.name {
                        self.current = nil
                    }
                    self.applySnapshot()
                } catch { self.presentNotice(title: "Unable to Delete Project", message: error.readableMessage) }
            }
        }
    }
}

extension ProjectPickerController: UICollectionViewDelegate {
    @objc dynamic func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let project = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: String(localized: "Rename Project…"),
                    image: UIImage(systemName: "pencil"),
                ) { [weak self] _ in
                    guard let self else { return }
                    ProjectActions.rename(project.name, from: self)
                },
                UIAction(
                    title: String(localized: "Delete"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive,
                ) { _ in
                    self?.confirmDelete(project)
                },
            ])
        }
    }

    @objc dynamic func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let project = dataSource.itemIdentifier(for: indexPath) else { return }
        dismiss(animated: true) { [onPick] in onPick?(project) }
    }
}
