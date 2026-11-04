import QuartzCore
import UIKit

/// When a list's change animates, after Fila's lists: data that lands within
/// `quietInterval` of whatever started it — the list's first fill, its last
/// change, the load it answers — simply appears, and so does the answer to
/// the list's first load, however long it took: the rows a page opens to are
/// not a change. An animated diff over a page still settling reads as rows
/// sliding about for no reason, and one that swaps a whole list for another
/// cross-fades the two into one. Only a list that has sat still on screen
/// for longer animates its change.
@MainActor
final class ListPacing {
    static let quietInterval: CFTimeInterval = 0.2

    private var startedAt: CFTimeInterval?
    @objc private dynamic var hasLoaded = false
    /// The first load began and nothing has answered it past the quiet
    /// interval yet.
    @objc private dynamic var awaitsFirstAnswer = false

    /// Starts the quiet interval now: the list is about to show other data
    /// (another project, a search), or its first fill went up.
    @objc dynamic func begin() {
        startedAt = CACurrentMediaTime()
    }

    /// A load for the list starts now: `begin()`, and the first one's
    /// answer appears without animation whenever it comes.
    @objc dynamic func beginLoad() {
        begin()
        if !hasLoaded {
            hasLoaded = true
            awaitsFirstAnswer = true
        }
    }

    /// Records a change applied to `view` now and answers whether it animates.
    @objc dynamic func animatesChange(in view: UIView) -> Bool {
        let now = CACurrentMediaTime()
        defer { startedAt = now }
        guard let startedAt, now - startedAt > Self.quietInterval else { return false }
        // a change inside the interval cannot tell a quick answer from the
        // load's own "loading" rows; the first one past it is the answer
        if awaitsFirstAnswer {
            awaitsFirstAnswer = false
            return false
        }
        return view.window != nil && !UIAccessibility.isReduceMotionEnabled
    }
}
