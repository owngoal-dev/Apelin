import UIKit

// A list's first data waits until the list is in a window at its own width,
// then goes in and is laid out in that same pass, without animation. Rows
// laid out any earlier are laid out at a width of zero, or at one the page
// does not keep, and whatever animation is running when the list reaches its
// width — a push, a sheet coming up — stretches every row to it. An apply
// without animation to a list that has not been laid out is no better: it is
// dropped until a later pass, and the rows slide in with the push.

/// The list's first data, waiting for the list's width.
@MainActor
final class FirstFill {
    @objc private dynamic var apply: (() -> Void)?
    private var completions: [() -> Void] = []
    /// The first data is in; from here on a list applies its changes itself.
    @objc private(set) dynamic var isDone = false

    /// Keeps `apply` as the list's first data, in place of any still
    /// waiting, and puts it in now if `list` is already at its width.
    @objc dynamic func schedule(_ apply: @escaping () -> Void, completion: (() -> Void)?, in list: UIScrollView) {
        self.apply = apply
        completion.map { completions.append($0) }
        list.setNeedsLayout()
        if Self.isReady(list) {
            UIView.performWithoutAnimation { list.layoutIfNeeded() }
        }
    }

    /// The list's `layoutSubviews`: `layout` runs as it is, unless the first
    /// data is waiting and the list has its width, when the data goes in
    /// first and both run without animation.
    @objc dynamic func layout(_ list: UIScrollView, _ layout: () -> Void) {
        guard let apply, Self.isReady(list) else {
            layout()
            return
        }
        self.apply = nil
        isDone = true
        let completions = completions
        self.completions = []
        UIView.performWithoutAnimation {
            apply()
            layout()
            completions.forEach { $0() }
        }
    }

    /// A list that comes into a window is laid out again for its data.
    @objc dynamic func moved(_ list: UIScrollView) {
        if apply != nil {
            list.setNeedsLayout()
        }
    }

    @objc private dynamic static func isReady(_ list: UIScrollView) -> Bool {
        list.window != nil && list.bounds.width > 0
    }
}

/// Every table with a diffable data source is one of these, so its first
/// rows wait for its width (`FirstFill`).
final class FirstFillTableView: UITableView {
    let firstFill = FirstFill()

    @objc dynamic var isFilled: Bool {
        firstFill.isDone
    }

    override func layoutSubviews() {
        firstFill.layout(self) { super.layoutSubviews() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        firstFill.moved(self)
    }
}

/// `FirstFillTableView`'s collection view.
final class FirstFillCollectionView: UICollectionView {
    let firstFill = FirstFill()

    @objc dynamic var isFilled: Bool {
        firstFill.isDone
    }

    override func layoutSubviews() {
        firstFill.layout(self) { super.layoutSubviews() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        firstFill.moved(self)
    }
}

extension UITableViewDiffableDataSource {
    /// Fills `tableView` for the first time once it has its width, without
    /// animation, in place of a first fill still waiting. `completion` runs
    /// after the rows are laid out.
    func applyFirst(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>,
        to tableView: UITableView,
        completion: (() -> Void)? = nil,
    ) {
        guard let tableView = tableView as? FirstFillTableView else {
            assertionFailure("A table with a diffable data source is a FirstFillTableView")
            applySnapshotUsingReloadData(snapshot)
            completion?()
            return
        }
        tableView.firstFill.schedule({ [weak self] in
            self?.applySnapshotUsingReloadData(snapshot)
        }, completion: completion, in: tableView)
    }
}

extension UITableViewDiffableDataSource {
    /// Applies a change after the first fill. One that does not animate is
    /// laid out at once, without animation: rows it adds take their frames
    /// now, not in a later pass that a push or sheet still moving would
    /// carry in from a frame of zero.
    func applyChange(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>,
        to tableView: UITableView,
        animated: Bool,
        completion: (() -> Void)? = nil,
    ) {
        guard !animated else {
            apply(snapshot, animatingDifferences: true, completion: completion)
            return
        }
        UIView.performWithoutAnimation {
            apply(snapshot, animatingDifferences: false)
            tableView.layoutIfNeeded()
        }
        completion?()
    }
}

extension UICollectionViewDiffableDataSource {
    /// `UITableViewDiffableDataSource.applyChange`'s, without animation.
    func applyChange(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>,
        to collectionView: UICollectionView,
    ) {
        UIView.performWithoutAnimation {
            apply(snapshot, animatingDifferences: false)
            collectionView.layoutIfNeeded()
        }
    }

    /// Fills `collectionView` for the first time once it has its width,
    /// without animation, in place of a first fill still waiting.
    func applyFirst(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>,
        to collectionView: UICollectionView,
        completion: (() -> Void)? = nil,
    ) {
        guard let collectionView = collectionView as? FirstFillCollectionView else {
            assertionFailure("A collection view with a diffable data source is a FirstFillCollectionView")
            applySnapshotUsingReloadData(snapshot)
            completion?()
            return
        }
        collectionView.firstFill.schedule({ [weak self] in
            self?.applySnapshotUsingReloadData(snapshot)
        }, completion: completion, in: collectionView)
    }
}
